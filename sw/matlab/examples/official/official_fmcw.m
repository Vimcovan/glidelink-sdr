%OFFICIAL_FMCW The MathWorks example "FMCW Radar Waveform Based Range Calculation Using Time
% Trigger" (USRP) on one GlideLink board.
%
% The example's waveform and processing: phased.FMCWWaveform (1 ms sweep, 15 MHz), sent
% and received by the same radio from the same trigger time, dechirp against the sent sweep, the
% beat frequency from the spectrum peak (the example: the spectrum analyzer's peak finder, here
% the FFT peak of the decimated beat signal), beat2range. Ours instead of the B210 time trigger
% (EnableTimeTrigger / TriggerTime on both objects): glidelink.Radio txBurst at hardware time T
% and an rx capture that starts before T; rx returns the hardware time of its first sample, which
% places T in the samples (both sides run on the board's sample clock).
% Sample rate 20 MSPS instead of 30 (above 20 MSPS the boards' TX path does not keep up yet: a
% cyclic waveform at 30 MSPS comes out with gaps), so the 15 MHz sweep is symmetric (-7.5..7.5 MHz,
% the example's: 0..15 MHz); bandwidth, slope and range resolution are the same.
% The "range" is that of whatever the sweep took from TX to RX: here the coupling between the
% board's TX and RX ports, so it measures the board's own TX -> RX latency (digital filters, FIFOs,
% the AD9361) as a distance; a correlation of the received sweep with the sent one checks it.

host = "192.168.4.1";                                 % one board, TX and RX: the TX board (the RX
                                                      % board's image has no TX data path)
Fs = 20e6;  fc = 3.21e9;  txAtten = 0;  rxGain = 50;
if exist("fcOverride", "var")                        % e.g. 915e6, the antennas' band
    fc = fcOverride;  txAtten = 20;  rxGain = 30;
end

%% the example's waveform
sweepTime = 1e-3;  sweepBW = 15e6;  slope = sweepBW / sweepTime;
rangeRes = bw2rangeres(sweepBW);
maxRange = time2range(sweepTime / 6);
fprintf("Range resolution = %g m, maximum range = %g m\n", rangeRes, maxRange);
hwav = phased.FMCWWaveform(SampleRate=Fs, SweepTime=sweepTime, SweepBandwidth=sweepBW, ...
    SweepInterval="Symmetric", OutputFormat="Sweeps", NumSweeps=1);
txData = hwav();
NumSamps = numel(txData);

%% one trigger time for TX and RX
clear r
r = glidelink.Radio(host);
r.config(Rate=Fs, Freq=fc, Bandwidth=18e6, TxAtten=txAtten, RxGainMode="manual", RxGain=rxGain);
pause(0.3);
T = r.time() + 0.1e9;                                 % trigger time, ns
r.txBurst(0.8 * txData / max(abs(txData)), [], T);    % queued: sent at T
[y, t0] = r.rx(round(0.12 * Fs));                     % starts before T
clear r
start = round((T - t0) * 1e-9 * Fs) + 1;              % sample of the received stream at T
if start < 1 || start + NumSamps - 1 > numel(y)
    error("trigger time %d samples outside the capture", start);
end
rxdata = y(start + (0:NumSamps - 1));
fprintf("TX at %.6f s, RX capture from %.6f s: the trigger is sample %d\n", T * 1e-9, t0 * 1e-9, start);

%% the example's processing
yDechirp = dechirp(rxdata, txData);
decimfact = 4;
yd = decimate(yDechirp, decimfact);
nfft = 2 ^ 20;
Y = fftshift(abs(fft(yd .* hann(numel(yd)), nfft)));
f = ((0:nfft - 1)' - nfft / 2) / nfft * Fs / decimfact;
[~, i] = max(Y .* (abs(f) > 1e3));                    % not the DC of the leakage-free part
beatFreq = abs(f(i));
c = 3e8;
beatFreqRange = beat2range(beatFreq, slope, c);
fprintf("Range of the target based on beat frequency = %.1f m (beat %.0f Hz)\n", beatFreqRange, beatFreq);
% check: the delay of the received sweep by correlation with the sent one
[cc, lags] = xcorr(y(max(1, start - 2000):start + NumSamps + 2000), txData);
[~, k] = max(abs(cc));
delaySamples = lags(k) + max(1, start - 2000) - start;
fprintf("Correlation: the sweep arrives %d samples (%.2f us, %.0f m) after T\n", delaySamples, ...
    delaySamples / Fs * 1e6, delaySamples / Fs * c / 2);
result = struct("name", "official FMCW", "frames", 1, "bits", NaN, "errors", 0, "metric", ...
    sprintf("beat %.0f Hz -> %.0f m; correlation %d samples = %.2f us", beatFreq, beatFreqRange, ...
    delaySamples, delaySamples / Fs * 1e6));

%% figure (the example's scopes as plots)
fig = figure(Name="MathWorks FMCW example on GlideLink", Color="w", Position=[100 100 1300 650]);
tl = tiledlayout(fig, 2, 2, TileSpacing="compact");
title(tl, sprintf("FMCW range by time trigger (MathWorks USRP example), %g GHz, %g MSPS, one GlideLink board", fc / 1e9, Fs / 1e6));
nexttile;
[p1, f1] = pwelch(txData, hann(1024), 512, 1024, Fs, "centered");
plot(f1 / 1e6, 10 * log10(p1 / max(p1)), LineWidth=1);  grid on;  ylim([-60 3]);
xlabel("Frequency (MHz)");  ylabel("dB");  title("Sent sweep spectrum");
nexttile;
m = abs(f) < 200e3;
plot(f(m) / 1e3, 20 * log10(Y(m) / max(Y)), LineWidth=1);  grid on;  ylim([-60 3]);
xline(f(i) / 1e3, ":", sprintf("%.0f Hz", beatFreq));
xlabel("Frequency (kHz)");  ylabel("dB");  title(sprintf("Dechirped spectrum: beat -> %.0f m", beatFreqRange));
nexttile([1 2]);
tt = (0:NumSamps - 1)' / Fs * 1e3;
plot(tt, real(txData) / max(abs(txData)), tt, real(rxdata) / max(abs(rxdata)), LineWidth=0.5);
xlim([0 0.05]);  grid on;  legend(["sent", "received from T"]);
xlabel("Time (ms)");  title("Sent and received sweep (first 50 us)");
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_official_fmcw.png"));
end
