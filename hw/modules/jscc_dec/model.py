"""DeepJSCC-Q decoder: bit-exact reference and test vectors for glidelink_jscc_dec.

The reference is the competition design's NumPy integer model (sim/network/golden_np.py and
make_golden.py of Vimcovan/glidelink-fpga, with the deployed model data/model_shallow), used
read-only from that repository: from 32768 soft symbols (12-bit Q10, the OFDM receiver's output)
it computes the 256x256 RGB image, which the RTL must reproduce bit for bit. decode() runs only
the decoder's operations of the model on any symbols (e.g. ones captured from the receiver).

    python model.py vectors [image] [snr]   tb/vectors/{regs,in,out}.hex for the module testbench:
                                            the image encoded by the model, AWGN at snr dB
                                            (default 20) on the unit-power symbols
    python model.py hil                     tb/vectors_hil/dec_hil.npz for sw/tests/dec_hil.py:
                                            four images at SNR 30 / 20 / 10 / 5 dB, their soft
                                            symbol words and the decoded images

The competition repository is found at $GLIDELINK_COMPETITION_REPO, default
D:/ClaudePrj/deepjsccq-ofdm-fpga.
"""
import copy
import os
import sys
from pathlib import Path

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = Path(os.environ.get("GLIDELINK_COMPETITION_REPO", "D:/ClaudePrj/deepjsccq-ofdm-fpga"))
FRAME_SYMS = 32768
IMAGE_BYTES = 256 * 256 * 3


def _golden():
    sys.dont_write_bytecode = True                       # leave the competition repository untouched
    sys.path.insert(0, str(REPO / "sim" / "network"))
    import make_golden                                   # noqa: E402  (competition repository)
    return make_golden


def _model():
    mg = _golden()
    return mg, mg.Golden(REPO / "data" / "model_shallow")


def channel(img, snr, seed=1):
    """(256, 256, 3) uint8 -> (32768, 2) int soft symbols [I, Q] (Q10, 12 bits): the image encoded
    by the model, AWGN at snr dB on the unit-power symbols (None: none)"""
    mg, g = _model()
    T, _ = mg.forward(g, np.asarray(img, np.int64), snr, seed)
    return T["rx_symbols"]


def decode(sym):
    """(32768, 2) int soft symbols [I, Q] -> (256, 256, 3) uint8, by the decoder's operations"""
    mg, g = _model()
    ops = g.m["ops"]
    k = next(i for i, op in enumerate(ops) if op["op"] == "rx_input")
    rx = ops[k]["out"]
    dec = []
    for op in copy.deepcopy(ops[k + 1:]):                # the decoder reads the symbols as "input"
        if op.get("in") == rx:
            op["in"] = "input"
        elif isinstance(op.get("in"), list):
            op["in"] = ["input" if n == rx else n for n in op["in"]]
        dec.append(op)
    g2 = copy.copy(g)
    g2.m = dict(g.m, ops=dec)
    x = np.clip(np.asarray(sym, np.int64), -2048, 2047).reshape(g.m["tensors"][rx]["shape_hwc"])
    T, _ = mg.forward(g2, x, None, 0)
    return T["output"].astype(np.uint8)


def load_image(path=None):
    mg = _golden()
    return mg.load_image(Path(path) if path else REPO / "src" / "sw" / "rx" / "assets" / "about" / "hardware.jpg")


def symbol_words(sym):
    i = sym[:, 0].astype(np.int64) & 0xFFFF
    q = sym[:, 1].astype(np.int64) & 0xFFFF
    return ((q << 16) | i).astype(np.uint32)


def image_words(img):
    """uint8 NHWC bytes, four per little-endian 32-bit word"""
    return np.frombuffer(np.asarray(img, np.uint8).tobytes(), dtype="<u4")


def psnr(a, b):
    return 10 * np.log10(255 ** 2 / np.mean((np.asarray(a, float) - np.asarray(b, float)) ** 2))


def write_vectors(d, image=None, snr=20.0):
    os.makedirs(d, exist_ok=True)
    img = load_image(image)
    sym = channel(img, snr)
    out = decode(sym)
    words = image_words(out)
    print(f"PSNR {psnr(out, img):.2f} dB at SNR {snr} dB")
    open(os.path.join(d, "regs.hex"), "w", newline="\n").write("")
    open(os.path.join(d, "in.hex"), "w", newline="\n").write("".join(f"{int(w):08X} 0\n" for w in symbol_words(sym)))
    last = np.zeros(len(words), int)
    last[-1] = 1
    open(os.path.join(d, "out.hex"), "w", newline="\n").write(
        "".join(f"{int(w):08X} {l}\n" for w, l in zip(words, last)))


def write_hil(d):
    os.makedirs(d, exist_ok=True)
    about = REPO / "src" / "sw" / "rx" / "assets" / "about"
    imgs = [load_image(about / "hardware.jpg"), load_image(about / "our_arch.png"),
            np.random.default_rng(3).integers(0, 256, (256, 256, 3)), np.full((256, 256, 3), 255)]
    snrs = [30.0, 20.0, 10.0, 5.0]
    syms, outs = [], []
    for k, (im, snr) in enumerate(zip(imgs, snrs)):
        s = channel(im, snr, seed=k + 1)
        o = decode(s)
        print(f"image {k}: SNR {snr} dB, PSNR {psnr(o, im):.2f} dB")
        syms.append(symbol_words(s))
        outs.append(image_words(o))
    np.savez(os.path.join(d, "dec_hil.npz"), images=np.array(imgs, np.uint8), symbols=np.array(syms),
             decoded=np.array(outs), snr=np.array(snrs))


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else ""
    if what == "vectors":
        write_vectors(os.path.join(HERE, "tb", "vectors"), sys.argv[2] if len(sys.argv) > 2 else None,
                      float(sys.argv[3]) if len(sys.argv) > 3 else 20.0)
    elif what == "hil":
        write_hil(os.path.join(HERE, "tb", "vectors_hil"))
    else:
        print(__doc__)
