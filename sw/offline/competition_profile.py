"""AD9361 profile of the competition design, for the ADI driver (docs/phase4_plan.md, 4.6).

The competition boards initialised the AD9361 from the PL with a register script exported by the
AD9361 Evaluation Software and then edited by hand (src/hw/{tx,rx}/rtl/phy/ad9361_config_lut.v of
Vimcovan/glidelink-fpga, read-only here). The platform uses the ADI Linux driver instead, so this
script turns that register script into what the driver loads:

    profiles/jscc_20msps.ftr       FIR file (filter_fir_config): both FIRs, the clock chain
                                   (BBPLL 1280 MHz, ADC / DAC 320 MHz, 20 MSPS) and the RF bandwidths
    profiles/jscc_agc_rx.txt       the fast-attack AGC registers of the deployed RX script, written after
                                   the driver's setup (the driver computes these from its own parameters
                                   and cannot express all of them; the competition values come from
                                   openwifi's agc_settings.sh, which also writes them after the driver):
                                   AGC state machine reset (0x0FA = 0x05), the block, then 0x0FA
    profiles/jscc_regs_<rx|tx>.json the register values at the end of each script (last write per
                                   address), the reference that ad9361_regdiff.py compares the driver's
                                   registers with. The deployed RX board ran the PS copy of its script
                                   (src/sw/rx/ad9361_rx_init.json, AGC lock level -14 dBFS instead of
                                   the LUT's -12), so the RX reference is taken from that file

    python competition_profile.py [--repo D:/ClaudePrj/deepjsccq-ofdm-fpga] [--driver ad9361.c]

--driver gives the ADI driver source, to check the gain table: the script programs the driver's own
200 - 1300 MHz table (its comment names GainTable2300MHz.csv, but the words are those of the 800 MHz
table), which the driver also selects at 915 MHz, so no custom table is needed.
"""
import argparse
import json
import os
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
LUT_RE = re.compile(r"\{1'b([01]),10'h([0-9A-Fa-f]{3}),8'h([0-9A-Fa-f]{2})\}\s*;\s*(?://\s*(.*))?")


def read_lut(path):
    """[(kind, addr, value, comment)], kind 'w' (write) or 'x' (wait / poll / read)"""
    ops = []
    for line in open(path, encoding="latin-1"):
        m = LUT_RE.search(line)
        if m:
            ops.append(("w" if m.group(1) == "1" else "x", int(m.group(2), 16), int(m.group(3), 16),
                        (m.group(4) or "").strip()))
    return ops


def final_regs(ops):
    regs = {}
    for kind, a, v, _ in ops:
        if kind == "w":
            regs[a] = v
    return regs


def fir(ops, base):
    """coefficients written through the FIR port at base (0x060 TX, 0x0F0 RX): address base, data
    base+1 / +2, write strobe = bit 1 of the config register base+5"""
    coef, addr, lsb, msb = {}, 0, 0, 0
    for kind, a, v, _ in ops:
        if kind != "w":
            continue
        if a == base:
            addr = v
        elif a == base + 1:
            lsb = v
        elif a == base + 2:
            msb = v
        elif a == base + 5 and v & 2:
            c = msb << 8 | lsb
            coef[addr] = c - 65536 if c >= 32768 else c
    return [coef[i] for i in range(max(coef) + 1)]


def gain_table(ops):
    """the full gain table words (0x131, 0x132, 0x133) per index, written with 0x137 = 0x1E"""
    tab, idx, w = {}, 0, [0, 0, 0]
    for kind, a, v, _ in ops:
        if kind != "w":
            continue
        if a == 0x130:
            idx = v
        elif a in (0x131, 0x132, 0x133):
            w[a - 0x131] = v
        elif a == 0x137 and v == 0x1E:
            tab[idx] = tuple(w)
    return [tab[i] for i in range(max(tab) + 1)]


def driver_tables(src):
    """the ADI driver's full gain tables: {band: (words [77][3], abs gains [77])}"""
    text = open(src, encoding="utf-8", errors="replace").read()

    def block(name):
        i = text.index(name)
        j = text.index("};", i)
        return text[i:j]
    bands = ["TBL_200_1300_MHZ", "TBL_1300_4000_MHZ", "TBL_4000_6000_MHZ"]       # order in the source
    nocomment = lambda t: re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    words = nocomment(block("full_gain_table[RXGAIN_TBLS_END]"))
    gains = nocomment(block("full_gain_table_abs_gain[RXGAIN_TBLS_END]"))
    rows = re.findall(r"\{\s*(0x[0-9A-Fa-f]+)\s*,\s*(0x[0-9A-Fa-f]+)\s*,\s*(0x[0-9A-Fa-f]+)\s*\}", words)
    vals = [int(x) for x in re.findall(r"-?\d+", gains[gains.index("=") + 1:])]
    out = {}
    for k, b in enumerate(bands):
        out[b] = ([tuple(int(x, 16) for x in r) for r in rows[77 * k:77 * (k + 1)]], vals[77 * k:77 * (k + 1)])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.environ.get("GLIDELINK_COMPETITION_REPO", "D:/ClaudePrj/deepjsccq-ofdm-fpga"))
    ap.add_argument("--driver", required=True, help="ADI ad9361.c (its gain tables)")
    a = ap.parse_args()
    repo = Path(a.repo)
    out = HERE / "profiles"
    out.mkdir(exist_ok=True)
    luts = {s: read_lut(repo / "src" / "hw" / s / "rtl" / "phy" / "ad9361_config_lut.v") for s in ("rx", "tx")}

    deployed = {"rx": repo / "src" / "sw" / "rx" / "ad9361_rx_init.json"}
    for s, ops in luts.items():
        regs = final_regs(ops)
        if s in deployed:
            js = {}
            for o in json.load(open(deployed[s]))["ops"]:
                if o[0] == "w":
                    js[o[1]] = o[2]
            print(f"{s}: deployed script differs from the LUT at",
                  [f"0x{a:03X}" for a in sorted(set(js) | set(final_regs(ops))) if js.get(a) != final_regs(ops).get(a)])
            regs = js
        json.dump({f"0x{k:03X}": v for k, v in sorted(regs.items())},
                  open(out / f"jscc_regs_{s}.json", "w", newline="\n"), indent=0)

    rx = {int(k, 16): v for k, v in json.load(open(out / "jscc_regs_rx.json")).items()}
    agc = [0x022] + [a for a in range(0x0FB, 0x11C) if a in rx] + [0x15C]
    with open(out / "jscc_agc_rx.txt", "w", newline="\n") as f:
        f.write("# fast-attack AGC registers of the competition RX (ad9361_rx_init.json), written after the\n"
                "# driver's setup in this order; address value (generated by competition_profile.py)\n")
        f.write("".join(f"0x{a:03X} 0x{v:02X}\n"
                        for a, v in [(0x0FA, 0x05)] + [(a, rx[a]) for a in agc] + [(0x0FA, rx[0x0FA])]))

    # the FIRs and the gain table are the same in both scripts
    ops = luts["rx"]
    assert fir(ops, 0x060) == fir(luts["tx"], 0x060) and fir(ops, 0x0F0) == fir(luts["tx"], 0x0F0)
    assert gain_table(ops) == gain_table(luts["tx"])
    regs = final_regs(ops)
    tx, rx = fir(ops, 0x060), fir(ops, 0x0F0)
    # register fields: 0x065 / 0x0F5 [7:5] taps / 16 - 1, 0x065[0] TX gain -6 dB, 0x0F6[1:0] RX gain
    # (0: +6, 1: 0, 2: -6, 3: -12 dB); 0x002 / 0x003 [1:0] FIR interpolation / decimation (1, 2, 4)
    assert len(tx) == 16 * ((regs[0x065] >> 5) + 1) and len(rx) == 16 * ((regs[0x0F5] >> 5) + 1)
    tx_gain = -6 if regs[0x065] & 1 else 0
    rx_gain = {0: 6, 1: 0, 2: -6, 3: -12}[regs[0x0F6] & 3]
    tx_int = {1: 1, 2: 2, 3: 4}[regs[0x002] & 3]
    rx_dec = {1: 1, 2: 2, 3: 4}[regs[0x003] & 3]
    n = max(len(tx), len(rx))                         # the driver loads one tap count for both:
    tx += [0] * (n - len(tx))                         # trailing zero taps leave the output unchanged
    rx += [0] * (n - len(rx))
    clk = "1280000000 320000000 160000000 80000000 40000000 20000000"
    with open(out / "jscc_20msps.ftr", "w", newline="\n") as f:
        f.write("# DeepJSCC-Q / competition AD9361 profile (from ad9361_config_lut.v of Vimcovan/glidelink-fpga,\n"
                "# generated by sw/offline/competition_profile.py): 20 MSPS, BBPLL 1280 MHz, ADC 320 MHz,\n"
                "# HB3 / HB2 / HB1 x2 each, FIR x2; TX FIR 64 taps (Kaiser fc 10.3 MHz), RX FIR 48 taps\n"
                "# (10MHz.ftr, zero-padded to 64: the driver loads one tap count for both);\n"
                "# RF bandwidths 30 MHz = 15 MHz baseband (BBF corners 21 / 24 MHz)\n")
        f.write(f"TX 3 GAIN {tx_gain} INT {tx_int}\nRX 3 GAIN {rx_gain} DEC {rx_dec}\n")
        f.write(f"RTX {clk}\nRRX {clk}\nBWTX 30000000\nBWRX 30000000\n")
        f.write("".join(f"{t},{r}\n" for t, r in zip(tx, rx)))

    gt = gain_table(ops)
    assert all(w == (0, 0, 0) for w in gt[77:])
    match = [b for b, (w, _) in driver_tables(a.driver).items() if w == gt[:77]]
    print(f"gain table in the script: {len(gt)} entries (77 used), equals the driver's {match or 'none'}")
    print(f"FIR: TX {len([c for c in tx if c])} taps gain {tx_gain} int {tx_int}, "
          f"RX {len([c for c in rx if c])} taps gain {rx_gain} dec {rx_dec}; files in {out}")


if __name__ == "__main__":
    main()
