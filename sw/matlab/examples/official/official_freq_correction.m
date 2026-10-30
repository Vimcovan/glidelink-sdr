%OFFICIAL_FREQ_CORRECTION The MathWorks example "Frequency Correction for ADALM-PLUTO Radio" on the
% two GlideLink boards.
%
% The example's procedure and estimator, unchanged: the TX board sends tones at 20, 40 and 80 kHz;
% the RX board finds the 80 kHz tone, K = (fc + fRef) / (fc + fReceived), and the parts-per-million
% correction p = (fReceived - fRef) / (fc + fRef) * 1e6 scales the receiver's centre frequency and
% sample rate together. Then the transmitter is moved by 1 ppm (as if its oscillator had drifted),
% the offset is measured again and the new correction combined with the current one.
% Ours instead of the Pluto's FrequencyCorrection property: the AD9361 driver's xo_correction (the
% 40 MHz reference, an adjustable clock of +-200 ppm as on the Pluto), set through glidelink.Radio:
% telling the driver the reference is 40 MHz / (1 + p/1e6) makes LOs and sample clock run
% (1 + p/1e6) faster. Sample rate 1 MSPS instead of 200 kSPS (the GlideLink AD9361 path starts at
% 0.52 MSPS); the tones and the estimator are the same. Around 2.42 GHz WiFi bursts raise the noise
% floor of some captures; the tones stay far above it.

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
sampleRate = 1e6;  centerFreq = 2.42e9;  fRef = 80e3;  txAtten = 30;  rxGain = 30;
xoNominal = 40e6;
setPPM = @(r, ppm) r.attr("xo_correction", round(xoNominal / (1 + ppm / 1e6)));
getPPM = @(r) (xoNominal / str2double(string(r.attr("xo_correction"))) - 1) * 1e6;

%% set up the transmitter and the receiver (the example's signals)
s1 = exp(1j * 2 * pi * 20e3 * (0:10000 - 1)' / sampleRate);   % 20 kHz
s2 = exp(1j * 2 * pi * 40e3 * (0:10000 - 1)' / sampleRate);   % 40 kHz
s3 = exp(1j * 2 * pi * fRef * (0:10000 - 1)' / sampleRate);   % 80 kHz
s = s1 + s2 + s3;
s = 0.6 * s / max(abs(s));
clear tx rx
tx = glidelink.Radio(txHost);  rx = glidelink.Radio(rxHost);
setPPM(tx, 0);  setPPM(rx, 0);                       % factory condition: the nominal 40 MHz
tx.config(Rate=sampleRate, Freq=centerFreq, Bandwidth=sampleRate, TxAtten=txAtten);
rx.config(Rate=sampleRate, RxFreq=centerFreq, TxFreq=centerFreq + 10e6, Bandwidth=sampleRate, ...
    RxGainMode="manual", RxGain=rxGain);              % the RX board's own TX LO away from its RX LO:
                                                      % at the same frequency it leaks in as a line
                                                      % at -0.6 kHz, stronger than the tones at 2.42 GHz
disp('Send 3 tones at 20, 40, and 80 kHz');
tx.txCyclic(s);  pause(0.5);
numSamples = 1024 * 1024;

%% receive, estimate and apply the correction (the example's estimator)
spectra = {};  titles = strings(0);
[fReceived, spectra{end + 1}] = findTone(rx.rx(numSamples), sampleRate);
titles(end + 1) = sprintf("Tone expected at 80 kHz, received at %.3f kHz", fReceived / 1e3);
ppm = (fReceived - fRef) / (centerFreq + fRef) * 1e6;
setPPM(rx, ppm);  settle(rx);
fprintf("Based on the tone detected at %.3f kHz, FrequencyCorrection of the receiver should be set to %.4f\n", ...
    fReceived / 1e3, ppm);
[fReceived2, spectra{end + 1}] = findTone(rx.rx(numSamples), sampleRate);
titles(end + 1) = sprintf("After the correction (%+.4f ppm): %.3f kHz", ppm, fReceived2 / 1e3);
fprintf("Tone detected at %.3f kHz\n", fReceived2 / 1e3);

%% the transmitter's oscillator "drifts" by 1 ppm
disp("Change the FrequencyCorrection of the transmitter to 1 to simulate that its oscillator has drifted");
setPPM(tx, 1);  settle(rx);
[fReceived3, spectra{end + 1}] = findTone(rx.rx(numSamples), sampleRate);
titles(end + 1) = sprintf("TX moved by 1 ppm: received at %.3f kHz", fReceived3 / 1e3);
currentPPM = getPPM(rx);
ppmToAdd = (fReceived3 - fRef) / (centerFreq + fRef) * 1e6;
newPPM = currentPPM + ppmToAdd + currentPPM * ppmToAdd / 1e6;
setPPM(rx, newPPM);  settle(rx);
fprintf("Based on the tone detected at %.3f kHz, FrequencyCorrection of the receiver should be changed from %.4f to %.4f\n", ...
    fReceived3 / 1e3, currentPPM, newPPM);
[fReceived4, spectra{end + 1}] = findTone(rx.rx(numSamples), sampleRate);
titles(end + 1) = sprintf("Corrected again (%+.4f ppm): %.3f kHz", newPPM, fReceived4 / 1e3);
fprintf("Tone detected at %.3f kHz\n", fReceived4 / 1e3);

tx.txStop();
setPPM(tx, 0);  setPPM(rx, 0);                       % back to the nominal reference
clear tx rx
result = struct("name", "official frequency correction", "frames", 4, "bits", NaN, "errors", 0, ...
    "metric", sprintf("RX %+.3f ppm; tone %.1f -> %.1f Hz; TX +1 ppm: %.1f -> %.1f Hz", ppm, ...
    fReceived - fRef, fReceived2 - fRef, fReceived3 - fRef, fReceived4 - fRef));
disp(result.metric);

%% figure
fig = figure(Name="MathWorks frequency correction example on GlideLink", Color="w", Position=[100 100 1200 700]);
tl = tiledlayout(fig, 2, 2, TileSpacing="compact");
title(tl, sprintf("Frequency correction (MathWorks Pluto example), %g GHz, %g MSPS, GlideLink boards", centerFreq / 1e9, sampleRate / 1e6));
for k = 1:4
    nexttile;
    [f, P] = spectra{k}{:};
    plot(f / 1e3, P, LineWidth=1);  grid on;  xlim([0 100]);  ylim([-80 3]);
    xline([20 40 80], ":");  xlabel("Frequency (kHz)");  ylabel("dB");  title(titles(k));
end
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_official_freq_correction.png"));
end

function settle(rx)
% as the example's "capture 10 frames, but only use the last": skip the transient after a change
for i = 1:10
    rx.rx(1024 * 1024 / 10);
end
end

function [fReceived, spec] = findTone(receivedSig, sampleRate)
% the example's tone search: the highest-frequency peak at least half as prominent as the maximum
numSamples = numel(receivedSig);
y = fftshift(abs(fft(receivedSig)));
[~, idx] = findpeaks(y, MinPeakProminence=max(0.5 * y));
fReceived = (max(idx) - numSamples / 2 - 1) / numSamples * sampleRate;
f = ((0:numSamples - 1)' - numSamples / 2) / numSamples * sampleRate;
spec = {f, 20 * log10(y / max(y))};
end
