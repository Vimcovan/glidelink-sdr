#!/usr/bin/env python3
"""Over-the-air QPSK between the two GlideLink boards, from one GNU Radio flowgraph on the PC.

    TX board: random bits -> QPSK (RRC, 4 samples per symbol) -> gr-soapy sink
    RX board: gr-soapy source -> AGC -> FLL band edge (CFO) -> polyphase clock sync -> Costas loop

Shown: spectrum and waterfall of the received signal, |x| in time, constellation before and after
synchronisation. A slider sets the TX gain (0 .. 89.75 dB, i.e. attenuation 89.75 .. 0 dB).

    python3 ota_qpsk.py [--rx driver=glidelink,uri=ip:192.168.3.1] [--tx ...uri=ip:192.168.4.1]
                        [--freq 915e6] [--rate 2.5e6] [--tx-gain 50]

Over the USB network links keep the rate low (2.5 MSPS = 10 MB/s of CS16 per board).
"""
import argparse
import math
import signal
import sys

import numpy as np
from PyQt5 import Qt
from gnuradio import analog, blocks, digital, filter, gr, qtgui, soapy
from gnuradio.filter import firdes
import sip

SPS, ROLLOFF, NFILTS = 4, 0.35, 32


class OtaQpsk(gr.top_block, Qt.QWidget):
    def __init__(self, a):
        gr.top_block.__init__(self, "GlideLink OTA QPSK")
        Qt.QWidget.__init__(self)
        self.setWindowTitle("GlideLink OTA QPSK  (TX %s -> RX %s, %.1f MHz)"
                            % (a.tx.split("uri=")[-1], a.rx.split("uri=")[-1], a.freq / 1e6))
        grid = Qt.QGridLayout(self)
        wrap = lambda blk: sip.wrapinstance(blk.qwidget(), Qt.QWidget)

        # transmitter
        const = digital.constellation_qpsk().base()
        bits = np.random.default_rng(1).integers(0, 256, 1 << 16).astype(np.uint8).tolist()
        self.bits = blocks.vector_source_b(bits, True)
        self.mod = digital.generic_mod(const, False, SPS, True, ROLLOFF, False, False)
        self.tx_amp = blocks.multiply_const_cc(0.5)
        self.snk = soapy.sink(a.tx, "fc32", 1, "", "", [""], [""])
        self.snk.set_sample_rate(0, a.rate)
        self.snk.set_bandwidth(0, min(a.rate, 18e6))
        self.snk.set_frequency(0, a.freq)
        self.snk.set_gain(0, a.tx_gain)
        self.connect(self.bits, self.mod, self.tx_amp, self.snk)

        # receiver
        self.src = soapy.source(a.rx, "fc32", 1, "", "", [""], [""])
        self.src.set_sample_rate(0, a.rate)
        self.src.set_bandwidth(0, min(a.rate, 18e6))
        self.src.set_frequency(0, a.freq)
        self.src.set_gain_mode(0, True)
        self.agc = analog.agc2_cc(1e-1, 1e-2, 1.0, 1.0)
        self.agc.set_max_gain(65536)
        self.fll = digital.fll_band_edge_cc(SPS, ROLLOFF, 44, 2 * math.pi / SPS / 100)
        taps = firdes.root_raised_cosine(NFILTS, NFILTS * SPS, 1.0, ROLLOFF, 11 * SPS * NFILTS)
        self.sync = digital.pfb_clock_sync_ccf(SPS, 2 * math.pi / 100, taps, NFILTS, NFILTS // 2, 1.5, 1)
        self.costas = digital.costas_loop_cc(2 * math.pi / 100, 4, False)
        self.connect(self.src, self.agc, self.fll, self.sync, self.costas)

        # displays
        self.freq_sink = qtgui.freq_sink_c(2048, 5, a.freq, a.rate, "RX spectrum", 1)
        self.freq_sink.set_update_time(0.1)
        self.freq_sink.set_y_axis(-140, 0)
        self.freq_sink.enable_grid(True)
        self.freq_sink.enable_autoscale(False)
        self.connect(self.src, self.freq_sink)

        self.wf_sink = qtgui.waterfall_sink_c(1024, 5, a.freq, a.rate, "RX waterfall", 1)
        self.wf_sink.set_update_time(0.05)
        self.wf_sink.set_intensity_range(-120, -20)
        self.connect(self.src, self.wf_sink)

        self.mag = blocks.complex_to_mag(1)
        self.time_sink = qtgui.time_sink_f(2000, a.rate, "|x| (RX, before AGC)", 1)
        self.time_sink.set_update_time(0.1)
        self.time_sink.enable_grid(True)
        self.time_sink.enable_autoscale(True)
        self.connect(self.src, self.mag, self.time_sink)

        self.raw_const = qtgui.const_sink_c(1024, "Before sync (AGC output)", 1)
        self.raw_const.set_update_time(0.1)
        self.raw_const.set_x_axis(-2, 2)
        self.raw_const.set_y_axis(-2, 2)
        self.raw_const.enable_grid(True)
        self.connect(self.agc, self.raw_const)

        self.const = qtgui.const_sink_c(1024, "After FLL + clock sync + Costas", 1)
        self.const.set_update_time(0.1)
        self.const.set_x_axis(-2, 2)
        self.const.set_y_axis(-2, 2)
        self.const.enable_grid(True)
        self.connect(self.costas, self.const)

        # controls
        row = Qt.QHBoxLayout()
        row.addWidget(Qt.QLabel("TX gain (dB):"))
        self.slider = Qt.QSlider(Qt.Qt.Horizontal)
        self.slider.setRange(0, 359)                      # 0.25 dB steps up to 89.75
        self.slider.setValue(int(round(a.tx_gain * 4)))
        self.gain_label = Qt.QLabel("%.2f" % a.tx_gain)
        self.slider.valueChanged.connect(self.set_tx_gain)
        row.addWidget(self.slider, 1)
        row.addWidget(self.gain_label)
        self.status = Qt.QLabel("")
        row.addWidget(self.status)
        grid.addLayout(row, 0, 0, 1, 3)
        grid.addWidget(wrap(self.freq_sink), 1, 0, 1, 2)
        grid.addWidget(wrap(self.wf_sink), 1, 2)
        grid.addWidget(wrap(self.time_sink), 2, 0)
        grid.addWidget(wrap(self.raw_const), 2, 1)
        grid.addWidget(wrap(self.const), 2, 2)

        self.timer = Qt.QTimer()
        self.timer.timeout.connect(self.poll)
        self.timer.start(500)

    def set_tx_gain(self, v):
        self.snk.set_gain(0, v / 4)
        self.gain_label.setText("%.2f" % (v / 4))

    def poll(self):
        cfo = self.fll.get_frequency() * self.src.get_sample_rate(0) / (2 * math.pi)
        self.status.setText("   CFO %+.2f kHz   RX gain %.0f dB" % (cfo / 1e3, self.src.get_gain(0)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rx", default="driver=glidelink,uri=ip:192.168.3.1")
    ap.add_argument("--tx", default="driver=glidelink,uri=ip:192.168.4.1")
    ap.add_argument("--freq", type=float, default=915e6)
    ap.add_argument("--rate", type=float, default=2.5e6)
    ap.add_argument("--tx-gain", type=float, default=50.0)
    a = ap.parse_args()

    app = Qt.QApplication(sys.argv)
    tb = OtaQpsk(a)
    tb.resize(1500, 900)
    tb.start()
    tb.show()

    def stop(*_):
        tb.stop()
        tb.wait()
        Qt.QApplication.quit()

    signal.signal(signal.SIGINT, stop)
    app.aboutToQuit.connect(stop)
    timer = Qt.QTimer()
    timer.start(500)
    timer.timeout.connect(lambda: None)
    app.exec_()


if __name__ == "__main__":
    main()
