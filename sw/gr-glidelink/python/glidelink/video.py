#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Video through the offline DeepJSCC-Q link, as GNU Radio streams of frames (one item = one
256x256 RGB frame, 196,608 bytes):

- video_file_source: frames from a video file (or an image, a directory of images, a camera index)
  on the PC, centre-cropped and resized to 256x256, at the file's frame rate (or a given one).
- jscc_tx_sink: frames to the TX board's application (source "net", port 7023); it switches the
  application to that source and sets the TX attenuation (a callback in GRC).
- jscc_rx_source: the images decoded by the RX board (its application's image stream, port 7021).
- video_sink: a Qt view of one stream, or of two: the frames sent and the frames decoded side by
  side. The link delays the decoded frames; each one is shown next to the sent frame it matches
  best among the last second's (PSNR), with the PSNR, both frame rates and the delay in frames.
"""
import collections
import os
import socket
import threading
import time

import numpy as np
from gnuradio import gr

IMG = 256
FRAME = IMG * IMG * 3


def square(rgb):
    """centre crop to a square and resize to 256x256"""
    import cv2
    h, w = rgb.shape[:2]
    s = min(h, w)
    sq = rgb[(h - s) // 2:(h - s) // 2 + s, (w - s) // 2:(w - s) // 2 + s]
    return cv2.resize(sq, (IMG, IMG), interpolation=cv2.INTER_AREA)


class video_file_source(gr.sync_block):
    """frames from a video file, an image, a directory of images or a camera ('0', '1', ...)"""

    def __init__(self, path="", fps=0.0, loop=True):
        gr.sync_block.__init__(self, name="Video File Source", in_sig=None, out_sig=[(np.uint8, FRAME)])
        import cv2
        self.cv2, self.loop, self.images, self.k = cv2, loop, None, 0
        if os.path.isdir(path):
            files = sorted(f for f in os.listdir(path) if f.lower().endswith((".png", ".jpg", ".jpeg", ".bmp")))
            self.images = [self._load(os.path.join(path, f)) for f in files]
            rate = 1.0
        elif path.lower().endswith((".png", ".jpg", ".jpeg", ".bmp")):
            self.images = [self._load(path)]
            rate = 1.0
        else:
            self.cap = cv2.VideoCapture(int(path) if path.isdigit() else path)
            if not self.cap.isOpened():
                raise RuntimeError(f"cannot open {path!r}")
            rate = self.cap.get(cv2.CAP_PROP_FPS) or 30.0
        self.period = 1.0 / (fps if fps > 0 else rate)
        self.t_next = None

    def _load(self, p):
        bgr = self.cv2.imread(p, self.cv2.IMREAD_COLOR)
        return square(self.cv2.cvtColor(bgr, self.cv2.COLOR_BGR2RGB))

    def _frame(self):
        if self.images is not None:
            img = self.images[self.k % len(self.images)]
            self.k += 1
            return img
        ok, bgr = self.cap.read()
        if not ok and self.loop:
            self.cap.set(self.cv2.CAP_PROP_POS_FRAMES, 0)
            ok, bgr = self.cap.read()
        if not ok:
            return None
        return square(self.cv2.cvtColor(bgr, self.cv2.COLOR_BGR2RGB))

    def work(self, input_items, output_items):
        now = time.monotonic()
        if self.t_next is None:
            self.t_next = now
        if now < self.t_next:                           # the file's pace
            time.sleep(self.t_next - now)
        self.t_next = max(self.t_next + self.period, time.monotonic() - self.period)
        img = self._frame()
        if img is None:
            return -1                                   # end of the file (loop off)
        output_items[0][0][:] = img.reshape(-1)
        return 1


class jscc_tx_sink(gr.sync_block):
    """frames to the TX board: its application's source 'net' (port 7023)"""

    def __init__(self, host="192.168.4.1", att=4.0, ctrl_port=7020, data_port=7023):
        gr.sync_block.__init__(self, name="JSCC TX Sink", in_sig=[(np.uint8, FRAME)], out_sig=None)
        self.host, self.ctrl_port, self.data_port = host, ctrl_port, data_port
        self.att, self.fid, self.s = att, 0, None
        self._ctrl(f"src net")
        self.set_att(att)

    def _ctrl(self, line):
        try:
            with socket.create_connection((self.host, self.ctrl_port), 5) as c:
                c.sendall(line.encode() + b"\n")
                return c.makefile().readline().strip()
        except OSError as e:
            print(f"JSCC TX Sink: {self.host}:{self.ctrl_port}: {e}", flush=True)
            return ""

    def set_att(self, att):
        self.att = att
        self._ctrl(f"att {float(att)}")

    def work(self, input_items, output_items):
        for img in input_items[0]:
            try:
                if self.s is None:
                    self.s = socket.create_connection((self.host, self.data_port), 5)
                    self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                self.s.sendall(b"JTX1" + self.fid.to_bytes(4, "little") + img.tobytes())
                self.fid = (self.fid + 1) & 0xFFFFFFFF
            except OSError:
                self.s = None                           # reconnect with the next frame
                time.sleep(0.5)
        return len(input_items[0])


class jscc_rx_source(gr.sync_block):
    """the images decoded by the RX board (its application's image stream, port 7021)"""

    def __init__(self, host="192.168.3.1", port=7021):
        gr.sync_block.__init__(self, name="JSCC RX Source", in_sig=None, out_sig=[(np.uint8, FRAME)])
        self.host, self.port = host, port
        self.q = collections.deque(maxlen=8)
        self.ready = threading.Condition()
        self.on = True
        threading.Thread(target=self._receive, daemon=True).start()

    def _receive(self):
        need = 16 + FRAME
        while self.on:
            try:
                s = socket.create_connection((self.host, self.port), 5)
                s.settimeout(10)
                buf = bytearray()
                while self.on:
                    while len(buf) < need:
                        chunk = s.recv(1 << 20)
                        if not chunk:
                            raise ConnectionError("closed")
                        buf += chunk
                    if buf[:4] != b"JRX1":
                        raise ConnectionError("out of step")
                    with self.ready:
                        self.q.append(bytes(buf[16:need]))
                        self.ready.notify()
                    del buf[:need]
            except OSError:
                time.sleep(1)

    def work(self, input_items, output_items):
        with self.ready:
            if not self.q:
                self.ready.wait(0.1)
            n = min(len(self.q), len(output_items[0]))
            for i in range(n):
                output_items[0][i][:] = np.frombuffer(self.q.popleft(), np.uint8)
        return n

    def stop(self):
        self.on = False
        return True


class video_sink(gr.basic_block):
    """Qt view: one stream, or the frames sent (input 0) next to the frames decoded (input 1).
    Each input is taken as it comes (the decoded stream lags, and stops while the link is down)."""

    def __init__(self, nconnections=2, zoom=2, history=30):
        gr.basic_block.__init__(self, name="Video Sink", in_sig=[(np.uint8, FRAME)] * nconnections, out_sig=None)
        from PyQt5 import Qt
        self.Qt, self.n, self.zoom = Qt, nconnections, zoom
        self.sent = collections.deque(maxlen=history)   # recent sent frames, for the match
        self.lock = threading.Lock()
        self.show = [None, None]                        # what to draw: [sent match, decoded]
        self.count = [0, 0]
        self.psnr, self.lag, self.psnrs = None, None, collections.deque(maxlen=100)
        self.rate, self.t_rate, self.c_rate = [0.0, 0.0], time.monotonic(), [0, 0]
        self.drawn = [-1, -1]
        self.widget = Qt.QWidget()
        lay = Qt.QVBoxLayout(self.widget)
        row = Qt.QHBoxLayout()
        row.addStretch(1)
        titles = ["Sent (PC)", "Decoded (RX board)"] if nconnections == 2 else ["Video"]
        self.lbl = []
        for t in titles:
            col = Qt.QVBoxLayout()
            col.addWidget(Qt.QLabel(t))
            lbl = Qt.QLabel()
            lbl.setFixedSize(IMG * zoom, IMG * zoom)
            lbl.setStyleSheet("background: #202020")
            col.addWidget(lbl)
            row.addLayout(col)
            row.addSpacing(16)
            self.lbl.append(lbl)
        row.addStretch(1)
        lay.addLayout(row)
        self.status = Qt.QLabel("waiting for frames ...")
        self.status.setStyleSheet("font-family: monospace")
        lay.addWidget(self.status)
        self.timer = Qt.QTimer()
        self.timer.timeout.connect(self._update)
        self.timer.start(15)

    def forecast(self, noutput_items, ninputs):
        return [0] * ninputs                            # no input needs anything to run

    def general_work(self, input_items, output_items):
        got = sum(len(x) for x in input_items)
        if got == 0:
            time.sleep(0.005)
            return 0
        if self.n == 1:
            n = len(input_items[0])
            if n:
                with self.lock:
                    self.show[1] = input_items[0][n - 1].copy()
                    self.count[1] += n
            self.consume(0, n)
            return 0
        for img in input_items[0]:
            with self.lock:
                self.sent.append((self.count[0], img.copy()))
                self.count[0] += 1
        for img in input_items[1]:
            self._decoded(img.copy())
        self.consume(0, len(input_items[0]))
        self.consume(1, len(input_items[1]))
        return 0

    def _decoded(self, d):
        with self.lock:
            cands = list(self.sent)
        if cands:                                       # the sent frame it matches best
            dd = d.astype(np.float32)
            mse = np.array([np.mean((dd - s.astype(np.float32)) ** 2) for _, s in cands])
            # the newest of the frames within 0.5 dB of the best match: in a still scene many sent
            # frames match equally well, and the newest one gives the link's real delay
            close = np.flatnonzero(mse <= mse.min() * 10 ** 0.05)
            i = int(close[-1])
            psnr = 10 * np.log10(255 ** 2 / max(mse.min(), 1e-3))
            with self.lock:
                self.show[0] = cands[i][1]
                self.psnr, self.lag = psnr, self.count[0] - 1 - cands[i][0]
                self.psnrs.append(psnr)
        with self.lock:
            self.show[1] = d
            self.count[1] += 1

    def _pixmap(self, img):
        Qt = self.Qt
        a = np.ascontiguousarray(img.reshape(IMG, IMG, 3))
        q = Qt.QImage(a.data, IMG, IMG, 3 * IMG, Qt.QImage.Format_RGB888)
        return Qt.QPixmap.fromImage(q.copy()).scaled(IMG * self.zoom, IMG * self.zoom)

    def _update(self):
        with self.lock:
            show, count = list(self.show), list(self.count)
            psnr, lag, mean = self.psnr, self.lag, (np.mean(self.psnrs) if self.psnrs else None)
        if self.n == 1:
            pairs = [(self.lbl[0], show[1])]
        else:
            pairs = [(self.lbl[0], show[0]), (self.lbl[1], show[1])]
        if count[1] != self.drawn[1]:                   # draw when a new frame came
            for lbl, img in pairs:
                if img is not None:
                    lbl.setPixmap(self._pixmap(img))
            self.drawn = count
        now = time.monotonic()
        if now - self.t_rate >= 1.0:
            self.rate = [(count[k] - self.c_rate[k]) / (now - self.t_rate) for k in (0, 1)]
            self.t_rate, self.c_rate = now, count
            if self.n == 1:
                self.status.setText(f"{self.rate[1]:5.1f} frames/s")
            else:
                txt = f"sent {self.rate[0]:5.1f} frames/s   decoded {self.rate[1]:5.1f} frames/s"
                if psnr is not None:
                    txt += f"   PSNR {psnr:5.2f} dB (mean of 100: {mean:5.2f} dB)   delay {lag} frames"
                self.status.setText(txt)
