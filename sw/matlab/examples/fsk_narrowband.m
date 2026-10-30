%FSK_NARROWBAND Narrowband, constant-envelope 2-FSK over the air between the two GlideLink boards.
%
% Continuous-phase 2-FSK, 10 kbaud, tones at -10 / +10 kHz, sampled at 0.6 MSPS (near the lowest rate
% of the AD9361), noncoherent detection (energy in each tone, no carrier recovery). The I/Q plot is
% a circle: constant envelope, PAPR 0 dB. The TX board repeats a frame (alternating preamble, 32-bit
% sync word, 1000 PRBS bits); the RX board captures 3 s.

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
fs = 0.6e6;  fc = 915e6;  Rs = 10e3;  dev = 10e3;  sps = fs / Rs;
txAtten = 40;  rxGain = 40;

% AGC for this waveform (run_agc.m sets gainMode = "agc"): continuous and constant envelope (PAPR
% 0 dB), so the slow-attack AGC, and the target can sit close to full scale for more ADC range.
agcMode = "slow_attack";
agcParams = {
    "adi,agc-inner-thresh-high", 6             % target window: -6 .. -8 dBFS (no peaks above the
    "adi,agc-inner-thresh-low", 8              %   average to leave room for)
    "adi,agc-outer-thresh-high", 3
    "adi,agc-outer-thresh-low", 14
    "adi,gc-dec-pow-measurement-duration", 1024 % 1024 samples of ClkRF (4 x fs): 427 us (the power
                                               %   is the same at every instant: no need to average long)
    "adi,agc-gain-update-interval-us", 5000};  % one gain update per 5 ms

%% waveform
syncWord = [1 1 1 1 1 0 0 1 1 0 1 0 1 1 0 0 1 0 1 0 0 0 0 1 0 0 1 1 0 1 1 0]';
rng(3);  payload = randi([0 1], 1000, 1);
bits = [repmat([1; 0], 16, 1); syncWord; payload];
f = dev * (2 * bits - 1);                             % tone per bit
phase = 2 * pi * cumsum(repelem(f, sps)) / fs;        % continuous phase
x = 0.7 * exp(1j * phase);
x = x .* exp(-1j * phase(end) * (0:numel(x) - 1)' / numel(x));   % phase-continuous when repeated
papr = 10 * log10(max(abs(x) .^ 2) / mean(abs(x) .^ 2));

%% boards
if ~exist("gainMode", "var")                        % set by run_agc.m
    gainMode = "manual";                            % "manual": the fixed gain; "agc": agcMode / agcParams
end
clear tx rx
tx = glidelink.Radio(txHost);  rx = glidelink.Radio(rxHost);
tx.config(Rate=fs, Freq=fc, Bandwidth=fs, TxAtten=txAtten);
rx.config(Rate=fs, Freq=fc, Bandwidth=fs);
if gainMode == "agc"
    agcSaved = glidelink.agcSetup(rx, agcMode, agcParams);
else
    rx.config(RxGain=rxGain);
end
tx.txCyclic(x);  pause(0.5);
y = rx.rx(3 * fs);
sr = rx.config();                                % gain mode / gain as read back
tx.txStop();
if exist("agcSaved", "var")
    glidelink.agcRestore(rx, agcSaved);  clear agcSaved
end
clear tx rx

%% receiver: CFO from the mean instantaneous frequency, tone energies, bit timing, sync word
y = y - mean(y);
fi = angle(y(2:end) .* conj(y(1:end - 1))) * fs / (2 * pi);
cfo = median(fi);                                     % the tones are balanced (preamble, PRBS)
y = y .* exp(-2j * pi * cfo * (0:numel(y) - 1)' / fs);
t = (0:numel(y) - 1)' / fs;
e1 = abs(movsum(y .* exp(-2j * pi * dev * t), sps)) .^ 2;    % energy in each tone over one bit
e0 = abs(movsum(y .* exp(+2j * pi * dev * t), sps)) .^ 2;
d = e1 - e0;
[~, ph] = max(arrayfun(@(k) sum(abs(d(k:sps:end))), 1:sps));  % bit timing: largest decision margin
dec = d(ph:sps:end) > 0;
s = 2 * double(syncWord) - 1;
c = conv(2 * dec - 1, flipud(s), "valid");
starts = find(c >= 30);                               % sync word found (<= 1 bit error)
nerr = 0;  nbit = 0;
for k = starts(:)'
    p = k + numel(syncWord);
    if p + 999 <= numel(dec)
        nerr = nerr + sum(dec(p:p + 999) ~= payload);  nbit = nbit + 1000;
    end
end
ber = nerr / max(nbit, 1);
fprintf("2-FSK: frames %d, bits %d, errors %d (BER %.2e), CFO %+.0f Hz, PAPR %.2f dB\n", ...
    numel(starts), nbit, nerr, ber, cfo, papr);
result = struct("name", "2-FSK narrowband", "frames", numel(starts), "bits", nbit, "errors", nerr, ...
    "metric", sprintf("CFO %+.0f Hz, PAPR %.1f dB", cfo, papr));

%% figure
fig = figure(Name="GlideLink 2-FSK", Color="w", Position=[100 100 1200 750]);
tl = tiledlayout(fig, 2, 2, TileSpacing="compact");
title(tl, sprintf("2-FSK %g kbaud, tones \\pm%g kHz, %g MSPS, over the air", Rs / 1e3, dev / 1e3, fs / 1e6));
nexttile;
[pxx, fr] = pwelch(y, hann(4096), 2048, 4096, fs, "centered");
plot(fr / 1e3, 10 * log10(pxx / max(pxx)), LineWidth=1.2);  grid on;  xlim([-60 60]);  ylim([-70 3]);
xlabel("Frequency (kHz)");  ylabel("dB");  title("Received spectrum (zoom \pm60 kHz)");
nexttile;
yn = y(1:20000) / rms(y(1:20000));
plot(real(yn), imag(yn), ".", MarkerSize=3);  axis equal;  grid on;  xlim([-2 2]);  ylim([-2 2]);
title(sprintf("I/Q: constant envelope (TX PAPR %.1f dB)", papr));
nexttile;
n = 1:8 * sps;
fs_ = movmean(fi, sps / 6);                           % smoothed for display
plot(n / fs * 1e3, fs_(n + 50 * sps) / 1e3, LineWidth=1.2);  grid on;  ylim([-20 20]);
xlabel("Time (ms)");  ylabel("kHz");  title("Instantaneous frequency (8 bits)");
nexttile;  axis off;
text(0, 0.75, sprintf("Frames: %d", numel(starts)), FontSize=14);
text(0, 0.55, sprintf("Bit errors: %d of %d (BER %.2e)", nerr, nbit, ber), FontSize=14);
text(0, 0.35, sprintf("Frequency offset: %+.0f Hz", cfo), FontSize=14);
text(0, 0.15, sprintf("Noncoherent detection, %d samples per bit", sps), FontSize=14);
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_fsk_narrowband.png"));
end
