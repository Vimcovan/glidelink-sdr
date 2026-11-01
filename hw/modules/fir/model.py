"""FIR filter: bit-exact reference model of glidelink_fir.v.

Real coefficients h[0..TAPS-1] (signed 16 bit) applied to I and Q separately:

    y[n] = sum_k h[k] x[n-k]                     (x before the first sample = 0)
    out  = sat16((y + r) >> SHIFT),  r = 2^(SHIFT-1) for SHIFT > 0, else 0

The delay line runs on across packets; a soft reset clears it. With
CONTROL.enable = 0 the samples pass unchanged and do not enter the delay line.
Coefficients are written to a shadow set (COEF_ADDR, then COEF_DATA with
auto-increment) and take effect together on CONTROL.load. Model: the module at register level
(the software GNU Radio block and the generic test drive it as they drive the PL module).

    python model.py vectors   writes tb/ vectors for the module testbench
"""
import os
import sys

import numpy as np

TAPS = 32
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack, sat16  # noqa: E402
import module_desc  # noqa: E402


def filt(x, h, shift):
    y = np.convolve(x, np.asarray(h, np.int64))[:len(x)]
    r = (1 << (shift - 1)) if shift > 0 else 0
    return sat16((y + r) >> shift)


def process(words, h, shift, enable=True):
    words = np.asarray(words, np.uint32)
    if not enable:
        return words.copy()
    h = np.asarray(h, np.int64)
    assert len(h) == TAPS
    i, q = unpack(words)
    return pack(filt(i, h, shift), filt(q, h, shift))


class Model(module_desc.RegisterModel):
    """glidelink_fir at register level"""

    def __init__(self, params=None):
        super().__init__(module_desc.load("fir", os.path.dirname(HERE)), params)
        self.n = int(self.params["TAPS"])
        self.shadow = [0] * self.n
        self.h = [0] * self.n
        self.caddr = 0
        self.hist = np.zeros(self.n - 1, np.uint32)          # the delay line (enabled samples)

    def on_write(self, name, value):
        if name == "COEF_ADDR":
            self.caddr = value & 0xFF
        elif name == "COEF_DATA":
            if self.caddr < self.n:
                self.shadow[self.caddr] = (value & 0xFFFF) - ((value & 0x8000) << 1)
            self.caddr = (self.caddr + 1) & 0xFF
        elif name == "CONTROL":
            if value & 2:
                self.hist[:] = 0
            if value & 4:
                self.h = list(self.shadow)

    def on_read(self, name):
        if name == "STATUS":
            return self.field("CONTROL", "enable")
        if name == "COEF_ADDR":
            return self.caddr
        if name == "COEF_DATA":
            return self.shadow[self.caddr] if self.caddr < self.n else 0
        return None

    def process(self, words):
        words = np.asarray(words, np.uint32)
        if not self.field("CONTROL", "enable"):
            return words.copy()
        x = np.concatenate([self.hist, words])
        i, q = unpack(x)
        shift = self.regs["SHIFT"]
        out = pack(filt(i, self.h, shift), filt(q, self.h, shift))[len(self.hist):]
        self.hist = x[len(x) - len(self.hist):]
        return out


def coef_writes(h):
    """register writes that load h: COEF_ADDR = 0, COEF_DATA x TAPS, CONTROL.load"""
    return [(0x018, 0)] + [(0x01C, int(c) & 0xFFFF) for c in h]


def lowpass(cutoff, shift=15):
    """a windowed-sinc low-pass, cutoff in units of fs, scaled to 2^shift"""
    n = np.arange(TAPS) - (TAPS - 1) / 2
    h = np.sinc(2 * cutoff * n) * np.hamming(TAPS)
    h = h / h.sum()
    return np.round(h * (1 << shift)).astype(np.int64)


def write_vectors(d, seed=2, h=None, shift=14, enable=True):
    rng = np.random.default_rng(seed)
    os.makedirs(d, exist_ok=True)
    n = 6000
    if h is None:
        # random coefficients include the extremes; a strong input forces saturation
        h = rng.integers(-32768, 32768, TAPS)
        h[0], h[5], h[31] = -32768, 32767, 12345
    i = rng.integers(-32768, 32768, n)
    q = rng.integers(-32768, 32768, n)
    i[1000:1400] = 32767                    # long full-scale run: saturates
    q[2000:2300] = -32768
    i[3000:3500] = rng.integers(-300, 300, 500)   # small values: rounding
    words = pack(i, q)
    out = process(words, h, shift, enable)
    last = np.zeros(n, int)
    pos = 0
    while pos < n:
        pos += int(rng.integers(1, 700))
        last[min(pos, n) - 1] = 1
    regs = coef_writes(h) + [(0x014, shift), (0x008, 0x4 | int(enable))]    # load (+ enable)
    open(os.path.join(d, "regs.hex"), "w", newline="\n").write("".join(f"{a:03X} {v:08X}\n" for a, v in regs))
    for name, w in (("in.hex", words), ("out.hex", out)):
        open(os.path.join(d, name), "w", newline="\n").write(
            "".join(f"{int(v):08X} {l}\n" for v, l in zip(w, last)))


if __name__ == "__main__":
    if (sys.argv[1] if len(sys.argv) > 1 else "") == "vectors":
        write_vectors(os.path.join(HERE, "tb", "vectors"))
        write_vectors(os.path.join(HERE, "tb", "vectors_shift0"), 5, np.arange(TAPS) % 5 - 2, 0)
        write_vectors(os.path.join(HERE, "tb", "vectors_lowpass"), 6, lowpass(0.1), 15)
        write_vectors(os.path.join(HERE, "tb", "vectors_bypass"), 7, enable=False)
    else:
        print(__doc__)
