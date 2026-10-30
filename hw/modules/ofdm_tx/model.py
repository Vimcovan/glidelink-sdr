"""OFDM transmitter: test vectors and an output checker for glidelink_ofdm_tx (docs/phase4_plan.md).

The module wraps the competition RTL unchanged, so this is not a second bit-exact model of it
(phase 4 decision G3); it checks the module's output against what the transmitter must send:

- packet structure: per frame one packet of 320 + 80 NSYM samples followed by GAP zeros, tlast
  on its last sample, tuser flags = end of burst;
- the 320 preamble samples, bit for bit: the preamble.mem entries with each 12-bit half
  shifted right by 1 (as preamble_insert.sv does), then left by 4 to 16-bit full scale;
- the data: each OFDM symbol (CP 16 + 64) is FFT'd, the 48 data subcarriers taken (802.11a,
  pilots at +-7 / +-21), the PN sign scrambling of iq_pn_scrambler.sv undone, and the result
  compared with the input symbols; the subcarrier order and the IFFT scale are calibrated on
  the first OFDM symbol. Every symbol must decide back to its 64-QAM point and the error must
  stay within the quantisation noise.

    python model.py vectors [frames]          tb/vectors/{regs,in}.hex (capture mode, no out.hex)
    python model.py vectors_prbs              tb/vectors_prbs: the module's own PRBS frames
    python model.py check <captured.hex> [prbs]   checks the testbench's capture
    python model.py check_rx <capture.npy>    checks an RF RX capture through the AD9361 digital
                                              loopback (module in PRBS mode): finds the frames
                                              by their preamble, then checks them as above
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack  # noqa: E402

NSYM, FRAME_SYMS, GAP = 683, 32768, 1000
PRE, CP, NFFT = 320, 16, 64
FRAME_LEN = PRE + 80 * NSYM
DATA_SC = [k for k in range(-26, 27) if k not in (0, -21, -7, 7, 21)]
LEVELS = 158 * (2 * np.arange(8) - 7)


def pn_signs(n):
    """iq_pn_scrambler.sv: LFSR x^7+x^4+1, seed 1011101, two steps per symbol (I bit, Q bit)"""
    st = [int(c) for c in "1011101"]            # st[0] = bit 6 ... st[6] = bit 0
    si, sq = np.empty(n, int), np.empty(n, int)
    for k in range(n):
        b6, b5, b3, b2 = st[0], st[1], st[3], st[4]
        fb1, fb2 = b6 ^ b3, b5 ^ b2
        si[k], sq[k] = fb1, fb2
        st = st[2:] + [fb1, fb2]                # {st[4:0], fb1, fb2}
    return si, sq


def neg_sat(v):
    return np.where(v == -2048, 2047, -v)


def symbols(frames, seed=3):
    rng = np.random.default_rng(seed)
    i = LEVELS[rng.integers(0, 8, frames * FRAME_SYMS)]
    q = LEVELS[rng.integers(0, 8, frames * FRAME_SYMS)]
    return i, q


def prbs_symbols(frames):
    """iq_prbs_source.sv: PRBS-15 (x^15+x^14+1, all-ones seed), restarted every frame, 6 bits per
    symbol, b0 b1 b2 -> I and b3 b4 b5 -> Q as Gray codes {msb, mid, lsb}, level 158 (2k - 7)"""
    st = [1] * 15                               # st[0] = bit 14 ... st[14] = bit 0
    bits = np.empty((FRAME_SYMS, 6), int)
    for n in range(FRAME_SYMS):
        for k in range(6):
            b = st[0] ^ st[1]
            bits[n, k] = b
            st = st[1:] + [b]
    def lvl(g2, g1, g0):
        k = (g2 << 2) | ((g2 ^ g1) << 1) | (g2 ^ g1 ^ g0)
        return 158 * (2 * k - 7)
    i = lvl(bits[:, 0], bits[:, 1], bits[:, 2])
    q = lvl(bits[:, 3], bits[:, 4], bits[:, 5])
    return np.tile(i, frames), np.tile(q, frames)


def write_vectors(d, frames=2):
    os.makedirs(d, exist_ok=True)
    i, q = symbols(frames)
    words = pack(i, q)                          # 12-bit values sign-extended into 16
    last = np.zeros(len(words), int)
    last[FRAME_SYMS - 1::FRAME_SYMS] = 1
    open(os.path.join(d, "regs.hex"), "w", newline="\n").write(f"010 {GAP:08X}\n")
    open(os.path.join(d, "in.hex"), "w", newline="\n").write(
        "".join(f"{int(w):08X} {l}\n" for w, l in zip(words, last)))


def read_capture(path):
    w, l, f = [], [], []
    for line in open(path):
        p = line.split()
        if len(p) >= 2:
            w.append(int(p[0], 16))
            l.append(int(p[1]))
            f.append(int(p[2], 16) if len(p) > 2 else 0)
    return np.array(w, np.uint32), np.array(l), np.array(f)


def preamble():
    rom = [int(x, 16) for x in open(os.path.join(HERE, "preamble.mem")).read().split()][:PRE]
    rom = np.array(rom)
    i = ((rom & 0xFFF) ^ 0x800) - 0x800
    q = (((rom >> 12) & 0xFFF) ^ 0x800) - 0x800
    return pack((i >> 1) << 4, (q >> 1) << 4)


def check(path, frames=None, prbs=False):
    words, last, flags = read_capture(path)
    ends = np.flatnonzero(last)
    pkt_len = FRAME_LEN + GAP
    errors = []
    print(f"{len(words)} samples, {len(ends)} packets")
    if len(ends) == 0 or np.any(np.diff(np.r_[-1, ends]) != pkt_len):
        errors.append(f"packet lengths {np.diff(np.r_[-1, ends])[:5]} (want {pkt_len})")
    n_frames = len(ends) if frames is None else frames
    return check_frames(words, flags, n_frames, prbs_symbols(n_frames) if prbs else symbols(n_frames), errors)


def check_rx(path):
    """An RF RX capture (uint32 words, 16-bit full scale) of the module's PRBS frames through the
    digital loopback: 12-bit samples come back unchanged, so the frames are found by the exact
    preamble and checked; the gap is checked too (no end-of-burst flag on this side)."""
    words = np.load(path).astype(np.uint32)
    pre = preamble()
    pkt_len = FRAME_LEN + GAP
    # candidate starts: the first preamble word, then the whole preamble must match
    cand = np.flatnonzero(words[:len(words) - pkt_len] == pre[0])
    starts = [int(c) for c in cand if np.array_equal(words[c:c + PRE], pre)]
    errors = []
    print(f"{len(words)} samples, {len(starts)} complete frames found at {starts[:4]}...")
    if len(starts) < 2:
        errors.append("fewer than 2 complete frames in the capture")
    elif np.any(np.diff(starts) != pkt_len):
        errors.append(f"frame spacing {np.diff(starts)[:5]} (want {pkt_len}: back to back with the gap)")
    frames = np.concatenate([words[s:s + pkt_len] for s in starts]) if starts else words[:0]
    flags = np.zeros(len(frames), int)
    flags[::pkt_len] = 0x02                     # not visible on the RX side: take it as given
    return check_frames(frames, flags, len(starts), prbs_symbols(len(starts)), errors)


def check_frames(words, flags, n_frames, source, errors):
    pkt_len = FRAME_LEN + GAP
    ti, tq = source
    si, sq = pn_signs(FRAME_SYMS)
    pre = preamble()
    worst, decided_wrong = 0.0, 0
    for f in range(n_frames):
        start = f * pkt_len
        pk = words[start:start + pkt_len]
        if flags[start] & 0x02 == 0:
            errors.append(f"frame {f}: end-of-burst flag missing")
        if not np.array_equal(pk[:PRE], pre):
            errors.append(f"frame {f}: preamble differs in {np.count_nonzero(pk[:PRE] != pre)} samples")
        if np.any(pk[FRAME_LEN:] != 0):
            errors.append(f"frame {f}: gap not zero")
        i, q = unpack(pk[PRE:FRAME_LEN])
        x = (i + 1j * q).reshape(NSYM, 80)[:, CP:] / 16.0
        X = np.fft.fft(x, axis=1)
        # expected data symbols after the PN sign scrambling, padded to NSYM * 48
        ei = np.where(si == 1, neg_sat(ti[f * FRAME_SYMS:(f + 1) * FRAME_SYMS]), ti[f * FRAME_SYMS:(f + 1) * FRAME_SYMS])
        eq = np.where(sq == 1, neg_sat(tq[f * FRAME_SYMS:(f + 1) * FRAME_SYMS]), tq[f * FRAME_SYMS:(f + 1) * FRAME_SYMS])
        e = np.zeros(NSYM * 48, complex)
        e[:FRAME_SYMS] = ei + 1j * eq
        e = e.reshape(NSYM, 48)
        if f == 0:
            # subcarrier order and scale from the first OFDM symbol: for each expected symbol
            # position the bin that matches it best
            bins = [k % NFFT for k in DATA_SC]
            order = []
            for n in range(48):
                c = [abs(np.vdot(X[:8, b], e[:8, n])) / (np.linalg.norm(X[:8, b]) + 1e-9) for b in bins]
                order.append(bins[int(np.argmax(c))])
            if len(set(order)) != 48:
                errors.append("could not calibrate the subcarrier order")
                break
            scale = np.vdot(X[:, order].ravel(), e.ravel()) / np.vdot(X[:, order].ravel(), X[:, order].ravel())
        y = X[:, order] * scale
        err = np.abs(y - e)
        worst = max(worst, float(err.max()))
        di = LEVELS[np.argmin(np.abs(y.real.ravel()[:, None] - LEVELS[None, :]), axis=1)]
        dq = LEVELS[np.argmin(np.abs(y.imag.ravel()[:, None] - LEVELS[None, :]), axis=1)]
        good = (di == e.real.ravel()) & (dq == e.imag.ravel())
        decided_wrong += int(np.count_nonzero(~good[:FRAME_SYMS]))
    print(f"data: worst error {worst:.1f} (64-QAM spacing 316), symbols decided wrong: {decided_wrong}")
    if decided_wrong or worst > 40:
        errors.append("data symbols do not come back")
    for e in errors:
        print("ERROR:", e)
    print("PASS" if not errors else "FAIL")
    return not errors


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else ""
    if what == "vectors":
        write_vectors(os.path.join(HERE, "tb", "vectors"), int(sys.argv[2]) if len(sys.argv) > 2 else 2)
    elif what == "vectors_prbs":
        d = os.path.join(HERE, "tb", "vectors_prbs")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "regs.hex"), "w", newline="\n").write(f"010 {GAP:08X}\n008 00000005\n")
        open(os.path.join(d, "in.hex"), "w", newline="\n").write("00000000 0\n")   # not taken
    elif what == "check":
        sys.exit(0 if check(sys.argv[2], prbs=len(sys.argv) > 3 and sys.argv[3] == "prbs") else 1)
    elif what == "check_rx":
        sys.exit(0 if check_rx(sys.argv[2]) else 1)
    else:
        print(__doc__)
