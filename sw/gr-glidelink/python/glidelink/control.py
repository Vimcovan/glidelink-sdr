#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""GlideLink control: connections inside the PL shell, driver parameters and registers.

The block has no streams. It opens its own SoapySDR device (control only, the
RF streams stay with gr-soapy's source / sink) and

- sets the stream switch routes (sink <- source, by name);
- writes settings in order: AD9361 driver parameters ("adi,...", see
  SoapySDRUtil --probe), "gain_control_mode", and "initialize" (true re-initialises
  the AD9361 with the parameters as now set, keeping frequency, rate, gains);
- writes registers, given as "AD9361:0x101" / "FPGA:0x2010" = value;
- reads back a list of items (setting keys or register names) every interval and
  sends them as a dictionary on the "status" message port.

At run time: set_settings() (the GRC callback of the settings parameter) writes
the entries that changed and re-initialises when the dictionary asks for it;
a dictionary on the "cmd" message port is applied the same way, with
"route:<sink>" keys for routes and "AD9361:<addr>" / "FPGA:<addr>" keys for
registers. read(item) returns one item for a function probe.
"""
import threading

import pmt
import SoapySDR
from gnuradio import gr

# switch ports: 0 RF, 1 host port 0, 2 slot 0, 3 host port 1, 3 + k slot k (k >= 1);
# an image has 1 to 11 slots (shell CAPS[31:24])
_slot_port = lambda k: 2 if k == 0 else 3 + k
SINKS = {"rf_tx": 0, "host0_rx": 1, "host1_rx": 3, **{f"slot{k}_in": _slot_port(k) for k in range(11)}}
SOURCES = {"rf_rx": 0, "host0_tx": 1, "host1_tx": 3, **{f"slot{k}_out": _slot_port(k) for k in range(11)},
           "none": 15}
REG_ROUTE, REG_PORT_RESET = 0x1000, 0x05C
# PORT_RESET bit that flushes each sink: RF TX (with the TX streamer), host 0 RX,
# host 1 RX, slot k (its stream state; registers are kept)
SINK_FLUSH = {0: 1 << 1, 1: 1 << 0, 3: 1 << 3, **{_slot_port(k): 1 << (2 if k == 0 else 4 + k) for k in range(11)}}
INTERFACES = ("AD9361", "FPGA")


def _str(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def _register(item):
    """'AD9361:0x101' -> ('AD9361', 0x101), anything else -> None"""
    iface, _, addr = item.partition(":")
    if iface in INTERFACES and addr:
        return iface, int(addr, 0)
    return None


class control(gr.basic_block):
    def __init__(self, args="driver=glidelink", routes=None, settings=None, registers=None,
                 readback=None, interval=1.0):
        gr.basic_block.__init__(self, name="GlideLink Control", in_sig=None, out_sig=None)
        self.dev = SoapySDR.Device(args)
        self.lock = threading.Lock()
        self.readback = list(readback or [])
        self.interval = interval
        self.applied = {}
        self.stop_event = threading.Event()
        self.thread = None

        self.message_port_register_in(pmt.intern("cmd"))
        self.set_msg_handler(pmt.intern("cmd"), self.handle_cmd)
        self.message_port_register_out(pmt.intern("status"))

        for sink, source in (routes or {}).items():
            self.set_route(sink, source)
        self.set_settings(settings or {})
        for name, value in (registers or {}).items():
            self.write_register(name, value)

    # routes

    def set_route(self, sink, source):
        """Route sink <- source. When the route changes, the sink is flushed too (PORT_RESET):
        a sink takes a new route only between packets, and one stalled inside a packet (e.g.
        a host port nobody reads) would otherwise never get there."""
        s = SOURCES[source] if isinstance(source, str) else int(source)
        j = SINKS[sink]
        with self.lock:
            if self.dev.readRegister("FPGA", REG_ROUTE + 4 * j) == s:
                return
            self.dev.writeRegister("FPGA", REG_ROUTE + 4 * j, s)
            self.dev.writeRegister("FPGA", REG_PORT_RESET, SINK_FLUSH[j])

    def get_route(self, sink):
        with self.lock:
            s = self.dev.readRegister("FPGA", REG_ROUTE + 4 * SINKS[sink])
        return next((k for k, v in SOURCES.items() if v == s), str(s))

    # settings

    def set_settings(self, settings):
        """Write the entries that differ from what was last written (all of them the
        first time), then re-initialise if "initialize" is true and something changed
        (or the dictionary is nothing but "initialize")."""
        changed = False
        init = False
        for key, value in settings.items():
            value = _str(value)
            if key == "initialize":
                init = value in ("true", "1")
                continue
            if self.applied.get(key) != value:
                self.write_setting(key, value)
                changed = True
        if init and (changed or len(settings) == 1):
            self.initialize()

    def write_setting(self, key, value):
        with self.lock:
            self.dev.writeSetting(key, _str(value))
        self.applied[key] = _str(value)

    def read_setting(self, key):
        with self.lock:
            return self.dev.readSetting(key)

    def initialize(self):
        with self.lock:
            self.dev.writeSetting("initialize", "true")

    # registers

    def write_register(self, name, value):
        iface, addr = _register(name)
        with self.lock:
            self.dev.writeRegister(iface, addr, int(value))

    def read_register(self, name):
        iface, addr = _register(name)
        with self.lock:
            return self.dev.readRegister(iface, addr)

    # read back

    def read(self, item):
        """One item: a register name ("AD9361:0x101") gives an int, "route:<sink>"
        the source's name, anything else a setting's value."""
        if _register(item):
            return self.read_register(item)
        if item.startswith("route:"):
            return self.get_route(item[6:])
        return self.read_setting(item)

    def status(self):
        return {item: self.read(item) for item in self.readback}

    def publish(self):
        d = pmt.make_dict()
        for k, v in self.status().items():
            d = pmt.dict_add(d, pmt.intern(k), pmt.from_long(v) if isinstance(v, int) else pmt.intern(str(v)))
        self.message_port_pub(pmt.intern("status"), d)

    def poll(self):
        while not self.stop_event.wait(self.interval):
            try:
                self.publish()
            except Exception as e:      # keep polling through a re-initialisation
                gr.log.warn(f"GlideLink Control: read back failed: {e}")

    def start(self):
        if self.readback and self.interval > 0:
            self.stop_event.clear()
            self.thread = threading.Thread(target=self.poll, daemon=True)
            self.thread.start()
        return True

    def stop(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join()
        return True

    # messages

    def handle_cmd(self, msg):
        if not pmt.is_dict(msg):
            gr.log.warn("GlideLink Control: cmd must be a dictionary")
            return
        settings = {}
        for k, v in pmt.to_python(msg).items():
            k = str(k)
            if k.startswith("route:"):
                self.set_route(k[6:], v)
            elif _register(k):
                self.write_register(k, v)
            else:
                settings[k] = v
        if settings:
            self.set_settings(settings)
        if self.readback:
            self.publish()
