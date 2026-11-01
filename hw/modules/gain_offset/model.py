"""Gain and offset: reference model of glidelink_gain_offset.v at register level (docs/module_guide.md).

I and Q each: sat16(((x * GAIN + 2^13) >> 14) + OFFSET), GAIN, OFFSET_I, OFFSET_Q signed 16 bit.

process(words) gets uint32 sc16 words {Q[31:16], I[15:0]} and returns the module's output for
them; registers are in self.regs by name (self.field(reg, field) for fields).
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack, sat16  # noqa: E402,F401
import module_desc  # noqa: E402


class Model(module_desc.RegisterModel):
    def __init__(self, params=None):
        super().__init__(module_desc.load("gain_offset", os.path.dirname(HERE)), params)

    def process(self, words):
        words = np.asarray(words, np.uint32)
        if not self.field("CONTROL", "enable"):
            return words.copy()
        s16 = lambda v: (v & 0xFFFF) - ((v & 0x8000) << 1)
        g = s16(self.regs["GAIN"])
        i, q = unpack(words)
        return pack(sat16(((i * g + (1 << 13)) >> 14) + s16(self.regs["OFFSET_I"])),
                    sat16(((q * g + (1 << 13)) >> 14) + s16(self.regs["OFFSET_Q"])))
