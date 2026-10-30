#!/usr/bin/env python3
"""DeepJSCC-Q transmitter application (docs/phase4_plan.md 4.6): images -> host port 1 -> encoder.

Runs on the TX board with glidelinkd (config/tx.yaml routes host1_tx -> jscc_enc -> ofdm_tx -> RF).
The source is a still image (png / jpg / npy), a directory of them (cycled) or a video (cv2);
every frame becomes 256x256 RGB (centre crop + resize, as the competition's TX) and is written to
host port 1 (raw, 49,152 words) at --fps.

    python3 jscc_tx_app.py --src media/presets/div2k_0802.png [--fps 30] [--port 7020]

TCP control (one line per command, one line back), for the PC tools (sw/offline/link_metrics.py):
    time              -> "time <board time>"                      clock offset estimate
    src <path>        -> "ok"                                     switch the source
    att <dB>          -> "att <dB set>"                           TX attenuation (AD9361 TX1)
    events            -> then one line per frame sent: "frame <n> <t_start> <t_end> <src id> <index>"
                         (index: image number in a directory source, in sorted file order)
"""
import argparse
import os
import socket
import threading
import time

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_TX, SOAPY_SDR_CS16

IMG = 256
WORDS = IMG * IMG * 3 // 4


def square(rgb):
    """centre crop to a square, resize to 256x256 (PIL Lanczos, as make_golden.load_image)"""
    from PIL import Image
    im = Image.fromarray(rgb)
    s = min(im.size)
    im = im.crop(((im.width - s) // 2, (im.height - s) // 2, (im.width + s) // 2, (im.height + s) // 2))
    return np.asarray(im.resize((IMG, IMG), Image.LANCZOS), np.uint8)


class Source:
    def __init__(self, spec):
        self.spec, self.video, self.frames, self.k = spec, None, [], 0
        if os.path.isdir(spec):
            files = sorted(f for f in os.listdir(spec) if f.lower().endswith((".png", ".jpg", ".jpeg", ".npy")))
            self.frames = [self.load(os.path.join(spec, f)) for f in files]
        elif spec.lower().endswith((".mp4", ".avi", ".mkv")):
            import cv2
            self.video = cv2.VideoCapture(spec)
        else:
            self.frames = [self.load(spec)]
        self.id = abs(hash(spec)) % 10000

    @staticmethod
    def load(path):
        if path.endswith(".npy"):
            return np.load(path).astype(np.uint8).reshape(IMG, IMG, 3)
        from PIL import Image
        return square(np.asarray(Image.open(path).convert("RGB")))

    def next(self):
        """(frame, index): the image number in the directory, or the video frame number"""
        if self.video is not None:
            import cv2
            ok, bgr = self.video.read()
            if not ok:
                self.video.set(cv2.CAP_PROP_POS_FRAMES, 0)
                ok, bgr = self.video.read()
            self.k += 1
            return square(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)), self.k - 1
        i = self.k % len(self.frames)
        self.k += 1
        return self.frames[i], i


class App:
    def __init__(self, a):
        self.a, self.src, self.lock = a, Source(a.src), threading.Lock()
        self.listeners = []
        self.dev = SoapySDR.Device(a.args)
        self.tx = self.dev.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CS16, [0],
                                       {"port": "1", "headers": "false", "bufferLength": str(WORDS)})
        self.dev.activateStream(self.tx)

    def control(self, conn):
        f = conn.makefile("rw", buffering=1)
        for line in f:
            cmd, _, arg = line.strip().partition(" ")
            if cmd == "time":
                f.write(f"time {time.time():.6f}\n")
            elif cmd == "src":
                try:
                    s = Source(arg)
                    with self.lock:
                        self.src = s
                    f.write("ok\n")
                except Exception as e:                  # noqa: BLE001  (reported to the client)
                    f.write(f"error {e}\n")
            elif cmd == "att":
                try:
                    from glidelinkd import IioDev
                    phy = IioDev("ad9361-phy")
                    phy.attr("out_voltage0_hardwaregain", -float(arg))
                    f.write(f"att {-float(phy.attr('out_voltage0_hardwaregain').split()[0]):.2f}\n")
                except Exception as e:                  # noqa: BLE001  (reported to the client)
                    f.write(f"error {e}\n")
            elif cmd == "events":
                with self.lock:
                    self.listeners.append(f)
                return                                  # the frame loop writes from now on
            else:
                f.write("error unknown command\n")

    def serve(self):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("", self.a.port))
        srv.listen(4)
        while True:
            c, _ = srv.accept()
            c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=self.control, args=(c,), daemon=True).start()

    def run(self):
        threading.Thread(target=self.serve, daemon=True).start()
        period, n = 1.0 / self.a.fps, 0
        t_next = time.time()
        while True:
            with self.lock:
                src = self.src
            img, idx = src.next()
            words = np.frombuffer(img.tobytes(), "<u4")
            now = time.time()
            if now < t_next:
                time.sleep(t_next - now)
            t0 = time.time()
            p = 0
            while p < WORDS:
                r = self.dev.writeStream(self.tx, [words[p:].view(np.int16)], WORDS - p, timeoutUs=2000000)
                if r.ret <= 0:
                    print("writeStream", r.ret, flush=True)
                    break
                p += r.ret
            t1 = time.time()
            t_next = max(t_next + period, t1 - period)  # keep the pace, do not burst after a stall
            with self.lock:
                for f in list(self.listeners):
                    try:
                        f.write(f"frame {n} {t0:.6f} {t1:.6f} {src.id} {idx}\n")
                        f.flush()                       # a socket text file is not line buffered
                    except OSError:
                        self.listeners.remove(f)
            n += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--port", type=int, default=7020)
    ap.add_argument("--args", default="driver=glidelink")
    App(ap.parse_args()).run()


if __name__ == "__main__":
    main()
