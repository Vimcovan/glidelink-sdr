"""Known-waveform test between two boards through SoapyGlideLink.

The TX board repeats a band-limited Zadoff-Chu sequence; the RX board correlates
its capture with the same sequence and reports timing, carrier frequency offset
and the SNR implied by the normalised correlation.

    TX board:  python3 known_waveform.py tx [--seconds 60]
    RX board:  python3 known_waveform.py rx
"""
import argparse
import time

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CF32

ZC_LEN, ZC_ROOT, INTERP = 1021, 7, 2


def waveform():
    """Zadoff-Chu sequence interpolated by INTERP (occupies 1 / INTERP of the band), peak 0.5 FS."""
    n = np.arange(ZC_LEN)
    zc = np.exp(-1j * np.pi * ZC_ROOT * n * (n + 1) / ZC_LEN)
    spec = np.fft.fft(zc)
    half = (ZC_LEN + 1) // 2
    padded = np.concatenate([spec[:half], np.zeros((INTERP - 1) * ZC_LEN, complex), spec[half:]])
    x = np.fft.ifft(padded)
    return (0.5 * x / np.abs(x).max()).astype(np.complex64)


def open_device(a, direction):
    d = SoapySDR.Device(a.args)
    d.setSampleRate(direction, 0, a.rate)
    d.setFrequency(direction, 0, a.freq)
    d.setBandwidth(direction, 0, a.rate)
    if direction == SOAPY_SDR_TX:
        d.setGain(SOAPY_SDR_TX, 0, a.tx_gain)
    else:
        d.setGainMode(SOAPY_SDR_RX, 0, True)
    return d


def run_tx(a):
    d = open_device(a, SOAPY_SDR_TX)
    x = waveform()
    reps = max(1, 16384 // len(x))
    buf = np.tile(x, reps)
    s = d.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CF32, [0], {"bufferLength": str(len(buf))})
    d.activateStream(s)
    t_end = time.time() + a.seconds
    print(f"TX: {len(x)}-sample ZC period, {a.freq / 1e6:.3f} MHz, {a.rate / 1e6:.2f} MSPS, "
          f"gain {a.tx_gain} dB, for {a.seconds} s")
    while time.time() < t_end:
        sent = 0
        while sent < len(buf):
            r = d.writeStream(s, [buf[sent:]], len(buf) - sent, timeoutUs=1000000)
            if r.ret <= 0:
                raise SystemExit(f"TX error {r.ret}")
            sent += r.ret
    d.deactivateStream(s)
    d.closeStream(s)


def run_rx(a):
    d = open_device(a, SOAPY_SDR_RX)
    x = waveform()
    L = len(x)
    s = d.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CF32, [0])
    d.activateStream(s)
    n = 1 << 16
    r = np.empty(n, np.complex64)
    for _ in range(20):                              # let the AGC settle
        d.readStream(s, [r], n, timeoutUs=1000000)
    got = 0
    while got < n:
        ret = d.readStream(s, [r[got:]], n - got, timeoutUs=1000000).ret
        if ret <= 0:
            raise SystemExit(f"RX error {ret}")
        got += ret
    gain = d.getGain(SOAPY_SDR_RX, 0)
    d.deactivateStream(s)
    d.closeStream(s)

    # circular correlation of one period against the known sequence
    seg = r[:L * (n // L)].reshape(-1, L)
    X = np.conj(np.fft.fft(x))
    corr = np.fft.ifft(np.fft.fft(seg[0]) * X)
    lag = int(np.argmax(np.abs(corr)))
    pslr = 20 * np.log10(np.abs(corr[lag]) / np.median(np.abs(corr)))

    # aligned periods: CFO from the phase step between periods, then coherent correlation
    aligned = r[lag:lag + L * (n // L - 1)].reshape(-1, L)
    c = aligned @ np.conj(x)
    cfo = np.angle(np.sum(c[1:] * np.conj(c[:-1]))) / (2 * np.pi * L) * a.rate
    t = np.arange(aligned.size).reshape(aligned.shape)
    derot = aligned * np.exp(-2j * np.pi * cfo / a.rate * t)
    # Each period is a circular convolution of x with the channel (fractional delay, multipath,
    # filters): estimate one response H over the occupied bins for all periods plus a complex
    # gain per period (sample-clock drift), and count the rest of the occupied band as noise.
    Xf = np.fft.fft(x)
    occ = np.abs(Xf) > 1e-3 * np.abs(Xf).max()
    Rf = np.fft.fft(derot, axis=1)[:, occ]
    g = Rf @ np.conj(Rf[0])
    g /= np.abs(g)
    H = np.mean(Rf / g[:, None], 0) / Xf[occ]
    model = g[:, None] * (H * Xf[occ])[None, :]
    resid = Rf - model
    snr = 10 * np.log10(np.sum(np.abs(model) ** 2) / np.sum(np.abs(resid) ** 2))
    g = g * np.sqrt(np.sum(np.abs(Rf) ** 2, 1) / np.sum(np.abs(model[0]) ** 2))
    print(f"RX: peak at lag {lag}/{L}, peak/median {pslr:.1f} dB, CFO {cfo:+.0f} Hz "
          f"({cfo / a.freq * 1e6:+.2f} ppm), SNR {snr:.1f} dB over {aligned.shape[0]} periods, "
          f"RX gain {gain:.0f} dB, |g| spread {np.std(np.abs(g)) / np.mean(np.abs(g)) * 100:.1f} %")
    if a.diag:
        per = 10 * np.log10(np.sum(np.abs(model) ** 2, 1) / np.sum(np.abs(resid) ** 2, 1))
        print("per-period SNR (dB):", " ".join(f"{v:.0f}" for v in per))
        np.save(a.diag, r)


ap = argparse.ArgumentParser()
ap.add_argument("mode", choices=["tx", "rx"])
ap.add_argument("--args", default="driver=glidelink")
ap.add_argument("--freq", type=float, default=915e6)
ap.add_argument("--rate", type=float, default=5e6)
ap.add_argument("--tx-gain", type=float, default=40.0)
ap.add_argument("--seconds", type=float, default=60.0)
ap.add_argument("--diag", metavar="FILE.npy", help="rx: print per-period SNR and save the capture")
a = ap.parse_args()
run_tx(a) if a.mode == "tx" else run_rx(a)
