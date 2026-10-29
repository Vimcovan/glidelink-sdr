"""Phase 1 acceptance on one board (docs/phase1_shell.md step 1.4): timed TX bursts come back
through the AD9361 digital loopback at a fixed offset on the RX timestamps.

Both streams use the shell's packet headers. Each burst (a ramp that cannot be mistaken for
the zeros between bursts) is sent at "now + lead" with END_BURST; the RX side finds the burst's
first sample and its time. The offset RX time - TX time must be the same for every burst, and
the shell's late / underflow / overflow counters must not move.

    python3 timed_burst.py [--rate 10e6] [--bursts 20] [--lead 0.02]
"""
import argparse
import threading
import time

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CS16, SOAPY_SDR_HAS_TIME, SOAPY_SDR_END_BURST

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink")
ap.add_argument("--rate", type=float, default=10e6)
ap.add_argument("--bursts", type=int, default=20)
ap.add_argument("--lead", type=float, default=0.02, help="seconds between now and the send time")
ap.add_argument("--len", type=int, default=1000)
a = ap.parse_args()

phy = next(i for i in range(8)
           if open(f"/sys/bus/iio/devices/iio:device{i}/name").read().strip() == "ad9361-phy")
LOOPBACK = f"/sys/kernel/debug/iio/iio:device{phy}/loopback"
open(LOOPBACK, "w").write("1")

d = SoapySDR.Device(a.args)
d.setSampleRate(SOAPY_SDR_RX, 0, a.rate)
rate = d.getSampleRate(SOAPY_SDR_RX, 0)
reg = lambda addr: d.readRegister("FPGA", addr)
counters = lambda: (reg(0x040), reg(0x044), reg(0x048), reg(0x04C))   # overflow, underflow, late, header errors

rx = d.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0])
tx = d.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CS16, [0])
d.activateStream(rx)
d.activateStream(tx)

# RX thread: keep (time of first sample, samples) for every read
chunks = []
stop = threading.Event()


def rx_loop():
    buf = np.empty(2 * 16384, np.int16)
    while not stop.is_set():
        r = d.readStream(rx, [buf], 16384, timeoutUs=200000)
        if r.ret > 0 and r.flags & SOAPY_SDR_HAS_TIME:
            chunks.append((r.timeNs, buf[:2 * r.ret].copy()))
        elif r.ret == SoapySDR.SOAPY_SDR_OVERFLOW:
            print("RX overflow")


t = threading.Thread(target=rx_loop)
t.start()
time.sleep(0.3)
before = counters()

burst = np.zeros(2 * a.len, np.int16)
burst[0::2] = 100 + np.arange(a.len) % 1500     # I: ramp 100.., never 0
burst[1::2] = -500                               # Q
sent = []
for b in range(a.bursts):
    t_tx = d.getHardwareTime() + int(a.lead * 1e9)
    r = d.writeStream(tx, [burst], a.len, SOAPY_SDR_HAS_TIME | SOAPY_SDR_END_BURST, t_tx, timeoutUs=1000000)
    if r.ret != a.len:
        print("TX write returned", r.ret)
    sent.append(t_tx)
    time.sleep(a.lead * 3)
time.sleep(0.2)
stop.set()
t.join()
after = counters()
for s in (rx, tx):
    d.deactivateStream(s)
    d.closeStream(s)
open(LOOPBACK, "w").write("0")

# find each burst's first sample in RX time
ticks = lambda ns: int(round(ns * rate / 1e9))
offsets = []
for t_tx in sent:
    k_tx = ticks(t_tx)
    found = None
    for t0, s in chunks:
        k0 = ticks(t0)
        n = len(s) // 2
        if k0 + n <= k_tx - 100 or k0 > k_tx + 1000:
            continue
        i = s[0::2]
        hit = np.nonzero((i == 100) & (s[1::2] == -500))[0]
        if len(hit):
            found = k0 + int(hit[0]) - k_tx
            break
    offsets.append(found)

ok = all(o is not None for o in offsets) and len(set(offsets)) == 1
diff = [y - x for x, y in zip(before, after)]
print(f"{rate / 1e6:.2f} MSPS, {a.bursts} bursts of {a.len}: RX - TX offset (samples) {sorted(set(offsets), key=str)}")
print(f"counter changes: overflow {diff[0]}, underflow {diff[1]}, late {diff[2]}, header errors {diff[3]}")
ok = ok and diff == [0, 0, 0, 0]
print("PASS" if ok else "FAIL")
