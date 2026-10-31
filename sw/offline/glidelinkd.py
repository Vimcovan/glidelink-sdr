#!/usr/bin/env python3
"""GlideLink offline daemon (docs/phase4_plan.md, 4.6): brings a board up from a configuration file
and keeps it running without a PC.

    python3 glidelinkd.py config/rx.yaml [--once]

At start, in this order:
  1. overlay: load the image (hw/scripts/load_overlay.sh) unless it is already applied;
  2. AD9361 through the ADI driver (sysfs): FIR file with clock chain and bandwidths, LO
     frequencies, RF bandwidths, RX gain mode / gain, TX attenuation, TX LO power down, then
     register writes from a file (e.g. the competition's fast-attack AGC block); finally the DAC
     data source of both TX channels is set to the shell (axi_ad9361 0x418 / 0x458 = 2): a rate or
     FIR change resets the interface core, which puts it back to its DDS default;
  3. module registers (CONTROL etc.), then the stream switch routes; a sink whose route changes is
     flushed (PORT_RESET), as gr-glidelink's control block does.
Then, every poll interval:
  - AGC watchdog (when configured): the fast-attack AGC sometimes stays locked at too low a gain
    when the signal gets weaker, and the receiver stops synchronising. If a module counter (e.g.
    ofdm_rx FRAMES_IN) grew by less than min_rate per second over the last stall_s seconds while the
    RX gain index is below the table maximum, the AGC state machine is reset (0x0FA = 0x05, then its
    configured value), at most once per holdoff_s (the competition's AgcGuard, on platform counters);
  - status: a JSON file (default /run/glidelink/status.json) with the counters, rates, RX gain and
    watchdog resets, for the applications and the GUI.

Every register access goes through debugfs direct_reg_access with a time limit: a PL bus fault
(seen once on the RX board, 2026-10-30) leaves the access hanging in the kernel; the daemon then
reports "hung" in the status file and the log instead of hanging itself.

Configuration (YAML), all sections optional:
  overlay:  {bit: ovl/glidelink23.bit, dtbo: ovl/glidelink23.dtbo, loader: load_overlay.sh}
  ad9361:   {fir: profiles/jscc_20msps.ftr, rx_lo_hz: 915e6, tx_lo_hz: 915e6,
             rx_rf_bandwidth_hz: 30e6, tx_rf_bandwidth_hz: 30e6, rx_gain_mode: fast_attack,
             rx_gain_db: 40, tx_attenuation_db: 4, tx_lo_powerdown: false,
             registers: profiles/jscc_agc_rx.txt}
  modules:  {slot1: {0x008: 0x3}}                       slot register writes (offset: value)
  routes:   {slot1_in: rf_rx, host1_rx: slot2_out}      sink: source (gr-glidelink names)
  watchdog: {slot: 1, counter: 0x010, min_rate: 5, stall_s: 0.5, holdoff_s: 3}
  status:   {path: /run/glidelink/status.json, counters: {rx_frames: [1, 0x010]}, poll_s: 0.1}
Relative paths are taken from the configuration file's directory.
"""
import argparse
import collections
import json
import os
import socket
import subprocess
import sys
import threading
import time

import yaml

SHELL_ROUTE, SHELL_PORT_RESET = 0x1000, 0x05C
_slot_port = lambda k: 2 if k == 0 else 3 + k
SINKS = {"rf_tx": 0, "host0_rx": 1, "host1_rx": 3, **{f"slot{k}_in": _slot_port(k) for k in range(11)}}
SOURCES = {"rf_rx": 0, "host0_tx": 1, "host1_tx": 3, **{f"slot{k}_out": _slot_port(k) for k in range(11)},
           "none": 15}
SINK_FLUSH = {0: 1 << 1, 1: 1 << 0, 3: 1 << 3, **{_slot_port(k): 1 << (2 if k == 0 else 4 + k) for k in range(11)}}
SLOT_BASE = lambda k: 0x2000 + 0x1000 * k               # slot k register window in the shell's space


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def sd_notify(msg):
    """systemd readiness (Type=notify): the application services start after READY=1"""
    addr = os.environ.get("NOTIFY_SOCKET")
    if addr:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.connect("\0" + addr[1:] if addr.startswith("@") else addr)
        s.sendall(msg.encode())
        s.close()


class Hung(Exception):
    pass


def timed(fn, timeout=2.0):
    """runs fn() in a worker thread; Hung if it does not return in time (the thread stays blocked)"""
    box = {}

    def run():
        try:
            box["v"] = fn()
        except Exception as e:                          # noqa: BLE001  (passed on to the caller)
            box["e"] = e
    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        raise Hung(getattr(fn, "__name__", "access"))
    if "e" in box:
        raise box["e"]
    return box.get("v")


class IioDev:
    """one IIO device by name: sysfs attributes and debugfs registers, time-limited"""

    def __init__(self, name):
        for n in range(32):
            p = f"/sys/bus/iio/devices/iio:device{n}"
            if os.path.exists(p + "/name") and open(p + "/name").read().strip() == name:
                self.sys, self.dbg = p, f"/sys/kernel/debug/iio/iio:device{n}"
                break
        else:
            raise RuntimeError(f"IIO device {name} not found")
        self.lock = threading.Lock()

    def attr(self, name, value=None):
        path = os.path.join(self.sys, name)

        def acc():
            if value is None:
                return open(path).read().strip()
            with open(path, "w") as f:
                f.write(str(value))
        with self.lock:
            return timed(acc, 10.0)                     # rate / FIR changes take ~1 s

    def reg(self, addr, value=None):
        path = os.path.join(self.dbg, "direct_reg_access")

        def acc():
            with open(path, "w") as f:
                f.write(f"0x{addr:X}" if value is None else f"0x{addr:X} 0x{value:X}")
            if value is None:
                return int(open(path).read().strip(), 0)
        with self.lock:
            return timed(acc)


def write_file(dev, path):
    """FIR file -> filter_fir_config (the driver parses the whole file in one write)"""
    data = open(path).read()
    with dev.lock:
        def acc():
            with open(os.path.join(dev.sys, "filter_fir_config"), "w") as f:
                f.write(data)
        timed(acc, 10.0)


class Daemon:
    def __init__(self, cfg_path):
        self.base = os.path.dirname(os.path.abspath(cfg_path))
        self.cfg = yaml.safe_load(open(cfg_path)) or {}
        self.status = {"config": os.path.abspath(cfg_path), "started": time.time(), "state": "starting"}
        self.phy = self.shell = None

    def path(self, p):
        return p if os.path.isabs(p) else os.path.join(self.base, p)

    # ------------------------------------------------------------------ bring-up
    def overlay(self):
        ov = self.cfg.get("overlay")
        if not ov:
            return
        name = os.path.splitext(os.path.basename(ov["bit"]))[0]
        applied = os.listdir("/sys/kernel/config/device-tree/overlays") if os.path.isdir(
            "/sys/kernel/config/device-tree/overlays") else []
        if applied:
            if name not in applied:
                raise RuntimeError(f"overlay {applied} applied, configuration wants {name}: reboot first")
            log(f"overlay {name} already applied")
            return
        loader = self.path(ov.get("loader", "load_overlay.sh"))
        bit, dtbo = self.path(ov["bit"]), self.path(ov["dtbo"])
        log(f"loading overlay {name}")
        subprocess.run(["bash", loader, os.path.basename(bit), os.path.basename(dtbo)],
                       cwd=os.path.dirname(bit), check=True, timeout=180)

    def ad9361(self):
        c = self.cfg.get("ad9361")
        if not c:
            return
        p = self.phy
        if "rx_gain_mode" in c:
            # before the FIR: switching the FIR on recalibrates the receiver, and a mode change
            # after that (slow_attack at boot -> fast_attack) left the RX path ~20 dB weaker at the
            # AGC (gain index ~50 instead of ~29 at the same signal, a quarter of the frames lost)
            p.attr("in_voltage0_gain_control_mode", c["rx_gain_mode"])
        if "fir" in c:
            # the driver applies the file's clock chain (RRX / RTX) only when the FIR is switched on;
            # with the FIR already on (the bridge, libad9361) it loads the new taps and interpolation
            # but keeps the old chain (TF 80 MHz for a x2 FIR: the TX sends a broken signal)
            p.attr("in_out_voltage_filter_fir_en", 0)
            write_file(p, self.path(c["fir"]))
            p.attr("in_out_voltage_filter_fir_en", 1)
            for line in open(self.path(c["fir"])):
                f = line.split()
                if f and f[0] in ("RRX", "RTX"):
                    want = [int(x) for x in f[1:]]
                    have = [int(x.split(":")[1]) for x in
                            p.attr("rx_path_rates" if f[0] == "RRX" else "tx_path_rates").split()]
                    if have != want:
                        raise RuntimeError(f"AD9361 {f[0]} clock chain {have}, FIR file wants {want}")
        for key, attr in (("rx_lo_hz", "out_altvoltage0_RX_LO_frequency"),
                          ("tx_lo_hz", "out_altvoltage1_TX_LO_frequency"),
                          ("rx_rf_bandwidth_hz", "in_voltage_rf_bandwidth"),
                          ("tx_rf_bandwidth_hz", "out_voltage_rf_bandwidth")):
            if key in c:
                p.attr(attr, int(float(c[key])))
        if "rx_gain_mode" in c:
            p.attr("in_voltage0_gain_control_mode", c["rx_gain_mode"])
        if "rx_gain_db" in c and c.get("rx_gain_mode", "manual") == "manual":
            p.attr("in_voltage0_hardwaregain", c["rx_gain_db"])
        if "tx_attenuation_db" in c:
            p.attr("out_voltage0_hardwaregain", -float(c["tx_attenuation_db"]))
        if "tx_lo_powerdown" in c:
            p.attr("out_altvoltage1_TX_LO_powerdown", int(bool(c["tx_lo_powerdown"])))
        self.agc_cfg = None
        if "registers" in c:
            n = 0
            for line in open(self.path(c["registers"])):
                line = line.split("#")[0].split()
                if len(line) == 2:
                    a, v = int(line[0], 0), int(line[1], 0)
                    p.reg(a, v)
                    if a == 0x0FA:
                        self.agc_cfg = v                # the last 0x0FA write: the gain control mode
                    n += 1
            log(f"AD9361: {n} register writes from {c['registers']}")
        dds = IioDev("cf-ad9361-dds-core-lpc")
        for ch in (0x418, 0x458):                       # DAC data select: 2 = DMA / shell input
            dds.reg(ch, 2)
        rates = p.attr("rx_path_rates")
        log(f"AD9361: {rates}; RX LO {p.attr('out_altvoltage0_RX_LO_frequency')}, gain mode "
            f"{p.attr('in_voltage0_gain_control_mode')}, TX gain {p.attr('out_voltage0_hardwaregain')}")
        self.status["ad9361"] = {"rx_path_rates": rates}

    def modules(self):
        for slot, writes in (self.cfg.get("modules") or {}).items():
            k = int(str(slot).replace("slot", ""))
            ident = self.shell.reg(SLOT_BASE(k))
            for off, v in writes.items():
                self.shell.reg(SLOT_BASE(k) + int(off), int(v))
            log(f"slot {k} (ID {ident:08X}): {len(writes)} register writes")

    def routes(self):
        flush = 0
        for sink, source in (self.cfg.get("routes") or {}).items():
            s, src = SINKS[sink], SOURCES[source]
            if self.shell.reg(SHELL_ROUTE + 4 * s) != src:
                self.shell.reg(SHELL_ROUTE + 4 * s, src)
                flush |= SINK_FLUSH.get(s, 0)
            log(f"route {sink} <- {source}")
        if flush:
            self.shell.reg(SHELL_PORT_RESET, flush)

    # ------------------------------------------------------------------ run
    def run(self, once=False):
        st = self.cfg.get("status") or {}
        out = st.get("path", "/run/glidelink/status.json")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        json.dump(self.status, open(out, "w"))          # "starting": the applications wait for "running"
        self.overlay()
        self.phy, self.shell = IioDev("ad9361-phy"), IioDev("glidelink-shell")
        self.status["shell_version"] = f"{self.shell.reg(0x004):08X}"
        self.ad9361()
        self.modules()
        self.routes()
        self.status["state"] = "running"
        log("up")
        sd_notify("READY=1")
        counters = {n: (int(s), int(o)) for n, (s, o) in (st.get("counters") or {}).items()}
        wd = self.cfg.get("watchdog")
        poll = float(st.get("poll_s", 0.1))
        hist = collections.deque()
        t_reset, resets, t_write = 0.0, 0, 0.0
        gmax = self.phy.reg(0x0FD) & 0x7F if wd else None
        while True:
            now = time.time()
            try:
                vals = {n: self.shell.reg(SLOT_BASE(s) + o) for n, (s, o) in counters.items()}
                if wd:
                    n = self.shell.reg(SLOT_BASE(int(wd["slot"])) + int(wd["counter"]))
                    g = self.phy.reg(0x109) & 0x7F                 # RX1 gain index (full table)
                    hist.append((now, n))
                    while len(hist) > 1 and now - hist[1][0] >= float(wd.get("stall_s", 0.5)):
                        hist.popleft()
                    t0, n0 = hist[0]
                    span = now - t0
                    rate = (n - n0) % 2 ** 32 / span if span > 0 else 0.0
                    stalled = span >= float(wd.get("stall_s", 0.5)) and rate < float(wd.get("min_rate", 5))
                    if stalled and g < gmax and now - t_reset > float(wd.get("holdoff_s", 3)):
                        self.phy.reg(0x0FA, 0x05)
                        self.phy.reg(0x0FA, self.agc_cfg if self.agc_cfg is not None else 0xE5)
                        t_reset, resets = now, resets + 1
                        log(f"AGC watchdog: {rate:.1f}/s over {span:.1f} s, gain {g} < {gmax}: reset #{resets}")
                    self.status["watchdog"] = {"rate": round(rate, 1), "gain_index": g, "gain_max": gmax,
                                               "stalled": stalled, "resets": resets}
                self.status.update(counters=vals, time=now, state="running")
            except Hung as e:
                self.status.update(state="hung", hung=str(e), time=now)
                log(f"register access hung ({e}): PL bus fault? the board needs a reboot")
            if now - t_write >= 0.5:
                tmp = out + ".tmp"
                json.dump(self.status, open(tmp, "w"))
                os.replace(tmp, out)
                t_write = now
            if once or self.status["state"] == "hung":
                return 0 if self.status["state"] == "running" else 1
            time.sleep(poll)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    ap.add_argument("--once", action="store_true", help="bring up, write the status once, exit")
    a = ap.parse_args()
    sys.exit(Daemon(a.config).run(a.once))


if __name__ == "__main__":
    main()
