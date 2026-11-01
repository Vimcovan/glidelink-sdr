"""Fixed-coefficient FIR filters on the Xilinx FIR Compiler (rrc_interp, lp_decim, rrc_mf): the
coefficient designs, the .coe files and the reference arithmetic they share.

The coefficients are set when the image is built (a .coe file the IP reads); the IP computes the
full-precision convolution, the wrapper (glidelink_fir_fixed.v) rounds, shifts and saturates:

    interpolation by L:  y[n L + p] = sum_j h[p + j L] x[n - j]      (= zero-stuffing, then h)
    decimation by M:     y[m] = (h * x)[m M + PHASE]
    out = sat16((y + 2^(SHIFT-1)) >> SHIFT)   on I and Q

    python fir_fixed.py <module dir>   writes <module dir>/ip/<id>.coe from its model's taps()
"""
import importlib.util
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack, sat16  # noqa: E402


def rrc(ntaps, sps, alpha, gain=1.0):
    """root raised cosine, sps samples per symbol, normalised to a DC gain of gain (as GNU Radio)"""
    t = (np.arange(ntaps) - (ntaps - 1) / 2) / sps
    h = np.zeros(ntaps)
    for k, x in enumerate(t):
        if abs(x) < 1e-12:
            h[k] = 1 - alpha + 4 * alpha / math.pi
        elif abs(abs(x) - 1 / (4 * alpha)) < 1e-12:
            h[k] = alpha / math.sqrt(2) * ((1 + 2 / math.pi) * math.sin(math.pi / (4 * alpha))
                                           + (1 - 2 / math.pi) * math.cos(math.pi / (4 * alpha)))
        else:
            h[k] = (math.sin(math.pi * x * (1 - alpha)) + 4 * alpha * x * math.cos(math.pi * x * (1 + alpha))) \
                / (math.pi * x * (1 - (4 * alpha * x) ** 2))
    return h * gain / h.sum()


def lowpass(ntaps, cutoff, gain=1.0):
    """windowed-sinc low-pass (Hamming), cutoff in units of the sample rate, DC gain gain"""
    n = np.arange(ntaps) - (ntaps - 1) / 2
    h = 2 * cutoff * np.sinc(2 * cutoff * n) * np.hamming(ntaps)
    return h * gain / h.sum()


def quantize(h, frac_bits):
    q = np.round(np.asarray(h) * 2 ** frac_bits).astype(np.int64)
    assert np.abs(q).max() <= 32767, "coefficient does not fit 16 bits"
    return [int(v) for v in q]


def write_coe(path, taps):
    with open(path, "w", newline="\n") as f:
        f.write("radix=10;\ncoefdata=\n" + ",\n".join(str(v) for v in taps) + ";\n")


def filt(x, h, shift):
    y = np.convolve(np.asarray(x, np.int64), np.asarray(h, np.int64))[:len(x)]
    r = (1 << (shift - 1)) if shift > 0 else 0
    return sat16((y + r) >> shift)


class Fixed:
    """The arithmetic of one filter with its delay line and decimation phase kept across calls."""

    def __init__(self, taps, shift, interp=1, decim=1, phase=0):
        self.h, self.shift, self.L, self.M, self.phase = list(taps), shift, interp, decim, phase
        self.reset()

    def reset(self):
        self.hi = np.zeros(len(self.h) - 1, np.int64)     # delay line, I and Q
        self.hq = np.zeros(len(self.h) - 1, np.int64)
        self.pos = 0                                       # filter outputs so far (decimation)

    def process(self, words):
        i, q = unpack(np.asarray(words, np.uint32))
        if self.L > 1:                                     # L - 1 zeros after each sample
            ui = np.zeros(len(i) * self.L, np.int64)
            uq = np.zeros(len(q) * self.L, np.int64)
            ui[::self.L], uq[::self.L] = i, q
            i, q = ui, uq
        n0 = len(self.hi)
        xi, xq = np.concatenate([self.hi, i]), np.concatenate([self.hq, q])
        yi, yq = filt(xi, self.h, self.shift)[n0:], filt(xq, self.h, self.shift)[n0:]
        self.hi, self.hq = xi[len(xi) - n0:], xq[len(xq) - n0:]
        if self.M > 1:                                     # one output in every M
            keep = (self.pos + np.arange(len(yi))) % self.M == self.phase
            self.pos += len(yi)
            yi, yq = yi[keep], yq[keep]
        return pack(yi, yq)


def load_model(module_dir):
    spec = importlib.util.spec_from_file_location("m", os.path.join(module_dir, "model.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    d = os.path.abspath(sys.argv[1])
    mid = os.path.basename(d)
    write_coe(os.path.join(d, "ip", mid + ".coe"), load_model(d).taps())
    print(f"{mid}: ip/{mid}.coe")
