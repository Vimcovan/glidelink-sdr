%OTFS_OTA Orthogonal time frequency space (OTFS) modulation over the air between the two GlideLink
% boards.
%
% QPSK symbols are placed on a delay-Doppler grid of M delay bins x N Doppler bins (64 x 32 at
% 1 MSPS: 1 us delay and 488 Hz Doppler resolution, 2.048 ms per frame) and turned into one block
% of M N samples with one cyclic prefix (the inverse FFT along Doppler). The block is sent with
% root raised cosine pulses (4 samples each, the radio at 4 MSPS) and matched-filtered on receive;
% the best of the 4 sampling phases is taken from the preamble correlation:
% one path then spreads over 1 to 2 delay bins (sent at 1 MSPS directly, the AD9361's analog
% filters cut the band edges and a path smears over many bins, leaking data into the guard). An
% embedded pilot sits in the middle of the grid with empty guard rows around it in delay (all
% Doppler bins): received, it spreads into the channel's delay-Doppler response, from which the
% paths (gain, delay, Doppler) are read with a threshold. The receiver builds the time-domain
% channel matrix from these paths and equalises the whole frame (LMMSE).
% Each frame starts with a preamble of two equal Zadoff-Chu sequences: frame timing and the
% frequency offset between the boards (corrected before the delay-Doppler processing).
% Two boards on a desk have a single path and no Doppler, so the TX side can pass each frame
% through a synthetic doubly dispersive channel first (emulateChannel = true: three paths with
% different delays and Doppler shifts, below); OTA the frame then also sees the real channel.
% Shown: the delay-Doppler channel estimate with the emulated paths, the constellation after a
% single-tap correction (strongest path only: inter-symbol and inter-carrier interference remain)
% and after the delay-Doppler equalisation.

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
fs = 1e6;  sps = 4;  fc = 915e6;  txAtten = 20;  rxGain = 40;   % fs: delay-Doppler (symbol) rate
M = 64;  N = 32;  Lcp = 16;                     % delay bins, Doppler bins, cyclic prefix (samples)
if ~exist("emulateChannel", "var")
    emulateChannel = true;                      % false: the over-the-air channel only
end
paths = [0 1.0  0                               % emulated paths: delay (samples), gain, Doppler (bins)
         2 0.6  3
         5 0.4 -2];

% AGC for this waveform (run_agc.m sets gainMode = "agc"): frames back to back (continuous, nearly
% constant average power), so the slow-attack AGC. The OTFS block is a sum of many symbols (PAPR
% about 10 dB, more with the boosted pilot): the target window is set low, and the power is
% averaged over half a frame so the pilot pulses do not move the gain.
agcMode = "slow_attack";
agcParams = {
    "adi,agc-inner-thresh-high", 16            % target window for the average power: -16 .. -19 dBFS
    "adi,agc-inner-thresh-low", 19
    "adi,agc-outer-thresh-high", 10
    "adi,agc-outer-thresh-low", 25
    "adi,gc-dec-pow-measurement-duration", 4096 % 4096 samples of ClkRF (4 x fs): 1 ms
    "adi,agc-gain-update-interval-us", 10000}; % one gain update per 10 ms (at least 2 measurements)

%% waveform
lp = M / 2;  kp = N / 2;  lmax = 10;            % pilot (0-based delay, Doppler); guard rows lp +- lmax
backoff = 3;                                    % the receiver starts the block 3 samples early in the
                                                % CP: all paths then have positive delays
guardRows = mod(lp + (-lmax:lmax), M) + 1;
isData = true(M, N);  isData(guardRows, :) = false;
nData = nnz(isData);
xp = sqrt(0.25 * nData);                        % pilot amplitude: a quarter of the data energy
rng(3);  bits = randi([0 1], 2 * nData, 1);
X = zeros(M, N);
X(isData) = pskmod(bits, 4, pi/4, "gray", InputType="bit");
X(lp + 1, kp + 1) = xp;
s = reshape(ifft(X, [], 2) * sqrt(N), [], 1);   % delay-Doppler -> time: inverse FFT along Doppler
MN = M * N;
if emulateChannel                               % circular in the block, as after removing the CP
    n = (0:MN - 1)';  sc = zeros(MN, 1);
    for i = 1:size(paths, 1)
        sc = sc + paths(i, 2) * exp(2j * pi * paths(i, 3) * (n - paths(i, 1)) / MN) .* circshift(s, paths(i, 1));
    end
else
    sc = s;
end
zc = zadoffChuSeq(25, 127);
pre = [zc; zc] * rms(sc);                       % two equal halves: timing and frequency offset
frame = [pre; sc(end - Lcp + 1:end); sc];
P = numel(frame);                               % 2318 symbols per frame
rrc = rcosdesign(0.2, 12, sps);                 % root raised cosine, roll-off 0.2, 12 symbols
x = upfirdn(repmat(frame, 3, 1), rrc * sps, sps);   % three frames: the middle one is periodic
x = x((numel(rrc) - 1) / 2 + P * sps + (1:P * sps));   % (filter delay: half its length)
x = 0.7 * x / max(abs(x));
papr = 10 * log10(max(abs(sc)) ^ 2 / mean(abs(sc) .^ 2));

%% boards
if ~exist("gainMode", "var")                        % set by run_agc.m
    gainMode = "manual";                            % "manual": the fixed gain; "agc": agcMode / agcParams
end
clear tx rx
tx = glidelink.Radio(txHost);  rx = glidelink.Radio(rxHost);
tx.config(Rate=sps * fs, Freq=fc, Bandwidth=sps * fs, TxAtten=txAtten);
rx.config(Rate=sps * fs, RxFreq=fc, TxFreq=fc + 10e6, Bandwidth=sps * fs);   % RX board's TX LO away
if gainMode == "agc"
    agcSaved = glidelink.agcSetup(rx, agcMode, agcParams);
else
    rx.config(RxGainMode="manual", RxGain=rxGain);
end
tx.txCyclic(x);  pause(0.5);
y = rx.rx(round(0.1 * sps * fs));               % 0.1 s: about 43 frames
sr = rx.config();
tx.txStop();
if exist("agcSaved", "var")
    glidelink.agcRestore(rx, agcSaved);  clear agcSaved
end
clear tx rx

%% receiver
yr = y - mean(y);                               % at sps * fs
ym = filter(rrc, 1, yr);                        % matched filter
best = 0;                                       % the sampling phase with the higher preamble peak
for ph = 1:sps
    yd = ym(ph:sps:end);
    cd = abs(filter(flipud(conj(pre)), 1, yd));
    if max(cd(1:2 * P)) > best
        best = max(cd(1:2 * P));  y = yd;  c = cd;
    end
end
[~, e0] = max(c(1:P));
starts = (e0 - numel(pre) + 1):P:(numel(y) - P + 1);
nFrames = 0;  nErr = 0;  nBits = 0;  eqAll = [];  oneTap = [];  cfos = [];  snrs = [];  Hdd = 0;
for st = starts
    w = max(1, st + numel(pre) - 4):min(numel(c), st + numel(pre) + 2);   % refine on the peak
    [~, m] = max(c(w));  st = w(m) - numel(pre) + 1; %#ok<FXSET>
    if st < 1 || st + P - 1 > numel(y)
        continue
    end
    seg = y(st:st + P - 1);
    p1 = seg(1:127);  p2 = seg(128:254);        % frequency offset from the two preamble halves
    cfo = angle(sum(conj(p1) .* p2)) / (2 * pi * 127) * fs;
    seg = seg .* exp(-2j * pi * cfo * (0:P - 1)' / fs);
    r = seg(numel(pre) + Lcp - backoff + (1:MN));   % the block, started backoff samples early
    Y = fft(reshape(r, M, N), [], 2) / sqrt(N);  % time -> delay-Doppler
    % noise from the guard rows just before the pilot: the data below the guard moves up by the path
    % delays (up to lp - 3 with backoff 3 and 5 samples of delay), the pilot response starts at lp + 2
    nv = mean(abs(Y(mod(lp + (-2:1), M) + 1, :)) .^ 2, "all");
    win = Y(guardRows, :);
    pathRows = guardRows - 1 - lp >= 0;          % paths: delays 0 .. lmax from the pilot
    [li, ki] = find(abs(win) > max(4 * sqrt(nv), max(abs(win(:))) * 10 ^ (-30 / 20)) & pathRows');
    dl = guardRows(li)' - 1 - lp;  dk = mod(ki - 1 - kp + N / 2, N) - N / 2;
    h = win(sub2ind(size(win), li, ki)) ./ (xp * exp(2j * pi * dk * lp / MN));
    Hdd = Hdd + abs(win) .^ 2;
    % time-domain channel: r[n] = sum_i h_i exp(j 2 pi k_i (n - l_i) / MN) s[n - l_i]
    n = (0:MN - 1)';  I = [];  J = [];  V = [];
    for i = 1:numel(h)
        I = [I; n + 1]; %#ok<AGROW>
        J = [J; mod(n - dl(i), MN) + 1]; %#ok<AGROW>
        V = [V; h(i) * exp(2j * pi * dk(i) * (n - dl(i)) / MN)]; %#ok<AGROW>
    end
    H = sparse(I, J, V, MN, MN);
    Es = (nData + xp ^ 2) / MN;                 % mean symbol energy per sample
    sh = (H' * H + nv / Es * speye(MN)) \ (H' * r);
    Xh = fft(reshape(sh, M, N), [], 2) / sqrt(N);
    [~, i0] = max(abs(h));
    X1 = Y / h(i0);                             % single tap: the strongest path only
    X1 = circshift(X1, [-dl(i0), -dk(i0)]);
    d = Xh(isData);
    rxBits = pskdemod(d, 4, pi/4, "gray", OutputType="bit");
    nFrames = nFrames + 1;  nErr = nErr + sum(rxBits ~= bits);  nBits = nBits + numel(bits);
    eqAll = [eqAll; d]; %#ok<AGROW>
    oneTap = [oneTap; X1(isData)]; %#ok<AGROW>
    cfos(end + 1) = cfo; %#ok<SAGROW>
    snrs(end + 1) = 10 * log10(abs(h(i0)) ^ 2 / nv); %#ok<SAGROW>
end
ref = X(isData);
evm = 100 * sqrt(mean(abs(eqAll - repmat(ref, nFrames, 1)) .^ 2) / mean(abs(ref) .^ 2));
ber = nErr / max(nBits, 1);
fprintf("OTFS %dx%d QPSK: frames %d, bit errors %d of %d (BER %.2e), EVM %.1f %%, SNR %.1f dB, CFO %+.0f Hz, %d paths seen, PAPR %.1f dB\n", ...
    M, N, nFrames, nErr, nBits, ber, evm, mean(snrs), median(cfos), numel(h), papr);
result = struct("name", "OTFS 64x32", "frames", nFrames, "bits", nBits, "errors", nErr, ...
    "metric", sprintf("EVM %.1f %%, SNR %.1f dB, %d paths", evm, mean(snrs), numel(h)));

%% figure
fig = figure(Name="GlideLink OTFS", Color="w", Position=[100 100 1300 800]);
tl = tiledlayout(fig, 2, 3, TileSpacing="compact");
title(tl, sprintf("OTFS %d x %d, QPSK, %g Msymbol/s (radio %g MSPS) at %g MHz, over the air%s", M, N, fs / 1e6, sps * fs / 1e6, fc / 1e6, ...
    string(ifelse(emulateChannel, " (with an emulated 3-path doubly dispersive channel)", ""))));
nexttile;
[pxx, f] = pwelch(yr, hann(1024), 512, 1024, sps * fs, "centered");
plot(f / 1e3, 10 * log10(pxx / max(pxx)), LineWidth=1.2);  grid on;  ylim([-60 3]);
xlabel("Frequency (kHz)");  ylabel("dB");  title("Received spectrum");
nexttile;
k = starts(1) + (0:P - 1);
plot((0:P - 1) / fs * 1e3, abs(y(k)), LineWidth=0.6);  grid on;  xlim([0 P / fs * 1e3]);
xline(numel(pre) / fs * 1e3, ":", "preamble | CP + OTFS block");
xlabel("Time (ms)");  title("|y|, one frame");
nexttile;
dd = 10 * log10(Hdd / max(Hdd(:)));
show = (-2:lmax) + lmax + 1;                    % the clean rows and the path rows of the guard (the
                                                % rows below carry data moved up by the path delays)
imagesc(-N / 2:N / 2 - 1, (-2:lmax) - backoff, circshift(dd(show, :), [0, N / 2 - kp]));
axis xy;  clim([-30 0]);  colorbar;  hold on;
if emulateChannel
    plot(paths(:, 3), paths(:, 1), "wo", MarkerSize=12, LineWidth=1.2);
end
xlabel("Doppler (bins of 488 Hz)");  ylabel("Delay (samples of 1 us)");
title("Delay-Doppler channel (pilot response, dB)");
nexttile;
plot(real(oneTap(1:min(end, 20000))), imag(oneTap(1:min(end, 20000))), ".", MarkerSize=3);
axis equal;  grid on;  xlim([-2 2]);  ylim([-2 2]);  title("Single-tap correction (strongest path)");
nexttile;
plot(real(eqAll(1:min(end, 20000))), imag(eqAll(1:min(end, 20000))), ".", MarkerSize=3);
axis equal;  grid on;  xlim([-2 2]);  ylim([-2 2]);  title("Delay-Doppler equalisation (LMMSE)");
nexttile;  axis off;
text(0, 0.9, sprintf("Frames: %d", nFrames), FontSize=13);
text(0, 0.75, sprintf("Bit errors: %d of %d", nErr, nBits), FontSize=13);
text(0, 0.6, sprintf("EVM: %.1f %%", evm), FontSize=13);
text(0, 0.45, sprintf("SNR (strongest path): %.1f dB", mean(snrs)), FontSize=13);
text(0, 0.3, sprintf("Frequency offset: %+.0f Hz", median(cfos)), FontSize=13);
text(0, 0.15, sprintf("Paths above threshold: %d", numel(h)), FontSize=13);
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_otfs.png"));
end

function o = ifelse(c, a, b)
if c, o = a; else, o = b; end
end
