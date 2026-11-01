"""RRC matched filter (Xilinx FIR Compiler): reference model of glidelink_rrc_mf.v (arithmetic: hw/modules/fir_fixed/fir_fixed.py).

RX: before the symbol sync. root raised cosine matched filter, 2 samples per symbol, rolloff 0.35, 11 symbols (23 taps), gain 1, x 2^15. taps() is what ip/rrc_mf.coe holds (python ../fir_fixed/fir_fixed.py .).
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fir_fixed"))
import fir_fixed  # noqa: E402
import module_desc  # noqa: E402

INTERP, DECIM, PHASE, SHIFT = 1, 1, 0, 15


def taps():
    return fir_fixed.quantize(fir_fixed.rrc(23, 2, 0.35, 1.0), 15)


class Model(module_desc.RegisterModel):
    def __init__(self, params=None):
        super().__init__(module_desc.load("rrc_mf", os.path.dirname(HERE)), params)
        self.f = fir_fixed.Fixed(taps(), SHIFT, INTERP, DECIM, PHASE)

    def on_write(self, name, value):
        if name == "CONTROL" and value & 2:
            self.f.reset()

    def on_read(self, name):
        return self.field("CONTROL", "enable") if name == "STATUS" else None

    def process(self, words):
        words = np.asarray(words, np.uint32)
        if not self.field("CONTROL", "enable"):
            return words.copy()
        return self.f.process(words)
