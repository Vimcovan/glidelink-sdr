"""Step 1.1 check of the PL shell registers through SoapyGlideLink ("FPGA" register interface
and the hardware time): ID / version / capabilities, CTRL_OUT, sample counter rate against the
sample rate, and setting the time.

    python3 shell_regs.py [--args driver=glidelink]
"""
import argparse
import time

import SoapySDR
from SoapySDR import SOAPY_SDR_RX

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink")
a = ap.parse_args()

d = SoapySDR.Device(a.args)
assert "FPGA" in d.listRegisterInterfaces(), "no glidelink-shell device"
rd = lambda addr: d.readRegister("FPGA", addr)

ident, ver, caps = rd(0x000), rd(0x004), rd(0x008)
print(f"ID 0x{ident:08X} ({ident.to_bytes(4, 'big').decode()}), version {ver >> 16}.{(ver >> 8) & 0xff}.{ver & 0xff}, "
      f"{caps & 0xff} RF channel(s), {(caps >> 8) & 0xff}/{(caps >> 16) & 0xff} host RX/TX, {caps >> 24} slot(s)")
d.writeRegister("FPGA", 0x00C, 0x12345678)
print(f"scratch 0x{rd(0x00C):08X}, CTRL_OUT 0x{rd(0x030):02X}")

ok = True
for rate in (2.5e6, 10e6, 30.72e6, 50e6):
    d.setSampleRate(SOAPY_SDR_RX, 0, rate)
    actual = d.getSampleRate(SOAPY_SDR_RX, 0)
    time.sleep(0.2)
    t0, w0 = d.getHardwareTime(), time.monotonic()
    time.sleep(1.0)
    t1, w1 = d.getHardwareTime(), time.monotonic()
    ratio = (t1 - t0) / ((w1 - w0) * 1e9)
    print(f"{actual / 1e6:7.3f} MSPS: hardware time advanced {ratio:.5f} s per second")
    ok &= abs(ratio - 1) < 2e-3

d.setHardwareTime(10**12)                    # 1000 s
t = d.getHardwareTime()
print(f"set to 1000 s, read back {t / 1e9:.6f} s")
ok &= 1000 <= t / 1e9 < 1000.1
print("PASS" if ok else "FAIL")
