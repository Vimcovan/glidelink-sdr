"""Phase 2 acceptance (docs/phase2_soapy_gr.md): the three layers of control through the Soapy module.

1. Driver parameters: write a fast-AGC parameter, re-initialise, and see it in the AD9361 register
   it sets; the standard parameters (sample rate, LOs, bandwidths, gain mode, gains) come back as
   they were.
2. A device-tree parameter that has a standard counterpart wins over the restore: writing
   adi,gc-rx1-mode = 0 and re-initialising leaves the RX in manual gain.
3. Raw registers: write and read back an AD9361 register.

Everything is put back as found at the end. Runs on the board (default) or from a PC:

    python3 settings_init.py [--args driver=glidelink,uri=ip:192.168.3.1]
"""
import argparse
import time

import SoapySDR
from SoapySDR import SOAPY_SDR_RX, SOAPY_SDR_TX

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink")
a = ap.parse_args()

LOCK = "adi,agc-inner-thresh-high"      # fast AGC lock level, dBFS below full scale
REG_LOCK = 0x101                        # AGC lock level / inner high threshold, bits [6:0]
GC_MODE = "adi,gc-rx1-mode"             # 0 manual, 1 fast attack, 2 slow attack, 3 hybrid

d = SoapySDR.Device(a.args)
failures = []


def check(what, ok):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        failures.append(what)


def state():
    return {
        "rate": d.getSampleRate(SOAPY_SDR_RX, 0),
        "rx_lo": d.getFrequency(SOAPY_SDR_RX, 0),
        "tx_lo": d.getFrequency(SOAPY_SDR_TX, 0),
        "rx_bw": d.getBandwidth(SOAPY_SDR_RX, 0),
        "tx_bw": d.getBandwidth(SOAPY_SDR_TX, 0),
        "gain_mode": d.readSetting("gain_control_mode"),
        "tx_gain": d.getGain(SOAPY_SDR_TX, 0),
    }


def initialize():
    t = time.time()
    d.writeSetting("initialize", "true")
    return time.time() - t


found = {"lock": d.readSetting(LOCK), "gc": d.readSetting(GC_MODE), "state": state(),
         "rx_gain": d.getGain(SOAPY_SDR_RX, 0)}
print("found:", found)

# 1. fast AGC lock level through a driver parameter, standard parameters restored
d.setSampleRate(SOAPY_SDR_RX, 0, 10e6)
d.setFrequency(SOAPY_SDR_RX, 0, 915e6)
d.setFrequency(SOAPY_SDR_TX, 0, 916e6)
d.setBandwidth(SOAPY_SDR_RX, 0, 8e6)
d.setBandwidth(SOAPY_SDR_TX, 0, 9e6)
d.writeSetting("gain_control_mode", "fast_attack")
d.setGain(SOAPY_SDR_TX, 0, 50)
before = state()
lock = 14 if int(found["lock"]) != 14 else 12
print(f"1. {LOCK} = {lock}, initialize")
d.writeSetting(LOCK, str(lock))
dt = initialize()
after = state()
check(f"initialize took {dt:.2f} s", dt < 5)
check(f"register 0x{REG_LOCK:03X} = {d.readRegister('AD9361', REG_LOCK) & 0x7f} (want {lock})",
      d.readRegister("AD9361", REG_LOCK) & 0x7f == lock)
check(f"{LOCK} reads back {d.readSetting(LOCK)}", d.readSetting(LOCK) == str(lock))
for k in before:
    same = abs(before[k] - after[k]) < 1 if isinstance(before[k], float) else before[k] == after[k]
    check(f"{k} restored: {before[k]} -> {after[k]}", same)

# 2. a device-tree parameter with a standard counterpart is not overridden
print(f"2. {GC_MODE} = 0, initialize")
d.writeSetting(GC_MODE, "0")
initialize()
check(f"gain mode after initialize: {d.readSetting('gain_control_mode')} (want manual)",
      d.readSetting("gain_control_mode") == "manual")
check(f"sample rate still restored: {d.getSampleRate(SOAPY_SDR_RX, 0)}", d.getSampleRate(SOAPY_SDR_RX, 0) == 10e6)

# 3. raw AD9361 register
print("3. AD9361 register write / read")
reg = d.readRegister("AD9361", REG_LOCK)
d.writeRegister("AD9361", REG_LOCK, (reg & 0x80) | 0x0B)
check(f"0x{REG_LOCK:03X} written 0x0B, reads 0x{d.readRegister('AD9361', REG_LOCK) & 0x7f:02X}",
      d.readRegister("AD9361", REG_LOCK) & 0x7f == 0x0B)
d.writeRegister("AD9361", REG_LOCK, reg)

# put everything back
d.writeSetting(LOCK, found["lock"])
d.writeSetting(GC_MODE, found["gc"])
initialize()
s = found["state"]
d.setSampleRate(SOAPY_SDR_RX, 0, s["rate"])
d.setFrequency(SOAPY_SDR_RX, 0, s["rx_lo"])
d.setFrequency(SOAPY_SDR_TX, 0, s["tx_lo"])
d.setBandwidth(SOAPY_SDR_RX, 0, s["rx_bw"])
d.setBandwidth(SOAPY_SDR_TX, 0, s["tx_bw"])
d.writeSetting("gain_control_mode", s["gain_mode"])
if s["gain_mode"] == "manual":
    d.setGain(SOAPY_SDR_RX, 0, found["rx_gain"])
d.setGain(SOAPY_SDR_TX, 0, s["tx_gain"])

print("PASS" if not failures else f"FAIL ({len(failures)})")
