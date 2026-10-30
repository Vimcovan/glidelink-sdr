%AGC_MODES Fixed gain, slow AGC and fast AGC of the AD9361 on the same bursty signal, over the air.
%
% The TX board repeats four 2 ms bursts (noise-like, 1 MHz wide) about 14 dB apart in power, with
% 0.5 to 2 ms of silence between them; each period starts with a short Zadoff-Chu marker, by which
% the receiver finds the period whatever gain is in use. The RX board receives the pattern with:
%   1 a fixed gain
%   2 the slow-attack AGC                  (driver parameters as they are)
%   3 the fast-attack AGC                  (driver parameters as they are)
%   4 the fast-attack AGC with adi,agc-inner-thresh-high 10 dB higher (lock level 10 dB lower;
%     applied with initialize, the bridge keeps the rate, LOs and bandwidth across it). The levels
%     came out about 15 dB lower, not exactly 10.
% and plots the received level against time for each. What was seen on 2026-10-30 (burst levels
% in dBFS: fixed -40 -29 -15 -29, slow -18 -9 0 -12, fast -32 -25 -10 -24, fast with the lock level
% parameter 10 dB lower -48 -39 -25 -39):
%   fixed gain   the levels follow the TX steps
%   slow AGC     the gain rises during the gaps; the strongest burst reaches full scale
%   fast AGC     the gain is set quickly when a burst starts and then locked: with the driver's
%                parameters it is not raised again while locked, so after the strong burst the weaker
%                ones keep that gain. This is the design of the fast AGC (no gain change inside a
%                packet); how it behaves is set by its parameters, e.g.
%                  adi,agc-inner-thresh-high                          lock level (dB below full scale)
%                  adi,fagc-allow-agc-gain-increase-enable            raise the gain while locked
%                  adi,fagc-rst-gla-engergy-lost-sig-thresh-below-ll  unlock when the signal drops
%                  adi,fagc-rst-gla-stronger-sig-thresh-above-ll      unlock on a stronger signal
%                  adi,fagc-gain-index-type-after-exit-rx-mode        gain to start from after unlock
%                (r.attr(name, value), then r.attr("initialize", 1); see the AD9361 user guide
%                UG-570, "Fast attack AGC"). The script restores every parameter it changes.

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
fs = 2e6;  fc = 915e6;  txAtten = 20;  fixedGain = 45;
burstLen = 2e-3;  gaps = [0.5 1 1.5 2] * 1e-3;  amps = [0.02 0.1 0.5 0.1];   % ~14 dB steps

%% waveform: a marker, then bursts of band-limited noise
rng(4);
nb = round(burstLen * fs);  ng = round(gaps * fs);
lp = designfilt("lowpassfir", FilterOrder=64, CutoffFrequency=0.5e6, SampleRate=fs);
zc = 0.3 * zadoffChuSeq(29, 255);                    % period marker
x = [zc; zeros(round(0.5e-3 * fs), 1)];  starts = zeros(1, 4);
for i = 1:4
    b = filter(lp, complex(randn(nb + 64, 1), randn(nb + 64, 1)));  b = b(65:end);
    b = amps(i) * b / rms(b) / 3;                    % rms a/3: peaks stay below a
    starts(i) = numel(x);
    x = [x; b; zeros(ng(i), 1)]; %#ok<AGROW>
end
period = numel(x);

%% boards
clear tx rx
tx = glidelink.Radio(txHost);  rx = glidelink.Radio(rxHost);
tx.config(Rate=fs, Freq=fc, Bandwidth=fs, TxAtten=txAtten);
rx.config(Rate=fs, Freq=fc, Bandwidth=fs);
lock0 = str2double(rx.attr("adi,agc-inner-thresh-high"));     % the driver's value, restored at the end
tx.txCyclic(x);
cases = ["Fixed gain " + fixedGain + " dB", "Slow AGC", ...
    "Fast AGC, lock level -" + lock0 + " dBFS", "Fast AGC, lock level -" + (lock0 + 10) + " dBFS"];
nc = numel(cases);
lvl = cell(1, nc);  caps = cell(1, nc);
for c = 1:nc
    switch c
        case 1, rx.config(RxGain=fixedGain);
        case 2, rx.config(RxGainMode="slow_attack");
        case 3, rx.config(RxGainMode="fast_attack");
        case 4
            rx.attr("adi,agc-inner-thresh-high", lock0 + 10);  rx.attr("initialize", 1);
            rx.config(RxGainMode="fast_attack");
    end
    pause(1);                                        % the AGC follows the repeating pattern
    caps{c} = rx.rx(round(0.1 * fs));
end
rx.attr("adi,agc-inner-thresh-high", lock0);  rx.attr("initialize", 1);
tx.txStop();
clear tx rx

%% levels: the period starts at the marker (correlation peak), level per burst (middle half)
for c = 1:nc
    y = caps{c};
    m = abs(conv(y(1:2 * period), flipud(conj(zc)), "valid"));
    [~, k0] = max(m(1:period));
    caps{c} = y(k0:k0 + 2 * period - 1);
    for b = 1:4
        mid = caps{c}(starts(b) + round(nb / 4) + (1:round(nb / 2)));
        lvl{c}(b) = 10 * log10(mean(abs(mid) .^ 2));
    end
    fprintf("%-34s burst levels (dBFS): %s\n", cases(c), sprintf("%6.1f ", lvl{c}));
end
txSteps = 20 * log10(amps / amps(1));
result = struct("name", "AGC modes", "frames", nc, "bits", NaN, "errors", 0, ...
    "metric", sprintf("burst levels: fixed %s, slow %s, fast %s dBFS", mat2str(round(lvl{1})), ...
    mat2str(round(lvl{2})), mat2str(round(lvl{3}))));

%% figure
fig = figure(Name="GlideLink AGC modes", Color="w", Position=[100 60 1200 900]);
tl = tiledlayout(fig, nc, 1, TileSpacing="compact");
title(tl, sprintf("Same bursts (TX steps %s dB) received with four gain settings, %g MSPS", ...
    mat2str(round(txSteps)), fs / 1e6));
t = (0:2 * period - 1) / fs * 1e3;
for c = 1:nc
    nexttile;
    e = 10 * log10(movmean(abs(caps{c}) .^ 2, round(20e-6 * fs)) + 1e-12);
    plot(t, e, LineWidth=1);  grid on;  ylim([-70 3]);  xlim([0 t(end)]);  hold on;
    for edge = [starts, starts + nb, starts + period, starts + nb + period]   % where the bursts are
        xline(edge / fs * 1e3, ":", Color=[0.5 0.5 0.5]);
    end
    ylabel("dBFS");
    title(sprintf("%s:  burst levels %s dBFS", cases(c), sprintf("%.0f ", lvl{c})), FontWeight="normal");
end
xlabel(tl, "Time (ms), two periods of the pattern (dotted: burst start / end)");
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_agc_modes.png"));
end
