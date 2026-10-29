"""Tone loopback through SoapyGlideLink on one board: TX sends a complex tone, RX
captures it over the air (or a cable with attenuation) and reports the spectral peak.

    python3 tone_loopback.py [--args driver=glidelink] [--freq 915e6] [--rate 10e6]
                             [--tone 1e6] [--tx-gain 50] [--rx-gain auto]
"""
import argparse
import threading

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CF32

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink")
ap.add_argument("--freq", type=float, default=915e6)
ap.add_argument("--rate", type=float, default=10e6)
ap.add_argument("--tone", type=float, default=1e6)
ap.add_argument("--tx-gain", type=float, default=50.0)
ap.add_argument("--rx-gain", default="auto")
ap.add_argument("--n", type=int, default=1 << 16)
a = ap.parse_args()

sdr = SoapySDR.Device(a.args)
sdr.setSampleRate(SOAPY_SDR_RX, 0, a.rate)
for d in (SOAPY_SDR_RX, SOAPY_SDR_TX):
    sdr.setFrequency(d, 0, a.freq)
    sdr.setBandwidth(d, 0, min(a.rate, 18e6))
sdr.setGain(SOAPY_SDR_TX, 0, a.tx_gain)
if a.rx_gain == "auto":
    sdr.setGainMode(SOAPY_SDR_RX, 0, True)
else:
    sdr.setGainMode(SOAPY_SDR_RX, 0, False)
    sdr.setGain(SOAPY_SDR_RX, 0, float(a.rx_gain))

# a whole number of tone periods per TX buffer, so the cyclic push stays continuous
mtu = 16384
k = round(a.tone / a.rate * mtu)
tone = (0.5 * np.exp(2j * np.pi * k * np.arange(mtu) / mtu)).astype(np.complex64)
f_tone = k * a.rate / mtu

tx = sdr.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CF32, [0])
rx = sdr.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CF32, [0])
sdr.activateStream(tx)
stop = threading.Event()


def tx_loop():
    while not stop.is_set():
        sent = 0
        while sent < mtu:
            r = sdr.writeStream(tx, [tone[sent:]], mtu - sent, timeoutUs=1000000)
            if r.ret <= 0:
                print("TX error", r.ret)
                return
            sent += r.ret


t = threading.Thread(target=tx_loop)
t.start()
sdr.activateStream(rx)

buf = np.empty(a.n, np.complex64)
for _ in range(20):                      # let the AGC settle
    sdr.readStream(rx, [buf], a.n, timeoutUs=1000000)
got = 0
while got < a.n:
    r = sdr.readStream(rx, [buf[got:]], a.n - got, timeoutUs=1000000)
    if r.ret <= 0:
        raise SystemExit(f"RX error {r.ret}")
    got += r.ret

stop.set()
t.join()
sdr.deactivateStream(rx)
sdr.deactivateStream(tx)
sdr.closeStream(rx)
sdr.closeStream(tx)

win = np.hanning(a.n)
spec = np.fft.fftshift(np.abs(np.fft.fft(buf * win)) ** 2)
freqs = np.fft.fftshift(np.fft.fftfreq(a.n, 1 / a.rate))
spec[np.abs(freqs) < 20e3] = 0          # ignore the DC / LO leakage bin
peak = int(np.argmax(spec))
snr = 10 * np.log10(spec[peak] / np.median(spec))
rms = np.sqrt(np.mean(np.abs(buf) ** 2))
print(f"tone sent at {f_tone / 1e6:+.4f} MHz, peak found at {freqs[peak] / 1e6:+.4f} MHz, "
      f"peak/median {snr:.1f} dB, RX rms {rms:.3f} FS, RX gain {sdr.getGain(SOAPY_SDR_RX, 0):.0f} dB")
