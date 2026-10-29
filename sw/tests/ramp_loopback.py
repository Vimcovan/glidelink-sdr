"""Bit-exact data path check through the AD9361 digital loopback (TX -> RX inside the chip).

TX sends I = a 12-bit counter running across buffers and Q = the TX buffer number, so stale or
lost data on either side shows up: I must step by exactly 1 (mod 4096) and Q may only stay or
step by 1. Turns the loopback on for the test and off again afterwards.

    python3 ramp_loopback.py [--rate 5e6] [--seconds 10]
"""
import argparse
import threading
import time

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CS16

LOOPBACK = "/sys/kernel/debug/iio/iio:device{}/loopback"

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink")
ap.add_argument("--rate", type=float, default=5e6)
ap.add_argument("--seconds", type=float, default=10.0)
a = ap.parse_args()

phy = next(i for i in range(8)
           if open(f"/sys/bus/iio/devices/iio:device{i}/name").read().strip() == "ad9361-phy")
open(LOOPBACK.format(phy), "w").write("1")

d = SoapySDR.Device(a.args)
d.setSampleRate(SOAPY_SDR_RX, 0, a.rate)
N = 16384
tx = d.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CS16, [0], {"bufferLength": str(N)})
rx = d.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], {"bufferLength": str(N)})
stop = threading.Event()
sent_bufs = [0]


def tx_loop():
    n0 = 0
    buf = np.empty(2 * N, np.int16)
    while not stop.is_set():
        k = sent_bufs[0]
        buf[0::2] = ((n0 + np.arange(N)) % 4096) - 2048
        buf[1::2] = (k % 4096) - 2048
        done = 0
        while done < N:
            r = d.writeStream(tx, [buf[2 * done:]], N - done, timeoutUs=1000000)
            if r.ret <= 0:
                print("TX error", r.ret)
                return
            done += r.ret
        n0 += N
        sent_bufs[0] += 1


d.activateStream(tx)
t = threading.Thread(target=tx_loop)
t.start()
time.sleep(0.2)
d.activateStream(rx)

buf = np.empty(2 * N, np.int16)
samples = i_err = q_err = 0
prev_i = prev_q = None
t_end = time.time() + a.seconds
while time.time() < t_end:
    r = d.readStream(rx, [buf], N, timeoutUs=1000000)
    if r.ret <= 0:
        print("RX error", r.ret)
        break
    i = buf[0:2 * r.ret:2].astype(np.int32)
    q = buf[1:2 * r.ret:2].astype(np.int32)
    if prev_i is not None:
        i = np.concatenate([[prev_i], i])
        q = np.concatenate([[prev_q], q])
    di = np.diff(i) % 4096
    dq = np.diff(q) % 4096
    i_err += int(np.count_nonzero(di != 1))
    q_err += int(np.count_nonzero((dq != 0) & (dq != 1)))
    samples += r.ret
    prev_i, prev_q = int(i[-1]), int(q[-1])

stop.set()
t.join()
for s in (rx, tx):
    d.deactivateStream(s)
    d.closeStream(s)
open(LOOPBACK.format(phy), "w").write("0")
print(f"{samples} samples at {a.rate / 1e6:.2f} MSPS, {sent_bufs[0]} TX buffers: "
      f"I steps != 1: {i_err}, Q jumps: {q_err}")
