#!/usr/bin/env python3
"""GlideLink bridge (docs/matlab_plan.md): the board's radio, shell and host port 1 over TCP, for
MATLAB (sw/matlab/+glidelink) or any client with sockets and JSON.

    python3 glidelink_bridge.py [--port 7030]

Runs on the board, instead of the offline services (glidelinkd@*, which own the routes): stop them
first, or use the glidelink-bridge service (Conflicts=). One client at a time.

Protocol: each request is one line of JSON, each reply one line of JSON; sample data follow a
line that gives their length in "bytes". Samples are CS16 (int16 I, Q interleaved, 12-bit full
scale = 2048, as Soapy); host port 1 data are 32-bit words.

  {"cmd": "info"}                                      -> driver, shell version, current settings
  {"cmd": "config", "rate": 1e6, "freq": 915e6, "rx_freq": .., "tx_freq": .., "bandwidth": 1e6,
   "rx_gain_mode": "slow_attack" | "fast_attack" | "manual", "rx_gain": 40, "tx_atten": 20,
   "loopback": 0 | 1}                                  -> the settings as read back
  {"cmd": "tx_cyclic", "bytes": n} + n bytes CS16      -> repeat the waveform until tx_stop
  {"cmd": "tx_stop"}
  {"cmd": "rx", "n": N}                                -> {"bytes": 4N} + N contiguous CS16 samples
                                                          (read on the board first, then sent)
  {"cmd": "host1", "n_out": M, "bytes": n} + n bytes   -> words through host port 1 (routes as set):
                                                          {"bytes": 4M} + M words back
  {"cmd": "route", "routes": {"slot0_in": "host1_tx", ...}}   sink: source (gr-glidelink names)
  {"cmd": "reg", "iface": "FPGA" | "AD9361", "addr": a, "value": v (omit to read)} -> {"value": ..}
"""
import argparse
import json
import os
import socket
import sys
import threading
import time

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CS16

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "offline"))
sys.path.insert(0, "/home/xilinx/claude/sdr/offline")
from glidelinkd import IioDev, SHELL_ROUTE, SHELL_PORT_RESET, SINKS, SOURCES, SINK_FLUSH  # noqa: E402

CHUNK = 65536


class Bridge:
    def __init__(self, a):
        self.a = a
        self.phy, self.shell = IioDev("ad9361-phy"), IioDev("glidelink-shell")
        self.dds = IioDev("cf-ad9361-dds-core-lpc")
        # the RF through host port 0 in both directions (an offline image routes it elsewhere)
        self.routes({"host0_rx": "rf_rx", "rf_tx": "host0_tx"})
        self.dev = SoapySDR.Device(a.args)
        self.tx_thread, self.tx_run = None, False

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
            p.attr("in_out_voltage_filter_fir_en", 0)   # an offline profile's FIR is for 20 MSPS only
            d.setSampleRate(SOAPY_SDR_RX, 0, float(r["rate"]))
            d.setSampleRate(SOAPY_SDR_TX, 0, float(r["rate"]))
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

    # ------------------------------------------------------------------ streams
    def tx_cyclic(self, data):
        self.tx_stop()
        iq = np.frombuffer(data, np.int16).copy()
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

    def tx_stop(self):
        self.tx_run = False
        if self.tx_thread is not None:
            self.tx_thread.join(5)
            self.tx_thread = None

    def rx(self, n):
        out = np.empty(2 * n, np.int16)
        s = self.dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], {"bufferLength": str(CHUNK)})
        self.dev.activateStream(s)
        got, t0 = 0, time.time()
        while got < n and time.time() - t0 < 10:
            r = self.dev.readStream(s, [out[2 * got:]], min(CHUNK, n - got), timeoutUs=1000000)
            if r.ret > 0:
                got += r.ret
        self.dev.deactivateStream(s)
        self.dev.closeStream(s)
        return out[:2 * got].tobytes()

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
    def handle(self, f):
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
                if cmd == "info":
                    reply({"ok": True, "driver": "glidelink", "shell": f"{self.shell.reg(0x004):08X}",
                           **self.settings()})
                elif cmd == "config":
                    reply({"ok": True, **self.config(r)})
                elif cmd == "tx_cyclic":
                    self.tx_cyclic(data)
                    reply({"ok": True, "samples": len(data) // 4})
                elif cmd == "tx_stop":
                    self.tx_stop()
                    reply({"ok": True})
                elif cmd == "rx":
                    reply({"ok": True}, self.rx(int(r["n"])))
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
            except Exception as e:                       # noqa: BLE001  (reported to the client)
                reply({"ok": False, "error": str(e)})

    def serve(self):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("", self.a.port))
        srv.listen(1)
        print(f"glidelink bridge on port {self.a.port}", flush=True)
        while True:
            c, addr = srv.accept()
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            print(f"client {addr[0]}", flush=True)
            try:
                self.handle(c.makefile("rwb"))
            except OSError:
                pass
            finally:
                self.tx_stop()
                c.close()
                print("client gone", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7030)
    ap.add_argument("--args", default="driver=glidelink")
    Bridge(ap.parse_args()).serve()


if __name__ == "__main__":
    main()
