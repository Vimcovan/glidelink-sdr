"""AGC: reference model of glidelink_agc.v at register level (docs/module_guide.md).

As GNU Radio's agc_cc, in fixed point, one sample at a time (g: 1.0 = 65536):

    y  = sat16((x * g + 2^15) >> 16)                       I and Q
    m  = max(|yI|, |yQ|) + (3 min(|yI|, |yQ|) >> 3)        magnitude within 7 %
    g += (2 (REFERENCE - m)) >> RATE_SHIFT                 arithmetic shift
    g  = min(max(g, 0), MAX_GAIN)

Disabled: samples pass unchanged, the gain holds. A soft reset (and a flush) sets g to GAIN as
written.
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack  # noqa: E402
import module_desc  # noqa: E402

GMASK = (1 << 26) - 1


def sat16(v):
    return -32768 if v < -32768 else 32767 if v > 32767 else v


class Model(module_desc.RegisterModel):
    def __init__(self, params=None):
        super().__init__(module_desc.load("agc", os.path.dirname(HERE)), params)
        self.g = self.regs["GAIN"]

    def on_write(self, name, value):
        if name == "GAIN" or (name == "CONTROL" and value & 2):
            self.g = self.regs["GAIN"] & GMASK

    def on_read(self, name):
        return self.g if name == "GAIN" else None

    def process(self, words):
        words = np.asarray(words, np.uint32)
        if not self.field("CONTROL", "enable"):
            return words.copy()
        i, q = unpack(words)
        ref, s, gmax = self.regs["REFERENCE"], self.regs["RATE_SHIFT"], self.regs["MAX_GAIN"]
        g = self.g
        oi = np.empty(len(i), np.int64)
        oq = np.empty(len(i), np.int64)
        for n, (xi, xq) in enumerate(zip(i.tolist(), q.tolist())):
            yi = sat16((xi * g + (1 << 15)) >> 16)
            yq = sat16((xq * g + (1 << 15)) >> 16)
            a, b = abs(yi), abs(yq)
            m = max(a, b) + ((3 * min(a, b)) >> 3)
            g += (2 * (ref - m)) >> s
            g = 0 if g < 0 else gmax if g > gmax else g
            oi[n], oq[n] = yi, yq
        self.g = g
        return pack(oi, oq)
