#!/usr/bin/env python3
"""Install gr-glidelink into the GNU Radio of the Python running this script, without CMake
(e.g. radioconda on Windows, which has no CMake). The blocks are pure Python:

- python/glidelink/*.py           -> <gnuradio package>/glidelink/
- hw/modules sc16.py, <module>/model.py and module.yaml (nco, fir, fft)
                                  -> <gnuradio package>/glidelink/modules/
- grc/*.yml                       -> <GNU Radio prefix>/share/gnuradio/grc/blocks/

    D:\\radioconda\\python.exe sw\\gr-glidelink\\install_conda.py
"""
import glob
import os
import shutil

from gnuradio import gr
import gnuradio

HERE = os.path.dirname(os.path.abspath(__file__))
HW_MODULES = os.path.join(HERE, "..", "..", "hw", "modules")
MODULES = ("nco", "fir", "fft")


def copy(src, dst_dir):
    os.makedirs(dst_dir, exist_ok=True)
    shutil.copy2(src, dst_dir)


def main():
    pkg = os.path.join(os.path.dirname(gnuradio.__file__), "glidelink")
    blocks = os.path.join(gr.prefix(), "share", "gnuradio", "grc", "blocks")
    for f in glob.glob(os.path.join(HERE, "python", "glidelink", "*.py")):
        copy(f, pkg)
    mods = os.path.join(pkg, "modules")
    copy(os.path.join(HW_MODULES, "sc16.py"), mods)
    for m in MODULES:
        for f in ("model.py", "module.yaml"):
            copy(os.path.join(HW_MODULES, m, f), os.path.join(mods, m))
    for f in glob.glob(os.path.join(HERE, "grc", "*.yml")):
        copy(f, blocks)
    print(f"Python package: {pkg}")
    print(f"GRC blocks:     {blocks}")


if __name__ == "__main__":
    main()
