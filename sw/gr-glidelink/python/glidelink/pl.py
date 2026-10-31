#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Connections inside the PL drawn in GRC, as RFNoC blocks are connected.

The PL ends of the GlideLink blocks are ports of the GRC domain "glidelink_pl"
(grc/glidelink_pl.domain.yml). GRC turns each connection between two such ports
into a call of connect(), which sets the stream switch route sink <- source on
the board; no data goes through GNU Radio. A block with PL ports names them in

    pl_args      the SoapySDR device string of its board
    pl_inputs    {port key: switch sink}    e.g. {"0": "slot1_in"}
    pl_outputs   {port key: switch source}  e.g. {"0": "slot1_out"}

The switch connects a source to one sink at a time (the domain allows one
connection per port). Routes of PL inputs left unconnected are not changed.

radio: the AD9361 as PL blocks see it, the RF RX samples (rf_rx) and the RF TX
input (rf_tx), with the RF settings, as RFNoC's radio block.
"""
import threading

import SoapySDR
from gnuradio import gr

from .control import route
from .rf import GAIN_MODES, TX_GAIN_MAX, device_args

_devices = {}
_lock = threading.Lock()


def device(args):
    """one SoapySDR device per board for the connections"""
    with _lock:
        if args not in _devices:
            _devices[args] = SoapySDR.Device(args)
        return _devices[args]


def _board(args):
    """the board a device string names: its uri ('' = the board this runs on)"""
    kv = dict(p.split("=", 1) for p in device_args(args).split(",") if "=" in p)
    return kv.get("uri", "")


def connect(src, src_key, dst, dst_key):
    """the GRC connection src:src_key -> dst:dst_key between PL ports"""
    source = src.pl_outputs[str(src_key)]
    sink = dst.pl_inputs[str(dst_key)]
    if _board(src.pl_args) != _board(dst.pl_args):
        raise ValueError(f"GlideLink PL connection {source} -> {sink}: the blocks are on different "
                         f"boards ({src.pl_args!r}, {dst.pl_args!r})")
    route(device(dst.pl_args), sink, source)


def slot_ports(args, slot):
    """pl_args / pl_inputs / pl_outputs of a module block in slot `slot`"""
    return args, {"0": f"slot{slot}_in"}, {"0": f"slot{slot}_out"}


class radio(gr.basic_block):
    """GlideLink Radio (PL): the RF of a board for PL chains. Output rf_rx (the AD9361 RX
    samples), input rf_tx (to the AD9361 TX); sample rate, LOs, bandwidth, RX gain mode and
    gain, TX attenuation. No data passes through GNU Radio.

    address    board, as for GlideLink Source
    samp_rate  0.52 .. 50 MSPS
    rx_freq / tx_freq   LOs; tx_freq 0: rx_freq + 10 MHz (keeps the board's own TX LO out of
               the RX band, docs/known_issues.md 2.1)
    """

    def __init__(self, address="192.168.3.1", samp_rate=10e6, rx_freq=915e6, tx_freq=0.0,
                 bandwidth=0.0, gain_mode="manual", gain=40.0, atten=30.0):
        gr.basic_block.__init__(self, name="GlideLink Radio (PL)", in_sig=None, out_sig=None)
        self.pl_args = device_args(address)
        self.pl_inputs, self.pl_outputs = {"0": "rf_tx"}, {"0": "rf_rx"}
        self.dev = device(self.pl_args)
        self._bandwidth, self._gain, self._gain_mode, self._rx_freq = bandwidth, gain, "manual", rx_freq
        self._tx_freq = tx_freq
        self.set_samp_rate(samp_rate)
        self.set_rx_freq(rx_freq)
        self.set_gain_mode(gain_mode)
        self.set_atten(atten)

    def set_samp_rate(self, samp_rate):
        self._samp_rate = samp_rate
        for d in (SoapySDR.SOAPY_SDR_RX, SoapySDR.SOAPY_SDR_TX):
            self.dev.setSampleRate(d, 0, samp_rate)
        self.set_bandwidth(self._bandwidth)

    def set_bandwidth(self, bandwidth):
        self._bandwidth = bandwidth
        bw = bandwidth if bandwidth > 0 else min(self._samp_rate, 56e6)
        for d in (SoapySDR.SOAPY_SDR_RX, SoapySDR.SOAPY_SDR_TX):
            self.dev.setBandwidth(d, 0, bw)

    def set_rx_freq(self, freq):
        self._rx_freq = freq
        self.dev.setFrequency(SoapySDR.SOAPY_SDR_RX, 0, freq)
        self.set_tx_freq(self._tx_freq)

    def set_tx_freq(self, freq):
        self._tx_freq = freq
        self.dev.setFrequency(SoapySDR.SOAPY_SDR_TX, 0, freq if freq > 0 else self._rx_freq + 10e6)

    def set_gain_mode(self, gain_mode):
        if gain_mode not in GAIN_MODES:
            raise ValueError(f"gain mode {gain_mode!r}: one of {', '.join(GAIN_MODES)}")
        self._gain_mode = gain_mode
        self.dev.writeSetting("gain_control_mode", gain_mode)
        if gain_mode == "manual":
            self.dev.setGain(SoapySDR.SOAPY_SDR_RX, 0, self._gain)

    def set_gain(self, gain):
        self._gain = gain
        if self._gain_mode == "manual":                 # the AGC owns the gain otherwise
            self.dev.setGain(SoapySDR.SOAPY_SDR_RX, 0, gain)

    def set_atten(self, atten):
        self.dev.setGain(SoapySDR.SOAPY_SDR_TX, 0, TX_GAIN_MAX - min(max(atten, 0.0), TX_GAIN_MAX))
