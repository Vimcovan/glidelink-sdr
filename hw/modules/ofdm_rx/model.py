"""OFDM receiver: test vectors and an output checker for glidelink_ofdm_rx (docs/phase4_plan.md).

The module wraps the competition RTL unchanged (phase 4 decision G3); this checks that what the
transmitter sent comes back: the input is the OFDM transmitter's output (its simulation capture,
tb/vectors of ../ofdm_tx, i.e. the frames of known symbols), with a stretch of low noise in front
and small noise on top; every received soft symbol must decide back to the 64-QAM point sent.

    python model.py vectors          tb/vectors/{regs,in}.hex from ../ofdm_tx/tb/vectors/captured.hex
    python model.py check <captured.hex> [prbs]
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack  # noqa: E402
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "ofdm_tx"))
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("ofdm_tx_model", os.path.join(os.path.dirname(HERE), "ofdm_tx", "model.py"))
tx = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tx)

LEAD = 3000                                     # samples of noise before the first frame
TX_FRAMES = 2                                   # frames in ../ofdm_tx/tb/vectors


def write_vectors(d, noise=2.0, seed=5):
    rng = np.random.default_rng(seed)
    words, _, _ = tx.read_capture(os.path.join(os.path.dirname(HERE), "ofdm_tx", "tb", "vectors", "captured.hex"))
    i, q = unpack(words)
    i = np.r_[np.zeros(LEAD), i / 16.0]         # back to 12-bit units for the noise
    q = np.r_[np.zeros(LEAD), q / 16.0]
    i = np.clip(np.round(i + rng.normal(0, noise, len(i))), -2048, 2047).astype(np.int64) << 4
    q = np.clip(np.round(q + rng.normal(0, noise, len(q))), -2048, 2047).astype(np.int64) << 4
    w = pack(i, q)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "regs.hex"), "w", newline="\n").write("")
    last = np.zeros(len(w), int)
    last[4095::4096] = 1                        # packets as the RF RX streamer cuts them
    open(os.path.join(d, "in.hex"), "w", newline="\n").write("".join(f"{int(x):08X} {l}\n" for x, l in zip(w, last)))


def check(path, prbs=False):
    words, last, _ = tx.read_capture(path)
    ends = np.flatnonzero(last)
    errors = []
    n = len(ends)
    print(f"{len(words)} symbols, {n} frames")
    if n == 0 or np.any(np.diff(np.r_[-1, ends]) != tx.FRAME_SYMS):
        errors.append(f"frame lengths {np.diff(np.r_[-1, ends])[:4]} (want {tx.FRAME_SYMS})")
    # the transmitter's vectors hold TX_FRAMES frames (symbols() draws all I, then all Q,
    # so it must be asked for the same number to give the same values)
    ti, tq = tx.prbs_symbols(max(n, 1)) if prbs else tx.symbols(max(n, TX_FRAMES))
    i, q = unpack(words[:n * tx.FRAME_SYMS])
    # the receiver's output scale: least squares against the symbols sent
    y = i + 1j * q
    e = ti[:len(y)] + 1j * tq[:len(y)]
    scale = np.vdot(y, e) / np.vdot(y, y)
    z = y * scale
    di = tx.LEVELS[np.argmin(np.abs(z.real[:, None] - tx.LEVELS[None, :]), axis=1)]
    dq = tx.LEVELS[np.argmin(np.abs(z.imag[:, None] - tx.LEVELS[None, :]), axis=1)]
    wrong = int(np.count_nonzero((di != e.real) | (dq != e.imag)))
    evm = 10 * np.log10(np.mean(np.abs(z - e) ** 2) / np.mean(np.abs(e) ** 2))
    print(f"scale {abs(scale):.3f}, EVM {evm:.1f} dB, symbols decided wrong: {wrong}")
    if wrong:
        errors.append("symbols do not come back")
    for x in errors:
        print("ERROR:", x)
    print("PASS" if not errors else "FAIL")
    return not errors


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else ""
    if what == "vectors":
        write_vectors(os.path.join(HERE, "tb", "vectors"))
    elif what == "check":
        sys.exit(0 if check(sys.argv[2], len(sys.argv) > 3 and sys.argv[3] == "prbs") else 1)
    else:
        print(__doc__)
