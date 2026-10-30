#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""GlideLink link console blocks for the offline DeepJSCC-Q system (docs/phase4_plan.md 4.6).

The boards run offline (glidelinkd@tx / glidelinkd@rx with their applications); these blocks talk
to the applications over TCP, from a GNU Radio flowgraph on the PC:

- jscc_tx_control: TX application (port 7020): source (image, directory or video on the TX board)
  and TX attenuation; the GRC callbacks set them while the flowgraph runs.
- jscc_rx_view: Qt widget: the frame the TX sent (TX application "ref") and the latest decoded
  image (RX application, port 7021) side by side, with a status line: decoded images per second,
  PSNR against the TX frame (meaningful for a still image), RX gain, RSSI, watchdog resets.
- jscc_rx_symbols: stream source of the receiver's soft symbols (RX application "symbols", one
  frame of 32768 per interval), scaled so the outer 64-QAM level is 1, for a constellation sink;
  evm() gives the decision-directed EVM of the last frame (dB). Each capture takes the receiver's
  output away from the decoder for one frame: about one image per interval is not decoded.
"""
import json
import math
import socket
import struct
import threading
import time

import numpy as np
from gnuradio import gr

IMG = 256
IMG_BYTES = IMG * IMG * 3
FRAME_SYMS = 32768
QAM_LV = 158 * (2 * np.arange(8) - 7)


class _Line:
    """line-protocol client of an application (reconnects on demand)"""

    def __init__(self, host, port, timeout=15.0):
        self.host, self.port, self.timeout = host, port, timeout
        self.s = self.f = None
        self.lock = threading.Lock()

    def _connect(self):
        self.s = socket.create_connection((self.host, self.port), 5)
        self.s.settimeout(self.timeout)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.f = self.s.makefile("rb")

    def cmd(self, line, payload=False):
        """one command; returns the reply line, and with payload=True the bytes announced as its
        last field"""
        with self.lock:
            for attempt in (0, 1):
                try:
                    if self.s is None:
                        self._connect()
                    self.s.sendall(line.encode() + b"\n")
                    reply = self.f.readline().decode().strip()
                    if not reply:
                        raise ConnectionError("closed")
                    if not payload:
                        return reply
                    n = int(reply.split()[-1])
                    data = self.f.read(n)
                    if len(data) != n:
                        raise ConnectionError("short read")
                    return reply, data
                except OSError:
                    self.s = None
                    if attempt:
                        raise


class jscc_tx_control(gr.basic_block):
    """TX application control: source and attenuation (no streams)"""

    def __init__(self, host="192.168.4.1", port=7020, src="", att=4.0):
        gr.basic_block.__init__(self, name="JSCC TX Control", in_sig=None, out_sig=None)
        self.c = _Line(host, port)
        self.src, self.att = None, None
        self.set_src(src)
        self.set_att(att)

    def set_src(self, src):
        if src and src != self.src:
            r = self.c.cmd(f"src {src}")
            if r != "ok":
                print(f"JSCC TX Control: src {src}: {r}")
            self.src = src

    def set_att(self, att):
        att = min(max(float(att), 0.0), 89.75)
        if att != self.att:
            self.c.cmd(f"att {att}")
            self.att = att

    def state(self):
        return json.loads(self.c.cmd("state"))


class jscc_rx_view(gr.basic_block):
    """Qt view of the link: TX frame | decoded image, status line (no streams)"""

    def __init__(self, rx_host="192.168.3.1", tx_host="192.168.4.1", interval=1.0, zoom=2):
        gr.basic_block.__init__(self, name="JSCC RX View", in_sig=None, out_sig=None)
        from PyQt5 import Qt
        self.Qt = Qt
        self.rx_host, self.interval, self.zoom = rx_host, interval, zoom
        self.ctrl = _Line(rx_host, 7022)
        self.tx = _Line(tx_host, 7020) if tx_host else None
        self.latest = self.ref = None
        self.n_img, self.status, self.on = 0, {}, True

        self.widget = Qt.QWidget()
        lay = Qt.QVBoxLayout(self.widget)
        row = Qt.QHBoxLayout()
        row.addStretch(1)
        self.lbl_tx, self.lbl_rx = Qt.QLabel(), Qt.QLabel()
        for title, lbl in (("TX frame", self.lbl_tx), ("Decoded (RX)", self.lbl_rx)):
            col = Qt.QVBoxLayout()
            col.addWidget(Qt.QLabel(title))
            lbl.setFixedSize(IMG * zoom, IMG * zoom)
            lbl.setStyleSheet("background: #202020")
            col.addWidget(lbl)
            row.addLayout(col)
            row.addSpacing(16)
        row.addStretch(1)
        lay.addLayout(row)
        self.lbl_status = Qt.QLabel("connecting ...")
        self.lbl_status.setStyleSheet("font-family: monospace")
        lay.addWidget(self.lbl_status)

        threading.Thread(target=self._images, daemon=True).start()
        threading.Thread(target=self._poll, daemon=True).start()
        self.timer = Qt.QTimer()
        self.timer.timeout.connect(self._update)
        self.timer.start(100)

    # background threads: TCP only, the Qt objects are touched in _update
    def _images(self):
        while self.on:
            try:
                s = socket.create_connection((self.rx_host, 7021), 5)
                s.settimeout(10)
                buf = b""
                while self.on:
                    while len(buf) < 16 + IMG_BYTES:
                        chunk = s.recv(1 << 20)
                        if not chunk:
                            raise ConnectionError("closed")
                        buf += chunk
                    if buf[:4] != b"JRX1":
                        raise ConnectionError("out of step")
                    self.latest = np.frombuffer(buf[16:16 + IMG_BYTES], np.uint8).reshape(IMG, IMG, 3)
                    self.n_img += 1
                    buf = buf[16 + IMG_BYTES:]
            except OSError:
                self.latest = None
                time.sleep(2)

    def _poll(self):
        last_n, last_t = 0, time.time()
        while self.on:
            st = {}
            try:
                st.update(json.loads(self.ctrl.cmd("status")))
                rf = self.ctrl.cmd("rf").split()
                st["gain"], st["rssi"] = float(rf[1]), float(rf[2])
            except (OSError, ValueError, IndexError):
                st["error"] = "RX application not reachable"
            if self.tx is not None:
                try:
                    _, data = self.tx.cmd("ref", payload=True)
                    self.ref = np.frombuffer(data, np.uint8).reshape(IMG, IMG, 3)
                except (OSError, ValueError):
                    self.ref = None
            now = time.time()
            st["view_fps"] = (self.n_img - last_n) / (now - last_t)
            last_n, last_t = self.n_img, now
            self.status = st
            time.sleep(self.interval)

    def _pixmap(self, img):
        Qt = self.Qt
        a = np.ascontiguousarray(img)
        q = Qt.QImage(a.data, IMG, IMG, 3 * IMG, Qt.QImage.Format_RGB888)
        return Qt.QPixmap.fromImage(q.copy()).scaled(IMG * self.zoom, IMG * self.zoom)

    def _update(self):
        rx, ref, st = self.latest, self.ref, self.status
        if rx is not None:
            self.lbl_rx.setPixmap(self._pixmap(rx))
        if ref is not None:
            self.lbl_tx.setPixmap(self._pixmap(ref))
        if not st:
            return
        if "error" in st:
            self.lbl_status.setText(st["error"])
            return
        parts = [f"decoded {st['view_fps']:5.1f} img/s"]
        if rx is not None and ref is not None:
            mse = np.mean((rx.astype(np.float64) - ref) ** 2)
            parts.append(f"PSNR {99.0 if mse == 0 else 10 * math.log10(255 ** 2 / mse):5.2f} dB")
        parts.append(f"RX gain {st.get('gain', 0):4.0f} dB  RSSI {st.get('rssi', 0):5.1f} dB")
        d = st.get("daemon") or {}
        wd = d.get("watchdog") or {}
        c = d.get("counters") or {}
        parts.append(f"PHY frames {c.get('phy_frames', '-')}  AGC resets {wd.get('resets', '-')}  "
                     f"[{d.get('state', '?')}]")
        self.lbl_status.setText("   ".join(parts))

    def stop(self):
        self.on = False
        self.timer.stop()
        return True


class jscc_rx_symbols(gr.sync_block):
    """the receiver's soft symbols, one frame per interval, outer 64-QAM level = 1"""

    def __init__(self, rx_host="192.168.3.1", interval=2.0):
        gr.sync_block.__init__(self, name="JSCC RX Symbols", in_sig=None, out_sig=[np.complex64])
        self.ctrl = _Line(rx_host, 7022)
        self.interval = interval
        self.buf = np.zeros(0, np.complex64)
        self.t_next = 0.0
        self._evm = float("nan")

    def evm(self):
        return self._evm

    def work(self, input_items, output_items):
        out = output_items[0]
        if len(self.buf) == 0:
            wait = self.t_next - time.time()
            if wait > 0:
                time.sleep(min(wait, 0.2))
                return 0
            self.t_next = time.time() + self.interval
            try:
                head, data = self.ctrl.cmd("symbols 1", payload=True)
            except (OSError, ValueError):
                return 0
            if int(head.split()[1]) == 0:
                return 0
            w = np.frombuffer(data[:4 * FRAME_SYMS], np.uint32)
            z = ((w & 0xFFFF).astype(np.uint16).view(np.int16).astype(np.float64)
                 + 1j * (w >> 16).astype(np.uint16).view(np.int16).astype(np.float64))
            ref = (QAM_LV[np.argmin(abs(z.real[:, None] - QAM_LV), 1)]
                   + 1j * QAM_LV[np.argmin(abs(z.imag[:, None] - QAM_LV), 1)])
            self._evm = float(10 * np.log10(np.mean(abs(z - ref) ** 2) / np.mean(abs(ref) ** 2)))
            self.buf = (z / QAM_LV[-1]).astype(np.complex64)
        n = min(len(out), len(self.buf))
        out[:n] = self.buf[:n]
        self.buf = self.buf[n:]
        return n
