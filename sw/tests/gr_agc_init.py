"""Phase 2 acceptance in GNU Radio (docs/phase2_soapy_gr.md): fast-AGC parameters changed and the
AD9361 re-initialised while a flowgraph receives, from a PC over the network.

Flowgraph: gr-soapy source (driver=glidelink) -> sample counter; GlideLink Control sets fast
attack AGC with lock level 10 and re-initialises at start. While running, the lock level is
changed to 14 through set_settings (what a GRC variable callback does) with 'initialize': True.
Checked: AD9361 register 0x101 follows the lock level, gain mode / sample rate / frequency are
kept, samples keep arriving after the re-initialisation, and an AD9361 register written through
the Soapy source block reads back.

    python3 gr_agc_init.py [--args driver=glidelink,uri=ip:192.168.4.1]
"""
import argparse
import time

import numpy as np
from gnuradio import gr, soapy, glidelink

ap = argparse.ArgumentParser()
ap.add_argument("--args", default="driver=glidelink,uri=ip:192.168.4.1")
ap.add_argument("--rate", type=float, default=2.5e6)
ap.add_argument("--freq", type=float, default=915e6)
a = ap.parse_args()

LOCK = "adi,agc-inner-thresh-high"


class counter(gr.sync_block):
    def __init__(self):
        gr.sync_block.__init__(self, name="counter", in_sig=[np.complex64], out_sig=None)
        self.n = 0

    def work(self, input_items, output_items):
        self.n += len(input_items[0])
        return len(input_items[0])


tb = gr.top_block()
dev, _, extra = a.args.partition(",")
src = soapy.source(dev, "fc32", 1, extra, "", [""], [""])
src.set_sample_rate(0, a.rate)
src.set_frequency(0, a.freq)
ctl = glidelink.control(a.args, {}, {"gain_control_mode": "fast_attack", LOCK: "10", "initialize": True},
                        {}, ["AD9361:0x101", "gain_control_mode", LOCK], 0.5)
cnt = counter()
tb.connect(src, cnt)

failures = []


def check(what, ok):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        failures.append(what)


def flowing(what):
    n0 = cnt.n
    time.sleep(1.0)
    rate = cnt.n - n0
    check(f"{what}: {rate / 1e6:.2f} MS/s arriving", rate > 0.8 * a.rate)


tb.start()
time.sleep(1.0)
print("start:", ctl.status())
check("lock level 10 in register 0x101", ctl.read("AD9361:0x101") & 0x7f == 10)
check("gain mode fast_attack", ctl.read("gain_control_mode") == "fast_attack")
flowing("before")

print("set_settings: lock level 14, initialize")
t = time.time()
ctl.set_settings({"gain_control_mode": "fast_attack", LOCK: "14", "initialize": True})
print(f"  took {time.time() - t:.2f} s; status {ctl.status()}")
check("lock level 14 in register 0x101", ctl.read("AD9361:0x101") & 0x7f == 14)
check("gain mode still fast_attack", ctl.read("gain_control_mode") == "fast_attack")
check(f"sample rate kept ({src.get_sample_rate(0)})", src.get_sample_rate(0) == a.rate)
check(f"frequency kept ({src.get_frequency(0)})", abs(src.get_frequency(0) - a.freq) < 1)
flowing("after re-initialisation")

print("AD9361 register through the Soapy source block")
reg = src.read_register("AD9361", 0x101)
src.write_register("AD9361", 0x101, (reg & 0x80) | 0x0C)
check(f"0x101 written 0x0C, control reads 0x{ctl.read('AD9361:0x101') & 0x7f:02X}",
      ctl.read("AD9361:0x101") & 0x7f == 0x0C)
src.write_register("AD9361", 0x101, reg)

tb.stop()
tb.wait()
ctl.set_settings({LOCK: "10", "gain_control_mode": "slow_attack", "initialize": True})
print("PASS" if not failures else f"FAIL ({len(failures)})")
