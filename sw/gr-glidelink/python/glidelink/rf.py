"""GlideLink Source / Sink: the RF receive and transmit paths of a board (AD9361 through host port 0)
as complex samples, full scale 1. Hierarchical blocks around gr-soapy with the glidelink Soapy driver,
so that a flowgraph names a board and RF settings instead of a Soapy device string."""
from gnuradio import gr, soapy

TX_GAIN_MAX = 89.75                                     # AD9361 TX attenuation 0 .. 89.75 dB
GAIN_MODES = ("manual", "slow_attack", "fast_attack", "hybrid")


def device_args(address):
    """'192.168.3.1' / 'ip:192.168.3.1' -> 'driver=glidelink,uri=ip:192.168.3.1'; '' -> the local
    board; a string with 'driver=' is used as it is."""
    a = address.strip()
    if "driver=" in a:
        return a
    if a and not a.startswith(("ip:", "usb:", "local:")):
        a = "ip:" + a
    return "driver=glidelink" + (",uri=" + a if a else "")


def _bandwidth(bandwidth, samp_rate):
    return bandwidth if bandwidth > 0 else min(samp_rate, 56e6)


class source(gr.hier_block2):
    """GlideLink Source: received samples of a board's AD9361.

    address    board ('192.168.3.1', 'ip:...', '' for the board this runs on, or a Soapy string)
    samp_rate  0.52 .. 50 MSPS (over the USB network link to a PC: up to 20 MSPS without loss)
    freq       RX LO, 70 MHz .. 6 GHz
    bandwidth  RF filter bandwidth; 0: the sample rate
    gain_mode  'manual', 'slow_attack', 'fast_attack', 'hybrid' (the AD9361 gain control modes)
    gain       RX gain in dB, in manual mode
    """

    def __init__(self, address="192.168.3.1", samp_rate=2.5e6, freq=915e6, bandwidth=0.0,
                 gain_mode="manual", gain=40.0):
        gr.hier_block2.__init__(self, "GlideLink Source", gr.io_signature(0, 0, 0),
                                gr.io_signature(1, 1, gr.sizeof_gr_complex))
        self.pl_args, self.pl_inputs, self.pl_outputs = device_args(address), {"0": "host0_rx"}, {}
        self.src = soapy.source(device_args(address), "fc32", 1, "", "", [""], [""])
        self.connect(self.src, self)
        self._samp_rate, self._bandwidth = samp_rate, bandwidth
        self.set_samp_rate(samp_rate)
        self.set_freq(freq)
        self._gain = gain
        self.set_gain_mode(gain_mode)

    def set_samp_rate(self, samp_rate):
        self._samp_rate = samp_rate
        self.src.set_sample_rate(0, samp_rate)
        self.src.set_bandwidth(0, _bandwidth(self._bandwidth, samp_rate))

    def set_freq(self, freq):
        self.src.set_frequency(0, freq)

    def set_bandwidth(self, bandwidth):
        self._bandwidth = bandwidth
        self.src.set_bandwidth(0, _bandwidth(bandwidth, self._samp_rate))

    def set_gain_mode(self, gain_mode):
        if gain_mode not in GAIN_MODES:
            raise ValueError(f"gain mode {gain_mode!r}: one of {', '.join(GAIN_MODES)}")
        self._gain_mode = gain_mode
        self.src.write_setting("gain_control_mode", gain_mode)
        if gain_mode == "manual":
            self.src.set_gain(0, self._gain)

    def set_gain(self, gain):
        self._gain = gain
        if self._gain_mode == "manual":                 # the AGC owns the gain otherwise
            self.src.set_gain(0, gain)


class sink(gr.hier_block2):
    """GlideLink Sink: samples to transmit on a board's AD9361 (complex, |x| <= 1).

    address    board, as for the source
    samp_rate  0.52 .. 50 MSPS (over the USB network link: up to 20 MSPS without loss)
    freq       TX LO, 47 MHz .. 6 GHz
    bandwidth  RF filter bandwidth; 0: the sample rate
    atten      TX attenuation, 0 .. 89.75 dB
    """

    def __init__(self, address="192.168.4.1", samp_rate=2.5e6, freq=915e6, bandwidth=0.0, atten=20.0):
        gr.hier_block2.__init__(self, "GlideLink Sink", gr.io_signature(1, 1, gr.sizeof_gr_complex),
                                gr.io_signature(0, 0, 0))
        self.pl_args, self.pl_inputs, self.pl_outputs = device_args(address), {}, {"0": "host0_tx"}
        self.snk = soapy.sink(device_args(address), "fc32", 1, "", "", [""], [""])
        self.connect(self, self.snk)
        self._samp_rate, self._bandwidth = samp_rate, bandwidth
        self.set_samp_rate(samp_rate)
        self.set_freq(freq)
        self.set_atten(atten)

    def set_samp_rate(self, samp_rate):
        self._samp_rate = samp_rate
        self.snk.set_sample_rate(0, samp_rate)
        self.snk.set_bandwidth(0, _bandwidth(self._bandwidth, samp_rate))

    def set_freq(self, freq):
        self.snk.set_frequency(0, freq)

    def set_bandwidth(self, bandwidth):
        self._bandwidth = bandwidth
        self.snk.set_bandwidth(0, _bandwidth(bandwidth, self._samp_rate))

    def set_atten(self, atten):
        self.snk.set_gain(0, TX_GAIN_MAX - min(max(atten, 0.0), TX_GAIN_MAX))
