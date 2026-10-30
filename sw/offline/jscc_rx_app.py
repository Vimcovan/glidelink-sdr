#!/usr/bin/env python3
"""DeepJSCC-Q receiver application (docs/phase4_plan.md 4.6): decoder -> host port 1 -> images.

Runs on the RX board with glidelinkd (config/rx.yaml routes RF -> ofdm_rx -> jscc_dec -> host1_rx).
Reads host port 1 with packet headers: an image is one stream packet of 49,152 words (tlast from
the decoder), delivered in parts of up to 8192 words that Soapy marks MORE_FRAGMENTS until the
last; a packet of any other length (data lost) is dropped and counted.

    python3 jscc_rx_app.py [--port 7021] [--ctrl 7022] [--save /run/glidelink/rx_latest.npy]

Image stream (TCP --port): a client gets every decoded image as a 16-byte header
<magic "JRX1", frame number u32, board time of arrival f64> followed by 196,608 bytes (256x256x3
uint8, NHWC).
Control (TCP --ctrl, one line per command):
    time              -> "time <board time>"                             clock offset estimate
    symbols <n>       -> "symbols <n> <bytes>\\n" + n x 32768 words (u32 {Q, I})
                         the receiver's soft symbols: for a moment host port 1 takes the OFDM
                         receiver's output instead of the decoder's, then the routes are restored
                         and the decoder flushed (it counts its own frames; a partial frame would
                         shift every later image)
    rf                -> "rf <RX gain dB> <RSSI dB> <ofdm_rx FRAMES_IN>"
Statistics go to /run/glidelink/rx_app.json every second.
"""
import argparse
import json
import os
import socket
import struct
import threading
import time

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_CS16, SOAPY_SDR_MORE_FRAGMENTS

from glidelinkd import IioDev, SHELL_ROUTE, SHELL_PORT_RESET, SINKS, SOURCES, SINK_FLUSH

IMG = 256
WORDS = IMG * IMG * 3 // 4
SYMS = 32768
MAGIC = b"JRX1"


class App:
    def __init__(self, a):
        self.a, self.clients, self.lock = a, [], threading.Lock()
        self.shell, self.phy = IioDev("glidelink-shell"), IioDev("ad9361-phy")
        self.dev = SoapySDR.Device(a.args)
        self.rx = self.dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0],
                                       {"port": "1", "headers": "true", "bufferLength": "16384"})
        self.dev.activateStream(self.rx)
        self.stats = {"frames": 0, "bad_packets": 0, "errors": 0, "fps": 0.0}
        self.sym_req = None                             # (n, event, list) while symbols are wanted

    # ------------------------------------------------------------------ TCP
    def serve_images(self):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("", self.a.port))
        srv.listen(4)
        while True:
            c, _ = srv.accept()
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            c.settimeout(2.0)                           # a client that stops reading is dropped, not waited for
            with self.lock:
                self.clients.append(c)

    def serve_ctrl(self):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("", self.a.ctrl))
        srv.listen(4)
        while True:
            c, _ = srv.accept()
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=self.control, args=(c,), daemon=True).start()

    def control(self, c):
        f = c.makefile("rwb", buffering=0)
        for line in f:
            cmd, _, arg = line.decode().strip().partition(" ")
            if cmd == "time":
                f.write(f"time {time.time():.6f}\n".encode())
            elif cmd == "symbols":
                n = max(1, min(int(arg or 1), 16))
                req = (n, threading.Event(), [])
                self.sym_req = req
                ok = req[1].wait(10.0)
                data = b"".join(req[2]) if ok else b""
                f.write(f"symbols {len(req[2]) if ok else 0} {len(data)}\n".encode() + data)
            elif cmd == "rf":
                g = self.phy.attr("in_voltage0_hardwaregain").split()[0]
                r = self.phy.attr("in_voltage0_rssi").split()[0]
                f.write(f"rf {g} {r} {self.shell.reg(0x2000 + 0x1000 * self.a.phy_slot + 0x010)}\n".encode())
            else:
                f.write(b"error unknown command\n")

    def send(self, n, t, img):
        hdr = MAGIC + struct.pack("<Id", n, t)
        with self.lock:
            for c in list(self.clients):
                try:
                    c.sendall(hdr + img)
                except OSError:
                    self.clients.remove(c)

    # ------------------------------------------------------------------ routes
    def route(self, sink, source):
        s = SINKS[sink]
        self.shell.reg(SHELL_ROUTE + 4 * s, SOURCES[source])
        return SINK_FLUSH[s]

    def symbols_on(self):
        self.route(f"slot{self.a.dec_slot}_in", "none")      # flushed when it is routed back
        self.shell.reg(SHELL_PORT_RESET, self.route("host1_rx", f"slot{self.a.phy_slot}_out"))

    def symbols_off(self):
        self.route("host1_rx", f"slot{self.a.dec_slot}_out")
        flush = self.route(f"slot{self.a.dec_slot}_in", f"slot{self.a.phy_slot}_out")
        self.shell.reg(SHELL_PORT_RESET, flush | SINK_FLUSH[SINKS["host1_rx"]])

    # ------------------------------------------------------------------ main loop
    def run(self):
        threading.Thread(target=self.serve_images, daemon=True).start()
        threading.Thread(target=self.serve_ctrl, daemon=True).start()
        frame = np.empty(WORDS + 16384, np.uint32)
        got, t_stat, n_stat = 0, time.time(), 0
        req, t_req = None, 0.0
        status = "/run/glidelink/rx_app.json"
        os.makedirs(os.path.dirname(status), exist_ok=True)
        while True:
            if req is None and self.sym_req is not None:
                req, self.sym_req, t_req = self.sym_req, None, time.time()
                self.symbols_on()
            r = self.dev.readStream(self.rx, [frame[got:].view(np.int16)], min(16384, len(frame) - got),
                                    timeoutUs=1000000)
            now = time.time()
            if r.ret > 0:
                got += r.ret
                if not r.flags & SOAPY_SDR_MORE_FRAGMENTS:      # end of a stream packet
                    if req is not None:
                        if got == SYMS:
                            req[2].append(frame[:SYMS].tobytes())
                    elif got == WORDS:
                        img = frame[:WORDS].tobytes()
                        self.stats["frames"] += 1
                        self.send(self.stats["frames"], now, img)
                        if self.a.save and self.stats["frames"] % 30 == 0:
                            np.save(self.a.save + ".tmp.npy", np.frombuffer(img, np.uint8).reshape(IMG, IMG, 3))
                            os.replace(self.a.save + ".tmp.npy", self.a.save)
                    else:
                        self.stats["bad_packets"] += 1
                    got = 0
                elif got > WORDS:                               # longer than an image: drop it
                    self.stats["bad_packets"] += 1
                    got = 0
            elif r.ret != SoapySDR.SOAPY_SDR_TIMEOUT:
                self.stats["errors"] += 1
                got = 0
            if req is not None and (len(req[2]) >= req[0] or now - t_req > 8.0):
                self.symbols_off()
                req[1].set()
                req, got = None, 0
            if now - t_stat >= 1.0:
                self.stats["fps"] = round((self.stats["frames"] - n_stat) / (now - t_stat), 2)
                self.stats["time"] = now
                t_stat, n_stat = now, self.stats["frames"]
                json.dump(self.stats, open(status + ".tmp", "w"))
                os.replace(status + ".tmp", status)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7021)
    ap.add_argument("--ctrl", type=int, default=7022)
    ap.add_argument("--phy-slot", type=int, default=1, help="slot of ofdm_rx")
    ap.add_argument("--dec-slot", type=int, default=2, help="slot of jscc_dec")
    ap.add_argument("--save", default="/run/glidelink/rx_latest.npy")
    ap.add_argument("--args", default="driver=glidelink")
    App(ap.parse_args()).run()


if __name__ == "__main__":
    main()
