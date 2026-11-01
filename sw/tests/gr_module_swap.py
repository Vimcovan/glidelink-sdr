"""Any GlideLink module on a board against its software block (docs/module_guide.md):

    A: vector source -> <id>_model (software) -> vector sink
    B: vector source -> GlideLink Host Sink -> [PL: <id>] -> GlideLink Host Source -> vector sink

with the block parameters of each entry of `tests` in the module's module.yaml (both blocks
generated from it; the PL block finds the module's slot by ID). N input samples, a whole number
of DMA buffers; raw host port 1. The host port 1 RX DMA hands over whole buffers only, so B
gets the whole buffers of the output (all of it for a module with one output per input), and
those must equal A's (within `tolerance` LSB where the model is not exact, exact: false). The
Host Source waits for data like a UHD source, so B is stopped once they are in.

    python gr_module_swap.py <id> [--args driver=glidelink,uri=ip:192.168.3.1] [--case K]
"""
import argparse
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
desc = glidelink.modules.description(a.id)
cases = desc.get("tests") or [{}]
if a.case is not None:
    cases = [cases[a.case]]
tol = int(desc.get("tolerance", 0 if desc.get("exact", True) else 4))
sw_cls, pl_cls = getattr(glidelink, a.id + "_model"), getattr(glidelink, a.id)
dev = glidelink.pl.device(a.args)

rng = np.random.default_rng(11)
t = np.arange(N)
scale = float(desc.get("test_input_scale", 1.0))
x = scale * (0.6 * np.exp(2j * np.pi * 0.07 * t) + 0.15 * (rng.normal(size=N) + 1j * rng.normal(size=N)))
x = np.round(np.clip(x.real, -1, 1) * 32767) / 32768 + 1j * np.round(np.clip(x.imag, -1, 1) * 32767) / 32768
x = list(x.astype(np.complex64))

failed = 0
for case in cases:
    params = {k: v for k, v in case.items() if k not in desc["offsets"]}
    label = ", ".join(f"{k}={v}" for k, v in params.items()) or "defaults"

    ta = gr.top_block()
    src_a, sink_a = blocks.vector_source_c(x), blocks.vector_sink_c()
    sw = sw_cls(**params)               # Python blocks must stay referenced while the flowgraph runs
    ta.connect(src_a, sw, sink_a)
    ta.run()
    out_a = np.array(sink_a.data(), np.complex64)
    need = len(out_a) // BUFFER * BUFFER

    tb = gr.top_block()
    pl = pl_cls(a.args, -1, **params)
    src_b, sink_b = blocks.vector_source_c(x), blocks.vector_sink_c()
    host_sink = glidelink.host_sink(a.args, "complex", False, BUFFER)
    host_source = glidelink.host_source(a.args, "complex", False, BUFFER)
    tb.connect(src_b, host_sink)
    tb.connect(host_source, sink_b)
    glidelink.pl_connect(host_sink, "0", pl, "0")
    glidelink.pl_connect(pl, "0", host_source, "0")
    tb.start()
    deadline = time.time() + 30
    while len(sink_b.data()) < need and time.time() < deadline:
        time.sleep(0.05)
    tb.stop()
    tb.wait()
    out_b = np.array(sink_b.data(), np.complex64)
    for sink in (pl.pl_inputs["0"], "host1_rx"):
        route(dev, sink, "none")

    n = min(need, len(out_b))
    d = out_a[:n] - out_b[:n]
    err = float(np.max(np.abs(np.concatenate([d.real, d.imag])), initial=0) * 32768)
    ok = n == need > 0 and len(out_b) == need and err <= tol
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'}  {a.id} in slot {pl.regs.slot}, {label}: {len(out_b)} of {need} samples "
          f"({len(out_a)} from the model), largest difference {err:.0f} LSB (allowed {tol})")
print("PASS" if not failed else "FAIL")
sys.exit(1 if failed else 0)
