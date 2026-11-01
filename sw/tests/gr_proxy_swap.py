"""Phase 3 acceptance in GNU Radio (docs/phase3_modules.md): replacing the software blocks by
their PL proxies leaves the flowgraph's output unchanged.

    A: vector source -> NCO (software) -> FIR (software) -> vector sink
    B: vector source -> GlideLink Host Sink ... [PL: NCO -> FIR] ... GlideLink Host Source
       -> head -> vector sink; the PL blocks (generated from module.yaml) find the modules'
       slots by ID and are connected as in GRC (pl_connect: host1_tx -> NCO -> FIR -> host1_rx)

Both get the same complex input; the first N outputs of A and B must be identical, sample for
sample. Raw host port (no headers), N a whole number of DMA buffers (the RX DMA hands over whole
buffers only), and PAD buffers more sent after them: the last buffers of a host port 1 transfer
stay in the path until more data follows.

    python3 gr_proxy_swap.py [--args driver=glidelink,uri=ip:192.168.3.1]
"""
import argparse

import numpy as np
from gnuradio import blocks, gr, glidelink
from gnuradio.glidelink.control import route

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink,uri=ip:192.168.3.1")
ap.add_argument("--buffers", type=int, default=8)
a = ap.parse_args()

BUFFER = 16384
N = a.buffers * BUFFER
PAD = 4 * BUFFER
SAMP_RATE = 2.5e6
FREQ = -137.5e3
TAPS = [int(c) for c in glidelink.modules.model("fir").lowpass(0.12)]
SHIFT = 15

rng = np.random.default_rng(11)
t = np.arange(N + PAD)
x = (0.6 * np.exp(2j * np.pi * 0.07 * t) + 0.15 * (rng.normal(size=N + PAD) + 1j * rng.normal(size=N + PAD)))
x = np.round(np.clip(x.real, -1, 1) * 32767) / 32768 + 1j * np.round(np.clip(x.imag, -1, 1) * 32767) / 32768
x = list(x.astype(np.complex64))

# A: software
ta = gr.top_block()
src_a = blocks.vector_source_c(x)
sink_a = blocks.vector_sink_c()
# Python blocks must stay referenced while the flowgraph runs (inline ones are collected: crash)
sw_nco = glidelink.nco_model(SAMP_RATE, FREQ, 0.0)
sw_fir = glidelink.fir_model(TAPS, SHIFT)
ta.connect(src_a, sw_nco, sw_fir, sink_a)
ta.run()
out_a = np.array(sink_a.data(), np.complex64)[:N]

# B: the same in the PL
tb = gr.top_block()
pl_nco = glidelink.nco(a.args, -1, SAMP_RATE, FREQ, 0.0)
pl_fir = glidelink.fir(a.args, -1, TAPS, SHIFT)
print(f"NCO in slot {pl_nco.regs.slot}, FIR in slot {pl_fir.regs.slot}")
src_b = blocks.vector_source_c(x)
sink_b = blocks.vector_sink_c()
host_sink = glidelink.host_sink(a.args, "complex", False, BUFFER)
host_source = glidelink.host_source(a.args, "complex", False, BUFFER)
head = blocks.head(gr.sizeof_gr_complex, N)
tb.connect(src_b, host_sink)
tb.connect(host_source, head, sink_b)
glidelink.pl_connect(host_sink, "0", pl_nco, "0")
glidelink.pl_connect(pl_nco, "0", pl_fir, "0")
glidelink.pl_connect(pl_fir, "0", host_source, "0")
tb.run()
out_b = np.array(sink_b.data(), np.complex64)
dev = glidelink.pl.device(a.args)
for sink in (pl_nco.pl_inputs["0"], pl_fir.pl_inputs["0"], "host1_rx"):
    route(dev, sink, "none")

same = len(out_a) == len(out_b) == N and np.array_equal(out_a, out_b)
diff = int(np.count_nonzero(out_a[:len(out_b)] != out_b[:len(out_a)]))
print(f"A (software): {len(out_a)} samples, B (PL proxies): {len(out_b)} samples, {diff} different")
print("PASS" if same else "FAIL")
