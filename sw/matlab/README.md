# GlideLink in MATLAB

MATLAB talks to each board through the GlideLink bridge, a fixed service on the board
(`glidelink-bridge`, TCP port 7030, started at boot). Nothing is installed on the PC besides MATLAB
(R2025b tested; `tcpclient` is part of MATLAB); the examples use the Communications Toolbox.

```matlab
addpath('D:/ClaudePrj/glidelink-sdr/sw/matlab')
run('D:/ClaudePrj/glidelink-sdr/sw/matlab/examples/qpsk_ota.m')     % QPSK between the two boards
```

## Examples (`sw/matlab/examples`, all over the air between the two boards, same bridge)

| Script | Scheme | What it shows |
|---|---|---|
| `qpsk_ota.m` | QPSK, RRC, 1 MSPS | single carrier, continuous; Communications Toolbox synchronisation chain |
| `fsk_narrowband.m` | 2-FSK, 10 kbaud, 0.6 MSPS | narrowband, constant envelope (PAPR 0 dB), noncoherent detection |
| `css_chirp.m` | chirp spread spectrum SF7, 125 kHz, 1 MSPS | constant envelope, spread spectrum; spectrogram of the chirps |
| `wlan_ofdm.m` | 802.11a/g 16-QAM 3/4, 20 MSPS (WLAN Toolbox) | wideband, high PAPR (10 dB), packets with idle time; channel estimate |
| `timed_bursts.m` | 20 Zadoff-Chu bursts at exact hardware times, 2 MSPS | bursts scheduled ahead; spacing precision (ns), clock offset (ppm) |
| `agc_modes.m` | the same bursts (14 dB steps) with fixed gain, slow AGC, fast AGC, fast AGC with another lock level | how each gain mode reacts (driver parameters as they are; the fast AGC's parameters are listed in the script) |
| `run_all.m` | all of the above, one after the other | summary table |
| `run_agc.m` | every scheme twice: the fixed gain, then the AGC configured for its waveform | summary table with the gain the AD9361 ended up with |

On 2026-10-30 `run_all` gave 0 bit errors in every scheme (QPSK 440 kbit, 2-FSK 27 kbit, CSS 768
symbols, OFDM 60 packets / 480 kbit at SNR 27.6 dB, bursts 20 of 20 with 2 ns spacing spread).

## AGC per waveform

Each scheme script carries an AGC configuration for its waveform (`agcMode`, `agcParams`, with the
reason for every value in the comments); `gainMode = "agc"` before running the script selects it
(`run_agc.m` does), otherwise the script uses its fixed gain. `glidelink.agcSetup(r, mode, params)`
writes the driver parameters, re-initialises the AD9361 and selects the gain mode;
`glidelink.agcRestore(r, saved)` puts parameters, gain mode and gain back at the end of the script.
The measurement durations count samples of ClkRF (4 x the sample rate here), and the driver
shortens a slow-AGC measurement that does not fit twice into the gain update interval.

| Script | AGC | Configuration |
|---|---|---|
| `qpsk_ota.m` | slow attack | average power -11..-14 dBFS (PAPR about 3.5 dB), 256 us average, update every 5 ms |
| `fsk_narrowband.m` | slow attack | -6..-8 dBFS (constant envelope), update every 5 ms |
| `css_chirp.m` | slow attack | -6..-8 dBFS, averaged over the 4.1 ms frame gap, update every 50 ms |
| `wlan_ofdm.m` | fast attack | as the competition OFDM receiver: lock level -14 dBFS (PAPR 10 dB), gain held after the first packet, no unlock on a stronger signal (the OFDM peaks reach lock level + 10 dB); started once packets are on the air, restarted if the samples clip |
| `timed_bursts.m` | fast attack | lock level -8 dBFS (constant envelope), unlock in the 10 ms gaps, each burst attacked from maximum gain |

On 2026-10-30 `run_agc` gave 0 errors in all ten runs (OFDM with the AGC: 60 of 60 packets at
gain 29 dB, SNR 26.9 dB). Over repeated OFDM runs the fast AGC locked about 13 dB too high once
in six (2 of 60 packets bad); per-packet unlocking (energy lost, then maximum or optimised gain)
gave 0 to 59 bad packets of 60 from run to run on these boards, so it is not used.

## `glidelink.Radio`

| Call | What it does |
|---|---|
| `r = glidelink.Radio("192.168.4.1")` | connect (checks the bridge protocol version) |
| `s = r.config(Rate=1e6, Freq=915e6, Bandwidth=2e6, RxGain=40, TxAtten=20)` | radio settings, read back; also `RxFreq`, `TxFreq`, `RxGainMode` (`"slow_attack"`, `"fast_attack"`, `"hybrid"`, `"manual"`), `Loopback` (AD9361 digital loopback). Rates 0.52 to 61.44 MSPS (the FIR is designed for the rate) |
| `r.txCyclic(x)` / `r.txStop()` | repeat a waveform (complex, abs(x) <= 1) on the board, no network load |
| `t = r.txBurst(x, 0.1)` / `r.txBurst(x, [], t)` | one burst at hardware time now + 0.1 s (or at t, ns), ended as a burst; returns once queued, so many bursts can be scheduled ahead (the bridge sends them in order) |
| `[y, t] = r.rx(n)` | n contiguous samples (complex, full scale 1), captured on the board, then sent; t = hardware time of the first sample (ns) |
| `t = r.time()` | hardware time (sample clock), ns |
| `v = r.attr(name)` / `r.attr(name, value)` | any AD9361 driver attribute: sysfs (`"in_voltage0_rssi"`, ...) or the driver's parameters (`"adi,agc-inner-thresh-high"`, ...; `r.attr("initialize", 1)` re-runs the driver's setup with them; the bridge keeps rate, LOs, bandwidth, gain mode / gain and TX attenuation across it unless their own device-tree parameter was written). Driver parameters stay set until changed again or the board reboots |
| `r.route(struct("slot0_in", "host1_tx", "host1_rx", "slot0_out"))` | stream switch routes, sink <- source |
| `w = r.host1(words, m)` | uint32 words to host port 1 (into the routed modules), m words back |
| `v = r.reg("FPGA", addr)` / `r.reg("FPGA", addr, value)` | shell and module registers (`"AD9361"`: chip registers) |

Each request takes about 15 ms in MATLAB (tcpclient); scripts that schedule bursts leave that much
time per burst before the first one. Several MATLAB sessions (or scripts) may be connected to a
board at once; their commands take turns.
A cyclic transmission stops when the connection that started it closes (`clear r`).

## The board side

The bridge service loads the board's image at boot and owns the routes, so it does not run together
with the offline DeepJSCC-Q system; switch on the board with `systemctl start glidelinkd@tx` (or `rx`)
and back with `systemctl start glidelink-bridge` (each stops the other). Installation:
`sw/bridge/install.sh <image.bit> --enable`.
