"""Phase 3 acceptance in GNU Radio (docs/phase3_modules.md): replacing the software blocks by
their PL proxies leaves the flowgraph's output unchanged.

    A: vector source -> NCO (software) -> FIR (software) -> vector sink
    B: vector source -> GlideLink Host Sink ... [PL: slot 1 NCO -> slot 2 FIR] ...
       GlideLink Host Source -> head -> vector sink, with GlideLink Control routing
       host1_tx -> slot1 -> slot2 -> host1_rx and the NCO / FIR proxies setting the modules

Both get the same complex input; A's and B's outputs must be identical, sample for sample.
Raw host port (no headers), and a whole number of DMA buffers (the RX DMA hands over whole
buffers only).

    python3 gr_proxy_swap.py [--args driver=glidelink,uri=ip:192.168.3.1]
"""
import argparse

import numpy as np
from gnuradio import blocks, gr, glidelink

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink,uri=ip:192.168.3.1")
ap.add_argument("--buffers", type=int, default=8)
a = ap.parse_args()

BUFFER = 16384
N = a.buffers * BUFFER
SAMP_RATE = 2.5e6
FREQ = -137.5e3
TAPS = [int(c) for c in glidelink.modules.model("fir").lowpass(0.12)]
SHIFT = 15

rng = np.random.default_rng(11)
t = np.arange(N)
x = (0.6 * np.exp(2j * np.pi * 0.07 * t) + 0.15 * (rng.normal(size=N) + 1j * rng.normal(size=N)))
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
out_a = np.array(sink_a.data(), np.complex64)

# B: the same in the PL
tb = gr.top_block()
ctl = glidelink.control(a.args, {"slot1_in": "host1_tx", "slot2_in": "slot1_out", "host1_rx": "slot2_out"},
                        {}, {}, [], 0)
pl_nco = glidelink.nco(a.args, 1, SAMP_RATE, FREQ, 0.0)
pl_fir = glidelink.fir(a.args, 2, TAPS, SHIFT)
src_b = blocks.vector_source_c(x)
sink_b = blocks.vector_sink_c()
host_sink = glidelink.host_sink(a.args, "complex", False, BUFFER)
host_source = glidelink.host_source(a.args, "complex", False, BUFFER)
head = blocks.head(gr.sizeof_gr_complex, N)
tb.connect(src_b, host_sink)
tb.connect(host_source, head, sink_b)
tb.run()
out_b = np.array(sink_b.data(), np.complex64)
for sink in ("slot1_in", "slot2_in", "host1_rx"):
    ctl.set_route(sink, "none")

same = len(out_a) == len(out_b) == N and np.array_equal(out_a, out_b)
diff = int(np.count_nonzero(out_a[:len(out_b)] != out_b[:len(out_a)]))
print(f"A (software): {len(out_a)} samples, B (PL proxies): {len(out_b)} samples, {diff} different")
print("PASS" if same else "FAIL")
