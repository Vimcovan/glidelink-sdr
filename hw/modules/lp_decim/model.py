"""Low-pass decimator by 2 (Xilinx FIR Compiler): reference model of glidelink_lp_decim.v (arithmetic: hw/modules/fir_fixed/fir_fixed.py).

RX: 4 to 2 samples per symbol after the RF (a QPSK at 4 samples per symbol occupies +-0.169 of the input rate). windowed-sinc low-pass (Hamming), cutoff 0.2 of the input rate, 33 taps, gain 1, x 2^15. taps() is what ip/lp_decim.coe holds (python ../fir_fixed/fir_fixed.py .).
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fir_fixed"))
import fir_fixed  # noqa: E402
import module_desc  # noqa: E402

INTERP, DECIM, PHASE, SHIFT = 1, 2, 0, 15


def taps():
    return fir_fixed.quantize(fir_fixed.lowpass(33, 0.2), 15)


class Model(module_desc.RegisterModel):
    def __init__(self, params=None):
        super().__init__(module_desc.load("lp_decim", os.path.dirname(HERE)), params)
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
