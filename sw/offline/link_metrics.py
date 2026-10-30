"""Link metrics of the offline DeepJSCC-Q system (docs/phase4_plan.md 4.6), for comparison with the
competition's measurements (data/measurements of Vimcovan/glidelink-fpga: board/tests/measure_link.py).

Runs on the PC. It talks only to the two applications over TCP (jscc_tx_app.py on the TX board:
control 7020; jscc_rx_app.py on the RX board: images 7021, control 7022); the boards run offline.

    python link_metrics.py sweep   --presets <dir> [--att 54,52,...] [--top 56] [--settle 3] [--dwell 8]
    python link_metrics.py latency --presets <dir> [--dwell 60]
    python link_metrics.py fps     [--dwell 600]
    common: --tx 192.168.4.1 --rx 192.168.3.1 --att0 4 --out <dir>

sweep    image quality against TX attenuation, as the competition's run k0802_final: source the
         preset div2k_0802 (--image), the attenuation first at --top, then the points in the given
         (descending) order, each --settle s to settle and --dwell s measured. Per point:
           rx_fps        decoded images per second
           psnr          mean / 10th percentile / median PSNR of the decoded images against the
                         image the TX sends (centre crop + 256x256 Lanczos, as the TX application)
           evm_db        final constellation EVM, decision directed on the 64-QAM levels without
                         scaling (the competition's formula), over 4 frames of the receiver's soft
                         symbols (jscc_rx_app "symbols")
           snr_da_db     data-aided SNR of the same symbols against the encoder output for the
                         image (hw/modules/jscc_enc/model.py), complex gain fitted
--att    extra attenuation over --att0 (the TX configuration's 4 dB; the competition's att0 was 0
         over its own 4 dB), so the points are comparable one to one.
latency  end-to-end latency, TX application takes a frame (before the image is written to host port
         1) -> RX application has the whole decoded image, on board clocks corrected by the offsets
         measured from the PC (several round trips, the one with the smallest round-trip time).
         The TX cycles through the images of --presets (the same directory as on the TX board), so
         each received image is matched to the latest frame of the same image sent before it.
fps      decoded images per second over a long run (the competition: 600 s).
Results: <out>/<mode>.json (and sweep.csv).
"""
import argparse
import csv
import json
import os
import socket
import struct
import sys
import threading
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = 256
QAM_LV = 158 * (2 * np.arange(8) - 7)                  # 64-QAM levels per axis, Q10
FRAME_SYMS = 32768


def square(rgb):
    im = Image.fromarray(rgb)
    s = min(im.size)
    im = im.crop(((im.width - s) // 2, (im.height - s) // 2, (im.width + s) // 2, (im.height + s) // 2))
    return np.asarray(im.resize((IMG, IMG), Image.LANCZOS), np.uint8)


def load_ref(path):
    return square(np.asarray(Image.open(path).convert("RGB")))


def psnr(a, b):
    m = np.mean((a.astype(np.float64) - b) ** 2)
    return 99.0 if m == 0 else 10 * np.log10(255 ** 2 / m)


class Line:
    """line-protocol client"""

    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), 5)
        self.s.settimeout(30)                           # symbol captures take up to ~10 s on the board
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.f = self.s.makefile("rb")

    def cmd(self, line):
        self.s.sendall(line.encode() + b"\n")
        return self.f.readline().decode().strip()

    def read(self, n):
        return self.f.read(n)


def clock_offset(c, n=15):
    """board clock - PC clock, from the round trip with the smallest delay"""
    best = None
    for _ in range(n):
        t0 = time.time()
        tb = float(c.cmd("time").split()[1])
        t1 = time.time()
        if best is None or t1 - t0 < best[0]:
            best = (t1 - t0, tb - (t0 + t1) / 2)
    return best[1], best[0]


class RxImages(threading.Thread):
    """decoded images from jscc_rx_app (port 7021): (board time, PC time, image)"""

    def __init__(self, host, port=7021):
        super().__init__(daemon=True)
        self.s = socket.create_connection((host, port), 5)
        self.s.settimeout(None)
        self.items, self.lock, self.on = [], threading.Lock(), True

    def recv(self, n):
        b = bytearray()
        while len(b) < n:
            chunk = self.s.recv(n - len(b))
            if not chunk:
                raise ConnectionError("RX application closed the image stream")
            b += chunk
        return bytes(b)

    def run(self):
        while self.on:
            hdr = self.recv(16)
            if hdr[:4] != b"JRX1":
                raise ConnectionError("image stream out of step")
            _, tb = struct.unpack("<Id", hdr[4:])
            img = np.frombuffer(self.recv(IMG * IMG * 3), np.uint8).reshape(IMG, IMG, 3)
            with self.lock:
                self.items.append((tb, time.time(), img))

    def take(self):
        with self.lock:
            out, self.items = self.items, []
        return out


class TxEvents(threading.Thread):
    """frame events from jscc_tx_app: (n, t_start, t_end, index), board clock"""

    def __init__(self, host, port=7020):
        super().__init__(daemon=True)
        self.c = Line(host, port)
        self.c.s.sendall(b"events\n")
        self.items, self.lock = [], threading.Lock()

    def run(self):
        for line in self.c.f:
            p = line.decode().split()
            if p and p[0] == "frame":
                with self.lock:
                    self.items.append((int(p[1]), float(p[2]), float(p[3]), int(p[5])))

    def take(self):
        with self.lock:
            out, self.items = self.items, []
        return out


def symbols(rxc, n=4):
    """n frames of the receiver's soft symbols -> complex (n, 32768), Q10"""
    rxc.s.sendall(f"symbols {n}\n".encode())
    head = rxc.f.readline().decode().split()
    k, size = int(head[1]), int(head[2])
    w = np.frombuffer(rxc.read(size), np.uint32).reshape(k, FRAME_SYMS) if k else np.zeros((0, FRAME_SYMS), np.uint32)
    i = (w & 0xFFFF).astype(np.uint16).view(np.int16).astype(float)
    q = (w >> 16).astype(np.uint16).view(np.int16).astype(float)
    return i + 1j * q


def evm_db(z):
    z = z.reshape(-1)
    ref = QAM_LV[np.argmin(abs(z.real[:, None] - QAM_LV), 1)] + 1j * QAM_LV[np.argmin(abs(z.imag[:, None] - QAM_LV), 1)]
    return float(10 * np.log10(np.mean(abs(z - ref) ** 2) / np.mean(abs(ref) ** 2)))


def snr_da_db(z, e):
    """data-aided SNR: complex gain fitted per frame against the known symbols e"""
    out = []
    for y in z:
        g = np.vdot(e, y) / np.vdot(e, e)
        out.append(np.mean(abs(e) ** 2) / np.mean(abs(y / g - e) ** 2))
    return float(10 * np.log10(np.mean(out))) if out else None


def encoder_symbols(img):
    sys.path.insert(0, os.path.join(HERE, "..", "..", "hw", "modules", "jscc_enc"))
    import model as enc                                  # noqa: E402  (bit-exact encoder model)
    s = enc.encode(img)
    return s[:, 0] + 1j * s[:, 1]


def stats(v):
    v = np.asarray(v, float)
    if len(v) == 0:
        return {"mean": None, "p10": None, "median": None, "p90": None, "n": 0}
    return {"mean": round(float(v.mean()), 2), "p10": round(float(np.percentile(v, 10)), 2),
            "median": round(float(np.median(v)), 2), "p90": round(float(np.percentile(v, 90)), 2), "n": len(v)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["sweep", "latency", "fps"])
    ap.add_argument("--tx", default="192.168.4.1")
    ap.add_argument("--rx", default="192.168.3.1")
    ap.add_argument("--att0", type=float, default=4.0, help="TX attenuation of the configuration, dB")
    ap.add_argument("--att", default="54,52,51,50,49,48,47,46,45,44,43,42,41,40,39,38,37,36,35,34,33.5,33,32.5,"
                    "32,31.5,31,30.5,30,29.5,29,28.5,28,27,26,24,22,20,16,12,8,4,0",
                    help="extra attenuation points, dB (the competition's k0802_final list)")
    ap.add_argument("--top", type=float, default=56.0)
    ap.add_argument("--top-settle", type=float, default=5.0)
    ap.add_argument("--settle", type=float, default=3.0)
    ap.add_argument("--dwell", type=float, default=8.0)
    ap.add_argument("--presets", default=None, help="the TX board's preset directory, copied to the PC")
    ap.add_argument("--image", default="div2k_0802.png", help="sweep source, in --presets")
    ap.add_argument("--board-presets", default="/home/xilinx/claude/tx/media/presets")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "..", "data", "measurements", "phase4"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    txc = Line(a.tx, 7020)
    rxc = Line(a.rx, 7022)
    result = {"args": vars(a), "started": time.time()}

    if a.mode == "sweep":
        ref = load_ref(os.path.join(a.presets, a.image))
        e = encoder_symbols(ref)
        print(txc.cmd(f"src {a.board_presets}/{a.image}"))
        rx = RxImages(a.rx)
        rx.start()
        print(txc.cmd(f"att {a.att0 + a.top}"))
        time.sleep(a.top_settle)
        rows = []
        for extra in [float(x) for x in a.att.split(",")]:
            txc.cmd(f"att {a.att0 + extra}")
            time.sleep(a.settle)
            rx.take()
            t0 = time.time()
            time.sleep(a.dwell)
            got = rx.take()
            span = time.time() - t0
            p = [psnr(img, ref) for _, _, img in got]
            z = symbols(rxc, 4)
            row = {"att": extra, "rx_fps": round(len(got) / span, 2), "frames": len(got),
                   "psnr": stats(p), "evm_db": round(evm_db(z), 2) if len(z) else None,
                   "snr_da_db": round(snr_da_db(z, e), 2) if len(z) else None, "sym_frames": len(z)}
            rows.append(row)
            print(f"att {extra:5.1f}: {row['rx_fps']:5.2f} fps, PSNR {row['psnr']['mean']}, "
                  f"EVM {row['evm_db']} dB, SNR(DA) {row['snr_da_db']} dB", flush=True)
        txc.cmd(f"att {a.att0}")
        result["results"] = rows
        with open(os.path.join(a.out, "sweep.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["att", "rx_fps", "frames", "psnr_mean", "psnr_p10", "psnr_median", "evm_db", "snr_da_db"])
            for r in rows:
                w.writerow([r["att"], r["rx_fps"], r["frames"], r["psnr"]["mean"], r["psnr"]["p10"],
                            r["psnr"]["median"], r["evm_db"], r["snr_da_db"]])

    elif a.mode == "latency":
        files = sorted(f for f in os.listdir(a.presets) if f.lower().endswith((".png", ".jpg", ".jpeg", ".npy")))
        refs = [load_ref(os.path.join(a.presets, f)) for f in files]
        print(txc.cmd(f"src {a.board_presets}"))
        ev = TxEvents(a.tx)
        ev.start()
        rx = RxImages(a.rx)
        rx.start()
        time.sleep(2.0)
        ev.take(), rx.take()
        off_tx, rtt_tx = clock_offset(txc)
        off_rx, rtt_rx = clock_offset(Line(a.rx, 7022))
        time.sleep(a.dwell)
        tx_ev, got = ev.take(), rx.take()
        lat, amb, psnrs = [], 0, []
        by_idx = {}
        for n, t0, t1, idx in tx_ev:
            by_idx.setdefault(idx, []).append(t0 - off_tx)
        for tb, _, img in got:
            p = [psnr(img, r) for r in refs]
            k = int(np.argmax(p))
            psnrs.append(p[k])
            t_rx = tb - off_rx
            cand = [t for t in by_idx.get(k, []) if t < t_rx]
            if not cand or sorted(p)[-1] - sorted(p)[-2] < 3:
                amb += 1
                continue
            lat.append((t_rx - max(cand)) * 1e3)
        result.update(images=files, clock={"tx_offset": off_tx, "tx_rtt_ms": rtt_tx * 1e3, "rx_offset": off_rx,
                                           "rx_rtt_ms": rtt_rx * 1e3},
                      latency_ms=stats(lat), ambiguous=amb, rx_fps=round(len(got) / a.dwell, 2),
                      tx_fps=round(len(tx_ev) / a.dwell, 2), psnr=stats(psnrs))
        print(f"latency {result['latency_ms']}, ambiguous {amb}, RX {result['rx_fps']} fps, "
              f"TX {result['tx_fps']} fps; clock RTT TX {rtt_tx * 1e3:.2f} ms, RX {rtt_rx * 1e3:.2f} ms")

    else:
        rx = RxImages(a.rx)
        rx.start()
        time.sleep(2.0)
        rx.take()
        t0, per_s, last = time.time(), [], time.time()
        n = 0
        while time.time() - t0 < a.dwell:
            time.sleep(1.0)
            k = len(rx.take())
            now = time.time()
            per_s.append(k / (now - last))
            last, n = now, n + k
        result.update(frames=n, rx_fps=round(n / (time.time() - t0), 2), per_second=stats(per_s))
        print(f"{n} images in {a.dwell:.0f} s: {result['rx_fps']} fps, per second {result['per_second']}")

    json.dump(result, open(os.path.join(a.out, f"{a.mode}.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
