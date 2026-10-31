#!/usr/bin/env python3
"""The FFT module (dsp image) on a board, with PL connections made the GRC way (pl_connect).

loop   host port 1 TX -> FFT (PL) -> host port 1 RX: known tones from the PC, the FFT output
       compared with the module's reference model (hw/modules/fft/model.py); a second pass with
       KEEP = 3 checks that only every third FFT comes back.
rf     RF RX -> FFT (PL, KEEP = 1, complex) -> host port 1 RX: per-FFT power, and the mean
       spectrum of the strongest FFTs against the weakest (bursts of the other board).

    python3 gr_pl_fft.py loop [board]
    python3 gr_pl_fft.py rf [board] [rx_freq] [gain]
"""
import os
import sys
import time

import numpy as np
from gnuradio import blocks, gr, glidelink

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "hw", "modules"))
sys.path.insert(0, os.path.join(HERE, "..", "..", "hw", "modules", "fft"))
import model  # noqa: E402
from sc16 import from_complex, to_complex  # noqa: E402

N_LOG2 = 10
N = 1 << N_LOG2


def collect(tb, snk, n_items, timeout=20.0):
    tb.start()
    t0 = time.time()
    while len(snk.data()) < n_items and time.time() - t0 < timeout:
        time.sleep(0.1)
    tb.stop()
    tb.wait()
    return np.array(snk.data()[:n_items], np.complex64)


def loop(board, keep):
    args = "driver=glidelink,uri=ip:" + board
    nfft = 48
    t = np.arange(nfft * N)
    rng = np.random.default_rng(1)
    x = (0.25 * np.exp(2j * np.pi * 37 * t / N) + 0.12 * np.exp(-2j * np.pi * 300.5 * t / N)
         + 0.01 * (rng.standard_normal(len(t)) + 1j * rng.standard_normal(len(t))))
    words = from_complex(x)
    xq = to_complex(words)                              # what the PL receives

    tb = gr.top_block()
    src = blocks.vector_source_c(xq.tolist(), True)     # repeated: whole FFTs, aligned
    snk_h = glidelink.host_sink(args, "complex", False)
    fft = glidelink.fft(args, 1, N, "forward", "normal", "complex", -1, keep)
    src_h = glidelink.host_source(args, "complex", False)
    vs = blocks.vector_sink_c()
    tb.connect(src, snk_h)
    tb.connect(src_h, vs)
    glidelink.pl_connect(snk_h, "0", fft, "0")
    glidelink.pl_connect(fft, "0", src_h, "0")
    y = collect(tb, vs, 24 * N)

    # the output starts at an FFT boundary (one FFT per packet); find which input FFT it is
    exp_all = to_complex(model.process(words, n_log2=N_LOG2))
    blocks_exp = exp_all.reshape(nfft, N)
    got = y.reshape(-1, N)
    errs = []
    for g in got:
        e = np.abs(blocks_exp - g).max(axis=1) * 32768
        errs.append(e.min())
    errs = np.array(errs)
    # with KEEP = k, consecutive outputs are k input FFTs apart
    first = [int(np.argmin(np.abs(blocks_exp - g).max(axis=1))) for g in got[:6]]
    step = np.diff(first) % nfft
    ok = errs.max() <= 4 and np.all(step == keep)
    print(f"loop KEEP={keep}: {len(got)} FFTs back, max error {errs.max():.1f} LSB (median {np.median(errs):.1f}), "
          f"input FFTs {first} -> {'PASS' if ok else 'FAIL'}")
    return ok


def rf(board, freq, gain):
    args = "driver=glidelink,uri=ip:" + board
    tb = gr.top_block()
    radio = glidelink.radio(board, 20e6, freq, 0, 0, "manual", gain, 89)
    scaling = 2 | 2 << 2 | 2 << 4 | 1 << 6 | 1 << 8     # 2^-8
    fft = glidelink.fft(args, 1, N, "forward", "normal", "complex", scaling, 1)
    src_h = glidelink.host_source(args, "complex", True)
    vs = blocks.vector_sink_c()
    tb.connect(src_h, vs)
    glidelink.pl_connect(radio, "0", fft, "0")
    glidelink.pl_connect(fft, "0", src_h, "0")
    nf = 4000                                            # 4000 x 51.2 us = 0.2 s
    y = collect(tb, vs, nf * N).reshape(-1, N)
    p = np.abs(y) ** 2
    frame_db = 10 * np.log10(p.mean(axis=1) + 1e-20)
    order = np.argsort(frame_db)
    strong, weak = order[-len(order) // 20:], order[:len(order) // 2]
    spec = lambda idx: 10 * np.log10(p[idx].mean(axis=0) + 1e-20)
    s, w = spec(strong), spec(weak)
    f = (np.arange(N) - N // 2) * 20e6 / N / 1e6
    inner, outer = np.abs(f) < 7, np.abs(f) > 9
    print(f"rf: {len(y)} FFTs, frame power median {np.median(frame_db):.1f} dBFS, max {frame_db.max():.1f} dBFS, "
          f"frames > median + 10 dB: {np.mean(frame_db > np.median(frame_db) + 10) * 100:.1f} %")
    print(f"    strongest 5 %: |f| < 7 MHz {s[inner].mean():.1f} dBFS, |f| > 9 MHz {s[outer].mean():.1f} dBFS; "
          f"weakest half: {w[inner].mean():.1f} / {w[outer].mean():.1f} dBFS")
    for lo in range(-10, 10, 2):
        sel = (f >= lo) & (f < lo + 2)
        print(f"    {lo:+3d}..{lo + 2:+3d} MHz  strong {s[sel].mean():6.1f}  weak {w[sel].mean():6.1f}")
    return True


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    board = sys.argv[2] if len(sys.argv) > 2 else "192.168.3.1"
    if cmd == "loop":
        sys.exit(0 if loop(board, 1) and loop(board, 3) else 1)
    elif cmd == "rf":
        rf(board, float(sys.argv[3]) if len(sys.argv) > 3 else 915e6, float(sys.argv[4]) if len(sys.argv) > 4 else 30)
    else:
        print(__doc__)
