#!/usr/bin/env python3
"""DeepJSCC-Q receiver application (docs/phase4_plan.md 4.6): decoder -> host port 1 -> images.

Runs on the RX board with glidelinkd (config/rx.yaml routes RF -> ofdm_rx -> jscc_dec -> host1_rx).
Reads host port 1 with packet headers: an image is one stream packet of 49,152 words (tlast from
the decoder), delivered in parts of up to 8192 words that Soapy marks MORE_FRAGMENTS until the
last; a packet of any other length (data lost) is dropped and counted.

    python3 jscc_rx_app.py [--port 7021] [--save /run/glidelink/rx_latest.npy]

TCP (port --port): a client gets every decoded image as a 16-byte header
<magic "JRX1", frame number u32, board time of arrival f64> followed by 196,608 bytes (256x256x3
uint8, NHWC); a line "time\\n" from the client is answered between frames with a header whose
frame number is 0xFFFFFFFF and no image (clock offset estimate). Statistics go to
/run/glidelink/rx_app.json every second.
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

IMG = 256
WORDS = IMG * IMG * 3 // 4
MAGIC = b"JRX1"


class App:
    def __init__(self, a):
        self.a, self.clients, self.lock = a, [], threading.Lock()
        self.dev = SoapySDR.Device(a.args)
        self.rx = self.dev.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0],
                                       {"port": "1", "headers": "true", "bufferLength": "16384"})
        self.dev.activateStream(self.rx)
        self.stats = {"frames": 0, "bad_packets": 0, "errors": 0, "fps": 0.0}

    def serve(self):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("", self.a.port))
        srv.listen(4)
        while True:
            c, _ = srv.accept()
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            c.setblocking(False)
            with self.lock:
                self.clients.append(c)

    def send(self, n, t, img):
        hdr = MAGIC + struct.pack("<Id", n, t)
        with self.lock:
            for c in list(self.clients):
                try:
                    try:
                        if b"time" in c.recv(64):
                            c.setblocking(True)
                            c.sendall(MAGIC + struct.pack("<Id", 0xFFFFFFFF, time.time()))
                    except BlockingIOError:
                        pass
                    c.setblocking(True)
                    c.sendall(hdr + img)
                    c.setblocking(False)
                except OSError:
                    self.clients.remove(c)

    def run(self):
        threading.Thread(target=self.serve, daemon=True).start()
        frame = np.empty(WORDS + 16384, np.uint32)
        got, t_stat, n_stat = 0, time.time(), 0
        status = "/run/glidelink/rx_app.json"
        os.makedirs(os.path.dirname(status), exist_ok=True)
        while True:
            r = self.dev.readStream(self.rx, [frame[got:].view(np.int16)], min(16384, len(frame) - got),
                                    timeoutUs=1000000)
            now = time.time()
            if r.ret > 0:
                got += r.ret
                if not r.flags & SOAPY_SDR_MORE_FRAGMENTS:      # end of a stream packet
                    if got == WORDS:
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
            if now - t_stat >= 1.0:
                self.stats["fps"] = round((self.stats["frames"] - n_stat) / (now - t_stat), 2)
                self.stats["time"] = now
                t_stat, n_stat = now, self.stats["frames"]
                json.dump(self.stats, open(status + ".tmp", "w"))
                os.replace(status + ".tmp", status)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7021)
    ap.add_argument("--save", default="/run/glidelink/rx_latest.npy")
    ap.add_argument("--args", default="driver=glidelink")
    App(ap.parse_args()).run()


if __name__ == "__main__":
    main()
