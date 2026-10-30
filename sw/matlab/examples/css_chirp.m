%CSS_CHIRP Chirp spread spectrum (LoRa-like CSS) over the air between the two GlideLink boards.
%
% Spreading factor 7 (128 chips per symbol, 7 bits), bandwidth 125 kHz, sampled at 1 MSPS. Each
% symbol is an up-chirp cyclically shifted by its value; the receiver multiplies by a down-chirp
% ("dechirp") and takes an FFT: the peak bin is the symbol. Frame: 8 up-chirps, 2 down-chirps,
% 64 payload symbols. Timing and frequency offset come from the preamble (an offset moves the
% up-chirp peaks and the down-chirp peaks in opposite directions). Constant envelope; it still
% decodes far below 0 dB SNR (try txAtten = 70).

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
fs = 1e6;  fc = 915e6;  BW = 125e3;  SF = 7;  N = 2 ^ SF;  os = fs / BW;
txAtten = 40;  rxGain = 40;

% AGC for this waveform (run_agc.m sets gainMode = "agc"): constant envelope (PAPR 0 dB), frames
% of 80 ms with a 4.1 ms gap: the slow-attack AGC, target close to full scale. The power is averaged
% over as long as the gap and the gain updated rarely, so a measurement inside the gap is rare; when
% one happens the gain rises by one outer step (2 dB) and the 6 dB headroom of the target takes it.
% Far below 0 dB SNR the AGC follows the noise power, which is what the ADC sees.
agcMode = "slow_attack";
agcParams = {
    "adi,agc-inner-thresh-high", 6             % target window: -6 .. -8 dBFS
    "adi,agc-inner-thresh-low", 8
    "adi,agc-outer-thresh-high", 3
    "adi,agc-outer-thresh-low", 14
    "adi,gc-dec-pow-measurement-duration", 16384 % 16384 samples of ClkRF (4 x fs): 4.1 ms, the gap
    "adi,agc-gain-update-interval-us", 50000}; % one gain update per 50 ms (under one frame)

%% waveform (chip rate = BW, then interpolated to fs)
n = (0:N - 1)';
up = exp(1j * pi * (n .^ 2 / N - n));               % base up-chirp, -BW/2 .. BW/2
down = conj(up);
sym = @(v) up .* exp(2j * pi * v * n / N);           % cyclic shift = frequency offset by v bins
rng(5);  payload = randi([0 N - 1], 64, 1);
frameChips = [repmat(up, 8, 1); repmat(down, 2, 1)];
for v = payload'
    frameChips = [frameChips; sym(v)]; %#ok<AGROW>
end
frameChips = [frameChips; zeros(4 * N, 1)];           % a short gap between frames
x = resample(frameChips, os, 1);                     % to fs
x = 0.7 * x / max(abs(x));

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
y = rx.rx(fs);
sr = rx.config();                                % gain mode / gain as read back
tx.txStop();
if exist("agcSaved", "var")
    glidelink.agcRestore(rx, agcSaved);  clear agcSaved
end
clear tx rx

%% receiver
y = y - mean(y);
yc = resample(y, 1, os);                              % back to the chip rate
L = numel(frameChips);
pre = [repmat(up, 8, 1); repmat(down, 2, 1)];
c = abs(conv(yc, flipud(conj(pre)), "valid"));        % coarse frame start
[~, k0] = max(c(1:L));
starts = k0:L:numel(yc) - L + 1;
nsym = 0;  nerr = 0;  nbiterr = 0;  peaks = [];
cfos = [];
for k = starts
    % each frame: the preamble correlation peak near where it is expected (a fixed spacing from the
    % first frame drifts with the clock offset, and one frame can lock a chirp off)
    w = max(1, k - N):min(numel(c), k + N);
    [~, m] = max(c(w));  k = w(m); %#ok<FXSET>
    if k + L - 1 > numel(yc)
        continue
    end
    seg = yc(k:k + L - 1);
    % fine timing / frequency: starting tau chips early puts the up-chirp peaks at (cfo - tau) and the
    % down-chirp peaks at (cfo + tau)
    fu = abs(fft(reshape(seg(N + 1:7 * N), N, 6) .* down, 8 * N));  % zero-padded: fractional bins
    fd = abs(fft(reshape(seg(8 * N + 1:10 * N), N, 2) .* up, 8 * N));
    [~, iu] = max(sum(fu, 2));  [~, id] = max(sum(fd, 2));
    bu = (iu - 1) / 8;  bd = (id - 1) / 8;
    bu = mod(bu + N / 2, N) - N / 2;  bd = mod(bd + N / 2, N) - N / 2;
    cfoBins = (bu + bd) / 2;  tau = (bd - bu) / 2;   % tau > 0: the coarse start is tau chips early
    cfos(end + 1) = cfoBins * BW / N; %#ok<AGROW>
    % the frame again from the samples at fs, started to 1/8 chip, frequency corrected, then down
    % to the chip rate: dechirping needs the chip grid aligned (half a chip off moves part of each
    % symbol's energy into the next one)
    kf = (k - 1) * os + 1 + round(tau * os);
    if kf < 1 || kf + L * os - 1 > numel(y)
        continue
    end
    seg = resample(y(kf:kf + L * os - 1) .* exp(-2j * pi * cfos(end) * (0:L * os - 1)' / fs), 1, os);
    for m = 1:numel(payload)
        s = seg((9 + m) * N + (1:N)) .* down;
        F = abs(fft(s));
        [~, v] = max(F);
        v = v - 1;
        nsym = nsym + 1;
        nerr = nerr + (v ~= payload(m));
        nbiterr = nbiterr + sum(bitget(bitxor(v, payload(m)), 1:SF));
        if numel(peaks) < 4 * N
            peaks = [peaks; F / max(F)]; %#ok<AGROW>
        end
    end
end
ser = nerr / max(nsym, 1);
cfo = median(cfos);
fprintf("CSS SF%d: frames %d, symbols %d, symbol errors %d (SER %.2e), bit errors %d, CFO %+.0f Hz\n", ...
    SF, numel(starts), nsym, nerr, ser, nbiterr, cfo);
result = struct("name", "CSS chirp SF7", "frames", numel(starts), "bits", nsym * SF, "errors", nbiterr, ...
    "metric", sprintf("SER %.1e, CFO %+.0f Hz", ser, cfo));

%% figure
fig = figure(Name="GlideLink chirp spread spectrum", Color="w", Position=[100 100 1200 750]);
tl = tiledlayout(fig, 2, 2, TileSpacing="compact");
title(tl, sprintf("Chirp spread spectrum SF%d, %g kHz, %g MSPS, over the air", SF, BW / 1e3, fs / 1e6));
nexttile([1 2]);
seg = y((k0 - 1) * os + (1:L * os));
[S, F, T] = spectrogram(seg, hann(256), 192, 256, fs, "centered");
imagesc(T * 1e3, F / 1e3, 10 * log10(abs(S) .^ 2));  axis xy;  ylim([-100 100]);
xlabel("Time (ms)");  ylabel("kHz");  title("Received frame: 8 up-chirps, 2 down-chirps, payload");
colormap(parula);
nexttile;
plot(0:N - 1, peaks(1:N), LineWidth=1.2);  grid on;  hold on;
xline(payload(1), "--");  xlabel("FFT bin after dechirping");  ylabel("normalised");
title(sprintf("One payload symbol: peak at its value (%d)", payload(1)));
nexttile;  axis off;
text(0, 0.75, sprintf("Frames: %d,  symbols: %d", numel(starts), nsym), FontSize=14);
text(0, 0.55, sprintf("Symbol errors: %d (SER %.2e)", nerr, ser), FontSize=14);
text(0, 0.35, sprintf("Bit errors: %d of %d", nbiterr, nsym * SF), FontSize=14);
text(0, 0.15, sprintf("Frequency offset: %+.0f Hz", cfo), FontSize=14);
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_css_chirp.png"));
end
