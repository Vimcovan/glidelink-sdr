%OFFICIAL_FM The MathWorks example "FM Demodulation and Spectrum Analysis with USRP Radio" on a
% GlideLink board (receive only).
%
% The example's two acquisitions, with its processing: wideband (20 MSPS, the whole FM band, Welch
% spectrum in dBFS, the 6 strongest peaks) and narrowband (one station through
% comm.FMBroadcastDemodulator: 75 kHz deviation, stereo, 48 kHz audio). Ours instead of
% comm.SDRuReceiver: glidelink.Radio; the RX board captures contiguously, then the samples go
% through the same processing (the example's loop runs the analyzer and the demodulator frame by
% frame on the stream).
% Changes: the wideband centre 98 MHz (88-108 MHz) becomes fcWide below (90 MHz: 81-99 MHz, most of
% the Japanese band 76-95 MHz and its wide-FM part 90-95 MHz); narrowband 500 kSPS becomes 960 kSPS
% (the GlideLink AD9361 path starts at 0.52 MSPS; 20 x the 48 kHz audio rate). The station is the
% strongest 200 kHz wide hump of the spectrum: the 6 peaks of the example's peak finder are shown,
% but on these boards narrow spurs (a comb from digital circuits) are among the highest.
% The boards' 915 MHz antennas are far from resonant at 100 MHz: off the air only strong stations
% come through, and weakly. So the narrowband part can also take its signal from the TX board
% (source = "boards"): an FM stereo broadcast made with comm.FMBroadcastModulator at 915 MHz,
% left channel music (handel), right channel a 1 kHz tone, and the demodulated audio is compared with
% what was sent (SNR, channel separation). The audio is written to a WAV file and played when MATLAB
% has a desktop.

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
if ~exist("source", "var")
    source = "boards";   % "boards": the TX board broadcasts at 915 MHz; "air": the strongest station
end
fcWide = 90e6;  fsWide = 20e6;  rxGain = 71;  audioSeconds = 6;
fsNarrow = 960e3;

%% wideband: the FM band and its strongest stations
clear rx
rx = glidelink.Radio(rxHost);
rx.config(Rate=fsWide, RxFreq=fcWide, TxFreq=915e6, Bandwidth=18e6, RxGainMode="manual", RxGain=rxGain);
                                                      % (TX LO away: it would leak in)
pause(0.3);
y = rx.rx(65536 * 32);                                % 32 of the example's frames
[pw, fw] = pwelch(y, hann(4096), 2048, 4096, fsWide, "centered");
pdB = 10 * log10(pw * fsWide / 4096);                % power per bin, dBFS (full scale 1)
inBand = abs(fw) < 9e6 & abs(fw) > 30e3;             % inside the analog filter, not the DC bin
[pk, loc] = findpeaks(pdB .* inBand + -200 * ~inBand, MinPeakProminence=8, MinPeakDistance=40, ...
    SortStr="descend", NPeaks=6);
stations = (fw(loc) + fcWide);
fprintf("Strongest peaks: %s MHz\n", join(compose("%.2f", stations' / 1e6), ", "));
% the station: the strongest wide signal (a 200 kHz running median keeps an FM station, not a line)
[pw2, fw2] = pwelch(y, hann(2048), 1024, 2048, fsWide, "centered");
smooth = movmedian(10 * log10(pw2), 21);
in2 = abs(fw2) < 9e6 & abs(fw2) > 200e3;
[~, i2] = max(smooth .* in2 - 200 * ~in2);
fc = round((fw2(i2) + fcWide) / 100e3) * 100e3;       % FM channels are on a 100 kHz raster
fprintf("Strongest wide (FM) signal: %.1f MHz\n", fc / 1e6);
if exist("station", "var")                            % or a station given before running the script
    fc = station;
end

%% narrowband: demodulate the strongest station, or the TX board's broadcast
if source == "boards"
    load handel y Fs                                  % music for the left channel (MATLAB's)
    t = (0:3 * 48e3 - 1)' / 48e3;                     % 3 s of 48 kHz audio
    left = resample(y, 48e3, Fs);  left = 0.8 * left(1:numel(t)) / max(abs(left));
    right = 0.5 * sin(2 * pi * 1e3 * t);              % a 1 kHz tone on the right
    fmModulate = comm.FMBroadcastModulator(AudioSampleRate=48e3, SampleRate=fsNarrow, ...
        FrequencyDeviation=75e3, Stereo=true);
    x = 0.7 * fmModulate([left right]);
    fc = 915e6;
    tx = glidelink.Radio(txHost);
    tx.config(Rate=fsNarrow, Freq=fc, Bandwidth=fsNarrow, TxAtten=40);
    tx.txCyclic(x);
    rx.config(Rate=fsNarrow, RxFreq=fc, TxFreq=fc + 10e6, Bandwidth=fsNarrow, RxGain=30);
else
    rx.config(Rate=fsNarrow, RxFreq=fc, Bandwidth=fsNarrow);
end
pause(0.5);
iq = rx.rx(round(audioSeconds * fsNarrow));
if source == "boards"
    tx.txStop();
end
clear rx tx
fmDemodulate = comm.FMBroadcastDemodulator(SampleRate=fsNarrow, FrequencyDeviation=75e3, ...
    PlaySound=false, Stereo=true, AudioSampleRate=48e3);
frame = 9600;                                         % 10 ms of samples per call
audio = [];
for k = 1:floor(numel(iq) / frame)
    audio = [audio; fmDemodulate(iq((k - 1) * frame + (1:frame)))]; %#ok<AGROW>
end
audio = audio / max(abs(audio(:))) * 0.9;
wav = fullfile(tempdir, sprintf("glidelink_fm_%.1fMHz.wav", fc / 1e6));
audiowrite(wav, audio, 48e3);
% the stereo pilot (19 kHz in the multiplex) shows a stereo broadcast
mpx = angle(iq(2:end) .* conj(iq(1:end - 1)));
[pm, fm] = pwelch(mpx, hann(8192), 4096, 8192, fsNarrow);
pilot = 10 * log10(max(pm(abs(fm - 19e3) < 200)) / median(pm(fm > 20e3 & fm < 50e3)));
fprintf("%.1f MHz: %.1f s of audio -> %s (stereo pilot %.0f dB above the multiplex floor)\n", ...
    fc / 1e6, size(audio, 1) / 48e3, wav, pilot);
metric = sprintf("%.1f MHz, pilot %.0f dB", fc / 1e6, pilot);
if source == "boards"
    % the demodulated audio against what was sent: delay from the left channel, then the SNR of the
    % left channel and how much of the right channel's 1 kHz tone leaks into the left. The left
    % channel goes through the demodulator's audio filters: fitted by 32 taps (least squares; without
    % the radio this gives 41.6 dB), per 0.5 s, median: the cyclic 3 s broadcast clicks where it
    % wraps, in one of the segments
    n = 2 * 48e3;  a = audio(48e3 + (1:n), :);       % 2 s after the first second (settled)
    [c, lags] = xcorr(a(:, 1), repmat(left, 2, 1), numel(left));
    [~, i] = max(abs(c));  d = lags(i);
    ref = repmat(left, 3, 1);  L = 32;  m = n / 4;  snrs = zeros(1, 4);
    for s0 = 0:3
        R = zeros(m, L);                              % a(k) = left(k - d) through the filters
        for k = 1:L
            R(:, k) = ref(mod(-d, numel(left)) + s0 * m + (1:m) - k + L / 2 + 1);
        end
        e = a(s0 * m + (1:m), 1);  h = R \ e;
        snrs(s0 + 1) = 10 * log10(sum((R * h) .^ 2) / sum((e - R * h) .^ 2));
    end
    snrL = median(snrs);
    tone = @(v) abs(sum(v .* exp(-2j * pi * 1e3 * (0:n - 1)' / 48e3)));
    sep = 20 * log10(tone(a(:, 2)) / tone(a(:, 1)));
    metric = sprintf("%s, left SNR %.1f dB, separation %.0f dB", metric, snrL, sep);
end
disp(metric);
result = struct("name", "official FM (" + source + ")", "frames", numel(stations), "bits", NaN, ...
    "errors", 0, "metric", metric);
if usejava("desktop")
    sound(audio, 48e3);
end

%% figure
fig = figure(Name="MathWorks FM example on GlideLink", Color="w", Position=[100 100 1300 450]);
tl = tiledlayout(fig, 1, 3, TileSpacing="compact");
title(tl, sprintf("FM broadcast (MathWorks USRP example) on GlideLink, %.1f MHz demodulated (%s)", fc / 1e6, source));
nexttile;
plot((fw + fcWide) / 1e6, pdB, LineWidth=1);  grid on;  hold on;
plot(stations / 1e6, pk, "v", MarkerFaceColor="auto");
text(stations / 1e6, pk + 2, compose("%.1f", stations / 1e6), HorizontalAlignment="center", FontSize=8);
xlim((fcWide + [-9e6 9e6]) / 1e6);
xlabel("Frequency (MHz)");  ylabel("dBFS per bin");  title(sprintf("Wideband, %g MSPS", fsWide / 1e6));
nexttile;
[pn, fn] = pwelch(iq, hann(2048), 1024, 2048, fsNarrow, "centered");
plot((fn + fc) / 1e6, 10 * log10(pn / max(pn)), LineWidth=1);  grid on;  ylim([-70 3]);
xlabel("Frequency (MHz)");  ylabel("dB");  title(sprintf("Narrowband, %g kSPS", fsNarrow / 1e3));
nexttile;
plot(fm / 1e3, 10 * log10(pm / max(pm)), LineWidth=1);  grid on;  xlim([0 60]);
xline([19 38], ":", ["pilot" "L-R"]);
xlabel("Frequency (kHz)");  ylabel("dB");  title("Demodulated multiplex (mono, pilot, stereo)");
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_official_fm.png"));
end
