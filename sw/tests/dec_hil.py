"""Phase 4.5 hardware-in-the-loop (docs/phase4_plan.md): the DeepJSCC-Q decoder module (slot 2,
250 MHz, image rx) against the integer model, word for word. Host port 1 TX -> slot 2 -> host
port 1 RX, raw, through the Soapy module.

The vectors come from hw/modules/jscc_dec/model.py hil (dec_hil.npz: four images encoded and
passed through AWGN at 30 / 20 / 10 / 5 dB, their 32768 soft symbol words and the decoded images
of 49152 words); the board cannot run the model, so the file is copied next to the script. The
symbol frames are sent back to back --frames times (cycling through the four); every returned
image must equal its model image.

    python3 dec_hil.py [--vectors dec_hil.npz] [--frames 60]
"""
import argparse
import os
import threading
import time

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CS16

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink")
ap.add_argument("--vectors", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "dec_hil.npz"))
ap.add_argument("--frames", type=int, default=60)
a = ap.parse_args()

z = np.load(a.vectors)
symbols, decoded = z["symbols"], z["decoded"]
SYMS, IMG_WORDS = symbols.shape[1], decoded.shape[1]
BUFFER = 16384

HOST1, SLOT_DEC, NONE = 3, 5, 15
BASE = 0x2000 + 0x1000 * 2                      # slot 2 register window
d = SoapySDR.Device(a.args)
reg = lambda addr, v=None: d.readRegister("FPGA", addr) if v is None else d.writeRegister("FPGA", addr, v)
route = lambda sink, src: reg(0x1000 + 4 * sink, src)
assert reg(BASE) == 0x4A444543, "needs image rx (jscc_dec in slot 2)"

order = [k % len(symbols) for k in range(a.frames)]
tx_words = np.concatenate([symbols[k] for k in order]).astype(np.uint32)
n_out = a.frames * IMG_WORDS

route(SLOT_DEC, HOST1)
route(HOST1, SLOT_DEC)
reg(BASE + 0x008, 0x3)                          # soft reset + enable
args = {"port": "1", "headers": "false", "bufferLength": str(BUFFER)}
rx = d.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], args)
tx = d.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CS16, [0], args)
d.activateStream(rx)
d.activateStream(tx)
got = np.zeros(n_out, np.uint32)
pos = [0]
t_last = [0.0]


def rx_loop():
    buf = np.empty(BUFFER, np.uint32)
    while pos[0] < n_out:
        r = d.readStream(rx, [buf.view(np.int16)], min(BUFFER, n_out - pos[0]), timeoutUs=3000000)
        if r.ret <= 0:
            print("  RX returned", r.ret)
            return
        got[pos[0]:pos[0] + r.ret] = buf[:r.ret]
        pos[0] += r.ret
    t_last[0] = time.time()


th = threading.Thread(target=rx_loop)
th.start()
t0 = time.time()
p = 0
while p < len(tx_words):
    r = d.writeStream(tx, [tx_words[p:p + BUFFER].view(np.int16)], min(BUFFER, len(tx_words) - p),
                      timeoutUs=3000000)
    if r.ret <= 0:
        print("  TX returned", r.ret)
        break
    p += r.ret
th.join(timeout=30)
for s in (rx, tx):
    d.deactivateStream(s)
    d.closeStream(s)

frames_hw = reg(BASE + 0x010)
syms_hw = reg(BASE + 0x014)
k = pos[0] // IMG_WORDS
bad = []
for f in range(k):
    diff = int(np.count_nonzero(got[f * IMG_WORDS:(f + 1) * IMG_WORDS] != decoded[order[f]]))
    if diff:
        bad.append((f, diff))
rate = k / (t_last[0] - t0) if t_last[0] else 0.0
print(f"{k} of {a.frames} frames back (decoder counted {frames_hw} frames, {syms_hw} symbols), "
      f"{len(bad)} frames different from the model")
for f, diff in bad[:5]:
    i = int(np.flatnonzero(got[f * IMG_WORDS:(f + 1) * IMG_WORDS] != decoded[order[f]])[0])
    print(f"  frame {f} (image {order[f]}): {diff} words differ, first at {i}: "
          f"got {got[f * IMG_WORDS + i]:08X}, model {decoded[order[f]][i]:08X}")
print(f"end-to-end through host port 1: {rate:.1f} frames/s (DMA both ways included)")

route(SLOT_DEC, NONE)
route(HOST1, NONE)
print("PASS" if k == a.frames and not bad and rate >= 30 else "FAIL")
