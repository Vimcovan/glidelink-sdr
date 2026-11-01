#!/usr/bin/env python3
"""Install gr-glidelink into the GNU Radio of the Python running this script, without CMake
(e.g. radioconda on Windows, which has no CMake). The blocks are pure Python:

- python/glidelink/*.py           -> <gnuradio package>/glidelink/
- hw/modules sc16.py, module_desc.py, and model.py / module.yaml of every module with a
  block section                   -> <gnuradio package>/glidelink/modules/
- grc/*.yml, and the modules' blocks generated from module.yaml (hw/scripts/gen_module.py)
                                  -> <GNU Radio prefix>/share/gnuradio/grc/blocks/

    D:\\radioconda\\python.exe sw\\gr-glidelink\\install_conda.py
"""
import glob
import os
import shutil
import sys

from gnuradio import gr
import gnuradio

HERE = os.path.dirname(os.path.abspath(__file__))
HW = os.path.join(HERE, "..", "..", "hw")
HW_MODULES = os.path.join(HW, "modules")
sys.path.insert(0, os.path.join(HW, "scripts"))
import gen_module  # noqa: E402


def copy(src, dst_dir):
    os.makedirs(dst_dir, exist_ok=True)
    shutil.copy2(src, dst_dir)


def main():
    pkg = os.path.join(os.path.dirname(gnuradio.__file__), "glidelink")
    blocks = os.path.join(gr.prefix(), "share", "gnuradio", "grc", "blocks")
    for f in glob.glob(os.path.join(HERE, "python", "glidelink", "*.py")):
        copy(f, pkg)
    mods = os.path.join(pkg, "modules")
    for f in ("sc16.py", "module_desc.py"):
        copy(os.path.join(HW_MODULES, f), mods)
    for m in gen_module.block_modules():
        for f in ("model.py", "module.yaml"):
            copy(os.path.join(HW_MODULES, m, f), os.path.join(mods, m))
        for fn, text in gen_module.grc_blocks(gen_module.module_desc.load(m)).items():
            with open(os.path.join(blocks, fn), "w", encoding="utf8", newline="\n") as fh:
                fh.write(text)
        print(f"module {m}: blocks glidelink_{m} (PL), glidelink_{m}_model (software)")
    for f in glob.glob(os.path.join(HERE, "grc", "*.yml")):
        copy(f, blocks)
    print(f"Python package: {pkg}")
    print(f"GRC blocks:     {blocks}")


if __name__ == "__main__":
    main()
