%TIMED_BURSTS Bursts sent at exact hardware times by the TX board, received by the RX board.
%
% The TX board queues 20 short bursts (Zadoff-Chu, 127 samples, 2 MSPS) at its hardware time
% T0 + k * 10 ms: txBurst returns once a burst is queued, the shell sends it when its sample
% counter reaches the time. The RX board captures the whole sequence; MATLAB finds each burst with
% a matched filter (sub-sample peak) and compares the spacing with 10 ms: the spread shows the
% timing precision, the mean the sample-clock offset between the two boards (ppm).

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
fs = 2e6;  fc = 915e6;  txAtten = 30;  rxGain = 40;
nb = 20;  spacing = 10e-3;

%% burst
zc = zadoffChuSeq(25, 127);
x = 0.7 * zc;

%% boards
clear tx rx
tx = glidelink.Radio(txHost);  rx = glidelink.Radio(rxHost);
tx.config(Rate=fs, Freq=fc, Bandwidth=fs, TxAtten=txAtten);
rx.config(Rate=fs, Freq=fc, Bandwidth=fs, RxGain=rxGain);
t0 = tx.time() + (0.2 + 0.03 * nb) * 1e9;             % ns, TX board clock: after the queueing
                                                      % (each MATLAB request takes ~15 ms)
for k = 0:nb - 1
    tx.txBurst(x, [], t0 + k * spacing * 1e9);        % queued, returns at once
end
y = rx.rx(round((0.6 + nb * spacing) * fs));          % starts before t0, ends after the last burst
clear tx rx

%% receiver: matched filter, peaks with sub-sample interpolation
c = abs(conv(y, flipud(conj(zc)), "valid"));
thr = max(0.5 * max(c), 10 * median(c));             % well above the correlation noise floor
pk = [];
k = 1;
while k <= numel(c)
    if c(k) > thr
        w = k:min(k + 200, numel(c));
        [~, m] = max(c(w));  m = w(m);
        if m > 1 && m < numel(c)
            d = 0.5 * (c(m - 1) - c(m + 1)) / (c(m - 1) - 2 * c(m) + c(m + 1));   % parabola vertex
        else
            d = 0;
        end
        pk(end + 1) = m + d; %#ok<AGROW>
        k = m + 0.5 * spacing * fs;
    else
        k = k + 1;
    end
end
dt = diff(pk) - spacing * fs;                          % samples
ppm = mean(dt) / (spacing * fs) * 1e6;
fprintf("timed bursts: %d of %d received, spacing error mean %+.3f samples (%+.2f ppm), std %.3f samples (%.1f ns)\n", ...
    numel(pk), nb, mean(dt), ppm, std(dt), std(dt) / fs * 1e9);
result = struct("name", "Timed bursts", "frames", numel(pk), "bits", NaN, "errors", nb - numel(pk), ...
    "metric", sprintf("spacing std %.3f samples, clock offset %+.2f ppm", std(dt), ppm));

%% figure
fig = figure(Name="GlideLink timed bursts", Color="w", Position=[100 100 1200 750]);
tl = tiledlayout(fig, 2, 2, TileSpacing="compact");
title(tl, sprintf("%d bursts at TX hardware time T0 + k x %g ms, %g MSPS, over the air", nb, spacing * 1e3, fs / 1e6));
nexttile([1 2]);
t = (0:numel(y) - 1) / fs * 1e3;
plot(t, abs(y), LineWidth=0.6);  grid on;  hold on;
plot((pk - 1) / fs * 1e3, abs(y(round(pk))) * 0 + 0.05 + max(abs(y)), "v", MarkerSize=6);
xlabel("RX time (ms)");  title("|x| of the RX capture: bursts every 10 ms");
nexttile;
bar(1:numel(dt), dt);  grid on;
xlabel("Burst pair");  ylabel("samples");  title("Spacing - 10 ms");
nexttile;  axis off;
text(0, 0.8, sprintf("Bursts received: %d of %d", numel(pk), nb), FontSize=14);
text(0, 0.6, sprintf("Spacing spread (std): %.3f samples = %.0f ns", std(dt), std(dt) / fs * 1e9), FontSize=14);
text(0, 0.4, sprintf("Sample clock offset TX vs RX: %+.2f ppm", ppm), FontSize=14);
text(0, 0.2, "TX: txBurst(x, [], t) per burst, queued ahead", FontSize=12);
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_timed_bursts.png"));
end
