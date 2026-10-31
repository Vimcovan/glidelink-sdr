#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""GlideLink user modules in GNU Radio (docs/design.md 5.3, docs/phase3_modules.md).

For each module two blocks:
- a software block that runs the module's bit-exact reference model
  (hw/modules/<id>/model.py) on the stream: the prototype, and the reference the
  PL module is checked against;
- a proxy block that stands for the module in its PL slot: it writes the module's
  registers (by the names in hw/modules/<id>/module.yaml) and passes no data.
  The data reaches the slot through the routes set with GlideLink Control.

Replacing the software blocks by the proxies (and the host port source / sink,
or the RF source, around them) must leave the output unchanged.
"""
import importlib.util
import os

import numpy as np
import SoapySDR
import yaml
from gnuradio import gr

from .pl import slot_ports

_HERE = os.path.dirname(os.path.abspath(__file__))
# installed next to this file; in the source tree, hw/modules
_DIRS = [os.path.join(_HERE, "modules"), os.path.join(_HERE, "..", "..", "..", "..", "hw", "modules")]
_DIR = next((d for d in _DIRS if os.path.isfile(os.path.join(d, "sc16.py"))), _DIRS[0])


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


sc16 = _load(os.path.join(_DIR, "sc16.py"), "glidelink_sc16")


def model(module_id):
    """the reference model of hw/modules/<module_id>"""
    return _load(os.path.join(_DIR, module_id, "model.py"), f"glidelink_model_{module_id}")


def description(module_id):
    with open(os.path.join(_DIR, module_id, "module.yaml")) as f:
        return yaml.safe_load(f)


SLOT_BASE, SLOT_SIZE = 0x2000, 0x1000


class slot_registers:
    """A module's registers in PL slot `slot`, by name, through the Soapy "FPGA"
    register interface (the shell's window)."""

    def __init__(self, args, slot, module_id):
        self.dev = SoapySDR.Device(args)
        self.base = SLOT_BASE + SLOT_SIZE * slot
        d = description(module_id)
        self.offsets = {r["name"]: r["offset"] for r in d["registers"]}
        found = self.read("ID")
        if found != d["id_value"]:
            raise RuntimeError(f"GlideLink: slot {slot} holds ID 0x{found:08X}, not {module_id} "
                               f"(0x{d['id_value']:08X})")

    def write(self, name, value):
        self.dev.writeRegister("FPGA", self.base + self.offsets[name], int(value) & 0xFFFFFFFF)

    def read(self, name):
        return self.dev.readRegister("FPGA", self.base + self.offsets[name])


def freq_word(freq, samp_rate):
    """NCO phase increment for a shift of freq at samp_rate"""
    return int(round(freq / samp_rate * 2**32)) & 0xFFFFFFFF


def phase_word(phase):
    """NCO phase register for a phase in turns (1.0 = 2 pi)"""
    return int(round(phase * 2**32)) & 0xFFFFFFFF


# ---------------------------------------------------------------------------
# NCO mixer

class nco_model(gr.sync_block):
    """Frequency shift by freq, bit-exact with the PL module (complex in / out,
    sc16 full scale 1.0)."""

    def __init__(self, samp_rate=1e6, freq=0.0, phase=0.0):
        gr.sync_block.__init__(self, name="GlideLink NCO (software)", in_sig=[np.complex64],
                               out_sig=[np.complex64])
        self.m = model("nco")
        self.samp_rate = samp_rate
        self.word = freq_word(freq, samp_rate)
        self.phase = phase_word(phase)

    def set_freq(self, freq):
        self.word = freq_word(freq, self.samp_rate)

    def work(self, input_items, output_items):
        words = sc16.from_complex(input_items[0])
        out, self.phase = self.m.process(words, self.word, self.phase)
        output_items[0][:] = sc16.to_complex(out)
        return len(out)


class nco(gr.basic_block):
    """The NCO mixer in its PL slot: writes FREQ, PHASE and enables it. A stream
    start flushes the slot, which brings the phase back to PHASE."""

    def __init__(self, args="driver=glidelink", slot=1, samp_rate=1e6, freq=0.0, phase=0.0):
        gr.basic_block.__init__(self, name="GlideLink NCO (PL)", in_sig=None, out_sig=None)
        self.pl_args, self.pl_inputs, self.pl_outputs = slot_ports(args, slot)
        self.regs = slot_registers(args, slot, "nco")
        self.samp_rate = samp_rate
        self.regs.write("FREQ", freq_word(freq, samp_rate))
        self.regs.write("PHASE", phase_word(phase))
        self.regs.write("CONTROL", 1)

    def set_freq(self, freq):
        self.regs.write("FREQ", freq_word(freq, self.samp_rate))


# ---------------------------------------------------------------------------
# FIR filter

def _taps(taps, n):
    t = [int(c) for c in taps]
    if len(t) > n:
        raise ValueError(f"at most {n} coefficients")
    return t + [0] * (n - len(t))


class fir_model(gr.sync_block):
    """FIR with integer coefficients (signed 16 bit, up to 32) and output shift,
    bit-exact with the PL module."""

    def __init__(self, taps=(32767,), shift=15):
        gr.sync_block.__init__(self, name="GlideLink FIR (software)", in_sig=[np.complex64],
                               out_sig=[np.complex64])
        self.m = model("fir")
        self.h = _taps(taps, self.m.TAPS)
        self.shift = int(shift)
        self.hist = np.zeros(self.m.TAPS - 1, np.uint32)    # the delay line

    def set_taps(self, taps):
        self.h = _taps(taps, self.m.TAPS)

    def set_shift(self, shift):
        self.shift = int(shift)

    def work(self, input_items, output_items):
        words = sc16.from_complex(input_items[0])
        x = np.concatenate([self.hist, words])
        out = self.m.process(x, self.h, self.shift)[len(self.hist):]
        self.hist = x[-len(self.hist):]
        output_items[0][:] = sc16.to_complex(out)
        return len(out)


class fir(gr.basic_block):
    """The FIR filter in its PL slot: loads the coefficients and shift, enables it.
    A stream start flushes the slot, which clears the delay line."""

    def __init__(self, args="driver=glidelink", slot=2, taps=(32767,), shift=15):
        gr.basic_block.__init__(self, name="GlideLink FIR (PL)", in_sig=None, out_sig=None)
        self.pl_args, self.pl_inputs, self.pl_outputs = slot_ports(args, slot)
        self.regs = slot_registers(args, slot, "fir")
        self.n = self.regs.read("TAPS")
        self.set_shift(shift)
        self.set_taps(taps)

    def set_taps(self, taps):
        self.regs.write("COEF_ADDR", 0)
        for c in _taps(taps, self.n):
            self.regs.write("COEF_DATA", c & 0xFFFF)
        self.regs.write("CONTROL", 0x5)                       # load + enable

    def set_shift(self, shift):
        self.regs.write("SHIFT", int(shift))


# ---------------------------------------------------------------------------
# FFT (the RFNoC FFT block core)

FFT_ORDERS = {"normal": 0, "reverse": 1, "natural": 2, "bit_reverse": 3}
FFT_OUTPUTS = {"complex": 0, "magnitude": 1, "magnitude_squared": 2}


def _log2(size):
    n = int(size).bit_length() - 1
    if size != 1 << n or not 3 <= n <= 12:
        raise ValueError(f"FFT size {size}: a power of two, 8 .. 4096")
    return n


class fft_model(gr.basic_block):
    """FFT / IFFT as the PL module computes it, in floating point (the Xilinx FFT core is not
    modelled bit for bit; the PL output agrees to about 1 LSB). Complex in / out, sc16 full
    scale 1.0; one cyclic prefix length each way (the PL module takes lists)."""

    def __init__(self, size=1024, direction="forward", order="normal", output="complex",
                 scaling=-1, keep=1, cp_rem=0, cp_ins=0):
        gr.basic_block.__init__(self, name="GlideLink FFT (software)", in_sig=[np.complex64],
                                out_sig=[np.complex64])
        self.m = model("fft")
        self.kcnt = 0
        self.configure(size, direction, order, output, scaling, keep, cp_rem, cp_ins)

    def configure(self, size, direction, order, output, scaling, keep, cp_rem, cp_ins):
        n = _log2(size)
        self.kw = {"n_log2": n, "scaling": None if scaling < 0 else int(scaling),
                   "direction": 1 if direction == "forward" else 0, "order": FFT_ORDERS[order],
                   "magnitude": FFT_OUTPUTS[output], "cp_rem": int(cp_rem), "cp_ins": int(cp_ins)}
        self.keep = max(int(keep), 1)
        self.blk, self.plen = (1 << n) + int(cp_rem), (1 << n) + int(cp_ins)
        self.params = (size, direction, order, output, scaling, keep, cp_rem, cp_ins)

    def _set(self, k, v):
        p = list(self.params)
        p[k] = v
        self.configure(*p)

    def set_size(self, size): self._set(0, size)
    def set_direction(self, direction): self._set(1, direction)
    def set_order(self, order): self._set(2, order)
    def set_output(self, output): self._set(3, output)
    def set_scaling(self, scaling): self._set(4, scaling)
    def set_keep(self, keep): self._set(5, keep)

    def forecast(self, noutput_items, ninputs):
        return [self.blk] * ninputs

    def general_work(self, input_items, output_items):
        x, out = input_items[0], output_items[0]
        produced = consumed = 0
        while consumed + self.blk <= len(x):
            if self.kcnt == 0:
                if produced + self.plen > len(out):
                    break
                words = sc16.from_complex(x[consumed:consumed + self.blk])
                out[produced:produced + self.plen] = sc16.to_complex(self.m.process(words, **self.kw))
                produced += self.plen
            self.kcnt = (self.kcnt + 1) % self.keep
            consumed += self.blk
        self.consume(0, consumed)
        return produced


class fft(gr.basic_block):
    """The FFT in its PL slot: writes its registers (the RFNoC FFT block's, and KEEP) and
    enables it. size 8 .. 4096; scaling -1: 1/N; cp_rem / cp_ins: the cyclic prefix lists
    (lengths, repeated). A change of size or of cp_ins resets the module between packets."""

    def __init__(self, args="driver=glidelink", slot=1, size=1024, direction="forward", order="normal",
                 output="complex", scaling=-1, keep=1, cp_rem=(), cp_ins=(), bypass=False):
        gr.basic_block.__init__(self, name="GlideLink FFT (PL)", in_sig=None, out_sig=None)
        self.pl_args, self.pl_inputs, self.pl_outputs = slot_ports(args, slot)
        self.regs = slot_registers(args, slot, "fft")
        self.m = model("fft")
        self._scaling = scaling
        self.set_direction(direction)
        self.set_order(order)
        self.set_output(output)
        self.set_keep(keep)
        self.set_bypass(bypass)
        self.set_cp_rem(cp_rem)
        self.set_cp_ins(cp_ins)
        self.set_size(size)
        self.regs.write("CONTROL", 1)

    def set_size(self, size):
        self._n = _log2(size)
        self.regs.write("LENGTH_LOG2", self._n)
        self.set_scaling(self._scaling)

    def set_scaling(self, scaling):
        self._scaling = scaling
        n = getattr(self, "_n", 12)
        self.regs.write("SCALING", self.m.default_scaling(n) if scaling < 0 else int(scaling))

    def set_direction(self, direction):
        self.regs.write("DIRECTION", 1 if direction == "forward" else 0)

    def set_order(self, order):
        self.regs.write("ORDER", FFT_ORDERS[order])

    def set_output(self, output):
        self.regs.write("MAGNITUDE", FFT_OUTPUTS[output])

    def set_keep(self, keep):
        self.regs.write("KEEP", max(int(keep), 1))

    def set_bypass(self, bypass):
        self.regs.write("BYPASS", int(bool(bypass)))

    def _list(self, prefix, lengths):
        self.regs.write(f"{prefix}_LIST_CLR", 1)
        for c in lengths:
            self.regs.write(f"{prefix}_LEN", int(c))
            self.regs.write(f"{prefix}_LIST_LOAD", 1)

    def set_cp_rem(self, lengths):
        self._list("CP_REM", lengths)

    def set_cp_ins(self, lengths):
        self._list("CP_INS", lengths)

    def overflow(self):
        """FFT overflow since the last call (the core's sticky bit, cleared on read)"""
        return bool(self.regs.read("OVERFLOW") & 1)
