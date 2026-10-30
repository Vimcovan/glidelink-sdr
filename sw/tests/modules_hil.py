"""Phase 3 hardware-in-the-loop (docs/phase3_modules.md): the PL modules against their reference
models, word for word. Host port 1 TX -> slot(s) -> host port 1 RX, raw, through the Soapy module:

    nco        slot 1 alone
    fir        slot 2 alone
    nco+fir    slot 1 then slot 2

Each case sends the same pseudo-random input (a tone plus noise near full scale, so the
saturation is exercised) and compares the output with hw/modules/<id>/model.py.

    python3 modules_hil.py [--args driver=glidelink,uri=ip:192.168.3.1] [--buffers 16]
"""
import argparse
import importlib.util
import os
import threading

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CS16

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink")
ap.add_argument("--buffers", type=int, default=16, help="DMA buffers of 16384 words per case")
a = ap.parse_args()

HW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "hw", "modules")
if not os.path.isdir(HW):                       # copied next to the script on the board
    HW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "modules")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


sc16 = load(os.path.join(HW, "sc16.py"), "sc16")
nco = load(os.path.join(HW, "nco", "model.py"), "nco_model")
fir = load(os.path.join(HW, "fir", "model.py"), "fir_model")

BUFFER = 16384
HOST1, SLOT1, SLOT2, NONE = 3, 4, 5, 15         # switch indices (sink = source for slots / host 1)
d = SoapySDR.Device(a.args)
reg = lambda addr, v: d.writeRegister("FPGA", addr, v)
route = lambda sink, src: reg(0x1000 + 4 * sink, src)
assert (d.readRegister("FPGA", 0x004) >= 0x00010400), "needs shell 1.4 (three slots)"

FREQ, PHASE = 0x0E38_E38E, 0x2000_0000          # +1/18 fs
H, SHIFT = fir.lowpass(0.11), 15
reg(0x3010, FREQ)
reg(0x3014, PHASE)
reg(0x3008, 1)
for addr, v in fir.coef_writes(H):
    reg(0x4000 + addr, v)
reg(0x4014, SHIFT)
reg(0x4008, 0x5)

n = a.buffers * BUFFER
rng = np.random.default_rng(7)
t = np.arange(n)
x = 28000 * np.exp(2j * np.pi * 0.031 * t) + rng.normal(0, 3000, n) + 1j * rng.normal(0, 3000, n)
words = sc16.pack(np.clip(np.round(x.real), -32768, 32767).astype(np.int64),
                  np.clip(np.round(x.imag), -32768, 32767).astype(np.int64))


def loop(chain):
    """routes host 1 TX -> chain -> host 1 RX, streams the words, returns what came back"""
    for s in (SLOT1, SLOT2):
        route(s, NONE)
    src = HOST1
    for s in chain:
        route(s, src)
        src = s
    route(HOST1, src)
    args = {"port": "1", "headers": "false", "bufferLength": str(BUFFER)}
    rx = d.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], args)
    tx = d.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CS16, [0], args)
    d.activateStream(rx)                        # flushes the slots on the path: phase = PHASE,
    d.activateStream(tx)                        # delay line cleared
    got = np.zeros(n, np.uint32)
    pos = [0]

    def rx_loop():
        buf = np.empty(BUFFER, np.uint32)
        while pos[0] < n:
            r = d.readStream(rx, [buf.view(np.int16)], BUFFER, timeoutUs=2000000)
            if r.ret <= 0:
                print("  RX returned", r.ret)
                return
            got[pos[0]:pos[0] + r.ret] = buf[:r.ret]
            pos[0] += r.ret

    th = threading.Thread(target=rx_loop)
    th.start()
    p = 0
    while p < n:
        r = d.writeStream(tx, [words[p:p + BUFFER].view(np.int16)], min(BUFFER, n - p), timeoutUs=2000000)
        if r.ret <= 0:
            print("  TX returned", r.ret)
            break
        p += r.ret
    th.join(timeout=20)
    for s in (rx, tx):
        d.deactivateStream(s)
        d.closeStream(s)
    return got, pos[0]


failures = []
for name, chain in (("nco", [SLOT1]), ("fir", [SLOT2]), ("nco+fir", [SLOT1, SLOT2])):
    want = words
    if SLOT1 in chain:
        want, _ = nco.process(want, FREQ, PHASE)
    if SLOT2 in chain:
        want = fir.process(want, H, SHIFT)
    got, k = loop(chain)
    diff = int(np.count_nonzero(got[:k] != want[:k]))
    ok = k == n and diff == 0
    print(f"{name:8s}: {k} of {n} words back, {diff} different from the model")
    if not ok:
        failures.append(name)
        if diff:
            i = int(np.flatnonzero(got[:k] != want[:k])[0])
            print(f"  first difference at {i}: got {got[i]:08X}, model {want[i]:08X}")

for s in (SLOT1, SLOT2, HOST1):
    route(s, NONE)
print("PASS" if not failures else "FAIL " + " ".join(failures))
