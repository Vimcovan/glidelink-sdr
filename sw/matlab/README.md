# GlideLink in MATLAB

MATLAB talks to each board through the GlideLink bridge, a fixed service on the board
(`glidelink-bridge`, TCP port 7030, started at boot). Nothing is installed on the PC besides MATLAB
(R2025b tested; `tcpclient` is part of MATLAB); the examples use the Communications Toolbox.

```matlab
addpath('D:/ClaudePrj/glidelink-sdr/sw/matlab')
run('D:/ClaudePrj/glidelink-sdr/sw/matlab/examples/qpsk_ota.m')     % QPSK between the two boards
```

## `glidelink.Radio`

| Call | What it does |
|---|---|
| `r = glidelink.Radio("192.168.4.1")` | connect (checks the bridge protocol version) |
| `s = r.config(Rate=1e6, Freq=915e6, Bandwidth=2e6, RxGain=40, TxAtten=20)` | radio settings, read back; also `RxFreq`, `TxFreq`, `RxGainMode` (`"slow_attack"`, `"fast_attack"`, `"hybrid"`, `"manual"`), `Loopback` (AD9361 digital loopback). Rates 0.52 to 61.44 MSPS (the FIR is designed for the rate) |
| `r.txCyclic(x)` / `r.txStop()` | repeat a waveform (complex, abs(x) <= 1) on the board, no network load |
| `t = r.txBurst(x, 0.1)` | one burst at hardware time now + 0.1 s, ended as a burst |
| `[y, t] = r.rx(n)` | n contiguous samples (complex, full scale 1), captured on the board, then sent; t = hardware time of the first sample (ns) |
| `t = r.time()` | hardware time (sample clock), ns |
| `v = r.attr(name)` / `r.attr(name, value)` | any AD9361 driver attribute: sysfs (`"in_voltage0_rssi"`, ...) or the driver's parameters (`"adi,agc-inner-thresh-high"`, ...; `r.attr("initialize", 1)` re-runs the driver's setup with them) |
| `r.route(struct("slot0_in", "host1_tx", "host1_rx", "slot0_out"))` | stream switch routes, sink <- source |
| `w = r.host1(words, m)` | uint32 words to host port 1 (into the routed modules), m words back |
| `v = r.reg("FPGA", addr)` / `r.reg("FPGA", addr, value)` | shell and module registers (`"AD9361"`: chip registers) |

Several MATLAB sessions (or scripts) may be connected to a board at once; their commands take turns.
A cyclic transmission stops when the connection that started it closes (`clear r`).

## The board side

The bridge service loads the board's image at boot and owns the routes, so it does not run together
with the offline DeepJSCC-Q system; switch on the board with `systemctl start glidelinkd@tx` (or `rx`)
and back with `systemctl start glidelink-bridge` (each stops the other). Installation:
`sw/bridge/install.sh <image.bit> --enable`.
