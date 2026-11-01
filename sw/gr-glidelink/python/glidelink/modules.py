#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""GlideLink user modules in GNU Radio (docs/design.md 5.3, docs/phase3_modules.md).

Every module whose module.yaml has a block section (hw/modules/module_desc.py) becomes two
blocks, both made here from the description, with the same parameters:

- <id>: the module in its PL slot. It writes the module's registers for its parameters and
  passes no data; the data reaches the slot through the PL connections drawn in GRC (pl.py)
  or the routes set with GlideLink Control. slot -1: the first slot holding the module.
- <id>_model: the module's reference model (model.py, class Model) in software, driven by the
  same register writes. The prototype, and the reference the PL module is checked against.

Replacing the software blocks by the PL blocks (and the host port source / sink, or the RF
source, around them) must leave the output unchanged (bit for bit where the model is exact).
"""
import inspect
import os
import sys

import numpy as np
import SoapySDR
from gnuradio import gr

from .pl import slot_ports

_HERE = os.path.dirname(os.path.abspath(__file__))
# installed next to this file; in the source tree, hw/modules
_DIRS = [os.path.join(_HERE, "modules"), os.path.join(_HERE, "..", "..", "..", "..", "hw", "modules")]
_DIR = next((d for d in _DIRS if os.path.isfile(os.path.join(d, "module_desc.py"))), _DIRS[0])
sys.path.insert(0, _DIR)
import module_desc  # noqa: E402
import sc16  # noqa: E402


def description(module_id):
    return module_desc.load(module_id, _DIR)


def model(module_id):
    """the reference model (model.py) of hw/modules/<module_id>"""
    return module_desc.load_model(description(module_id))


SLOT_BASE, SLOT_SIZE = 0x2000, 0x1000


def find_slot(dev, desc):
    """the first slot holding the module (its ID register)"""
    n = (dev.readRegister("FPGA", 0x008) >> 24) & 0xFF
    for k in range(n):
        if dev.readRegister("FPGA", SLOT_BASE + SLOT_SIZE * k) == desc["id_value"]:
            return k
    raise RuntimeError(f"GlideLink: no slot holds {desc['id']} (ID 0x{desc['id_value']:08X}); "
                       "load an image with it")


class slot_registers:
    """A module's registers in PL slot `slot` (-1: found by its ID), by name, through the Soapy
    "FPGA" register interface (the shell's window)."""

    def __init__(self, args, slot, module_id):
        self.dev = SoapySDR.Device(args)
        d = description(module_id)
        self.slot = find_slot(self.dev, d) if slot < 0 else slot
        self.base = SLOT_BASE + SLOT_SIZE * self.slot
        self.offsets = d["offsets"]
        found = self.read("ID")
        if found != d["id_value"]:
            raise RuntimeError(f"GlideLink: slot {self.slot} holds ID 0x{found:08X}, not {module_id} "
                               f"(0x{d['id_value']:08X})")

    def write(self, name, value):
        self.dev.writeRegister("FPGA", self.base + self.offsets[name], int(value) & 0xFFFFFFFF)

    def read(self, name):
        return self.dev.readRegister("FPGA", self.base + self.offsets[name])


def _defaults(desc):
    return [(p["name"], p.get("default", 0)) for p in desc["block"].get("params", [])]


def _bind(cls_name, names_defaults, a, kw):
    sig = inspect.Signature([inspect.Parameter(n, inspect.Parameter.POSITIONAL_OR_KEYWORD, default=v)
                             for n, v in names_defaults])
    b = sig.bind(*a, **kw)
    b.apply_defaults()
    return dict(b.arguments)


def _setters(cls, desc):
    for p in desc["block"].get("params", []):
        def setter(self, value, _n=p["name"]):
            self.program.set(_n, value)
        setter.__name__ = f"set_{p['name']}"
        setattr(cls, setter.__name__, setter)


class _module_block(gr.basic_block):
    """The module in its PL slot: register writes only (pl_args / pl_inputs / pl_outputs for
    the PL connections)."""

    def __init__(self, *a, **kw):
        d = self.desc
        v = _bind(type(self).__name__, [("args", "driver=glidelink"), ("slot", -1)] + _defaults(d), a, kw)
        gr.basic_block.__init__(self, name=f"GlideLink {d.get('name', d['id'])} (PL)", in_sig=None, out_sig=None)
        args = v.pop("args")
        self.regs = slot_registers(args, v.pop("slot"), d["id"])
        self.pl_args, self.pl_inputs, self.pl_outputs = slot_ports(args, self.regs.slot)
        self.program = module_desc.Program(d, self.regs.write, self.regs.read, model(d["id"]))
        self.program.start(v)

    def read(self, name):
        """a register of the module, by name"""
        return self.regs.read(name)

    def write(self, name, value):
        self.regs.write(name, value)


class _model_block(gr.basic_block):
    """The reference model in software: complex in / out (sc16 full scale 1.0), the model's
    output as it comes (any number of samples per input)."""

    def __init__(self, *a, **kw):
        d = self.desc
        v = _bind(type(self).__name__, _defaults(d), a, kw)
        gr.basic_block.__init__(self, name=f"GlideLink {d.get('name', d['id'])} (software)",
                                in_sig=[np.complex64], out_sig=[np.complex64])
        m = model(d["id"])
        self.m = m.Model()
        self.program = module_desc.Program(d, self.m.write, self.m.read, m)
        self.program.start(v)
        self.pending = np.zeros(0, np.complex64)

    def read(self, name):
        return self.m.read(name)

    def write(self, name, value):
        self.m.write(name, value)

    def forecast(self, noutput_items, ninputs):
        return [0 if len(self.pending) else 1] * ninputs

    def general_work(self, input_items, output_items):
        x, out = input_items[0], output_items[0]
        if len(self.pending) == 0 and len(x):
            n = min(len(x), max(len(out), 1))
            self.pending = sc16.to_complex(self.m.process(sc16.from_complex(x[:n])))
            self.consume(0, n)
        k = min(len(self.pending), len(out))
        out[:k] = self.pending[:k]
        self.pending = self.pending[k:]
        return k


def _make(module_id):
    d = description(module_id)
    doc = d["block"].get("doc", d.get("name", module_id)).strip()
    plist = ", ".join(p["name"] for p in d["block"].get("params", []))
    pl = type(module_id, (_module_block,), {"desc": d, "__doc__": f"{doc}\n\nThe module in its PL slot: "
              f"{module_id}(args, slot, {plist}); slot -1 finds it. Setters set_<parameter>."})
    sw = type(f"{module_id}_model", (_model_block,), {"desc": d, "__doc__": f"{doc}\n\nThe reference model "
              f"in software: {module_id}_model({plist}). Setters set_<parameter>."})
    _setters(pl, d)
    _setters(sw, d)
    return pl, sw


def block_modules():
    """ids of the modules with a block section"""
    ids = []
    for name in sorted(os.listdir(_DIR)):
        y = os.path.join(_DIR, name, "module.yaml")
        if os.path.isfile(y) and os.path.isfile(os.path.join(_DIR, name, "model.py")):
            if "\nblock:" in open(y, encoding="utf8").read():
                ids.append(name)
    return ids


BLOCKS = {}
for _id in block_modules():
    BLOCKS[_id], BLOCKS[_id + "_model"] = _make(_id)
globals().update(BLOCKS)
