"""FLL band-edge: reference model of glidelink_fll.v at register level (docs/module_guide.md).

As GNU Radio's fll_band_edge_cc, in fixed point, one sample at a time. The band-edge filters
are the baseband filter b (two sincs, as GNU Radio designs it) turned to +-(1 + rolloff) / (2 sps)
cycles per sample; with c_k = b_k cos(w (k - N)), s_k = b_k sin(w (k - N)) the upper filter is
P + jQ and the lower P - jQ, P = sum c_k y[n-k], Q = sum s_k y[n-k], so

    error = |lower|^2 - |upper|^2 = -4 Im(P conj(Q))

Per sample (phase / frequency: 2^32 per cycle; tables as the NCO module):

    y  = x exp(j 2 pi phase / 2^32)      4096-point table, (+2^14) >> 15, saturated
    P, Q over the last TAPS outputs y (coefficients c, s: signed 16 bit, COEF_DATA 2k = c_k,
         2k + 1 = s_k), each part >> (TAP_SHIFT - 1) and saturated to 18 bits
    e  = Pq Qi - Pi Qq,  eq = e >> 12      (37 bits -> 25: the loop does not need the 12 LSBs,
                                            dropping them moves the frequency by < 50 Hz against
                                            ~500 Hz of loop jitter at 10 MSPS)
    f' = f - ((eq BETA) >> BETA_SHIFT),  phase += f' - ((eq ALPHA) >> ALPHA_SHIFT),
    f = min(max(f', -FREQ_MAX), FREQ_MAX)

which is GNU Radio's freq += beta err; phase += freq + alpha err with err = -e / 2^30 (y at full
scale 1.0, coefficients x 2^TAP_SHIFT) when ALPHA = 2 alpha / pi 2^(ALPHA_SHIFT + 12) (17 bits:
the gain fits a DSP's 18-bit port, eq its 27-bit one) and the same for BETA.
Disabled: samples pass unchanged, the loop holds. Output: y.

design(sps, rolloff, filter_size) gives the coefficients and TAP_SHIFT; loop_gains(w) ALPHA, BETA
(GNU Radio's control loop, damping sqrt(2)/2); freq_max(sps) the limit +-2 / sps rad per sample.
"""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack  # noqa: E402
import module_desc  # noqa: E402

TABLE_BITS = 12
M32 = 0xFFFFFFFF


def table():
    k = np.arange(1 << TABLE_BITS)
    c = np.round(32767 * np.cos(2 * np.pi * k / (1 << TABLE_BITS))).astype(np.int64)
    s = np.round(32767 * np.sin(2 * np.pi * k / (1 << TABLE_BITS))).astype(np.int64)
    return c, s


def design(sps, rolloff, filter_size):
    """(coefficient words: c_0, s_0, c_1, s_1, ..., TAP_SHIFT) for the band-edge filters"""
    M = round(filter_size / sps)
    k = -M + np.arange(filter_size) * 2.0 / sps
    bb = np.sinc(rolloff * k - 0.5) + np.sinc(rolloff * k + 0.5)
    bb = bb / bb.sum()
    N = int((filter_size - 1.0) / 2.0)
    w = 2 * np.pi * (1 + rolloff) / (2.0 * sps)
    c = bb * np.cos(w * (np.arange(filter_size) - N))
    s = bb * np.sin(w * (np.arange(filter_size) - N))
    ts = int(math.floor(math.log2(32767 / max(np.abs(c).max(), np.abs(s).max()))))
    ci, si = np.round(c * 2 ** ts).astype(int), np.round(s * 2 ** ts).astype(int)
    words = [int(v) & 0xFFFF for pair in zip(ci, si) for v in pair]
    return words, ts


def mantissa(g):
    """(G, shift) with g ~ G / 2^(shift + 12), G within 17 bits, as precise as that allows"""
    sh = 31
    while sh > 0 and round(g * 2 ** (sh + 12)) >= 1 << 17:
        sh -= 1
    return round(g * 2 ** (sh + 12)), sh


def loop_gains(w):
    """(ALPHA, ALPHA_SHIFT, BETA, BETA_SHIFT) for loop bandwidth w, as GNU Radio's control_loop
    (damping sqrt(2) / 2)"""
    z = math.sqrt(2) / 2
    d = 1 + 2 * z * w + w * w
    alpha, beta = 4 * z * w / d, 4 * w * w / d
    return mantissa(2 * alpha / math.pi) + mantissa(2 * beta / math.pi)


def freq_max(sps):
    return round(2 ** 32 / (math.pi * sps))


def s32(v):
    v &= M32
    return v - (1 << 32) if v & 0x80000000 else v


def sat(v, bits):
    lim = 1 << (bits - 1)
    return -lim if v < -lim else lim - 1 if v > lim - 1 else v


class Model(module_desc.RegisterModel):
    def __init__(self, params=None):
        super().__init__(module_desc.load("fll", os.path.dirname(HERE)), params)
        self.n = int(self.params["TAPS"])
        self.shadow = [0] * (2 * self.n)
        self.c = [0] * self.n
        self.s = [0] * self.n
        self.caddr = 0
        self.tab = [t.tolist() for t in table()]
        self.restart()

    def restart(self):
        self.hi = [0] * self.n                  # history of the outputs, newest first
        self.hq = [0] * self.n
        self.phase = 0
        self.f = s32(self.regs["FREQ"])

    def on_write(self, name, value):
        if name == "COEF_ADDR":
            self.caddr = value & 0xFF
        elif name == "COEF_DATA":
            if self.caddr < 2 * self.n:
                self.shadow[self.caddr] = (value & 0xFFFF) - ((value & 0x8000) << 1)
            self.caddr = (self.caddr + 1) & 0xFF
        elif name == "FREQ":
            self.f = s32(value)
        elif name == "CONTROL":
            if value & 4:
                self.c, self.s = self.shadow[0::2], self.shadow[1::2]
            if value & 2:
                self.restart()

    def on_read(self, name):
        if name == "STATUS":
            return self.field("CONTROL", "enable")
        if name == "COEF_ADDR":
            return self.caddr
        if name == "COEF_DATA":
            return self.shadow[self.caddr] if self.caddr < 2 * self.n else 0
        if name == "FREQ":
            return self.f & M32
        if name == "PHASE":
            return self.phase
        return None

    def process(self, words):
        words = np.asarray(words, np.uint32)
        if not self.field("CONTROL", "enable"):
            return words.copy()
        xi_all, xq_all = unpack(words)
        C, S = self.tab
        sh = self.regs["TAP_SHIFT"] - 1
        alpha, beta, fmax = self.regs["ALPHA"], self.regs["BETA"], self.regs["FREQ_MAX"]
        ash, bsh = self.regs["ALPHA_SHIFT"], self.regs["BETA_SHIFT"]
        c, s, hi, hq = self.c, self.s, self.hi, self.hq
        phase, f = self.phase, self.f
        oi = np.empty(len(words), np.int64)
        oq = np.empty(len(words), np.int64)
        for n, (xi, xq) in enumerate(zip(xi_all.tolist(), xq_all.tolist())):
            k = phase >> 20
            yi = sat((xi * C[k] - xq * S[k] + (1 << 14)) >> 15, 16)
            yq = sat((xi * S[k] + xq * C[k] + (1 << 14)) >> 15, 16)
            hi.insert(0, yi); hi.pop()
            hq.insert(0, yq); hq.pop()
            pi = sum(a * b for a, b in zip(c, hi)) >> sh
            pq = sum(a * b for a, b in zip(c, hq)) >> sh
            qi = sum(a * b for a, b in zip(s, hi)) >> sh
            qq = sum(a * b for a, b in zip(s, hq)) >> sh
            pi, pq, qi, qq = sat(pi, 18), sat(pq, 18), sat(qi, 18), sat(qq, 18)
            eq = (pq * qi - pi * qq) >> 12
            f2 = f - ((eq * beta) >> bsh)
            phase = (phase + f2 - ((eq * alpha) >> ash)) & M32
            f = -fmax if f2 < -fmax else fmax if f2 > fmax else f2
            oi[n], oq[n] = yi, yq
        self.phase, self.f = phase, f
        return pack(oi, oq)


def write_rom(path):
    c, s = table()
    lines = ["// generated by hw/modules/fll/model.py (python model.py rom): do not edit",
             "// 4096-point table, {sin, cos}, each round(32767 * f(2 pi k / 4096)); one-cycle read", "",
             "`timescale 1ns/100ps", "", "module glidelink_fll_rom (", "  input             clk,",
             "  input     [11:0]  addr,", "  output reg [31:0] data", ");", "", "  always @(posedge clk)",
             "    case (addr)"]
    for k in range(len(c)):
        lines.append(f"      12'd{k}: data <= 32'h{(int(s[k]) & 0xFFFF):04X}{(int(c[k]) & 0xFFFF):04X};")
    lines += ["    endcase", "", "endmodule", ""]
    open(path, "w", newline="\n").write("\n".join(lines))


if __name__ == "__main__":
    if (sys.argv[1] if len(sys.argv) > 1 else "") == "rom":
        write_rom(os.path.join(HERE, "glidelink_fll_rom.v"))
    else:
        print(__doc__)
