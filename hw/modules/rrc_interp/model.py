"""RRC interpolator (Xilinx FIR Compiler): reference model of glidelink_rrc_interp.v (arithmetic: hw/modules/fir_fixed/fir_fixed.py).

TX: the PC's QPSK symbols to the RF rate. root raised cosine pulse shaping, 4 samples per symbol, rolloff 0.35, 11 symbols (45 taps), gain 4 (the zeros of the interpolation), x 2^14. taps() is what ip/rrc_interp.coe holds (python ../fir_fixed/fir_fixed.py .).
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "fir_fixed"))
import fir_fixed  # noqa: E402
import module_desc  # noqa: E402

INTERP, DECIM, PHASE, SHIFT = 4, 1, 0, 14


def taps():
    return fir_fixed.quantize(fir_fixed.rrc(45, 4, 0.35, 4.0), 14)


class Model(module_desc.RegisterModel):
    def __init__(self, params=None):
        super().__init__(module_desc.load("rrc_interp", os.path.dirname(HERE)), params)
        # the IP's output lags the zero-stuffed filter output by one sample (its first output is 0;
        # seen in its simulation model): as the coefficients with a zero in front
        self.f = fir_fixed.Fixed([0] + list(taps()), SHIFT, INTERP, DECIM, PHASE)

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
