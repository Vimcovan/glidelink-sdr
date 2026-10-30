#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""GlideLink host port source / sink: module data to and from the PL shell.

They stream host port 1 (SoapySDR stream argument port=1): the words a module
in a slot produces or takes, routed by GlideLink Control. Item types: complex
(sc16 words scaled to +-1.0, full scale 32768) or int (the 32-bit words as
they are, {Q, I}).

With packet headers (the default) the source tags "rx_time" (UHD style: a
tuple of whole seconds and fractional seconds, from the shell's sample counter
at the RF sample rate) on its first sample and after a gap, and "rx_eob" on
the last sample of a packet that ends a burst; an overflow (packets dropped
because the reader fell behind) is logged and followed by a new "rx_time".
The sink sends a packet per work call, timed where a "tx_time" tag starts it
and ending the burst where a "tx_eob" tag is.

Over the network (uri=ip:...), a read that finds no data for the libiio timeout
(1 s) drops the connection to the board's iiod (libiio 0.23's network backend
cannot resume after a timeout): the source then logs it and ends (WORK_DONE),
as it also does on any other stream error, so the flowgraph can finish.
"""
import numpy as np
import pmt
import SoapySDR
from SoapySDR import (SOAPY_SDR_RX, SOAPY_SDR_TX, SOAPY_SDR_CF32, SOAPY_SDR_CS16, SOAPY_SDR_HAS_TIME,
                      SOAPY_SDR_END_BURST, SOAPY_SDR_TIMEOUT, SOAPY_SDR_OVERFLOW)
from gnuradio import gr

TIMEOUT_US = 100000


def _types(item_type):
    if item_type == "complex":
        return np.complex64, SOAPY_SDR_CF32
    if item_type == "int":
        return np.int32, SOAPY_SDR_CS16
    raise ValueError("item type must be complex or int")


def _stream_args(headers, buffer_length):
    return {"port": "1", "headers": "true" if headers else "false", "bufferLength": str(int(buffer_length))}


def _time_pmt(ns):
    return pmt.make_tuple(pmt.from_uint64(ns // 1000000000), pmt.from_double((ns % 1000000000) * 1e-9))


def _time_ns(tag_value):
    secs = pmt.to_uint64(pmt.tuple_ref(tag_value, 0))
    frac = pmt.to_double(pmt.tuple_ref(tag_value, 1))
    return secs * 1000000000 + int(round(frac * 1e9))


class host_source(gr.sync_block):
    def __init__(self, args="driver=glidelink", item_type="complex", headers=True, buffer_length=65536):
        self.dtype, self.fmt = _types(item_type)
        gr.sync_block.__init__(self, name="GlideLink Host Source", in_sig=None, out_sig=[self.dtype])
        self.dev = SoapySDR.Device(args)
        self.sargs = _stream_args(headers, buffer_length)
        self.stream = None
        self.timed = False             # the next sample needs an rx_time tag

    def start(self):
        self.stream = self.dev.setupStream(SOAPY_SDR_RX, self.fmt, [0], self.sargs)
        self.dev.activateStream(self.stream)
        self.timed = True
        return True

    def stop(self):
        if self.stream is not None:
            self.dev.deactivateStream(self.stream)
            self.dev.closeStream(self.stream)
            self.stream = None
        return True

    def work(self, input_items, output_items):
        out = output_items[0]
        view = out.view(np.int16) if self.dtype == np.int32 else out
        r = self.dev.readStream(self.stream, [view], len(out), timeoutUs=TIMEOUT_US)
        if r.ret == SOAPY_SDR_TIMEOUT:
            return 0
        if r.ret == SOAPY_SDR_OVERFLOW:
            gr.log.warn("GlideLink Host Source: overflow (packets dropped)")
            self.timed = True
            return 0
        if r.ret < 0:
            gr.log.error(f"GlideLink Host Source: readStream error {r.ret}, the stream ends")
            return -1                   # WORK_DONE
        start = self.nitems_written(0)
        if self.timed and r.flags & SOAPY_SDR_HAS_TIME:
            self.add_item_tag(0, start, pmt.intern("rx_time"), _time_pmt(r.timeNs))
            self.timed = False
        if r.flags & SOAPY_SDR_END_BURST:
            self.add_item_tag(0, start + r.ret - 1, pmt.intern("rx_eob"), pmt.PMT_T)
            self.timed = True          # the next burst starts at its own time
        return r.ret


class host_sink(gr.sync_block):
    def __init__(self, args="driver=glidelink", item_type="complex", headers=True, buffer_length=65536):
        self.dtype, self.fmt = _types(item_type)
        gr.sync_block.__init__(self, name="GlideLink Host Sink", in_sig=[self.dtype], out_sig=None)
        self.dev = SoapySDR.Device(args)
        self.sargs = _stream_args(headers, buffer_length)
        self.stream = None

    def start(self):
        self.stream = self.dev.setupStream(SOAPY_SDR_TX, self.fmt, [0], self.sargs)
        self.dev.activateStream(self.stream)
        return True

    def stop(self):
        if self.stream is not None:
            self.dev.deactivateStream(self.stream)
            self.dev.closeStream(self.stream)
            self.stream = None
        return True

    def work(self, input_items, output_items):
        inp = input_items[0]
        n = len(inp)
        start = self.nitems_read(0)
        flags, time_ns = 0, 0
        # a tx_time tag starts a timed packet: send up to it first
        for tag in self.get_tags_in_window(0, 0, n, pmt.intern("tx_time")):
            k = tag.offset - start
            if k > 0:
                n = k
                break
            flags |= SOAPY_SDR_HAS_TIME
            time_ns = _time_ns(tag.value)
        for tag in self.get_tags_in_window(0, 0, n, pmt.intern("tx_eob")):
            n = tag.offset - start + 1
            flags |= SOAPY_SDR_END_BURST
            break
        view = inp[:n].view(np.int16) if self.dtype == np.int32 else inp[:n]
        r = self.dev.writeStream(self.stream, [view], n, flags, time_ns, timeoutUs=TIMEOUT_US)
        if r.ret == SOAPY_SDR_TIMEOUT:
            return 0
        if r.ret < 0:
            gr.log.error(f"GlideLink Host Sink: writeStream error {r.ret}, the stream ends")
            return -1                   # WORK_DONE
        return r.ret
