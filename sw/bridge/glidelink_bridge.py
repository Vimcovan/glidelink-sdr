#!/usr/bin/env python3
"""GlideLink bridge (docs/matlab_plan.md): the board's radio, shell and host port 1 over TCP, for
MATLAB (sw/matlab/+glidelink) or any client with sockets and JSON. A fixed service: scripts use its
commands, they never need to change it.

    python3 glidelink_bridge.py [--port 7030] [--image <bit file>]

Started by the glidelink-bridge service (sw/bridge/install.sh). Without an overlay loaded it loads
--image first (load_overlay.sh). It cannot run together with the offline services (glidelinkd@*,
which own the routes; the service units conflict). Several clients may be connected; their commands
run one at a time.

Protocol (version PROTOCOL, additions PROTOCOL_REV): each request is one line of JSON, each reply one line of JSON with
"ok" (and "error" when false); data follow a reply line that gives their length in "bytes", and
a request line likewise. Samples are CS16 (int16 I, Q interleaved, 12-bit full scale = 2048, as
Soapy); host port 1 data are 32-bit words.

  {"cmd": "info"}                     -> protocol, shell version, image, current settings
  {"cmd": "config", "rate": 1e6, "freq": 915e6, "rx_freq": .., "tx_freq": .., "bandwidth": 1e6,
   "rx_gain_mode": "slow_attack" | "fast_attack" | "hybrid" | "manual", "rx_gain": 40,
   "tx_atten": 20, "loopback": 0 | 1}  -> the settings as read back. Any rate from 0.52 to 61.44 MSPS
                                         (up to 40 MSPS with libad9361's FIR, above that the
                                         driver's filters alone); keys given are applied in this
                                         order, the others are left as they are
  {"cmd": "attr", "name": n, "value": v (omit to read)}   -> {"value": ..}: any attribute of the
                                         AD9361 driver: sysfs (e.g. "in_voltage0_rssi") or debugfs
                                         ("adi,agc-inner-thresh-high", ..., "initialize" = 1 re-runs
                                         the driver's setup with them; rate, LOs, bandwidth, gain
                                         mode / gain and TX attenuation are kept, unless their own
                                         device-tree parameter was written)
  {"cmd": "tx_cyclic", "bytes": n} + n bytes CS16      -> repeat the waveform until tx_stop;
                                         {"mode": "hardware"}: from a cyclic DMA buffer (any rate,
                                         no CPU; up to CYCLIC_MAX samples), else "stream" (written
                                         by a thread, up to about 20 MSPS)
  {"cmd": "tx_stop"}
  {"cmd": "tx_burst", "bytes": n, "delay": s} + CS16   -> one burst at hardware time now + s (or
                                                          "time": ns), ended (end of burst); returns
                                                          once queued, so bursts can be scheduled
                                                          ahead; tx_stop cancels what is left
  {"cmd": "time"}                     -> {"time": ns}: the shell's hardware time (sample clock)
  {"cmd": "rx", "n": N}               -> {"bytes": 4N} + N CS16 samples (read on the board
                                         first, then sent); {"time": ns} of the first sample;
                                         {"overflows": k, "dropped": d, "drops": [[i, m], ..]}:
                                         k gaps (from the packet times), d samples lost in all, the
                                         first DROPS_MAX as m samples lost before sample i. The
                                         samples are contiguous when k = 0. Captured in C
                                         (libglidelink_fast.so, up to 50 MSPS)
  {"cmd": "host1", "n_out": M, "bytes": n} + n bytes   -> words through host port 1 (routes as set):
                                                          {"bytes": 4M} + M words back
  {"cmd": "route", "routes": {"slot0_in": "host1_tx", ...}}   sink: source (gr-glidelink names);
                                         a source that fed another sink is taken from it
  {"cmd": "reg", "iface": "FPGA" | "AD9361", "addr": a, "value": v (omit to read)} -> {"value": ..}
"""
import argparse
import json
import queue
import os
import socket
import sys
import threading
import time

import ctypes
import subprocess

import numpy as np
import SoapySDR
from SoapySDR import (SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CS16, SOAPY_SDR_HAS_TIME,
                      SOAPY_SDR_END_BURST)

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "offline"))
sys.path.insert(0, "/home/xilinx/claude/sdr/offline")
from glidelinkd import IioDev, SHELL_ROUTE, SHELL_PORT_RESET, SINKS, SOURCES, SINK_FLUSH, timed  # noqa: E402

CHUNK = 65536
PROTOCOL = 1
# fields added within protocol 1 (old clients ignore them): 1 = rx drops ("overflows", "dropped",
# "drops"), tx_cyclic "mode", info "fast"
PROTOCOL_REV = 1
HERE = os.path.dirname(os.path.abspath(__file__))
CYCLIC_MAX = 1 << 23             # samples (32 MB) in the TX cyclic buffer; longer: streamed
DROPS_MAX = 64


def load_fast():
    """the C paths (glidelink_fast.c), None if the library is not built (then Python, <= 20 MSPS)"""
    path = os.path.join(HERE, "libglidelink_fast.so")
    if not os.path.exists(path):
        print("libglidelink_fast.so not found: RX and cyclic TX in Python (up to about 20 MSPS)", flush=True)
        return None
    lib = ctypes.CDLL(path, use_errno=True)
    ll, llp = ctypes.c_longlong, ctypes.POINTER(ctypes.c_longlong)
    lib.gl_rx.restype = ll
    lib.gl_rx.argtypes = [ctypes.c_void_p, ll, ll, ctypes.c_double, ctypes.c_double, ctypes.c_uint32,
                          llp, llp, llp, llp, llp, ctypes.c_int]
    lib.gl_tx_cyclic_start.restype = ctypes.c_void_p
    lib.gl_tx_cyclic_start.argtypes = [ctypes.c_void_p, ll, ctypes.c_uint32]
    lib.gl_tx_cyclic_stop.argtypes = [ctypes.c_void_p]
    return lib


def load_image(bit):
    """the overlay, unless one is applied (load_overlay.sh next to the image or in sw/offline)"""
    applied = os.listdir("/sys/kernel/config/device-tree/overlays")
    if applied:
        return applied[0]
    name = os.path.splitext(os.path.basename(bit))[0]
    loader = next(p for p in (os.path.join(os.path.dirname(bit), "..", "load_overlay.sh"),
                              os.path.join(HERE, "..", "offline", "load_overlay.sh"),
                              "/home/xilinx/claude/sdr/load_overlay.sh") if os.path.exists(p))
    print(f"loading image {name}", flush=True)
    subprocess.run(["bash", loader, os.path.basename(bit), name + ".dtbo"], cwd=os.path.dirname(bit),
                   check=True, timeout=180)
    return name


FIR_MAX_RATE = 40e6


def set_bb_rate(rate):
    """libad9361: rate with a FIR designed for it (the driver alone refuses rates below 2.08 MSPS)"""
    iio, lib = ctypes.CDLL("libiio.so.0"), ctypes.CDLL("libad9361.so.0")
    iio.iio_create_local_context.restype = ctypes.c_void_p
    iio.iio_context_find_device.restype = ctypes.c_void_p
    iio.iio_context_find_device.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    iio.iio_context_destroy.argtypes = [ctypes.c_void_p]
    lib.ad9361_set_bb_rate.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    ctx = iio.iio_create_local_context()
    try:
        ret = lib.ad9361_set_bb_rate(iio.iio_context_find_device(ctx, b"ad9361-phy"), int(rate))
    finally:
        iio.iio_context_destroy(ctx)
    if ret < 0:
        raise RuntimeError(f"ad9361_set_bb_rate({rate:g}): error {ret}")


class Bridge:
    def __init__(self, a):
        self.a = a
        self.image = load_image(a.image)
        self.phy, self.shell = IioDev("ad9361-phy"), IioDev("glidelink-shell")
        self.dds = IioDev("cf-ad9361-dds-core-lpc")
        # the RF through host port 0 in both directions (an offline image routes it elsewhere)
        self.routes({"host0_rx": "rf_rx", "rf_tx": "host0_tx"})
        self.dev = SoapySDR.Device(a.args)
        self.fast = load_fast()
        self.tx_thread, self.tx_run, self.tx_owner, self.burst = None, False, None, None
        self.cyclic = None                               # hardware cyclic TX buffer (C handle)
        self.dt_written = set()                          # device-tree parameters written since the last setup
        self.lock = threading.Lock()

    # ------------------------------------------------------------------ helpers
    def routes(self, routes):
        flush = 0
        for sink, source in routes.items():
            s = SINKS[sink]
            for other, v in SINKS.items():           # a source feeds one sink: free it elsewhere
                if other != sink and self.shell.reg(SHELL_ROUTE + 4 * v) == SOURCES[source] and source != "none":
                    self.shell.reg(SHELL_ROUTE + 4 * v, SOURCES["none"])
                    flush |= SINK_FLUSH.get(v, 0)
            if self.shell.reg(SHELL_ROUTE + 4 * s) != SOURCES[source]:
                self.shell.reg(SHELL_ROUTE + 4 * s, SOURCES[source])
                flush |= SINK_FLUSH.get(s, 0)
        if flush:
            self.shell.reg(SHELL_PORT_RESET, flush)

    def slots_on_path(self, port, rx):
        """PORT_RESET bits of the module slots chained upstream of sink `port` (rx) or downstream
        of source `port` (Soapy module slotsOnPath): flushed with the host port"""
        n = (self.shell.reg(0x008) >> 24) & 0xff
        route = [self.shell.reg(SHELL_ROUTE + 4 * j) for j in range(3 + n)]
        slot_of = {(2 if k == 0 else 3 + k): k for k in range(n)}
        bits, at = 0, port
        for _ in range(n):
            if rx:
                k = slot_of.get(route[at]) if at < len(route) else None
            else:
                k = next((slot_of.get(j) for j in range(len(route)) if route[j] == at), None)
            if k is None:
                break
            bits |= 1 << (2 if k == 0 else 4 + k)
            at = 2 if k == 0 else 3 + k
        return bits

    def settings(self):
        p = self.phy
        return {"rate": float(p.attr("in_voltage_sampling_frequency")),
                "rx_freq": float(p.attr("out_altvoltage0_RX_LO_frequency")),
                "tx_freq": float(p.attr("out_altvoltage1_TX_LO_frequency")),
                "bandwidth": float(p.attr("in_voltage_rf_bandwidth")),
                "rx_gain_mode": p.attr("in_voltage0_gain_control_mode"),
                "rx_gain": float(p.attr("in_voltage0_hardwaregain").split()[0]),
                "tx_atten": -float(p.attr("out_voltage0_hardwaregain").split()[0]),
                "rssi": float(p.attr("in_voltage0_rssi").split()[0])}

    def config(self, r):
        d, p = self.dev, self.phy
        if "rate" in r:
            if self.burst is not None and float(r["rate"]) != d.getSampleRate(SOAPY_SDR_TX, 0):
                self.close_burst()                       # the burst stream turns burst times into
                                                         # samples at the rate it was opened with
            rate = float(r["rate"])
            if rate > FIR_MAX_RATE:
                # libad9361 0.2 loads a fixed 96-tap FIR above 40 MSPS, with which RF RX is
                # unusable (measured at 46 to 50 MSPS: a quarter of the samples near full
                # scale); the driver alone (as the Soapy module sets the rate) is clean
                p.attr("in_out_voltage_filter_fir_en", 0)
                p.attr("in_voltage_sampling_frequency", int(round(rate)))
            else:
                set_bb_rate(rate)
        for key, direction in (("freq", None), ("rx_freq", SOAPY_SDR_RX), ("tx_freq", SOAPY_SDR_TX)):
            if key in r:
                for dr in ((SOAPY_SDR_RX, SOAPY_SDR_TX) if direction is None else (direction,)):
                    d.setFrequency(dr, 0, float(r[key]))
        if "bandwidth" in r:
            for dr in (SOAPY_SDR_RX, SOAPY_SDR_TX):
                d.setBandwidth(dr, 0, float(r["bandwidth"]))
        if "rx_gain_mode" in r:
            p.attr("in_voltage0_gain_control_mode", r["rx_gain_mode"])
        if "rx_gain" in r:
            p.attr("in_voltage0_gain_control_mode", "manual")
            p.attr("in_voltage0_hardwaregain", float(r["rx_gain"]))
        if "tx_atten" in r:
            p.attr("out_altvoltage1_TX_LO_powerdown", 0)
            p.attr("out_voltage0_hardwaregain", -float(r["tx_atten"]))
        if "loopback" in r:
            dbg = p.dbg + "/loopback"
            open(dbg, "w").write(str(int(r["loopback"])))
        return self.settings()

    def attr(self, name, value=None):
        """an AD9361 driver attribute: sysfs first, else debugfs (device tree parameters, initialize)"""
        if "/" in name or name.startswith("."):
            raise ValueError("attribute name only")
        path = os.path.join(self.phy.sys, name)
        if not os.path.exists(path):
            path = os.path.join(self.phy.dbg, name)
        if not os.path.exists(path):
            raise ValueError(f"no attribute {name}")

        def acc():
            if value is not None:
                with open(path, "w") as f:
                    f.write(str(value))
            return open(path).read().strip()
        if name == "initialize" and value is not None and int(value):
            # the driver's setup puts rate, LOs, bandwidths, gain mode and gains back to the device
            # tree values: keep the current ones, except those whose device-tree parameter the
            # client has written since the last setup (as the Soapy module does, phase 2 E2)
            keep = self.settings()
            restore = {"rate": keep["rate"]}
            for key, dt in (("rx_freq", "adi,rx-synthesizer-frequency-hz"),
                            ("tx_freq", "adi,tx-synthesizer-frequency-hz"),
                            ("bandwidth", "adi,rf-rx-bandwidth-hz"),
                            ("rx_gain_mode", "adi,gc-rx1-mode"),
                            ("tx_atten", "adi,tx-attenuation-mdB")):
                if dt not in self.dt_written:
                    restore[key] = keep[key]
            if keep["rx_gain_mode"] == "manual" and "adi,gc-rx1-mode" not in self.dt_written:
                restore["rx_gain"] = keep["rx_gain"]
                del restore["rx_gain_mode"]
            out = timed(acc, 30.0)
            self.dt_written.clear()
            self.config(restore)
            return out
        if name.startswith("adi,") and value is not None:
            self.dt_written.add(name)
        return timed(acc, 15.0)

    # ------------------------------------------------------------------ streams
    def tx_cyclic(self, data):
        """"hardware" (a cyclic DMA buffer) or "stream" (a thread writing it, up to about 20 MSPS)"""
        self.tx_stop()
        self.close_burst()
        iq = np.frombuffer(data, np.int16).copy()
        if self.fast is not None and 0 < len(iq) // 2 <= CYCLIC_MAX:
            if (len(iq) // 2) % 2:                       # 64-bit DMA words: two periods
                iq = np.tile(iq, 2)
            h = self.fast.gl_tx_cyclic_start(iq.ctypes.data, len(iq) // 2, self.slots_on_path(1, False))
            if h:
                self.cyclic = h
                for ch in (0x418, 0x458):                # DAC data from the DMA
                    self.dds.reg(ch, 2)
                return "hardware"
            print(f"cyclic buffer of {len(iq) // 2} samples: error {ctypes.get_errno()}, streaming", flush=True)
        self.tx_run = True

        def loop():
            s = self.dev.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CS16, [0], {"bufferLength": str(CHUNK)})
            self.dev.activateStream(s)
            for ch in (0x418, 0x458):               # DAC data from the shell (a rate change resets it)
                self.dds.reg(ch, 2)
            n = len(iq) // 2
            reps = max(1, CHUNK // n)                # whole waveform periods per write
            buf = np.tile(iq, reps)
            while self.tx_run:
                p = 0
                while p < len(buf) // 2 and self.tx_run:
                    r = self.dev.writeStream(s, [buf[2 * p:]], len(buf) // 2 - p, timeoutUs=1000000)
                    if r.ret <= 0:
                        break
                    p += r.ret
            self.dev.deactivateStream(s)
            self.dev.closeStream(s)
        self.tx_thread = threading.Thread(target=loop, daemon=True)
        self.tx_thread.start()
        return "stream"

    def tx_stop(self):
        self.close_burst()
        if self.cyclic is not None:
            self.fast.gl_tx_cyclic_stop(self.cyclic)
            self.cyclic = None
        self.tx_run = False
        if self.tx_thread is not None:
            self.tx_thread.join(5)
            self.tx_thread = None

    def rx(self, n):
        """(n CS16 samples, {"time": ns of the first or None, "overflows", "dropped", "drops"})"""
        out = np.empty(2 * n, np.int16)
        rate = self.dev.getSampleRate(SOAPY_SDR_RX, 0)
        timeout = max(10.0, 2.0 * n / rate)
        if self.fast is not None:
            # IIO buffers of about 5 ms (4 queued: 20 ms of slack for the capture loop), not much
            # longer than the capture (a buffer is only handed over when full)
            buflen = min(262144, max(8192, 1 << int(np.ceil(np.log2(rate * 0.005)))))
            buflen = min(buflen, (n + 4 * (n // 4096 + 2) + 7) // 8 * 8)
            ll = ctypes.c_longlong
            t, ovf, dropped = ll(), ll(), ll()
            pos, lens = (ll * DROPS_MAX)(), (ll * DROPS_MAX)()
            got = self.fast.gl_rx(out.ctypes.data, n, buflen, rate, timeout, self.slots_on_path(1, True),
                                  ctypes.byref(t), ctypes.byref(ovf), ctypes.byref(dropped), pos, lens, DROPS_MAX)
            if got < 0:
                raise RuntimeError(f"rx: error {-got} ({os.strerror(-got)})")
            k = min(ovf.value, DROPS_MAX)
            info = {"time": t.value if t.value >= 0 else None, "overflows": ovf.value,
                    "dropped": dropped.value, "drops": [[pos[j], lens[j]] for j in range(k)]}
            return out[:2 * got].tobytes(), info
        s = self.dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], {"bufferLength": str(CHUNK), "headers": "true"})
        self.dev.activateStream(s)
        got, t0, t_first, t_next = 0, time.time(), None, None
        info = {"overflows": 0, "dropped": 0, "drops": []}
        while got < n and time.time() - t0 < timeout:
            r = self.dev.readStream(s, [out[2 * got:]], min(CHUNK, n - got), timeoutUs=1000000)
            if r.ret > 0:
                if r.flags & SOAPY_SDR_HAS_TIME:
                    if got == 0:
                        t_first = r.timeNs
                    elif t_next is not None and r.timeNs > t_next + 1e9 / rate / 2:
                        lost = int(round((r.timeNs - t_next) * rate / 1e9))
                        info["overflows"] += 1
                        info["dropped"] += lost
                        if len(info["drops"]) < DROPS_MAX:
                            info["drops"].append([got, lost])
                    t_next = r.timeNs + r.ret * 1e9 / rate
                got += r.ret
        self.dev.deactivateStream(s)
        self.dev.closeStream(s)
        info["time"] = t_first
        return out[:2 * got].tobytes(), info

    def tx_burst(self, data, t_ns):
        """queues one timed burst and returns at once. A sender thread writes the queue to the TX
        stream in order: the DMA holds only a few buffers (one per burst) and a timed burst keeps
        its buffer until it has been sent, so writing from the request would block the client
        once a few bursts are scheduled ahead. The stream stays open until tx_stop, a cyclic
        transmission or the client leaves (which cancel what has not been sent)."""
        if self.tx_thread is not None or self.cyclic is not None:
            raise RuntimeError("cyclic TX running: tx_stop first")
        iq = np.frombuffer(data, np.int16)
        if (len(iq) // 2) % 2:                           # the DMA moves 64-bit words: a packet of
            iq = np.concatenate([iq, np.zeros(2, np.int16)])   # 4 header words + an odd number of
        if self.burst is None:                           # samples is not sent; one zero sample pads it
            self.burst = self.dev.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CS16, [0], {"bufferLength": str(CHUNK),
                                                                                  "headers": "true"})
            self.dev.activateStream(self.burst)           # packet headers carry the time (raw: none)
            for ch in (0x418, 0x458):
                self.dds.reg(ch, 2)
            self.burst_q = queue.Queue()
            self.burst_thread = threading.Thread(target=self.burst_sender, args=(self.burst, self.burst_q),
                                                 daemon=True)
            self.burst_thread.start()
        self.burst_q.put((iq, t_ns))
        return len(iq) // 2

    def burst_sender(self, stream, q):
        while True:
            item = q.get()
            if item is None:
                return
            iq, t_ns = item
            n, p, flags = len(iq) // 2, 0, SOAPY_SDR_HAS_TIME
            while p < n:
                k = min(CHUNK, n - p)
                r = self.dev.writeStream(stream, [iq[2 * p:]], k,
                                         flags | (SOAPY_SDR_END_BURST if p + k == n else 0), t_ns, timeoutUs=500000)
                if r.ret == SoapySDR.SOAPY_SDR_TIMEOUT:
                    if q.queue and q.queue[-1] is None:  # closing: give up on this burst
                        break
                    continue                             # waiting for an earlier burst's buffer
                if r.ret <= 0:
                    print(f"burst: writeStream {r.ret}", flush=True)
                    break
                p += r.ret
                flags = 0                                # the time applies to the first sample only

    def close_burst(self):
        if self.burst is not None:
            with self.burst_q.mutex:
                self.burst_q.queue.clear()               # cancel what has not been written
            self.burst_q.put(None)
            self.burst_thread.join(5)
            self.dev.deactivateStream(self.burst)
            self.dev.closeStream(self.burst)
            self.burst = None

    def host1(self, data, n_out):
        args = {"port": "1", "headers": "false", "bufferLength": str(CHUNK)}
        rx = self.dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], args)
        tx = self.dev.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CS16, [0], args)
        self.dev.activateStream(rx)
        self.dev.activateStream(tx)
        words = np.frombuffer(data, np.uint32)
        got = np.zeros(n_out, np.uint32)
        pos = [0]

        def reader():
            buf = np.empty(CHUNK, np.uint32)
            t0 = time.time()
            while pos[0] < n_out and time.time() - t0 < 10:
                r = self.dev.readStream(rx, [buf.view(np.int16)], min(CHUNK, n_out - pos[0]), timeoutUs=1000000)
                if r.ret > 0:
                    got[pos[0]:pos[0] + r.ret] = buf[:r.ret]
                    pos[0] += r.ret
        th = threading.Thread(target=reader)
        th.start()
        p = 0
        while p < len(words):
            r = self.dev.writeStream(tx, [words[p:].view(np.int16)], min(CHUNK, len(words) - p), timeoutUs=2000000)
            if r.ret <= 0:
                break
            p += r.ret
        th.join(15)
        for st in (rx, tx):
            self.dev.deactivateStream(st)
            self.dev.closeStream(st)
        return got[:pos[0]].tobytes()

    # ------------------------------------------------------------------ protocol
    def handle(self, f, who):
        def reply(obj, payload=b""):
            if payload:
                obj["bytes"] = len(payload)
            f.write((json.dumps(obj) + "\n").encode() + payload)
            f.flush()

        for line in f:
            try:
                r = json.loads(line)
                cmd = r.get("cmd")
                data = f.read(int(r["bytes"])) if "bytes" in r else b""
                with self.lock:                          # clients take turns on the board
                    self.command(cmd, r, data, reply, who)
            except Exception as e:                       # noqa: BLE001  (reported to the client)
                reply({"ok": False, "error": str(e)})

    def command(self, cmd, r, data, reply, who):
        if cmd == "info":
            reply({"ok": True, "protocol": PROTOCOL, "protocol_rev": PROTOCOL_REV, "driver": "glidelink", "image": self.image,
                   "shell": f"{self.shell.reg(0x004):08X}", "fast": self.fast is not None, **self.settings()})
        elif cmd == "config":
            reply({"ok": True, **self.config(r)})
        elif cmd == "tx_cyclic":
            mode = self.tx_cyclic(data)
            self.tx_owner = who
            reply({"ok": True, "samples": len(data) // 4, "mode": mode})
        elif cmd == "tx_stop":
            self.tx_stop()
            reply({"ok": True})
        elif cmd == "rx":
            data, info = self.rx(int(r["n"]))
            if info["overflows"]:
                print(f"rx: {info['overflows']} gaps, {info['dropped']} samples lost", flush=True)
            reply({"ok": True, **info}, data)
        elif cmd == "attr":
            reply({"ok": True, "value": self.attr(r["name"], r.get("value"))})
        elif cmd == "time":
            reply({"ok": True, "time": self.dev.getHardwareTime()})
        elif cmd == "tx_burst":
            t = int(r["time"]) if "time" in r else self.dev.getHardwareTime() + int(float(r.get("delay", 0.1)) * 1e9)
            reply({"ok": True, "samples": self.tx_burst(data, t), "time": t})
            self.tx_owner = who
        elif cmd == "host1":
            reply({"ok": True}, self.host1(data, int(r["n_out"])))
        elif cmd == "route":
            self.routes(r["routes"])
            reply({"ok": True})
        elif cmd == "reg":
            dev = self.shell if r.get("iface", "FPGA") == "FPGA" else self.phy
            if "value" in r:
                dev.reg(int(r["addr"]), int(r["value"]))
            reply({"ok": True, "value": dev.reg(int(r["addr"]))})
        else:
            reply({"ok": False, "error": f"unknown command {cmd}"})

    def client(self, c, addr):
        print(f"client {addr[0]}:{addr[1]}", flush=True)
        f = c.makefile("rwb")
        try:
            self.handle(f, (c, addr))
        except OSError:
            pass
        finally:
            with self.lock:
                if self.tx_owner == (c, addr):           # its cyclic TX ends with it
                    self.tx_stop()
            c.close()
            print(f"client {addr[0]}:{addr[1]} gone", flush=True)

    def serve(self):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("", self.a.port))
        srv.listen(8)
        print(f"glidelink bridge on port {self.a.port}", flush=True)
        while True:
            c, addr = srv.accept()
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=self.client, args=(c, addr), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7030)
    ap.add_argument("--args", default="driver=glidelink")
    ap.add_argument("--image", default="/home/xilinx/claude/sdr/offline/ovl/glidelink_rx.bit",
                    help="image loaded when no overlay is applied (with its .dtbo / .hwh next to it)")
    Bridge(ap.parse_args()).serve()


if __name__ == "__main__":
    main()
