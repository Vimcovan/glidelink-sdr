"""GlideLink user module descriptions (hw/modules/<id>/module.yaml), shared by the image
generator, the testbench scripts and the GNU Radio blocks.

registers: in the order given; offsets from 0x008 on in steps of 4 unless an entry sets
`offset`. ID (0x000) and VERSION (0x004) come first, from id_value and version. Each entry:

    name     register name (upper case by convention)
    access   rw (default), ro, wo
    width    bits, default 32 (or the fields' span)
    default  value after reset (rw)
    fields   [{name, bits: "n" or "msb:lsb", access: rw | ro | pulse, default, doc}]
    strobe   rw / wo: the module also gets <name>_wr, one cycle per write
    readback rw: reads return the module's <name>_rd instead of the stored value
    signed   reads sign-extend the value to 32 bits
    value    ro: a constant (Verilog expression of the module's parameters, e.g. TAPS)
    doc      one line

With `bus: generated` (the default) hw/scripts/gen_module.py writes the AXI4-Lite register
file and the module sees each register as plain ports (see there). With `bus: module` the
module decodes AXI4-Lite itself and the list only names the registers for software.

block: the module as a GNU Radio block, the same parameters for the PL block and for the
software block (the reference model). Each parameter:

    name, label, type (real, int, bool, string, enum, int_vector, real_vector), default
    options  enum: [[value, label, register value], ...]
    check    expression that must hold, e.g. "8 <= size <= 4096"
    write    register writes when the parameter is set: {REG: expr, ...} or a list of
             [REG, expr]; an expression giving a list writes REG once per element;
             [[REG_A, REG_B], expr] writes REG_A, REG_B for each tuple of the list
    doc      one line

start: writes after all parameters (e.g. {CONTROL: 1}). Expressions are Python, over the
parameters (enums as their register values), read(REG), log2(n) (exact powers of two),
pad(list, n), round, min, max, abs, int, len, math and the module's model (model.f(...)).
Results are rounded and masked to 32 bits.
"""
import ast
import importlib.util
import math
import os
import re

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
TYPES = ("real", "int", "bool", "string", "enum", "int_vector", "real_vector")


def module_dir(module_id, root=HERE):
    return os.path.join(root, module_id)


def bits_range(bits):
    """'4:0' -> (4, 0), 3 -> (3, 3)"""
    s = str(bits)
    if ":" in s:
        hi, lo = (int(v) for v in s.split(":"))
    else:
        hi = lo = int(s)
    if not 0 <= lo <= hi <= 31:
        raise ValueError(f"bits {bits}")
    return hi, lo


def version_word(v):
    major, minor, patch = (int(x) for x in str(v).split("."))
    return (major << 16) | (minor << 8) | patch


def normalize_registers(desc):
    """the register list with ID / VERSION first, offsets, access, width, fields resolved"""
    regs = []
    names = {r["name"] for r in desc.get("registers", []) or []}
    if "ID" not in names:
        regs.append({"name": "ID", "offset": 0x000, "access": "ro", "width": 32,
                     "value_int": desc["id_value"], "builtin": True})
    if "VERSION" not in names:
        regs.append({"name": "VERSION", "offset": 0x004, "access": "ro", "width": 32,
                     "value_int": version_word(desc.get("version", "1.0.0")), "builtin": True})
    nxt = 0x008
    for r in desc.get("registers", []) or []:
        r = dict(r)
        r.setdefault("offset", nxt)
        if r["offset"] % 4 or not 0 <= r["offset"] < 0x1000:
            raise ValueError(f"{r['name']}: offset 0x{r['offset']:X}")
        nxt = r["offset"] + 4
        r.setdefault("access", "rw")
        if r["access"] not in ("rw", "ro", "wo"):
            raise ValueError(f"{r['name']}: access {r['access']}")
        if "fields" in r:
            fl = []
            for f in r["fields"]:
                f = dict(f)
                f["hi"], f["lo"] = bits_range(f["bits"])
                f.setdefault("access", "ro" if r["access"] == "ro" else "rw")
                f.setdefault("default", 0)
                fl.append(f)
            r["fields"] = fl
            r.setdefault("width", max(f["hi"] for f in fl) + 1)
            r["default"] = sum((int(f["default"]) & ((1 << (f["hi"] - f["lo"] + 1)) - 1)) << f["lo"]
                               for f in fl)
        r.setdefault("width", 32)
        r.setdefault("default", 0)
        regs.append(r)
    seen = {}
    for r in regs:
        if r["offset"] in seen:
            raise ValueError(f"{r['name']} and {seen[r['offset']]} at 0x{r['offset']:03X}")
        seen[r["offset"]] = r["name"]
    return regs


def load(module_id, root=HERE):
    """module.yaml of hw/modules/<module_id> (or of an installed copy in root), normalized"""
    d = module_dir(module_id, root)
    with open(os.path.join(d, "module.yaml"), encoding="utf8") as f:
        desc = yaml.safe_load(f)
    desc["dir"] = d
    desc.setdefault("bus", "generated")
    desc["regs"] = normalize_registers(desc)
    desc["offsets"] = {r["name"]: r["offset"] for r in desc["regs"]}
    if "block" in desc:
        for p in desc["block"].get("params", []):
            if p.get("type", "real") not in TYPES:
                raise ValueError(f"parameter {p['name']}: type {p['type']}")
    return desc


def load_model(desc):
    """the module's model.py as a Python module"""
    path = os.path.join(desc["dir"], desc.get("model", "model.py"))
    spec = importlib.util.spec_from_file_location(f"glidelink_model_{desc['id']}", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# ---------------------------------------------------------------------------
# block parameters -> register writes
# ---------------------------------------------------------------------------

def log2(n):
    k = int(n).bit_length() - 1
    if n != 1 << k:
        raise ValueError(f"{n} is not a power of two")
    return k


def pad(values, n):
    v = [int(c) for c in values]
    if len(v) > n:
        raise ValueError(f"at most {n} values")
    return v + [0] * (n - len(v))


def _write_list(w):
    return list(w.items()) if isinstance(w, dict) else [tuple(x) for x in w]


def _names(expr):
    if not isinstance(expr, str):
        return set()
    return {n.id for n in ast.walk(ast.parse(expr, mode="eval")) if isinstance(n, ast.Name)}


def _word(v):
    return int(round(v)) & 0xFFFFFFFF if isinstance(v, float) else int(v) & 0xFFFFFFFF


class Program:
    """The writes a block does for its parameters: start() all of them, set(name, value)
    those of the parameters whose writes use `name`. write(reg, value) / read(reg) are the
    target: the board's slot registers (PL block) or a Model (software block)."""

    def __init__(self, desc, write, read, model=None):
        self.desc, self.write, self.read, self.model = desc, write, read, model
        blk = desc.get("block", {})
        self.params = blk.get("params", [])
        self.byname = {p["name"]: p for p in self.params}
        self.values = {}
        self.entries = []                   # (parameter, [(regs, expr)], names used)
        for p in self.params:
            ws = _write_list(p.get("write", {}) or {})
            used = {p["name"]} | set().union(*[_names(e) for _, e in ws]) if ws else {p["name"]}
            self.entries.append((p, ws, used))
        self.start_writes = _write_list(blk.get("start", {}) or {})

    def _value(self, p, v):
        t = p.get("type", "real")
        if t == "enum":
            for opt in p["options"]:
                if str(opt[0]) == str(v):
                    return opt[2] if len(opt) > 2 else opt[0]
            raise ValueError(f"{p['name']}: {v!r} not one of {[o[0] for o in p['options']]}")
        if t == "bool":
            return int(bool(v))
        if t == "int":
            return int(v)
        if t in ("int_vector", "real_vector"):
            return list(v)
        return v

    def _env(self):
        env = {"read": self.read, "log2": log2, "pad": pad, "round": round, "min": min, "max": max,
               "abs": abs, "int": int, "len": len, "math": math, "model": self.model}
        for name, p in self.byname.items():
            if name in self.values:
                env[name] = self._value(p, self.values[name])
        return env

    def _run(self, writes):
        env = self._env()
        for regs, expr in writes:
            v = eval(expr, {"__builtins__": {}}, env) if isinstance(expr, str) else expr
            if isinstance(regs, (list, tuple)):
                for tup in v:
                    for reg, x in zip(regs, tup):
                        self.write(reg, _word(x))
            elif isinstance(v, (list, tuple)):
                for x in v:
                    self.write(regs, _word(x))
            else:
                self.write(regs, _word(v))

    def _check(self, p):
        c = p.get("check")
        if c and not eval(c, {"__builtins__": {}}, self._env()):
            raise ValueError(f"{p['name']} = {self.values[p['name']]!r}: needs {c}")

    def start(self, values):
        self.values = dict(values)
        for p, ws, _ in self.entries:
            self._check(p)
            self._run(ws)
        self._run(self.start_writes)

    def set(self, name, value):
        self.values[name] = value
        self._check(self.byname[name])
        for p, ws, used in self.entries:
            if name in used:
                self._run(ws)


# ---------------------------------------------------------------------------
# register-level reference models
# ---------------------------------------------------------------------------

class RegisterModel:
    """Base of a module's software model: the registers by name as the module holds them.
    write(name, value) stores the value (rw / wo) and calls on_write; read(name) returns the
    stored value, the constant of ro registers, or what on_read gives. A model implements
    process(words) -> words (uint32 sc16 words in, any number out), keeping its own state."""

    def __init__(self, desc, params=None):
        self.desc = desc
        self.params = dict(desc.get("parameters", {}) or {})
        self.params.update(params or {})
        self.r = {}
        for reg in desc["regs"]:
            self.r[reg["name"]] = reg
        self.regs = {name: int(reg.get("default", 0)) for name, reg in self.r.items()}

    def field(self, reg, name):
        f = next(f for f in self.r[reg]["fields"] if f["name"] == name)
        return (self.regs[reg] >> f["lo"]) & ((1 << (f["hi"] - f["lo"] + 1)) - 1)

    def write(self, name, value):
        reg = self.r[name]
        value = int(value) & 0xFFFFFFFF
        if reg["access"] == "ro":
            return
        self.regs[name] = value & ((1 << reg["width"]) - 1) if reg["width"] < 32 else value
        self.on_write(name, value)
        for f in reg.get("fields", []):     # pulse fields read back 0
            if f["access"] == "pulse":
                self.regs[name] &= ~(((1 << (f["hi"] - f["lo"] + 1)) - 1) << f["lo"])

    def read(self, name):
        reg = self.r[name]
        if "value_int" in reg:
            return reg["value_int"]
        if "value" in reg:
            return int(eval(str(reg["value"]), {"__builtins__": {}}, dict(self.params)))
        v = self.on_read(name)
        if v is None:
            return 0 if reg["access"] == "wo" else self.regs[name]
        return int(v) & 0xFFFFFFFF

    def on_write(self, name, value):
        pass

    def on_read(self, name):
        return None

    def process(self, words):
        raise NotImplementedError
