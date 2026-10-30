"""Phase 4.2 / 4.3 on one board (image phy_test: slot 1 ofdm_tx, slot 2 ofdm_rx, both 100 MHz),
through the AD9361 digital loopback at 20 MSPS (docs/phase4_plan.md).

    tx      ofdm_tx in PRBS mode -> RF TX -> loopback -> RF RX -> host port 0: the capture is
            checked by hw/modules/ofdm_tx/model.py (frames, preamble bit for bit, gap, every data
            symbol back to its 64-QAM point after an FFT)
    txrx    ofdm_tx (PRBS) -> RF TX -> loopback -> RF RX -> ofdm_rx -> host port 1: every received
            frame must decide back to the PRBS frame; the receiver's frame counters give the rate

Run on the board, next to modules/ (sc16.py, ofdm_tx/{model.py,preamble.mem}, ofdm_rx/model.py):

    python3 phy_loopback.py [tx|txrx|both] [--seconds 2]
"""
import argparse
import importlib.util
import os
import sys
import time

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_CS16

ap = argparse.ArgumentParser()
ap.add_argument("what", nargs="?", default="both", choices=["tx", "txrx", "both"])
ap.add_argument("--args", default="driver=glidelink")
ap.add_argument("--seconds", type=float, default=2.0)
a = ap.parse_args()

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = next(d for d in (os.path.join(HERE, "modules"), os.path.join(HERE, "..", "..", "hw", "modules"))
            if os.path.isdir(d))


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


txm = load(os.path.join(MODS, "ofdm_tx", "model.py"), "ofdm_tx_model")

RF, HOST0, HOST1, SLOT_TX, SLOT_RX, NONE = 0, 1, 3, 4, 5, 15
BASE_TX, BASE_RX = 0x3000, 0x4000
d = SoapySDR.Device(a.args)
reg = lambda addr, v=None: d.readRegister("FPGA", addr) if v is None else d.writeRegister("FPGA", addr, v)
route = lambda sink, src: reg(0x1000 + 4 * sink, src)
assert reg(BASE_TX) == 0x4F465458 and reg(BASE_RX) == 0x4F465258, "needs image phy_test"

phy = next(i for i in range(12) if os.path.exists(f"/sys/bus/iio/devices/iio:device{i}/name")
           and open(f"/sys/bus/iio/devices/iio:device{i}/name").read().strip() == "ad9361-phy")
LOOPBACK = f"/sys/kernel/debug/iio/iio:device{phy}/loopback"
d.setSampleRate(SOAPY_SDR_RX, 0, 20e6)
open(LOOPBACK, "w").write("1")

# transmitter: PRBS frames to the RF
reg(BASE_TX + 0x008, 0x2)                       # soft reset
reg(BASE_TX + 0x008, 0x5)                       # enable + PRBS
route(RF, SLOT_TX)
reg(0x05C, 0x2)                                 # flush the RF TX side (shells before the idle-route fix kept the old source)
failures = []


def capture(port, n, chunk=1 << 18):
    """n words from host port 0 (RF RX, raw) or 1 (module data, raw)"""
    args = {"headers": "false", "bufferLength": str(chunk)}
    if port == 1:
        args["port"] = "1"
    s = d.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], args)
    d.activateStream(s)
    out = np.empty(n, np.uint32)
    got = 0
    while got < n:
        r = d.readStream(s, [out[got:].view(np.int16)], min(chunk, n - got), timeoutUs=2000000)
        if r.ret <= 0:
            print("  readStream", r.ret)
            break
        got += r.ret
    d.deactivateStream(s)
    d.closeStream(s)
    return out[:got]


if a.what in ("tx", "both"):
    print("== tx: OFDM transmitter through the digital loopback")
    route(HOST0, RF)
    w = capture(0, 4 * (txm.FRAME_LEN + txm.GAP))
    # host port 0 gives CS16 at 12-bit full scale: back to the PL's 16-bit words
    i = (w & 0xFFFF).astype(np.uint16).view(np.int16).astype(np.int64) << 4
    q = (w >> 16).astype(np.uint16).view(np.int16).astype(np.int64) << 4
    words = ((q & 0xFFFF) << 16 | (i & 0xFFFF)).astype(np.uint32)
    path = "/tmp/phy_tx_capture.npy"
    np.save(path, words)
    if not txm.check_rx(path):
        failures.append("tx")

if a.what in ("txrx", "both"):
    print("== txrx: OFDM transmitter -> loopback -> OFDM receiver")
    route(HOST0, NONE)                          # the RF RX source goes to one sink: the receiver
    reg(0x05C, 0x1)                             # host port 0 RX may sit mid-packet with nobody reading: drop it
    route(SLOT_RX, RF)
    route(HOST1, SLOT_RX)
    reg(BASE_RX + 0x008, 0x3)                   # soft reset + enable
    f0, t0 = reg(BASE_RX + 0x010), time.time()
    time.sleep(a.seconds)
    f1, t1 = reg(BASE_RX + 0x010), time.time()
    rate = (f1 - f0) / (t1 - t0)
    print(f"  receiver: {rate:.1f} frames/s (frame airtime 2.798 ms: 357.4 frames/s at most), "
          f"dropped {reg(BASE_RX + 0x014)} (frame buffer full: nobody reading yet)")
    sym = capture(1, 8 * txm.FRAME_SYMS)
    n = len(sym) // txm.FRAME_SYMS
    ti, tq = txm.prbs_symbols(1)
    e = ti + 1j * tq
    i = ((sym & 0xFFFF).astype(np.uint16).view(np.int16)).astype(float)
    q = ((sym >> 16).astype(np.uint16).view(np.int16)).astype(float)
    worst_evm, wrong = -99.0, 0
    for f in range(n):
        y = i[f * txm.FRAME_SYMS:(f + 1) * txm.FRAME_SYMS] + 1j * q[f * txm.FRAME_SYMS:(f + 1) * txm.FRAME_SYMS]
        sc = np.vdot(y, e) / np.vdot(y, y)
        z = y * sc
        di = txm.LEVELS[np.argmin(np.abs(z.real[:, None] - txm.LEVELS[None, :]), axis=1)]
        dq = txm.LEVELS[np.argmin(np.abs(z.imag[:, None] - txm.LEVELS[None, :]), axis=1)]
        wrong += int(np.count_nonzero((di != e.real) | (dq != e.imag)))
        worst_evm = max(worst_evm, 10 * np.log10(np.mean(np.abs(z - e) ** 2) / np.mean(np.abs(e) ** 2)))
    print(f"  {n} frames read: worst EVM {worst_evm:.1f} dB, symbols decided wrong {wrong}")
    if n < 4 or wrong or rate < 340:
        failures.append("txrx")

for s in (RF, HOST1, SLOT_RX):
    route(s, NONE)
route(RF, HOST0)
route(HOST0, RF)
reg(BASE_TX + 0x008, 0x0)
open(LOOPBACK, "w").write("0")
print("PASS" if not failures else "FAIL " + " ".join(failures))
