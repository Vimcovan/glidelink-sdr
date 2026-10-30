"""Host port 1 through the Soapy module (stream argument port=1), looped through slot 0:
host 1 TX -> slot 0 (passthrough) -> host 1 RX.

Raw mode: a 32-bit counter must come back word for word. Header mode: the same, and every read
must carry the time given to writeStream for its first sample (the passthrough keeps tuser; only
the RF TX streamer acts on the time). In header mode host port 1 RX drops whole packets when its
DMA has no room (as for the RF source), so the sender is paced to --rate for a reader in Python.

The host RX DMA hands over whole buffers only, so each run moves a whole number of them:
raw packets of 4096 words, header packets of 4092 samples (4096 words with the header).

    python3 host1_soapy.py [--args driver=glidelink] [--packets 200]
"""
import argparse
import threading
import time

import numpy as np
import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CS16, SOAPY_SDR_HAS_TIME, SOAPY_SDR_END_BURST

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink")
ap.add_argument("--packets", type=int, default=200)
ap.add_argument("--rate", type=float, default=4e6, help="header mode: words/s sent")
a = ap.parse_args()

SLOT0_IN, HOST1_RX, SRC_SLOT0, SRC_HOST1 = 2, 3, 2, 3
d = SoapySDR.Device(a.args)
route = lambda sink, src: d.writeRegister("FPGA", 0x1000 + 4 * sink, src)
route(SLOT0_IN, SRC_HOST1)
route(HOST1_RX, SRC_SLOT0)
rate = d.getSampleRate(SOAPY_SDR_RX, 0)
failures = []


BUFFER = 16384


def run(headers):
    length = BUFFER // 4 - (4 if headers else 0)
    args = {"port": "1", "headers": "true" if headers else "false", "bufferLength": str(BUFFER)}
    rx = d.setupStream(SOAPY_SDR_RX, SOAPY_SDR_CS16, [0], args)
    tx = d.setupStream(SOAPY_SDR_TX, SOAPY_SDR_CS16, [0], args)
    d.activateStream(rx)
    d.activateStream(tx)
    n = a.packets * length
    words = np.arange(n, dtype=np.uint32)
    got = np.zeros(n, np.uint32)
    times = []
    pos = [0]
    overflows = [0]

    def rx_loop():
        buf = np.empty(length, np.uint32)
        while pos[0] < n:
            r = d.readStream(rx, [buf.view(np.int16)], length, timeoutUs=2000000)
            if r.ret == SoapySDR.SOAPY_SDR_OVERFLOW:
                overflows[0] += 1
                continue
            if r.ret <= 0:
                print("RX returned", r.ret)
                break
            got[pos[0]:pos[0] + r.ret] = buf[:r.ret]
            if headers and r.flags & SOAPY_SDR_HAS_TIME:
                times.append((pos[0], r.timeNs))
            pos[0] += r.ret

    th = threading.Thread(target=rx_loop)
    th.start()
    t_ns = lambda p: int(SoapySDR.ticksToTimeNs(1000000 + p, rate))
    p = 0
    t0 = time.time()
    while p < n:                        # a write may take part of a packet (end of a DMA buffer)
        m = min(length, n - p)
        flags = (SOAPY_SDR_HAS_TIME if headers else 0) | (SOAPY_SDR_END_BURST if p + m == n else 0)
        while headers and p > a.rate * (time.time() - t0):
            time.sleep(0.0005)
        r = d.writeStream(tx, [words[p:p + m].view(np.int16)], m, flags, t_ns(p) if headers else 0,
                          timeoutUs=2000000)
        if r.ret <= 0:
            print("TX write returned", r.ret)
            break
        p += r.ret
    th.join(timeout=10)
    for s in (rx, tx):
        d.deactivateStream(s)
        d.closeStream(s)

    mode = "headers" if headers else "raw"
    ok = pos[0] == n and np.array_equal(got, words) and overflows[0] == 0
    print(f"{mode}: {pos[0]} of {n} words back, {'equal' if np.array_equal(got, words) else 'DIFFERENT'}, "
          f"{overflows[0]} overflows")
    if headers:
        bad = [(p, t) for p, t in times if abs(t - t_ns(p)) > 1]
        print(f"  {len(times)} reads timed, {len(bad)} with a time other than the one written")
        ok = ok and len(times) > 0 and not bad
    if not ok:
        failures.append(mode)


run(False)
run(True)
route(SLOT0_IN, 0xF)
route(HOST1_RX, 0xF)
print("PASS" if not failures else "FAIL")
