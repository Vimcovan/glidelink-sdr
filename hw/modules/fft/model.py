"""FFT / IFFT (the RFNoC FFT block core): reference model of glidelink_fft.sv.

Not bit-exact: the Xilinx FFT core (scaled, convergent rounding, 24-bit phase factors)
is modelled in floating point, so the module is checked against this model with a
tolerance (check_captured). Per FFT of N = 2^LENGTH_LOG2 samples:

    X = FFT(x) (forward, DIRECTION = 1) or N * IFFT(x) (inverse), times the scaling
    schedule's gain (1/N for the default schedule at N = 4096; 2^-sum(stage shifts)
    in general), then reordered (ORDER) and optionally reduced to magnitude
    ~ max(|I|, |Q|) + min(|I|, |Q|) / 4 or magnitude squared (I^2 + Q^2) / 32768,
    clipped to 0 .. 32767, in I with Q = 0. KEEP = k passes FFTs 0, k, 2k, ... (the wrapper's
register, not part of the RFNoC block).

Cyclic prefix removal / insertion with one-entry lists (CP_*_LEN, then CP_*_LIST_LOAD;
the lists repeat) drops the first cp_rem samples of each input block of N + cp_rem, and
repeats the last cp_ins outputs in front of each FFT. Model: the module at register level, with
lists of any length (the software GNU Radio block drives it as the PL block drives the module).

    python model.py vectors   writes tb/ vectors for the module testbench (capture mode;
                              tb/vectors_bypass: compare mode, CONTROL.enable = 0)
    python model.py check     compares tb/<vectors>/captured.hex with the model
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack, sat16  # noqa: E402
import module_desc  # noqa: E402

MAX_LOG2 = 12
ORDER_NORMAL, ORDER_REVERSE, ORDER_NATURAL, ORDER_BITREV = 0, 1, 2, 3
MAG_NONE, MAG_MAG, MAG_SQ = 0, 1, 2


def stages(n_log2):
    """radix-4 stages of the Xilinx pipelined streaming FFT (the last one radix-2 for odd log2)"""
    return (n_log2 + 1) // 2


def default_scaling(n_log2=MAX_LOG2):
    """1/N: 2 per radix-4 stage, 1 for a final radix-2 stage (as fft_scale_default)"""
    s = stages(n_log2)
    if n_log2 % 2 == 0:
        return int("10" * s, 2)
    return int("01" + "10" * (s - 1), 2)


def scaling_gain(scaling, n_log2):
    """total gain of a scaling schedule: 2^-(sum of the 2-bit shifts of the used stages)"""
    shift = sum((scaling >> (2 * k)) & 3 for k in range(stages(n_log2)))
    return 2.0 ** -shift


def bitrev(n_log2):
    k = np.arange(1 << n_log2)
    return np.array([int(format(v, f"0{n_log2}b")[::-1], 2) for v in k]) if n_log2 else k


def transform(x, n_log2, scaling=None, direction=1, order=ORDER_NORMAL, bypass=False):
    """complex FFT of one block, as integers before rounding (bypass: the block itself, reordered)"""
    n = 1 << n_log2
    if scaling is None:
        scaling = default_scaling(n_log2)
    if bypass:
        X = np.asarray(x, np.complex128)
    else:
        X = np.fft.fft(x) if direction else np.fft.ifft(x) * n
        X = X * scaling_gain(scaling, n_log2)
    if order == ORDER_NORMAL:
        X = np.fft.fftshift(X)
    elif order == ORDER_REVERSE:
        X = np.fft.fftshift(X)[::-1]
    elif order == ORDER_BITREV:
        X = X[bitrev(n_log2)]
    return X


def process(words, n_log2=MAX_LOG2, scaling=None, direction=1, order=ORDER_NORMAL,
            magnitude=MAG_NONE, cp_rem=0, cp_ins=0, keep=1, enable=True, bypass=False):
    """output words for the input words (whole blocks only)"""
    words = np.asarray(words, np.uint32)
    if not enable:
        return words.copy()
    n = 1 << n_log2
    i, q = unpack(words)
    x = (i + 1j * q).astype(np.complex128)
    blk = n + cp_rem
    out = []
    for b in range(0, len(x) // blk, max(keep, 1)):    # KEEP: one FFT in every keep
        X = transform(x[b * blk + cp_rem:(b + 1) * blk], n_log2, scaling, direction, order, bypass)
        if cp_ins:
            X = np.concatenate([X[-cp_ins:], X])
        xi, xq = np.round(X.real), np.round(X.imag)
        if magnitude == MAG_MAG:
            a, c = np.abs(xi), np.abs(xq)
            xi, xq = np.minimum(np.maximum(a, c) + np.floor(np.minimum(a, c) / 4), 32767), 0 * xq
        elif magnitude == MAG_SQ:
            xi, xq = np.minimum(np.round((xi ** 2 + xq ** 2) / 32768), 32767), 0 * xq
        out.append(pack(sat16(xi.astype(np.int64)), sat16(xq.astype(np.int64))))
    return np.concatenate(out) if out else np.zeros(0, np.uint32)


class Model(module_desc.RegisterModel):
    """glidelink_fft at register level: whole FFT blocks as they arrive, the cyclic prefix
    lists cycled, one FFT in every KEEP passed"""

    RESETS = ("CONTROL", "LENGTH_LOG2", "RESET", "CP_INS_LIST_LOAD", "CP_INS_LIST_CLR")

    def __init__(self, params=None):
        super().__init__(module_desc.load("fft", os.path.dirname(HERE)), params)
        self.ins, self.rem = [], []
        self.restart()

    def restart(self):
        self.buf = np.zeros(0, np.uint32)
        self.ri = self.ii = self.kcnt = 0

    def on_write(self, name, value):
        if name == "CP_INS_LIST_LOAD":
            self.ins.append(self.regs["CP_INS_LEN"] & 0xFFF)
        elif name == "CP_INS_LIST_CLR":
            self.ins = []
        elif name == "CP_REM_LIST_LOAD":
            self.rem.append(self.regs["CP_REM_LEN"] & 0xFFF)
        elif name == "CP_REM_LIST_CLR":
            self.rem = []
        if name in self.RESETS:             # the wrapper resets the core between packets
            self.restart()

    def on_read(self, name):
        return {"CP_INS_LIST_OCC": len(self.ins), "CP_REM_LIST_OCC": len(self.rem), "OVERFLOW": 0}.get(name)

    def process(self, words):
        words = np.asarray(words, np.uint32)
        if not self.field("CONTROL", "enable"):
            return words.copy()
        self.buf = np.concatenate([self.buf, words])
        n_log2 = self.regs["LENGTH_LOG2"] & 0x1F
        keep = max(self.regs["KEEP"] & 0xFFFF, 1)
        out, pos = [], 0
        while True:
            rem = self.rem[self.ri % len(self.rem)] if self.rem else 0
            blk = (1 << n_log2) + rem
            if len(self.buf) - pos < blk:
                break
            ins = self.ins[self.ii % len(self.ins)] if self.ins else 0
            if self.kcnt == 0:
                out.append(process(self.buf[pos:pos + blk], n_log2, self.regs["SCALING"], self.regs["DIRECTION"] & 1,
                                   self.regs["ORDER"] & 3, self.regs["MAGNITUDE"] & 3, rem, ins,
                                   bypass=bool(self.regs["BYPASS"] & 1)))
            self.kcnt = (self.kcnt + 1) % keep
            self.ri += 1
            self.ii += 1
            pos += blk
        self.buf = self.buf[pos:]
        return np.concatenate(out) if out else np.zeros(0, np.uint32)


# ---------------------------------------------------------------------------
# testbench vectors (capture mode: tb_module.v writes captured.hex)
# ---------------------------------------------------------------------------

CASES = {
    # name: (register writes, model arguments, FFTs)
    "vectors": ([(0x008, 1)], {}, 3),                                   # 4096, normal order
    "vectors_256_natural": ([(0x114, 8), (0x118, default_scaling(8)), (0x148, ORDER_NATURAL), (0x008, 1)],
                            {"n_log2": 8, "order": ORDER_NATURAL}, 8),
    "vectors_cp_magsq": ([(0x114, 6), (0x118, default_scaling(6)), (0x130, 16), (0x134, 1), (0x14C, MAG_SQ), (0x008, 1)],
                         {"n_log2": 6, "cp_rem": 16, "magnitude": MAG_SQ}, 20),
    "vectors_ifft_cpins": ([(0x114, 6), (0x118, 0), (0x11C, 0), (0x148, ORDER_NATURAL), (0x120, 16), (0x124, 1), (0x008, 1)],
                           {"n_log2": 6, "scaling": 0, "direction": 0, "order": ORDER_NATURAL, "cp_ins": 16}, 20),
    "vectors_keep": ([(0x114, 8), (0x118, default_scaling(8)), (0x010, 3), (0x14C, MAG_MAG), (0x008, 1)],
                     {"n_log2": 8, "keep": 3, "magnitude": MAG_MAG}, 12),
}


def stimulus(n_log2, nfft, cp_rem, rng, small=False):
    n = 1 << n_log2
    t = np.arange(nfft * (n + cp_rem))
    x = np.zeros(len(t), np.complex128)
    for f, a in ((3, 9000), (-17, 6000), (n // 4 + 0.5, 3000)):    # on-bin and off-bin tones
        x += a * np.exp(2j * np.pi * f * t / n)
    x += 500 * (rng.standard_normal(len(t)) + 1j * rng.standard_normal(len(t)))
    if small:                                                       # IFFT without scaling: no overflow
        x = x / 64
    return pack(sat16(np.round(x.real).astype(np.int64)), sat16(np.round(x.imag).astype(np.int64)))


def write_vectors(name, seed=3):
    regs, args, nfft = CASES[name]
    d = os.path.join(HERE, "tb", name)
    os.makedirs(d, exist_ok=True)
    rng = np.random.default_rng(seed)
    words = stimulus(args.get("n_log2", MAX_LOG2), nfft, args.get("cp_rem", 0), rng,
                     small=args.get("scaling", None) == 0)
    last = np.zeros(len(words), int)
    pos = 0
    while pos < len(words):                 # input packets of any size: the module repacketizes
        pos += int(rng.integers(50, 1500))
        last[min(pos, len(words)) - 1] = 1
    open(os.path.join(d, "regs.hex"), "w", newline="\n").write("".join(f"{a:03X} {v:08X}\n" for a, v in regs))
    open(os.path.join(d, "in.hex"), "w", newline="\n").write(
        "".join(f"{int(v):08X} {l}\n" for v, l in zip(words, last)))
    return nfft


def write_bypass(seed=4):
    """CONTROL.enable = 0: the samples pass unchanged (compare mode, tuser checked)"""
    d = os.path.join(HERE, "tb", "vectors_bypass")
    os.makedirs(d, exist_ok=True)
    rng = np.random.default_rng(seed)
    words = rng.integers(0, 1 << 32, 5000, dtype=np.uint64).astype(np.uint32)
    last = np.zeros(len(words), int)
    pos = 0
    while pos < len(words):
        pos += int(rng.integers(1, 700))
        last[min(pos, len(words)) - 1] = 1
    # a LENGTH_LOG2 write while disabled: the core resets, the stream must not notice
    open(os.path.join(d, "regs.hex"), "w", newline="\n").write("114 00000008\n")
    for nm in ("in.hex", "out.hex"):
        open(os.path.join(d, nm), "w", newline="\n").write(
            "".join(f"{int(v):08X} {l}\n" for v, l in zip(words, last)))


def check_captured(name, tol_lsb=4.0):
    regs, args, nfft = CASES[name]
    d = os.path.join(HERE, "tb", name)
    words = np.array([int(l.split()[0], 16) for l in open(os.path.join(d, "in.hex"))], np.uint32)
    cap = [l.split() for l in open(os.path.join(d, "captured.hex"))]
    got = np.array([int(c[0], 16) for c in cap], np.uint32)
    lasts = np.array([int(c[1]) for c in cap])
    exp = process(words, **args)
    plen = (1 << args.get("n_log2", MAX_LOG2)) + args.get("cp_ins", 0)
    ok = len(got) == len(exp) and np.all(np.flatnonzero(lasts) == np.arange(plen - 1, len(got), plen))
    gi, gq = unpack(got[:len(exp)])
    ei, eq = unpack(exp[:len(got)])
    err = np.abs(np.concatenate([gi - ei, gq - eq]))
    rms = float(np.sqrt(np.mean(err ** 2))) if len(err) else float("inf")
    peak = int(err.max()) if len(err) else -1
    ok = ok and rms <= tol_lsb
    print(f"{name}: {len(got)} of {len(exp)} samples, packets of {plen}: "
          f"{'ok' if ok else 'WRONG'}, error rms {rms:.2f} LSB, peak {peak} LSB -> {'PASS' if ok else 'FAIL'}")
    return ok


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    names = sys.argv[2:] or list(CASES)
    if cmd == "vectors":
        for nm in names:
            nfft, keep = write_vectors(nm), CASES[nm][1].get("keep", 1)
            print(nm, -(-nfft // keep))         # output packets
        if not sys.argv[2:]:
            write_bypass()
    elif cmd == "check":
        sys.exit(0 if all([check_captured(nm) for nm in names]) else 1)
    else:
        print(__doc__)
