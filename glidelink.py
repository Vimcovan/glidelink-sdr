#!/usr/bin/env python3
"""GlideLink user modules from the command line (docs/module_guide.md):

    python glidelink.py new <id> [--name "Readable name"]
        hw/modules/<id>/: module.yaml, RTL and reference model of a module that passes the
        samples through; it builds, simulates and runs as it is
    python glidelink.py test <id> [--case K]
        the module against its reference model in xsim: for each entry of `tests` in
        module.yaml (block parameters, or register names with raw values) the register writes
        come from the same parameter -> register mapping as the GNU Radio blocks, random sc16
        packets go in with random gaps and back-pressure, and the output and the registers
        read back afterwards are compared with the model
    python glidelink.py build <image> | build <id> [<id> ...] [--name <image>]
        a PL image: hw/images/<image>.yaml, or the listed modules in slots 1, 2, ... (written to
        hw/images/<image>.yaml, default name "user"); Vivado, then the bitstream and hardware
        description in hw/build/<image>/
    python glidelink.py deploy <board> [<image>] [--no-reboot]
        copies the image to the board, makes it the boot image, reboots, and checks that each
        slot holds the module the image says
    python glidelink.py status <board>
        the board's boot image and the module in each slot

Machine settings come from environment variables or glidelink.local.yaml next to this file
(not in git): VIVADO (vivado executable), ADI_HDL_DIR (ADI HDL tree with its libraries built),
GLIDELINK_SSH_KEY and GLIDELINK_SSH_USER (default root) for the boards.
"""
import argparse
import copy
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

import numpy as np
import yaml

ROOT = os.path.dirname(os.path.abspath(__file__))
HW = os.path.join(ROOT, "hw")
sys.path.insert(0, os.path.join(HW, "scripts"))
sys.path.insert(0, os.path.join(HW, "modules"))
import gen_module  # noqa: E402
import module_desc  # noqa: E402
from sc16 import pack  # noqa: E402

PROJECT = os.path.join(HW, "projects", "fmcomms2_pynqzu")
SIM = os.path.join(HW, "library", "glidelink_module", "tb", "run_module_sim.ps1")
BOARD_PY = "python3"


def setting(name, default=None):
    if os.environ.get(name):
        return os.environ[name]
    cfg = os.path.join(ROOT, "glidelink.local.yaml")
    if os.path.isfile(cfg):
        with open(cfg, encoding="utf8") as f:
            v = (yaml.safe_load(f) or {}).get(name)
        if v:
            return str(v)
    return default


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# new
# ---------------------------------------------------------------------------

YAML_TEMPLATE = """\
# GlideLink user module (docs/module_guide.md)
id: {id}
name: {name}
rtl: glidelink_{id}.v
top: glidelink_{id}
model: model.py
id_value: 0x{id_value:08X}          # "{id_text}": the ID register, by which the PL block finds the slot
version: 1.0.0
data:
  input: sc16                 # {{Q[31:16], I[15:0]}}
  output: sc16
# rate: {{interp: 4}}           # outputs per input when not 1 : 1 ({{decim: 2}}, or variable); the
#                             # platform makes the packets (tuser, tlast) from it
function: >-
  Passes the samples through (template: replace with what the module does).
registers:                    # ID 0x000, VERSION 0x004, then from 0x008 on; ports: docs/module_guide.md
  - name: CONTROL
    fields:
      - {{name: enable, bits: 0, doc: "1 = process, 0 = pass unchanged"}}
      - {{name: soft_reset, bits: 1, access: pulse, doc: "pipeline emptied"}}
  # - {{name: GAIN, width: 16, default: 16384, doc: "gain, 1.0 = 16384"}}
block:                        # the GNU Radio blocks (PL and software), same parameters
  doc: {name}.
  params: []
  # params:
  #   - {{name: gain, label: Gain, type: real, default: 1.0, write: {{GAIN: "gain * 16384"}}}}
  start: {{CONTROL: 1}}
tests:                        # python glidelink.py test {id}: block parameters per case
  - {{}}
"""

RTL_TEMPLATE = """\
// ***************************************************************************
// GlideLink user module: {name}. Description and registers: module.yaml;
// reference model: model.py (docs/module_guide.md).
//
// Template: one pipeline stage; with CONTROL.enable the samples pass through
// unchanged too. Replace the marked line by the processing. Samples only: the
// packets around them are the platform's (module.yaml rate:).
// ***************************************************************************

`timescale 1ns/100ps

module glidelink_{id} (
{ports});

  // one stage: the output register takes a sample when it is empty or being read
  reg         v = 1'b0;
  reg  [31:0] data = 32'd0;
  wire        ce = !v || m_axis_tready;

  assign s_axis_tready = ce;
  assign m_axis_tvalid = v;
  assign m_axis_tdata = data;

  always @(posedge clk) begin
    if (!rstn || flush || soft_reset)
      v <= 1'b0;
    else if (ce)
      v <= s_axis_tvalid;
    if (ce) begin
      data <= enable ? s_axis_tdata : s_axis_tdata;     // <- the processing
    end
  end

endmodule
"""

MODEL_TEMPLATE = '''\
"""{name}: reference model of glidelink_{id}.v at register level (docs/module_guide.md).

process(words) gets uint32 sc16 words {{Q[31:16], I[15:0]}} and returns the module's output for
them; registers are in self.regs by name (self.field(reg, field) for fields).
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from sc16 import pack, unpack, sat16  # noqa: E402,F401
import module_desc  # noqa: E402


class Model(module_desc.RegisterModel):
    def __init__(self, params=None):
        super().__init__(module_desc.load("{id}", os.path.dirname(HERE)), params)

    def process(self, words):
        words = np.asarray(words, np.uint32)
        if not self.field("CONTROL", "enable"):
            return words.copy()
        return words.copy()                                     # <- the processing
'''


def id_value(mid):
    """four ASCII characters: the id's first three letters / digits and a digit that no other
    module uses"""
    used = set()
    for y in glob.glob(os.path.join(HW, "modules", "*", "module.yaml")):
        with open(y, encoding="utf8") as f:
            v = (yaml.safe_load(f) or {}).get("id_value")
        if v is not None:
            used.add(int(v))
    base = (re.sub(r"[^A-Za-z0-9]", "", mid).upper() + "XXX")[:3]
    for d in "123456789":
        text = base + d
        v = int.from_bytes(text.encode(), "big")
        if v not in used:
            return v, text
    fail("no free ID value; set id_value in module.yaml by hand")


def cmd_new(a):
    mid = a.id
    if not re.fullmatch(r"[a-z][a-z0-9_]*", mid):
        fail("the id is lower case letters, digits and _ , starting with a letter")
    d = os.path.join(HW, "modules", mid)
    if os.path.exists(d):
        fail(f"{d} exists")
    os.makedirs(d)
    v, text = id_value(mid)
    name = a.name or mid.replace("_", " ")
    with open(os.path.join(d, "module.yaml"), "w", encoding="utf8", newline="\n") as f:
        f.write(YAML_TEMPLATE.format(id=mid, name=name, id_value=v, id_text=text))
    ports = gen_module.ports_text(module_desc.load(mid))
    with open(os.path.join(d, f"glidelink_{mid}.v"), "w", encoding="utf8", newline="\n") as f:
        f.write(RTL_TEMPLATE.format(id=mid, name=name, ports=ports))
    with open(os.path.join(d, "model.py"), "w", encoding="utf8", newline="\n") as f:
        f.write(MODEL_TEMPLATE.format(id=mid, name=name))
    print(f"hw/modules/{mid}/: module.yaml, glidelink_{mid}.v, model.py (ID 0x{v:08X} \"{text}\")")
    print(f"next: python glidelink.py test {mid}")


# ---------------------------------------------------------------------------
# test
# ---------------------------------------------------------------------------

def stimulus(rng, n=6000, scale=1.0):
    """sc16 words: full-scale noise, a tone, small values, the extremes (all times scale);
    packets of random length"""
    t = np.arange(n)
    x = np.zeros(n, np.complex128)
    k = n // 3
    x[:k] = rng.uniform(-32768, 32768, k) + 1j * rng.uniform(-32768, 32768, k)
    x[k:2 * k] = 20000 * np.exp(2j * np.pi * 0.0123 * t[k:2 * k]) + rng.normal(0, 800, k) + 1j * rng.normal(0, 800, k)
    x[2 * k:] = rng.normal(0, 300, n - 2 * k) + 1j * rng.normal(0, 300, n - 2 * k)
    x[::97] = -32768 - 32768j
    x[50::131] = 32767 - 32768j
    x[70::151] = 32767 + 32767j
    x = x * scale
    i = np.clip(np.round(x.real), -32768, 32767).astype(np.int64)
    q = np.clip(np.round(x.imag), -32768, 32767).astype(np.int64)
    last = np.zeros(n, int)
    pos = 0
    while pos < n:
        pos += int(rng.integers(1, 700))
        last[min(pos, n) - 1] = 1
    return pack(i, q), last


def run_sim(mod_dir, vec, capture=False, tuser=True, mid=None):
    """tuser: check the output packets' headers (the platform's packets; not for modules that
    make their own, framing: module or bus: module); mid: (beats, packets) before a flush in the
    middle of the stream (tb_module.v MID_FLUSH)"""
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", SIM, mod_dir, "-Vectors", vec]
    if mid:
        cmd += ["-MidFlush", str(mid[0]), "-MidFlushPkts", str(mid[1])]
    if capture:
        cmd += ["-Capture", "-InFlags", "0"] + ([] if tuser else ["-NoTuser"])
    r = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    return r.stdout + r.stderr


def cmd_test(a):
    if os.name != "nt":
        fail("the simulation script (run_module_sim.ps1, Vivado xsim) runs on Windows")
    desc = module_desc.load(a.id)
    has_model = os.path.isfile(os.path.join(desc["dir"], desc.get("model", "model.py")))
    m = module_desc.load_model(desc) if has_model else None
    if m is not None and not hasattr(m, "Model"):
        m = None
    cases = desc.get("tests") or [{}]
    if a.case is not None:
        cases = [cases[a.case]]
    exact = desc.get("exact", True)
    platform_packets = desc.get("bus", "generated") != "module" and desc.get("framing", "platform") != "module"
    tol = int(desc.get("tolerance", 0 if exact else 4))
    results = []
    # every case, then a flush in the middle of a stream (the module backed up, as on a board
    # when a stream starts while it is still busy): from there on the output must be the model's
    # from its state after the register writes, nothing stuck and nothing left from before
    entries = [(a.case if a.case is not None else i, c, False) for i, c in enumerate(cases)]
    if m is not None and a.case is None:
        entries.append((len(cases), cases[0], True))
    for k, case, mid in entries:
        vec = os.path.join(desc["dir"], "build", f"test{k}")
        os.makedirs(vec, exist_ok=True)
        for f in ("out.hex", "reads.hex", "captured.hex"):
            if os.path.exists(os.path.join(vec, f)):
                os.remove(os.path.join(vec, f))
        rng = np.random.default_rng(1000 + k)
        scale = float(desc.get("test_input_scale", 1.0))
        words, last = stimulus(rng, scale=scale)
        n_a = 0                             # mid-stream flush: beats (whole packets) before it
        if mid:
            n_a = next(i + 1 for i in range(1500, len(last)) if last[i])
            mid = (n_a, int(last[:n_a].sum()))
        writes = []
        model = m.Model() if m else None

        def write(name, value):
            writes.append((desc["offsets"][name], value))
            if model:
                model.write(name, value)

        def read(name):
            if model:
                return model.read(name)
            fail(f"read('{name}') in a parameter needs the reference model")

        params = {p["name"]: p.get("default", 0) for p in desc.get("block", {}).get("params", [])}
        raw = {n: v for n, v in case.items() if n in desc["offsets"]}
        params.update({n: v for n, v in case.items() if n not in raw})
        if "block" in desc:
            module_desc.Program(desc, write, read, m).start(params)
        for n, v in raw.items():
            write(n, int(v))
        with open(os.path.join(vec, "regs.hex"), "w", newline="\n") as f:
            f.write("".join(f"{o:03X} {v & 0xFFFFFFFF:08X}\n" for o, v in writes))
        with open(os.path.join(vec, "in.hex"), "w", newline="\n") as f:
            f.write("".join(f"{int(w):08X} {l}\n" for w, l in zip(words, last)))
        label = ", ".join(f"{n}={v}" for n, v in case.items()) or "defaults"
        if mid:
            label = f"flush mid-stream after {n_a} beats, then {label}"
        if model is None:
            out = run_sim(desc["dir"], vec, capture=True, tuser=platform_packets)
            n = sum(1 for _ in open(os.path.join(vec, "captured.hex"))) if os.path.exists(os.path.join(vec, "captured.hex")) else 0
            ok = "PASS" in out and n > 0
            results.append((label, ok, f"no reference model: {n} samples out, not checked"))
            continue
        before = copy.deepcopy(model)
        exp = model.process(words[n_a:])    # the flush leaves the model as after the writes
        if len(exp) == len(words) - n_a and exact and not mid:
            with open(os.path.join(vec, "out.hex"), "w", newline="\n") as f:
                f.write("".join(f"{int(w):08X} {l}\n" for w, l in zip(exp, last[n_a:])))
            reads = []
            for r in desc["regs"]:
                if r["access"] == "wo" or r.get("test_read") is False:
                    continue
                if desc["bus"] == "module" and not r.get("builtin"):
                    continue
                reads.append((r["offset"], model.read(r["name"])))
            with open(os.path.join(vec, "reads.hex"), "w", newline="\n") as f:
                f.write("".join(f"{o:03X} {v & 0xFFFFFFFF:08X}\n" for o, v in reads))
            out = run_sim(desc["dir"], vec, mid=mid)
            ok = "PASS" in out and "FAIL" not in out
            info = next((l.strip() for l in out.splitlines() if "compared" in l), "")
            rb = next((l.strip() for l in out.splitlines() if "read back" in l), "")
            errs = [l.strip() for l in out.splitlines() if "ERROR" in l][:5]
            results.append((label, ok, "; ".join([info, rb] + errs) if info else out.strip()[-800:]))
        else:
            # output not one to one with the input (e.g. FFT): a block-based module may hold a block
            # back while the next one is incomplete (the Xilinx FFT core stalls as a whole while its
            # input is starved mid-frame), so more input follows the stimulus; all the stimulus's
            # output must come, as the model says
            pad, padlast = stimulus(rng, 3000, scale)
            with open(os.path.join(vec, "in.hex"), "a", newline="\n") as f:
                f.write("".join(f"{int(w):08X} {l}\n" for w, l in zip(pad, padlast)))
            need = len(exp)
            out = run_sim(desc["dir"], vec, capture=True, tuser=platform_packets, mid=mid)
            cap = os.path.join(vec, "captured.hex")
            got = np.array([int(l.split()[0], 16) for l in open(cap)], np.uint32) if os.path.exists(cap) else np.zeros(0, np.uint32)

            def compare(skip_in, shift):
                """(largest difference after the start-up stretch, its length, outputs expected): the
                output against the model's for the input from beat n_a + skip_in on, shifted"""
                e = copy.deepcopy(before).process(np.concatenate([words[n_a + skip_in:], pad]))
                g = got[shift:] if shift >= 0 else np.concatenate([np.zeros(-shift, np.uint32), got])
                n = min(len(g), len(e))
                gi, gq = (g[:n] & 0xFFFF).astype(np.uint16).view(np.int16), (g[:n] >> 16).astype(np.uint16).view(np.int16)
                ei, eq = (e[:n] & 0xFFFF).astype(np.uint16).view(np.int16), (e[:n] >> 16).astype(np.uint16).view(np.int16)
                d = np.maximum(np.abs(gi.astype(int) - ei), np.abs(gq.astype(int) - eq))
                i0 = 0
                if mid:
                    bad = np.nonzero(d > tol)[0]
                    i0 = int(bad[-1]) + 1 if len(bad) else 0
                return int(d[i0:].max(initial=0)), i0, len(e)

            # after a mid-stream flush the module may go on from what it still held: a FIR's delay
            # line, a decimator's phase (an incomplete group of inputs finished by the first new
            # one). So the model may start a few inputs later and the output be a sample or two off;
            # past a start-up stretch it must then be the model's. Anything left over from before
            # the flush would shift all of it.
            tries = [(0, 0)] + ([(p, sh) for p in range(8) for sh in (0, 1, -1, 2, -2) if (p, sh) != (0, 0)] if mid else [])
            for skip_in, shift in tries:
                err, i0, n_exp = compare(skip_in, shift)
                if err <= tol and i0 <= need // 2:
                    break
            ok = ("PASS" in out and need - 2 <= len(got) <= n_exp + 2 and err <= tol and i0 <= need // 2
                  and (mid or need <= len(got) <= n_exp))
            note = ""
            if mid and (skip_in or shift):
                note += f", aligned {skip_in} input(s) later, output shifted by {shift}"
            if i0:
                note += f", the first {i0} differ (start-up after the flush)"
            results.append((label, ok, f"{len(got)} samples out ({need} needed), largest difference {err} LSB (allowed {tol}){note}"))
    print(f"{desc['id']}: {len(results)} case(s)")
    for label, ok, info in results:
        print(f"  {'PASS' if ok else 'FAIL'}  {label}: {info}")
    sys.exit(0 if all(r[1] for r in results) else 1)


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

def project_name(image):
    return "fmcomms2_pynqzu" if image == "demo" else f"fmcomms2_pynqzu_{image}"


def cmd_build(a):
    if len(a.what) == 1 and os.path.isfile(os.path.join(HW, "images", a.what[0] + ".yaml")) and not a.name:
        image = a.what[0]
    else:
        for mid in a.what:
            if not os.path.isfile(os.path.join(HW, "modules", mid, "module.yaml")):
                fail(f"no image hw/images/{mid}.yaml and no module hw/modules/{mid}")
        image = a.name or "user"
        slots = [{"module": "passthrough"}] + [{"module": mid} for mid in a.what]
        path = os.path.join(HW, "images", image + ".yaml")
        with open(path, "w", encoding="utf8", newline="\n") as f:
            f.write(f"# written by glidelink.py build {' '.join(a.what)}\nname: {image}\n"
                    + yaml.safe_dump({"slots": slots}, sort_keys=False, default_flow_style=None))
        print(f"hw/images/{image}.yaml: " + ", ".join(f"slot {k} {s['module']}" for k, s in enumerate(slots)))
    vivado = setting("VIVADO") or shutil.which("vivado") or shutil.which("vivado.bat")
    adi = setting("ADI_HDL_DIR")
    if not vivado or not adi:
        fail("set VIVADO (the vivado executable) and ADI_HDL_DIR (ADI HDL tree, libraries built: hw/README.md) "
             "as environment variables or in glidelink.local.yaml")
    env = dict(os.environ, GLIDELINK_IMAGE=image, ADI_HDL_DIR=adi, ADI_IGNORE_VERSION_CHECK="1")
    log = f"build_{image}.log"
    print(f"Vivado: image {image} (about an hour; log hw/projects/fmcomms2_pynqzu/{log})")
    t0 = time.time()
    steps = ("synth_design", "opt_design", "place_design", "phys_opt_design", "route_design", "write_bitstream")
    seen = set()
    p = subprocess.Popen([vivado, "-mode", "batch", "-source", "system_project.tcl", "-log", log, "-nojournal"],
                         cwd=PROJECT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                         errors="replace")
    with open(os.path.join(PROJECT, f"build_{image}.stdout"), "w", encoding="utf8") as out:
        for line in p.stdout:
            out.write(line)
            for s in steps:
                if f"Command: {s}" in line and s not in seen:
                    seen.add(s)
                    print(f"  {int(time.time() - t0) // 60:3d} min  {s}", flush=True)
            if line.startswith("ERROR"):
                print("  " + line.rstrip(), flush=True)
    p.wait()
    proj = os.path.join(PROJECT, project_name(image))
    bit = proj + ".runs/impl_1/system_top.bit"
    hwh = proj + ".gen/sources_1/bd/system/hw_handoff/system.hwh"
    if p.returncode != 0 or not os.path.isfile(bit) or os.path.getmtime(bit) < t0:
        fail(f"the build failed (hw/projects/fmcomms2_pynqzu/{log})")
    dst = os.path.join(HW, "build", image)
    os.makedirs(dst, exist_ok=True)
    shutil.copy2(bit, os.path.join(dst, f"glidelink_{image}.bit"))
    shutil.copy2(hwh, os.path.join(dst, f"glidelink_{image}.hwh"))
    shutil.copy2(os.path.join(PROJECT, f"gen_{image}", "image.json"), os.path.join(dst, "image.json"))
    timing = ""
    rpt = proj + ".runs/impl_1/system_top_timing_summary_routed.rpt"
    if os.path.isfile(rpt):
        txt = open(rpt, encoding="utf8", errors="replace").read()
        mm = re.search(r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+.*?\n\s*(-?[\d.]+)\s+(-?[\d.]+)\s+\d+\s+\d+\s+(-?[\d.]+)", txt, re.S)
        if mm:
            timing = f", worst setup slack {mm.group(1)} ns, hold {mm.group(3)} ns"
    print(f"done in {int(time.time() - t0) // 60} min{timing}: hw/build/{image}/glidelink_{image}.bit, .hwh")
    print(f"next: python glidelink.py deploy <board> {image}")


# ---------------------------------------------------------------------------
# deploy / status
# ---------------------------------------------------------------------------

def ssh_base(board):
    key = setting("GLIDELINK_SSH_KEY")
    opts = ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes"] + (["-i", os.path.expanduser(key)] if key else [])
    return opts, f"{setting('GLIDELINK_SSH_USER', 'root')}@{board}"


def ssh(board, command, check=True):
    opts, target = ssh_base(board)
    r = subprocess.run(["ssh"] + opts + [target, command], capture_output=True, text=True, errors="replace")
    if check and r.returncode != 0:
        fail(f"ssh {target}: {r.stderr.strip() or r.stdout.strip()}")
    return r


def scp(board, src, dst):
    opts, target = ssh_base(board)
    r = subprocess.run(["scp", "-q"] + opts + [src, f"{target}:{dst}"], capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"scp {src}: {r.stderr.strip()}")


SLOTS_PY = r"""
import SoapySDR
d = SoapySDR.Device("driver=glidelink")
n = (d.readRegister("FPGA", 0x008) >> 24) & 0xFF
print(" ".join("%08X" % d.readRegister("FPGA", 0x2000 + 0x1000 * k) for k in range(n)))
"""


def board_slots(board):
    r = ssh(board, f"{BOARD_PY} -c '{SLOTS_PY.strip()}'", check=False)
    if r.returncode != 0:
        return None
    return [int(v, 16) for v in r.stdout.split()]


def module_ids():
    ids = {}
    for y in glob.glob(os.path.join(HW, "modules", "*", "module.yaml")):
        with open(y, encoding="utf8") as f:
            v = (yaml.safe_load(f) or {}).get("id_value")
        if v is not None:
            ids[int(v)] = os.path.basename(os.path.dirname(y))
    return ids


def boot_image(board):
    r = ssh(board, "cat /etc/default/glidelink-bridge")
    mm = re.search(r"GLIDELINK_IMAGE=(\S+)", r.stdout)
    if not mm:
        fail(f"{board}: no GLIDELINK_IMAGE in /etc/default/glidelink-bridge (sw/bridge/install.sh)")
    return mm.group(1)


def show_slots(board, expect=None):
    ids = module_ids()
    found = board_slots(board)
    if found is None:
        print("  slots: not readable (is the bridge service running?)")
        return False
    ok = True
    for k, v in enumerate(found):
        name = ids.get(v, "passthrough" if k == 0 else f"unknown (ID 0x{v:08X})")
        line = f"  slot {k}: {name}"
        if expect is not None:
            want = expect[k]["module"] if k < len(expect) else None
            good = want == name
            ok &= good
            line += "" if good else f"  <- image says {want}"
        print(line)
    if expect is not None and len(found) != len(expect):
        print(f"  {len(found)} slots on the board, {len(expect)} in the image")
        ok = False
    return ok


def cmd_status(a):
    print(f"{a.board}: boot image {boot_image(a.board)}")
    show_slots(a.board)


def wait_board(board, timeout=180):
    """seconds until the board answers with the image loaded (the bridge service loads it after
    it starts, about 10 s), None after timeout"""
    t0 = time.time()
    time.sleep(15)
    while time.time() - t0 < timeout:
        if board_slots(board):
            return time.time() - t0
        time.sleep(5)
    return None


def cmd_deploy(a):
    image = a.image
    if not image:
        built = sorted(glob.glob(os.path.join(HW, "build", "*", "image.json")), key=os.path.getmtime)
        if not built:
            fail("no image built yet (python glidelink.py build ...)")
        image = os.path.basename(os.path.dirname(built[-1]))
    src = os.path.join(HW, "build", image)
    bit, hwh = (os.path.join(src, f"glidelink_{image}.{e}") for e in ("bit", "hwh"))
    if not os.path.isfile(bit):
        fail(f"hw/build/{image}/glidelink_{image}.bit missing (python glidelink.py build {image})")
    expect = json.load(open(os.path.join(src, "image.json")))["slots"]
    current = boot_image(a.board)
    rdir = os.path.dirname(current)
    rbit = f"{rdir}/glidelink_{image}.bit"
    print(f"{a.board}: boot image {current} -> {rbit}")
    scp(a.board, bit, rbit)
    scp(a.board, hwh, f"{rdir}/glidelink_{image}.hwh")
    dtbo = os.path.join(src, f"glidelink_{image}.dtbo")
    if os.path.isfile(dtbo):
        scp(a.board, dtbo, f"{rdir}/glidelink_{image}.dtbo")
    elif current != rbit:                   # the device tree overlay is the same for every image
        ssh(a.board, f"cp {current[:-4]}.dtbo {rdir}/glidelink_{image}.dtbo")
    ssh(a.board, f"sed -i 's#^GLIDELINK_IMAGE=.*#GLIDELINK_IMAGE={rbit}#' /etc/default/glidelink-bridge && sync")
    if a.no_reboot:
        print("boot image set; it is loaded at the next reboot")
        return
    print("rebooting (about 70 s) ...", flush=True)
    ssh(a.board, "(sleep 1; reboot) > /dev/null 2>&1 &", check=False)
    t = wait_board(a.board)
    if t is None:
        fail(f"{a.board} is not back after 3 minutes: check its power and USB cable, or its serial console")
    print(f"back after {int(t)} s")
    ok = show_slots(a.board, expect)
    print("PASS: every slot holds the module of the image" if ok else "FAIL: the slots differ from the image")
    sys.exit(0 if ok else 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("new", help="a new module from the template")
    p.add_argument("id")
    p.add_argument("--name")
    p.set_defaults(fn=cmd_new)
    p = sub.add_parser("test", help="simulate the module against its reference model")
    p.add_argument("id")
    p.add_argument("--case", type=int)
    p.set_defaults(fn=cmd_test)
    p = sub.add_parser("build", help="build a PL image")
    p.add_argument("what", nargs="+", help="an image (hw/images/<image>.yaml) or module ids")
    p.add_argument("--name", help="image name for a list of modules (default user)")
    p.set_defaults(fn=cmd_build)
    p = sub.add_parser("deploy", help="make an image a board's boot image and check its slots")
    p.add_argument("board")
    p.add_argument("image", nargs="?")
    p.add_argument("--no-reboot", action="store_true")
    p.set_defaults(fn=cmd_deploy)
    p = sub.add_parser("status", help="a board's boot image and slots")
    p.add_argument("board")
    p.set_defaults(fn=cmd_status)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
