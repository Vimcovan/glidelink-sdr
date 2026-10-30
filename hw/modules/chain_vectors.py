"""Vectors for the shell testbench tb_shell4: host port 1 -> slot 1 (NCO) -> slot 2 (FIR)
-> host port 1, through the shell's register window. regs.hex holds shell addresses
(routes, then slot 1 at 0x3000, slot 2 at 0x4000); out.hex = FIR(NCO(in)) by the models.

    python chain_vectors.py <dir>
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sc16 import pack  # noqa: E402


def load(name):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name, "model.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


nco, fir = load("nco"), load("fir")


def main(d):
    os.makedirs(d, exist_ok=True)
    rng = np.random.default_rng(9)
    n = 8000
    t = np.arange(n)
    x = 20000 * np.exp(2j * np.pi * -0.05 * t) + rng.normal(0, 2000, n) + 1j * rng.normal(0, 2000, n)
    words = pack(np.clip(np.round(x.real), -32768, 32767).astype(np.int64),
                 np.clip(np.round(x.imag), -32768, 32767).astype(np.int64))
    freq, phase = 0x0CCC_CCCD, 0x1234_5678           # +0.05 fs: the tone moves to DC
    h, shift = fir.lowpass(0.08), 15
    mid, _ = nco.process(words, freq, phase)
    out = fir.process(mid, h, shift)
    regs = [(0x1010, 3), (0x1014, 4), (0x100C, 5)]   # slot 1 <- host 1 TX, slot 2 <- slot 1, host 1 RX <- slot 2
    regs += [(0x3000 + a, v) for a, v in [(0x010, freq), (0x014, phase), (0x008, 1)]]
    regs += [(0x4000 + a, v) for a, v in fir.coef_writes(h) + [(0x014, shift), (0x008, 0x5)]]
    open(os.path.join(d, "regs.hex"), "w", newline="\n").write("".join(f"{a:04X} {v:08X}\n" for a, v in regs))
    for name, w in (("in.hex", words), ("out.hex", out)):
        open(os.path.join(d, name), "w", newline="\n").write("".join(f"{int(v):08X}\n" for v in w))


if __name__ == "__main__":
    main(sys.argv[1])
