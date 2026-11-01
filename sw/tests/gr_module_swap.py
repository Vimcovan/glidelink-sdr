"""Any GlideLink module on a board against its software block (docs/module_guide.md):

    A: vector source -> <id>_model (software) -> vector sink
    B: vector source -> GlideLink Host Sink -> [PL: <id>] -> GlideLink Host Source -> head -> vector sink

with the block parameters of each entry of `tests` in the module's module.yaml (both blocks
generated from it; the PL block finds the module's slot by ID). The first N outputs must be
identical (within `tolerance` LSB where the model is not exact, exact: false). Raw host port 1,
N a whole number of DMA buffers, and after them input for 4 more output buffers (the last
buffers of a host port 1 transfer stay in the path until more data follows).

    python gr_module_swap.py <id> [--args driver=glidelink,uri=ip:192.168.3.1] [--case K]
"""
import argparse
import subprocess
import sys
import time

import numpy as np
from gnuradio import blocks, gr, glidelink
from gnuradio.glidelink.control import route

ap = argparse.ArgumentParser()
ap.add_argument("id")
ap.add_argument("--args", default="driver=glidelink,uri=ip:192.168.3.1")
ap.add_argument("--case", type=int)
ap.add_argument("--buffers", type=int, default=8)
a = ap.parse_args()

BUFFER = 16384
N = a.buffers * BUFFER
PAD_MAX = 64 * BUFFER                       # output rates down to 1/16 of the input
desc = glidelink.modules.description(a.id)
cases = desc.get("tests") or [{}]
if a.case is None and len(cases) > 1:      # one process per case: a fresh device and host port streams
    rc = []
    for k in range(len(cases)):
        if k:
            time.sleep(3)                   # the board's iiod releases the last case's buffers
        rc.append(subprocess.call([sys.executable] + sys.argv + ["--case", str(k)]))
    print("ALL PASS" if not any(rc) else "FAIL")
    sys.exit(1 if any(rc) else 0)
if a.case is not None:
    cases = [cases[a.case]]
tol = int(desc.get("tolerance", 0 if desc.get("exact", True) else 4))
sw_cls, pl_cls = getattr(glidelink, a.id + "_model"), getattr(glidelink, a.id)
dev = glidelink.pl.device(a.args)

rng = np.random.default_rng(11)
t = np.arange(N + PAD_MAX)
scale = float(desc.get("test_input_scale", 1.0))
x = scale * (0.6 * np.exp(2j * np.pi * 0.07 * t) + 0.15 * (rng.normal(size=len(t)) + 1j * rng.normal(size=len(t))))
x = np.round(np.clip(x.real, -1, 1) * 32767) / 32768 + 1j * np.round(np.clip(x.imag, -1, 1) * 32767) / 32768
x_all = x.astype(np.complex64)

failed = 0
for case in cases:
    params = {k: v for k, v in case.items() if k not in desc["offsets"]}
    label = ", ".join(f"{k}={v}" for k, v in params.items()) or "defaults"

    # the outputs of the first N inputs: the model on its own; then enough input after them
    m = glidelink.modules.model(a.id)
    model = m.Model()
    glidelink.modules.module_desc.Program(desc, model.write, model.read, m).start(
        {**{p["name"]: p.get("default", 0) for p in desc["block"]["params"]}, **params})
    need = len(model.process(glidelink.modules.sc16.from_complex(x_all[:N])))
    x = list(x_all[:N + min(PAD_MAX, int(4 * BUFFER * N / max(need, 1)))])

    ta = gr.top_block()
    src_a, sink_a = blocks.vector_source_c(x), blocks.vector_sink_c()
    sw = sw_cls(**params)               # Python blocks must stay referenced while the flowgraph runs
    ta.connect(src_a, sw, sink_a)
    ta.run()
    out_a = np.array(sink_a.data(), np.complex64)[:need]

    tb = gr.top_block()
    pl = pl_cls(a.args, -1, **params)
    src_b, sink_b = blocks.vector_source_c(x), blocks.vector_sink_c()
    host_sink = glidelink.host_sink(a.args, "complex", False, BUFFER)
    host_source = glidelink.host_source(a.args, "complex", False, BUFFER)
    head = blocks.head(gr.sizeof_gr_complex, need)
    tb.connect(src_b, host_sink)
    tb.connect(host_source, head, sink_b)
    glidelink.pl_connect(host_sink, "0", pl, "0")
    glidelink.pl_connect(pl, "0", host_source, "0")
    tb.run()
    out_b = np.array(sink_b.data(), np.complex64)
    for sink in (pl.pl_inputs["0"], "host1_rx"):
        route(dev, sink, "none")

    n = min(len(out_a), len(out_b))
    err = float(np.max(np.abs(np.concatenate([(out_a[:n] - out_b[:n]).real, (out_a[:n] - out_b[:n]).imag])),
                       initial=0) * 32768)
    ok = n == len(out_a) and n > 0 and err <= tol
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {a.id} in slot {pl.regs.slot}, {label}: {n} samples, "
          f"largest difference {err:.0f} LSB (allowed {tol})")
print("PASS" if not failed else "FAIL")
sys.exit(1 if failed else 0)
