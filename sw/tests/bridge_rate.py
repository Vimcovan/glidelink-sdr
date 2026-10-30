#!/usr/bin/env python3
"""Bridge sample-rate check between two boards over the air (or a cable), through the GlideLink
bridge (TCP 7030) as a MATLAB client uses it:

  cyclic  the TX board repeats 1 ms chirp + 1 ms silence (tx_cyclic); on the RX board the
          chirp onsets must be exactly 2 ms apart
  bursts  the TX board sends three timed bursts 50 ms apart (tx_burst); in one rx capture on
          the RX board they must be 50 ms apart

Onsets by matched filter (exact to a sample). --rx and --tx may be the same board (its own
signal over the air); only the TX image (glidelink_tx) has a TX data path.

The rx reply's drop report (overflows / dropped) is printed with each capture.

    python bridge_rate.py [--rx 192.168.3.1] [--tx 192.168.4.1] [--rates 20e6 30e6 50e6]
"""
import argparse
import json
import socket
import time

import numpy as np


class Bridge:
    def __init__(self, host, port=7030):
        self.s = socket.create_connection((host, port), timeout=60)
        self.f = self.s.makefile("rwb")

    def req(self, obj, payload=b""):
        if payload:
            obj["bytes"] = len(payload)
        self.f.write((json.dumps(obj) + "\n").encode() + payload)
        self.f.flush()
        rep = json.loads(self.f.readline())
        if not rep.get("ok"):
            raise RuntimeError(rep.get("error"))
        data = self.f.read(rep["bytes"]) if "bytes" in rep else b""
        return rep, data


def cs16(x):
    v = np.empty(2 * len(x), np.int16)
    v[0::2], v[1::2] = np.round(x.real * 2047), np.round(x.imag * 2047)
    return v.tobytes()


def iq(data):
    v = np.frombuffer(data, np.int16).astype(float) / 2048
    return v[0::2] + 1j * v[1::2]


def chirp(rate, dur):
    t = np.arange(int(rate * dur)) / rate
    return 0.7 * np.exp(1j * np.pi * (rate * 0.2 / dur) * (t - dur / 2) ** 2)


def onsets(y, ref, min_gap):
    """sample indices where ref starts in y: matched-filter peaks above half the highest, at least
    min_gap samples apart (the strongest of each cluster)"""
    m = 1 << int(np.ceil(np.log2(len(y) + len(ref))))
    c = np.abs(np.fft.ifft(np.fft.fft(y, m) * np.conj(np.fft.fft(ref, m)))[:len(y) - len(ref) + 1])
    out = []
    for i in np.argsort(c)[::-1]:
        if c[i] < 0.5 * c.max():
            break
        if all(abs(i - j) >= min_gap for j in out):
            out.append(i)
    return np.sort(np.array(out, int))


def drops(rep):
    return f"overflows {rep.get('overflows', '?')}, dropped {rep.get('dropped', '?')}"


def run(rx, tx, rate, a):
    for b in (rx, tx):
        b.req({"cmd": "config", "rate": rate, "freq": a.freq, "bandwidth": min(rate * 0.8, 56e6)})
    # cyclic
    x = np.concatenate([chirp(rate, 1e-3), np.zeros(int(rate * 1e-3))])
    rep, _ = tx.req({"cmd": "tx_cyclic"}, cs16(x))
    time.sleep(0.3)
    rrep, data = rx.req({"cmd": "rx", "n": int(rate * 0.1)})
    tx.req({"cmd": "tx_stop"})
    p = np.diff(onsets(iq(data), x[:int(rate * 1e-3)], int(rate * 1.5e-3)))
    want = len(x)
    print(f"{rate / 1e6:5.1f} MSPS cyclic ({rep.get('mode', '?')}): {len(p)} periods, want {want}: "
          f"min {p.min() if len(p) else '-'} max {p.max() if len(p) else '-'} beyond ±1 {np.sum(np.abs(p - want) > 1)}; "
          f"rx {drops(rrep)}")
    # three timed bursts 50 ms apart, queued first (they start 0.25 s later), then one capture
    c = chirp(rate, 0.2e-3)
    t0 = tx.req({"cmd": "time"})[0]["time"] + int(0.25e9)
    for k in range(3):
        tx.req({"cmd": "tx_burst", "time": t0 + k * 50_000_000}, cs16(c))
    rrep, data = rx.req({"cmd": "rx", "n": int(rate * 0.5)})
    tx.req({"cmd": "tx_stop"})
    d = np.diff(onsets(iq(data), c, int(rate * 10e-3))) / rate * 1e3
    print(f"{rate / 1e6:5.1f} MSPS bursts: spacing {np.round(d, 4).tolist()} ms (want 50); rx {drops(rrep)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rx", default="192.168.3.1")
    ap.add_argument("--tx", default="192.168.4.1")
    ap.add_argument("--rates", type=float, nargs="+", default=[20e6, 30e6, 50e6])
    ap.add_argument("--freq", type=float, default=915e6)
    a = ap.parse_args()
    rx = Bridge(a.rx)
    tx = rx if a.tx == a.rx else Bridge(a.tx)
    for b, name in ((rx, "RX"), (tx, "TX")):
        r = b.req({"cmd": "info"})[0]
        print(f"{name} board: protocol {r['protocol']}, fast {r.get('fast')}, shell {r['shell']}, "
              f"{r['rate'] / 1e6:g} MSPS, {r['rx_freq'] / 1e6:g} / {r['tx_freq'] / 1e6:g} MHz")
    for rate in a.rates:
        run(rx, tx, rate, a)


if __name__ == "__main__":
    main()
