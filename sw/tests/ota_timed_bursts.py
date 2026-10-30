"""Timed TX bursts between two boards over the air (docs/phase1_shell.md acceptance 1).

The boards share no time base, so what is checked is the spacing: the TX board sends a
Zadoff-Chu burst every --period seconds by its own sample counter (timed send, end of burst);
the RX board captures --seconds with packet headers, placing every read by its timestamp,
picks the stretches with energy about one burst long and times each burst by correlation
(sub-sample by parabolic interpolation of the peak; the correlation is a non-coherent sum
over 16 segments, so the boards' carrier offset does not smear it). The spacings must equal
the period, scaled by the two crystals' offset, with small jitter.

Both sides first silence the DDS tones of cf_axi_dds, which the DAC sends whenever no TX
buffer is running.

    RX board:  python3 ota_timed_bursts.py rx            (captures --seconds)
    TX board:  python3 ota_timed_bursts.py tx            (started while RX waits)
"""
import argparse
import glob
import time

import numpy as np
import SoapySDR
from SoapySDR import (SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CF32, SOAPY_SDR_HAS_TIME,
                      SOAPY_SDR_END_BURST)

ZC_LEN, ZC_ROOT, INTERP = 1021, 7, 2

ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["tx", "rx"])
ap.add_argument("--args", default="driver=glidelink")
ap.add_argument("--freq", type=float, default=915e6)
ap.add_argument("--rate", type=float, default=2.5e6)
ap.add_argument("--period", type=float, default=0.01, help="burst spacing in seconds")
ap.add_argument("--bursts", type=int, default=40)
ap.add_argument("--tx-gain", type=float, default=55.0)
ap.add_argument("--rx-gain", type=float, default=55.0)
ap.add_argument("--seconds", type=float, default=4.0, help="rx: capture length")
a = ap.parse_args()


def zc_burst():
    n = np.arange(ZC_LEN)
    spec = np.fft.fft(np.exp(-1j * np.pi * ZC_ROOT * n * (n + 1) / ZC_LEN))
    half = (ZC_LEN + 1) // 2
    x = np.fft.ifft(np.concatenate([spec[:half], np.zeros((INTERP - 1) * ZC_LEN, complex), spec[half:]]))
    return (0.5 * x / np.abs(x).max()).astype(np.complex64)


def mute_dds_tones():
    for dev in glob.glob("/sys/bus/iio/devices/iio:device*"):
        if open(dev + "/name").read().strip() == "cf-ad9361-dds-core-lpc":
            for f in glob.glob(dev + "/out_altvoltage*_scale"):
                open(f, "w").write("0")


mute_dds_tones()
d = SoapySDR.Device(a.args)
d.setSampleRate(SOAPY_SDR_RX, 0, a.rate)
rate = d.getSampleRate(SOAPY_SDR_RX, 0)
period_samples = int(round(a.period * rate))
x = zc_burst()
L = len(x)

if a.mode == "tx":
    d.setFrequency(SOAPY_SDR_TX, 0, a.freq)
    d.setBandwidth(SOAPY_SDR_TX, 0, rate)
    d.setGain(SOAPY_SDR_TX, 0, a.tx_gain)
    s = d.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CF32, [0])
    d.activateStream(s)
    # times in samples of this board's counter, exactly period_samples apart
    t0 = int(round(d.getHardwareTime() * rate / 1e9)) + int(0.3 * rate)
    for k in range(a.bursts):
        t_ns = int(round((t0 + k * period_samples) * 1e9 / rate))
        r = d.writeStream(s, [x], L, SOAPY_SDR_HAS_TIME | SOAPY_SDR_END_BURST, t_ns, timeoutUs=2000000)
        if r.ret != L:
            print("TX write returned", r.ret)
    time.sleep(0.3 + a.bursts * a.period + 0.2)
    late = d.readRegister("FPGA", 0x048)
    d.deactivateStream(s)
    d.closeStream(s)
    print(f"TX: {a.bursts} bursts of {L} samples every {period_samples} samples, late counter {late}")
    raise SystemExit

d.setFrequency(SOAPY_SDR_RX, 0, a.freq)
d.setBandwidth(SOAPY_SDR_RX, 0, rate)
d.setGainMode(SOAPY_SDR_RX, 0, False)
d.setGain(SOAPY_SDR_RX, 0, a.rx_gain)
s = d.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CF32, [0])
d.activateStream(s)

# continuous capture, placed by the RX timestamps
n_total = int(a.seconds * rate)
rx = np.zeros(n_total, np.complex64)
buf = np.empty(65536, np.complex64)
first = None
got = gaps = overflows = 0
while got < n_total:
    r = d.readStream(s, [buf], len(buf), timeoutUs=1000000)
    if r.ret == SoapySDR.SOAPY_SDR_OVERFLOW:
        overflows += 1
        continue
    if r.ret <= 0:
        raise SystemExit(f"RX error {r.ret}")
    tick = int(round(r.timeNs * rate / 1e9))
    if first is None:
        first = tick
    pos = tick - first
    if pos != got:
        gaps += 1
    if pos >= n_total:
        break
    n = min(r.ret, n_total - pos)
    rx[pos:pos + n] = buf[:n]
    got = pos + n
d.deactivateStream(s)
d.closeStream(s)

# candidates: stretches with energy about one burst long (this also skips the
# AD9361 TX quadrature calibration, a tone of 15-20 ms the TX board radiates when
# its frequency or bandwidth is set)
B = 250
blk = np.abs(rx[:n_total // B * B]).reshape(-1, B).mean(1)
on = np.r_[False, blk > 8 * np.median(blk), False]
edges = np.flatnonzero(np.diff(on.astype(int)))
segs = [(i * B, j * B) for i, j in zip(edges[0::2], edges[1::2]) if 0.5 * L <= (j - i) * B <= 1.5 * L + 2 * B]

# arrival time of each: non-coherent sum of 16 partial correlations (the boards'
# carrier offset turns the phase across a whole burst, not across a segment)
S = L // 16
peaks = []
for lo, hi in segs:
    lo, hi = max(0, lo - L), min(n_total, hi + L)
    y = rx[lo:hi]
    c = sum(np.abs(np.correlate(y, x[k * S:(k + 1) * S], "valid"))[k * S:k * S + len(y) - L + 1]
            for k in range(16))
    j = int(np.argmax(c))
    if 0 < j < len(c) - 1:
        y0, y1, y2 = c[j - 1], c[j], c[j + 1]
        den = y0 - 2 * y1 + y2
        peaks.append(lo + j + (0.5 * (y0 - y2) / den if den != 0 else 0.0))
peaks = np.sort(np.array(peaks))
# the bursts are the longest chain spaced about one period; anything else is foreign
chains, cur = [], peaks[:1].tolist()
for p in peaks[1:]:
    if abs(p - cur[-1] - period_samples) < 0.01 * period_samples:
        cur.append(p)
    else:
        chains.append(cur)
        cur = [p]
chains.append(cur)
burst_t = np.array(max(chains, key=len))
print(f"RX: {got} samples, gaps {gaps}, overflows {overflows}, {len(segs)} burst-long stretches, "
      f"{len(burst_t)} bursts on the period grid, {len(peaks) - len(burst_t)} other")
peaks = burst_t
spacing = np.diff(peaks)
if len(spacing):
    dev = spacing - period_samples
    print(f"spacing: mean {spacing.mean():.3f} samples (nominal {period_samples}, offset "
          f"{dev.mean() / period_samples * 1e6:+.2f} ppm), std {spacing.std():.3f}, "
          f"min {spacing.min():.3f}, max {spacing.max():.3f}")
    ok = len(peaks) >= 0.9 * a.bursts and spacing.std() < 0.5 and np.all(np.abs(dev) < 2)
    print("PASS" if ok else "FAIL")
