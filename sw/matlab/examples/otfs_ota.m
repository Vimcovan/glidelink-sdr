%OTFS_OTA Orthogonal time frequency space (OTFS) modulation over the air between the two GlideLink
% boards.
%
% QPSK symbols are placed on a delay-Doppler grid of M delay bins x N Doppler bins (64 x 32 at
% 1 Msymbol/s: 1 us delay and 488 Hz Doppler resolution, 2.048 ms per block) and turned into one
% block of M N symbols with one cyclic prefix (the inverse FFT along Doppler). The block is sent
% with root raised cosine pulses (4 samples each, the radio at 4 MSPS) and matched-filtered on
% receive; the best of the 4 sampling phases is taken from the preamble correlation. Each frame
% starts with a preamble of two equal Zadoff-Chu sequences: frame timing and the frequency offset
% (corrected before the delay-Doppler processing).
% An embedded pilot sits in the middle of the grid with empty guard rows around it in delay (all
% Doppler bins): received, it spreads into the channel's delay-Doppler response. Paths are not on
% the grid: the receiver takes the strongest peak of the pilot response, fits its delay and Doppler
% (least squares, fractional values) and removes it, then the next (successive cancellation). It
% does this on the first frame; on every frame it refits the complex path gains (linear least
% squares), builds the time-domain channel matrix (each path: its gain, its Doppler phase per
% sample and the raised cosine pulse at its fractional delay) and equalises the block (LMMSE).
% Two boards on a desk have a single path and almost no Doppler, so the TX side can pass the
% signal through a synthetic doubly dispersive channel first (emulateChannel = true: three paths
% with fractional delays and Doppler shifts, below), simulated at the radio's sample rate on the
% whole transmitted signal (preamble included): delays as exact fractional delays of the periodic
% signal, Doppler as a frequency shift that runs on from frame to frame. The cyclic transmit buffer
% holds 40 frames; for it to repeat seamlessly a Doppler shift is a multiple of 4 MSPS / its length
% (10.8 Hz), far finer than the 488 Hz grid. OTA the signal then also sees the real channel.
% Shown: the delay-Doppler pilot response with the fitted paths, the fitted paths against the
% emulated ones (relative to the strongest), and the constellation after a single-tap correction
% (strongest path only) and after the delay-Doppler equalisation.

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
fs = 1e6;  sps = 4;  fc = 915e6;  txAtten = 20;  rxGain = 40;   % fs: delay-Doppler (symbol) rate
M = 64;  N = 32;  Lcp = 16;                     % delay bins, Doppler bins, cyclic prefix (symbols)
if ~exist("emulateChannel", "var")
    emulateChannel = true;                      % false: the over-the-air channel only
end
paths = [0    1.0    0     0                    % emulated paths: delay (us), gain, Doppler (Hz),
         1.7  0.6  1260    1.0                  %   phase (rad)
         4.3  0.45 -690   -2.0];

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
lp = M / 2;  kp = N / 2;  lmax = 16;            % pilot (0-based delay, Doppler); guard rows lp +- lmax
backoff = 6;                                    % the receiver starts the block 6 symbols early in the
                                                % CP: the paths and their pulse tails have positive delays
beta = 0.2;  span = 12;                         % root raised cosine: roll-off, length in symbols
guardRows = mod(lp + (-lmax:lmax), M) + 1;
isData = true(M, N);  isData(guardRows, :) = false;
nData = nnz(isData);
xp = sqrt(0.25 * nData);                        % pilot amplitude: a quarter of the data energy
rng(3);  bits = randi([0 1], 2 * nData, 1);
X = zeros(M, N);
X(isData) = pskmod(bits, 4, pi/4, "gray", InputType="bit");
X(lp + 1, kp + 1) = xp;
MN = M * N;
s = reshape(ifft(X, [], 2) * sqrt(N), [], 1);   % delay-Doppler -> time: inverse FFT along Doppler
zc = zadoffChuSeq(25, 127);
pre = [zc; zc] * rms(s);                        % two equal halves: timing and frequency offset
frame = [pre; s(end - Lcp + 1:end); s];
P = numel(frame);                               % 2318 symbols per frame
rrc = rcosdesign(beta, span, sps);
x = upfirdn(repmat(frame, 3, 1), rrc * sps, sps);   % three frames: the middle one is periodic
x = x((numel(rrc) - 1) / 2 + P * sps + (1:P * sps));   % (filter delay: half its length)
F = 40;  fsr = sps * fs;
x = repmat(x, F, 1);  L = numel(x);             % the cyclic transmit buffer: 40 frames
nuEmu = round(paths(:, 3) * L / fsr) * fsr / L; % Doppler on the buffer's frequency grid (10.8 Hz)
if emulateChannel
    f = [0:ceil(L / 2) - 1, -floor(L / 2):-1]' / L * fsr;
    Xf = fft(x);  t = (0:L - 1)' / fsr;  xe = zeros(L, 1);
    for i = 1:size(paths, 1)                    % exact fractional delay of the periodic signal, then
        xe = xe + paths(i, 2) * exp(1j * paths(i, 4)) * exp(2j * pi * nuEmu(i) * t) .* ...
            ifft(Xf .* exp(-2j * pi * f * paths(i, 1) * 1e-6));   % the Doppler shift
    end
    x = xe;
end
x = 0.7 * x / max(abs(x));
papr = 10 * log10(max(abs(s)) ^ 2 / mean(abs(s) .^ 2));

%% boards
if ~exist("gainMode", "var")                        % set by run_agc.m
    gainMode = "manual";                            % "manual": the fixed gain; "agc": agcMode / agcParams
end
clear tx rx
tx = glidelink.Radio(txHost);  rx = glidelink.Radio(rxHost);
tx.config(Rate=fsr, Freq=fc, Bandwidth=fsr, TxAtten=txAtten);
rx.config(Rate=fsr, RxFreq=fc, TxFreq=fc + 10e6, Bandwidth=fsr);   % RX board's TX LO away
if gainMode == "agc"
    agcSaved = glidelink.agcSetup(rx, agcMode, agcParams);
else
    rx.config(RxGainMode="manual", RxGain=rxGain);
end
tx.txCyclic(x);  pause(0.5);
y = rx.rx(round(0.1 * fsr));                    % 0.1 s: about 43 frames
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
% frame starts and one frequency offset for all frames: with several paths of different Doppler the
% preamble gives a mix of them that changes from frame to frame (the paths' phases rotate); one
% correction keeps every path at the same Doppler in every frame
for i = 1:numel(starts)
    w = max(1, starts(i) + numel(pre) - 4):min(numel(c), starts(i) + numel(pre) + 2);
    [~, m] = max(c(w));  starts(i) = w(m) - numel(pre) + 1;
end
starts = starts(starts >= 1 & starts + P - 1 <= numel(y));
cfos = zeros(size(starts));
for i = 1:numel(starts)
    p1 = y(starts(i) + (0:126));  p2 = y(starts(i) + (127:253));
    cfos(i) = angle(sum(conj(p1) .* p2)) / (2 * pi * 127) * fs;
end
cfo = median(cfos);
winRows = mod(lp + (2:lmax), M) + 1;            % the pilot response: delays 2 .. lmax
noiseRows = mod(lp + (-3:1), M) + 1;            % empty: the data below the guard reaches about lp - 4
Xp = zeros(M, N);  Xp(lp + 1, kp + 1) = xp;
sp = reshape(ifft(Xp, [], 2) * sqrt(N), [], 1); % the pilot alone, in time
model = @(tau, nub) pathMatrix(tau, nub / MN, MN, beta);   % delay in symbols, Doppler in bins
resp = @(tau, nub) pilotResponse(model(tau, nub), sp, M, N, winRows);
fit = [];                                       % fitted paths: delay (symbols), Doppler (bins)
nFrames = 0;  nErr = 0;  nBits = 0;  eqAll = [];  oneTap = [];  snrs = [];  Hdd = 0;
for st = starts
    seg = y(st:st + P - 1) .* exp(-2j * pi * cfo * (st - 1 + (0:P - 1)') / fs);
    r = seg(numel(pre) + Lcp - backoff + (1:MN));   % the block, started backoff symbols early
    Y = fft(reshape(r, M, N), [], 2) / sqrt(N);  % time -> delay-Doppler
    nv = mean(abs(Y(noiseRows, :)) .^ 2, "all");
    Yw = Y(winRows, :);
    Hdd = Hdd + abs(Yw) .^ 2;
    if isempty(fit)                             % the paths, off the grid: strongest peak, fit its
        R = Yw(:);                              % delay and Doppler, remove it, next
        for p = 1:6
            [pk, idx] = max(abs(R));
            if pk < 6 * sqrt(nv)
                break
            end
            [ri, ci] = ind2sub(size(Yw), idx);
            q0 = [ri + 1, mod(ci - 1 - kp + N / 2, N) - N / 2];   % the peak's bin
            cost = @(q) fitCost(resp(q(1), q(2)), R);
            [du, dv] = ndgrid(-0.5:0.1:0.5);    % coarse: +-0.5 bin in delay and Doppler
            e = arrayfun(@(a, b) cost(q0 + [a b]), du, dv);
            [~, k] = min(e(:));
            qc = q0 + [du(k) dv(k)];            % fine: least squares from there (the search runs on
            v = fminsearch(@(v) cost(qc + v - 1), [1 1], optimset(TolX=1e-3, Display="off"));
            q = qc + v - 1;                     % v = 1 + offset: its first steps are 0.05 bin)
            b = resp(q(1), q(2));
            R = R - (b' * R) / (b' * b) * b;
            fit(end + 1, :) = q; %#ok<SAGROW>
        end
        Hi = cell(1, size(fit, 1));  B = zeros(numel(Yw), size(fit, 1));
        for i = 1:size(fit, 1)
            Hi{i} = model(fit(i, 1), fit(i, 2));
            B(:, i) = pilotResponse(Hi{i}, sp, M, N, winRows);
        end
    end
    h = B \ Yw(:);                              % this frame's path gains (least squares)
    H = sparse(MN, MN);
    for i = 1:numel(h)
        H = H + h(i) * Hi{i};
    end
    Es = (nData + xp ^ 2) / MN;                 % mean symbol energy per sample
    sh = (H' * H + nv / Es * speye(MN)) \ (H' * r);
    Xh = fft(reshape(sh, M, N), [], 2) / sqrt(N);
    [~, i0] = max(abs(h));                      % single tap: the strongest path only, nearest bin
    g0 = h(i0) * xp * exp(2j * pi * fit(i0, 2) * lp / MN);   % (its pilot response peak)
    X1 = circshift(Y, [-round(fit(i0, 1)), -round(fit(i0, 2))]) / (g0 / xp);
    d = Xh(isData);
    rxBits = pskdemod(d, 4, pi/4, "gray", OutputType="bit");
    nFrames = nFrames + 1;  nErr = nErr + sum(rxBits ~= bits);  nBits = nBits + numel(bits);
    eqAll = [eqAll; d]; %#ok<AGROW>
    oneTap = [oneTap; X1(isData)]; %#ok<AGROW>
    snrs(end + 1) = 10 * log10(sum(abs(h) .^ 2) / nv); %#ok<SAGROW>   % per data symbol
end
ref = X(isData);
evm = 100 * sqrt(mean(abs(eqAll - repmat(ref, nFrames, 1)) .^ 2) / mean(abs(ref) .^ 2));
ber = nErr / max(nBits, 1);
% the fitted paths against the emulated ones, both relative to the strongest path
[~, i0] = max(abs(h));
rel = [fit(:, 1) - fit(i0, 1), (fit(:, 2) - fit(i0, 2)) * fs / MN, 20 * log10(abs(h) / abs(h(i0)))];
fprintf("OTFS %dx%d QPSK: frames %d, bit errors %d of %d (BER %.2e), EVM %.1f %%, SNR %.1f dB, CFO %+.0f Hz, PAPR %.1f dB\n", ...
    M, N, nFrames, nErr, nBits, ber, evm, mean(snrs), median(cfos), papr);
fprintf("fitted paths (relative to the strongest): delay (us), Doppler (Hz), power (dB)\n");
fprintf("  %+6.2f us  %+7.0f Hz  %6.1f dB\n", rel');
if emulateChannel
    fprintf("emulated: delay (us), Doppler (Hz), power (dB)\n");
    fprintf("  %+6.2f us  %+7.0f Hz  %6.1f dB\n", [paths(:, 1), nuEmu, 20 * log10(paths(:, 2))]');
end
result = struct("name", "OTFS 64x32", "frames", nFrames, "bits", nBits, "errors", nErr, ...
    "metric", sprintf("EVM %.1f %%, %d paths fitted", evm, size(fit, 1)));

%% figure
fig = figure(Name="GlideLink OTFS", Color="w", Position=[100 100 1300 800]);
tl = tiledlayout(fig, 2, 3, TileSpacing="compact");
title(tl, sprintf("OTFS %d x %d, QPSK, %g Msymbol/s (radio %g MSPS) at %g MHz, over the air%s", M, N, ...
    fs / 1e6, fsr / 1e6, fc / 1e6, string(ifelse(emulateChannel, ...
    " (with an emulated 3-path channel: fractional delays and Doppler)", ""))));
nexttile;
[pxx, fq] = pwelch(yr, hann(1024), 512, 1024, fsr, "centered");
plot(fq / 1e3, 10 * log10(pxx / max(pxx)), LineWidth=1.2);  grid on;  ylim([-60 3]);
xlabel("Frequency (kHz)");  ylabel("dB");  title("Received spectrum");
nexttile;
dd = 10 * log10(Hdd / max(Hdd(:)));
imagesc((-N / 2:N / 2 - 1) * fs / MN, (2:lmax) - backoff, circshift(dd, [0, N / 2 - kp]));
axis xy;  clim([-30 0]);  colorbar;  hold on;
plot(fit(:, 2) * fs / MN, fit(:, 1) - backoff, "wx", MarkerSize=12, LineWidth=1.5);
xlabel("Doppler (Hz)");  ylabel("Delay (us)");  title("Pilot response (dB); x: fitted paths");
nexttile;
plot(rel(:, 2), rel(:, 1), "x", MarkerSize=12, LineWidth=1.5);  hold on;  grid on;
if emulateChannel
    plot(nuEmu - nuEmu(1), paths(:, 1) - paths(1, 1), "o", MarkerSize=12, LineWidth=1.2);
    legend(["fitted", "emulated"], Location="best");
end
xlabel("Doppler (Hz)");  ylabel("Delay (us)");  title("Paths relative to the strongest");
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
text(0, 0.45, sprintf("SNR per data symbol: %.1f dB", mean(snrs)), FontSize=13);
text(0, 0.3, sprintf("Frequency offset: %+.0f Hz", median(cfos)), FontSize=13);
text(0, 0.15, sprintf("Paths fitted: %d", size(fit, 1)), FontSize=13);
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_otfs.png"));
end

function H = pathMatrix(tau, nu, MN, beta)
% one path of unit gain on the block (circular, the cyclic prefix): r[n] = exp(j 2 pi nu n)
% sum_d g(d - tau) s[n - d], g the raised cosine (transmit and receive pulses), nu in cycles/symbol
n = (0:MN - 1)';  d = floor(tau) - 10:ceil(tau) + 10;
[nn, dd] = ndgrid(n, d);
V = exp(2j * pi * nu * nn) .* rcPulse(dd - tau, beta);
H = sparse(nn + 1, mod(nn - dd, MN) + 1, V, MN, MN);
end

function b = pilotResponse(H, sp, M, N, rows)
Yp = fft(reshape(H * sp, M, N), [], 2) / sqrt(N);
b = reshape(Yp(rows, :), [], 1);
end

function e = fitCost(b, R)
e = norm(R - (b' * R) / (b' * b) * b) ^ 2;      % residual after the least-squares gain
end

function g = rcPulse(t, beta)
% raised cosine, t in symbols
g = sinc(t) .* cos(pi * beta * t) ./ (1 - (2 * beta * t) .^ 2);
k = abs(abs(2 * beta * t) - 1) < 1e-9;
g(k) = pi / 4 * sinc(1 / (2 * beta));
end

function o = ifelse(c, a, b)
if c, o = a; else, o = b; end
end
