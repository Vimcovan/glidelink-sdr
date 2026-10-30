"""DeepJSCC-Q encoder: bit-exact reference and test vectors for glidelink_jscc_enc.

The reference is the competition design's NumPy integer model (sim/network/golden_np.py and
make_golden.py of Vimcovan/glidelink-fpga, with the deployed model data/model_shallow), used
read-only from that repository: it computes, for a 256x256 RGB image, the encoder's 32768 64-QAM
symbols (levels 158 (2k - 7), Q10), which the RTL must reproduce bit for bit.

    python model.py vectors [image]     tb/vectors/{regs,in,out}.hex for the module testbench
    python model.py hil                 tb/vectors_hil/enc_hil.npz for sw/tests/enc_hil.py: four
                                        images (two photos / figures, noise, all white) and their
                                        symbol words

The competition repository is found at $GLIDELINK_COMPETITION_REPO, default
D:/ClaudePrj/deepjsccq-ofdm-fpga.
"""
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


def encode(img):
    """(256, 256, 3) uint8 -> (32768, 2) int Q10 symbol levels [I, Q], by the integer model"""
    mg = _golden()
    g = mg.Golden(REPO / "data" / "model_shallow")
    T, _ = mg.forward(g, np.asarray(img, np.int64), None, 0)
    return T["tx_symbols_q10"]


def load_image(path=None):
    mg = _golden()
    return mg.load_image(Path(path) if path else REPO / "src" / "sw" / "rx" / "assets" / "about" / "hardware.jpg")


def pack_image(img):
    """uint8 NHWC bytes, four per little-endian 32-bit word"""
    return np.frombuffer(np.asarray(img, np.uint8).tobytes(), dtype="<u4")


def symbol_words(sym):
    i = sym[:, 0].astype(np.int64) & 0xFFFF
    q = sym[:, 1].astype(np.int64) & 0xFFFF
    return ((q << 16) | i).astype(np.uint32)


def write_vectors(d, image=None):
    os.makedirs(d, exist_ok=True)
    img = load_image(image)
    words = pack_image(img)
    out = symbol_words(encode(img))
    assert len(words) == IMAGE_BYTES // 4 and len(out) == FRAME_SYMS
    open(os.path.join(d, "regs.hex"), "w", newline="\n").write("")
    open(os.path.join(d, "in.hex"), "w", newline="\n").write("".join(f"{int(w):08X} 0\n" for w in words))
    last = np.zeros(len(out), int)
    last[-1] = 1
    open(os.path.join(d, "out.hex"), "w", newline="\n").write(
        "".join(f"{int(w):08X} {l}\n" for w, l in zip(out, last)))
    np.save(os.path.join(d, "image.npy"), img)


def write_hil(d):
    os.makedirs(d, exist_ok=True)
    about = REPO / "src" / "sw" / "rx" / "assets" / "about"
    imgs = [load_image(about / "hardware.jpg"), load_image(about / "our_arch.png"),
            np.random.default_rng(3).integers(0, 256, (256, 256, 3)), np.full((256, 256, 3), 255)]
    imgs = np.array(imgs, np.uint8)
    syms = np.array([symbol_words(encode(im)) for im in imgs])
    np.savez(os.path.join(d, "enc_hil.npz"), images=imgs, symbols=syms)


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else ""
    if what == "vectors":
        write_vectors(os.path.join(HERE, "tb", "vectors"), sys.argv[2] if len(sys.argv) > 2 else None)
    elif what == "hil":
        write_hil(os.path.join(HERE, "tb", "vectors_hil"))
    else:
        print(__doc__)
