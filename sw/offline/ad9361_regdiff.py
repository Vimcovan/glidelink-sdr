"""Compare the AD9361 registers set up by the ADI driver with the competition register script.

Run on a board, next to profiles/ (jscc_regs_<rx|tx>.json from competition_profile.py) and the
competition LUT comments (optional, --lut ad9361_config_lut.v for the register names):

    python3 ad9361_regdiff.py [--side rx|tx] [--only 0x0F0-0x11F,0x200-0x227] [--lut ...]

Reads every register the script writes (debugfs direct_reg_access of ad9361-phy) and prints those
that differ, with the script's comment. Read-only: it changes nothing on the AD9361.
"""
import argparse
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))


def phy_paths():
    for n in range(16):
        p = f"/sys/bus/iio/devices/iio:device{n}"
        if os.path.exists(p + "/name") and open(p + "/name").read().strip() == "ad9361-phy":
            return p, f"/sys/kernel/debug/iio/iio:device{n}"
    raise SystemExit("no ad9361-phy")


def reg_read(dbg, addr):
    with open(dbg + "/direct_reg_access", "w") as f:
        f.write(f"0x{addr:X}")
    return int(open(dbg + "/direct_reg_access").read().strip(), 0)


def ranges(spec):
    out = []
    for part in spec.split(","):
        a, _, b = part.partition("-")
        out.append((int(a, 0), int(b or a, 0)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--side", default="rx", choices=["rx", "tx"])
    ap.add_argument("--only", default="", help="address ranges, e.g. 0x0FA-0x11B,0x200-0x227")
    ap.add_argument("--lut", default="", help="competition ad9361_config_lut.v, for the comments")
    a = ap.parse_args()
    want = {int(k, 16): v for k, v in json.load(open(os.path.join(HERE, "profiles", f"jscc_regs_{a.side}.json"))).items()}
    names = {}
    if a.lut:
        for line in open(a.lut, encoding="latin-1"):
            m = re.search(r"\{1'b1,10'h([0-9A-Fa-f]{3}),8'h[0-9A-Fa-f]{2}\}\s*;\s*//\s*(.*)", line)
            if m:
                names[int(m.group(1), 16)] = m.group(2).strip()[:70]
    sel = ranges(a.only) if a.only else None
    _, dbg = phy_paths()
    diff = 0
    for addr in sorted(want):
        if sel and not any(lo <= addr <= hi for lo, hi in sel):
            continue
        if addr in (0x3DF,) or 0x130 <= addr <= 0x137 or 0x060 <= addr <= 0x064 or 0x0F0 <= addr <= 0x0F4:
            continue                                     # strobes / table and FIR ports: not readable state
        if addr in (0x109, 0x10A):
            continue                                     # read back as the live gain (state 5 power when written)
        got = reg_read(dbg, addr)
        if got != want[addr]:
            diff += 1
            print(f"0x{addr:03X}  script 0x{want[addr]:02X}  driver 0x{got:02X}  {names.get(addr, '')}")
    print(f"{diff} registers differ")


if __name__ == "__main__":
    main()
