#!/usr/bin/env python3
"""Spectrum of the GlideLink board in GNU Radio (gr-soapy source -> Qt frequency sink).

    python3 spectrum.py [--args driver=glidelink,uri=ip:192.168.3.1] [--freq 915e6] [--rate 2.5e6]

Over the USB network link keep the rate low (2.5 MSPS = 10 MB/s of CS16).
"""
import argparse
import signal
import sys

from PyQt5 import Qt
from gnuradio import gr, qtgui, soapy
import sip


class Spectrum(gr.top_block, Qt.QWidget):
    def __init__(self, args, freq, rate, gain):
        gr.top_block.__init__(self, "GlideLink spectrum")
        Qt.QWidget.__init__(self)
        self.setWindowTitle("GlideLink spectrum")
        layout = Qt.QVBoxLayout(self)

        self.src = soapy.source(args, "fc32", 1, "", "", [""], [""])
        self.src.set_sample_rate(0, rate)
        self.src.set_bandwidth(0, min(rate, 18e6))
        self.src.set_frequency(0, freq)
        if gain is None:
            self.src.set_gain_mode(0, True)
        else:
            self.src.set_gain_mode(0, False)
            self.src.set_gain(0, gain)

        self.sink = qtgui.freq_sink_c(2048, 5, freq, rate, "RX", 1)   # 5 = Blackman-Harris
        self.sink.set_update_time(0.1)
        self.sink.set_y_axis(-140, 0)
        self.sink.enable_autoscale(False)
        self.sink.enable_grid(True)
        layout.addWidget(sip.wrapinstance(self.sink.qwidget(), Qt.QWidget))
        self.connect(self.src, self.sink)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--args", default="driver=glidelink,uri=ip:192.168.3.1")
    ap.add_argument("--freq", type=float, default=915e6)
    ap.add_argument("--rate", type=float, default=2.5e6)
    ap.add_argument("--gain", type=float, default=None, help="manual RX gain in dB (default: AGC)")
    a = ap.parse_args()

    app = Qt.QApplication(sys.argv)
    tb = Spectrum(a.args, a.freq, a.rate, a.gain)
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
    timer.timeout.connect(lambda: None)   # let Python see SIGINT
    app.exec_()


if __name__ == "__main__":
    main()
