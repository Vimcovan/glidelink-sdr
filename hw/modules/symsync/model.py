"""Symbol sync (Gardner): reference model of glidelink_symsync.v at register level.

Timing recovery for 2 samples per symbol of a matched-filtered signal (M. Rice, Digital
Communications: A Discrete-Time Approach, ch. 8): a modulo-1 NCO decremented by W per sample
marks the symbols, a piecewise parabolic Farrow interpolator (alpha 1/2) takes the symbol and
the midpoint before it, a Gardner detector gives the timing error and a PI loop filter steers W.
Fixed point (eta, W: 1.0 = 2^24; mu: 1.0 = 2^15; samples Q15), per input sample x:

    history h0 = x(n), h1, h2, h3, h4
    when the NCO underflowed two samples ago with mu:
        ys = farrow(h0, h1, h2, h3, mu)     between h2 and h1
        ym = farrow(h1, h2, h3, h4, mu)     between h3 and h2 (half a symbol earlier)
        e  = ymI (ysI - yprevI) + ymQ (ysQ - yprevQ),  yprev = ys;  ys goes out
        v  = I + ((e KP) >> 30),  I = I + ((e KI) >> 30) within +-MAX_DEV (no wind-up)
        W  = W0 + v within W0 +- MAX_DEV
    eta -= W; if eta < 0: underflow, mu = min(2 eta_before >> 9, 32767), eta += 2^24

    farrow(a, b, c, d, mu) = sat16(c + (((((a - b - c + d) mu) >> 15) + (-a + 3b - c - d)) mu >> 15 >> 1))

gains(loop_bw, damping, ted_gain) gives KP, KI (Rice eq. C.56, N = 2, K0 = -1); loop_bw is
B_n T (per symbol). Output: one sample per symbol, carrying the tuser of a packet start and any
tlast among the input samples since the previous output.
"""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack  # noqa: E402
import module_desc  # noqa: E402

ONE = 1 << 24


def sat16(v):
    return -32768 if v < -32768 else 32767 if v > 32767 else v


def farrow(a, b, c, d, mu):
    v2 = a - b - c + d
    v1 = -a + 3 * b - c - d
    t = ((v2 * mu) >> 15) + v1
    return sat16(c + (((t * mu) >> 15) >> 1))


def gains(loop_bw, damping, ted_gain):
    """(KP, KI): PI loop gains x 2^24 for B_n T = loop_bw, damping, TED gain (per Q15^2 / 2^30)"""
    n = 2
    theta = loop_bw / n / (damping + 1 / (4 * damping))
    d = 1 + 2 * damping * theta + theta * theta
    k1 = 4 * damping * theta / d / ted_gain
    k2 = 4 * theta * theta / d / ted_gain
    return round(k1 * 2 ** 24), round(k2 * 2 ** 24)


def s24(v):
    v &= 0xFFFFFF
    return v - (1 << 24) if v & 0x800000 else v


class Model(module_desc.RegisterModel):
    def __init__(self, params=None):
        super().__init__(module_desc.load("symsync", os.path.dirname(HERE)), params)
        self.restart()

    def restart(self):
        self.h = [(0, 0)] * 5
        self.eta = 0
        self.w = self.regs["W0"]
        self.integ = 0
        self.flags = [None, None]               # mu of underflows one and two samples ago
        self.yprev = (0, 0)

    def on_write(self, name, value):
        if name == "CONTROL" and value & 2:
            self.restart()

    def on_read(self, name):
        if name == "STATUS":
            return self.field("CONTROL", "enable")
        if name == "W":
            return self.w
        return None

    def process(self, words):
        words = np.asarray(words, np.uint32)
        if not self.field("CONTROL", "enable"):
            return words.copy()
        xi, xq = unpack(words)
        kp, ki = s24(self.regs["KP"]), s24(self.regs["KI"])
        w0, dev = self.regs["W0"], self.regs["MAX_DEV"]
        h, eta, w, integ, flags, yprev = self.h, self.eta, self.w, self.integ, self.flags, self.yprev
        out = []
        for a, b in zip(xi.tolist(), xq.tolist()):
            h = [(a, b)] + h[:4]
            mu = flags[1]
            if mu is not None:
                ysi = farrow(h[0][0], h[1][0], h[2][0], h[3][0], mu)
                ysq = farrow(h[0][1], h[1][1], h[2][1], h[3][1], mu)
                ymi = farrow(h[1][0], h[2][0], h[3][0], h[4][0], mu)
                ymq = farrow(h[1][1], h[2][1], h[3][1], h[4][1], mu)
                e = ymi * (ysi - yprev[0]) + ymq * (ysq - yprev[1])
                yprev = (ysi, ysq)
                out.append((ysi, ysq))
                v = integ + ((e * kp) >> 30)
                integ += (e * ki) >> 30
                integ = -dev if integ < -dev else dev if integ > dev else integ
                w = w0 + v
                w = w0 - dev if w < w0 - dev else w0 + dev if w > w0 + dev else w
            nxt = eta - w
            uf = None
            if nxt < 0:
                uf = min((2 * eta) >> 9, 32767)
                nxt += ONE
            eta = nxt
            flags = [uf, flags[0]]
        self.h, self.eta, self.w, self.integ, self.flags, self.yprev = h, eta, w, integ, flags, yprev
        if not out:
            return np.zeros(0, np.uint32)
        o = np.array(out, np.int64)
        return pack(o[:, 0], o[:, 1])
