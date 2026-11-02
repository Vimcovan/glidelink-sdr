"""Run a GRC flowgraph with its windows and print, every 10 s, the sample rates the PC actually
receives and sends and the EVM of the received symbols (docs/qpsk_tutorial.md):

    python flowgraph_probe.py <flowgraph.grc> [--secs 60] [--rx rx] [--tx tx] [--symbols costas] [--shot out.png]

--rx / --tx: the flowgraph's GlideLink Source / Sink block ids; --symbols: the block whose output
are the symbols (one per symbol, QPSK); by default the software Costas loop "costas", or the
GlideLink Source when "costas" is a PL block (the PL sends the symbols). A rate below the one the
flowgraph asks for means samples were lost (GNU Radio prints O for a receive overflow, U for a
transmit underflow). --shot saves the flowgraph's window at the end. Run it in the "radioconda
Prompt" (the SoapySDR modules need the environment).
"""
import argparse
import importlib
import os
import subprocess
import sys
import tempfile
import threading
import time

import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("grc")
ap.add_argument("--secs", type=int, default=60)
ap.add_argument("--rx", default="rx")
ap.add_argument("--tx", default="tx")
ap.add_argument("--symbols", default=None)
ap.add_argument("--shot", default=None)
a = ap.parse_args()

out = tempfile.mkdtemp(prefix="glidelink_probe_")
subprocess.run(["grcc", "-o", out, a.grc], check=True, capture_output=True)
py = [f for f in os.listdir(out) if f.endswith(".py")][0]
sys.path.insert(0, out)
mod = importlib.import_module(py[:-3])

from PyQt5 import Qt  # noqa: E402
from gnuradio import blocks, gr  # noqa: E402

app = Qt.QApplication(sys.argv)
tb = getattr(mod, py[:-3])()
rx, tx = getattr(tb, a.rx), getattr(tb, a.tx)
name = a.symbols or ("costas" if hasattr(tb, "costas") and not hasattr(tb.costas, "pl_args") else a.rx)
keep = blocks.keep_one_in_n(gr.sizeof_gr_complex, 50)
syms = blocks.vector_sink_c()
tb.connect(getattr(tb, name), keep, syms)
if hasattr(tb, "flowgraph_started"):
    tb.flowgraph_started.set()
tb.start()
tb.show()
done = threading.Event()


def finish():                               # in the GUI thread: the window shot, then stop
    if not done.is_set():
        return
    if a.shot:
        tb.grab().save(a.shot)
    tb.stop()
    tb.wait()
    app.quit()


timer = Qt.QTimer()
timer.timeout.connect(finish)
timer.start(200)


def evm():
    y = np.array(syms.data()[-20000:])
    syms.reset()
    if len(y) < 100:
        return float("nan")
    y = y / np.sqrt(np.mean(np.abs(y) ** 2))
    ref = (np.sign(y.real) + 1j * np.sign(y.imag)) / np.sqrt(2)
    return 20 * np.log10(np.sqrt(np.mean(np.abs(y - ref) ** 2)))


def report():
    lr = lt = 0
    for k in range(a.secs // 10):
        time.sleep(10)
        r, t = rx.src.nitems_written(0), tx.snk.nitems_read(0)
        print(f"t={10 * (k + 1):3d} s  PC receives {(r - lr) / 1e7:5.2f} MSPS, sends {(t - lt) / 1e7:5.2f} MSPS, "
              f"symbol EVM {evm():6.1f} dB", flush=True)
        lr, lt = r, t
    done.set()


threading.Thread(target=report, daemon=True).start()
app.exec_()
