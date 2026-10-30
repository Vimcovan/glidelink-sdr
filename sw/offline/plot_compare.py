"""PSNR against -EVM: the platform's sweep (link_metrics.py sweep) next to the competition's run
k0802_final (data/measurements/psnr_snr of Vimcovan/glidelink-fpga, read-only), same image, same
attenuation points. As in the competition's figure, points where the receiver decodes fewer than
25 images per second are left out (the synchronisation edge).

    python plot_compare.py [--sweep ../../data/measurements/phase4/sweep.json] [--out ...png]
"""
import argparse
import csv
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt                          # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("GLIDELINK_COMPETITION_REPO", "D:/ClaudePrj/deepjsccq-ofdm-fpga")
SURFACE, INK, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#6b6b68", "#e6e5e1"
BLUE, ORANGE = "#2a78d6", "#eb6834"                     # categorical slots 1, 2 (validated)


def competition():
    rows = [r for r in csv.DictReader(open(os.path.join(REPO, "data", "measurements", "psnr_snr", "k0802_final.csv")))
            if r["mode"] == "jscc" and r["psnr_decoded"] and r["evm_db"] and float(r["rx_fps"]) >= 25]
    return [(-float(r["evm_db"]), float(r["psnr_decoded"]), float(r["att"])) for r in rows]


def platform(path):
    rows = json.load(open(path))["results"]
    return [(-r["evm_db"], r["psnr"]["mean"], r["att"]) for r in rows
            if r["evm_db"] is not None and r["psnr"]["mean"] is not None and r["rx_fps"] >= 25]


def main():
    ap = argparse.ArgumentParser()
    meas = os.path.join(HERE, "..", "..", "data", "measurements", "phase4")
    ap.add_argument("--sweep", default=os.path.join(meas, "sweep.json"))
    ap.add_argument("--out", default=os.path.join(meas, "psnr_evm.png"))
    a = ap.parse_args()
    plt.rcParams.update({"font.size": 10, "axes.edgecolor": MUTED, "axes.labelcolor": INK,
                         "xtick.color": MUTED, "ytick.color": MUTED, "text.color": INK})
    fig, ax = plt.subplots(figsize=(7.2, 4.4), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)
    ax.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    series = [("Competition system (k0802_final)", competition(), BLUE, "o"),
              ("GlideLink platform (offline)", platform(a.sweep), ORANGE, "s")]
    for label, pts, color, marker in series:
        pts = sorted(pts)
        ax.plot([p[0] for p in pts], [p[1] for p in pts], color=color, linewidth=2, marker=marker,
                markersize=6, markeredgecolor=SURFACE, markeredgewidth=1.2, label=label)
    ax.set_xlabel("-EVM (dB), final constellation")
    ax.set_ylabel("PSNR (dB), div2k_0802")
    ax.legend(frameon=False, loc="lower right")
    fig.tight_layout()
    fig.savefig(a.out, facecolor=SURFACE)
    print(a.out)


if __name__ == "__main__":
    main()
