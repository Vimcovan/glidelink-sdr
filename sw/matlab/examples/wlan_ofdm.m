%WLAN_OFDM 802.11a/g (non-HT) OFDM packets over the air between the two GlideLink boards.
%
% Wideband (20 MSPS, 16.6 MHz occupied), high PAPR (OFDM), bursty: 1000-byte packets, 16-QAM rate
% 3/4 (36 Mbit/s), separated by 100 us of silence. Generated and received with the WLAN Toolbox:
% packet detection, coarse / fine frequency offset, symbol timing on the L-LTF, channel and noise
% estimate from the L-LTF, the L-SIG check (a detection whose L-SIG fails is a false one and is
% skipped), equalisation and decoding of the data field. The RX board captures 50 ms
% at 20 MSPS on the board, then sends it.

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
fc = 915e6;  txAtten = 20;  rxGain = 30;
cfg = wlanNonHTConfig(MCS=4, PSDULength=1000);
fs = wlanSampleRate(cfg);

%% waveform
rng(9);  psdu = randi([0 1], 8 * cfg.PSDULength, 1);
x = wlanWaveformGenerator(psdu, cfg, NumPackets=1, IdleTime=100e-6);
x = 0.9 * x / max(abs(x));
on = abs(x) > 0;
papr = 10 * log10(max(abs(x(on)) .^ 2) / mean(abs(x(on)) .^ 2));

%% boards
clear tx rx
tx = glidelink.Radio(txHost);  rx = glidelink.Radio(rxHost);
tx.config(Rate=fs, Freq=fc, Bandwidth=18e6, TxAtten=txAtten);
rx.config(Rate=fs, Freq=fc, Bandwidth=18e6, RxGain=rxGain);
tx.txCyclic(x);  pause(0.5);
y = rx.rx(round(0.05 * fs));
tx.txStop();
clear tx rx

%% receiver
ind = wlanFieldIndices(cfg);
search = 1;  npkt = 0;  nerr = 0;  nbad = 0;  nfalse = 0;  eqAll = [];  chAll = [];  snrs = [];  cfos = [];
while npkt < 60
    off = wlanPacketDetect(y(search:end), "CBW20");
    if isempty(off)
        break
    end
    pkt = search + off;
    if pkt + double(ind.NonHTData(2)) + 200 > numel(y)
        break
    end
    cfo1 = wlanCoarseCFOEstimate(y(pkt + (ind.LSTF(1):ind.LSTF(2)) - 1), "CBW20");
    tOff = wlanSymbolTimingEstimate(frequencyOffset(y(pkt + (ind.LSTF(1):ind.LSIG(2)) - 1), fs, -cfo1), ...
        "CBW20");                                % the packet starts tOff samples from pkt
    s0 = pkt + tOff;
    search = s0 + double(ind.NonHTData(2));
    if s0 < 1 || s0 + double(ind.NonHTData(2)) - 1 > numel(y)
        continue
    end
    seg = frequencyOffset(y(s0:s0 + double(ind.NonHTData(2)) - 1), fs, -cfo1);
    cfo2 = wlanFineCFOEstimate(seg(ind.LLTF(1):ind.LLTF(2)), "CBW20");
    seg = frequencyOffset(seg, fs, -cfo2);
    lltf = wlanLLTFDemodulate(seg(ind.LLTF(1):ind.LLTF(2)), cfg);
    chEst = wlanLLTFChannelEstimate(lltf, cfg);
    nVar = wlanLLTFNoiseEstimate(lltf);
    [~, sigFail] = wlanLSIGRecover(seg(ind.LSIG(1):ind.LSIG(2)), chEst, nVar, "CBW20");
    if sigFail                                   % parity / rate check of L-SIG failed: a false
        nfalse = nfalse + 1;                     % detection (noise, the middle of a packet):
        search = pkt + 80;                       % look again a little further on
        continue
    end
    [rxPsdu, eqSym] = wlanNonHTDataRecover(seg(ind.NonHTData(1):ind.NonHTData(2)), chEst, nVar, cfg);
    e = sum(rxPsdu ~= psdu);
    npkt = npkt + 1;  nerr = nerr + e;  nbad = nbad + (e > 0);
    eqAll = [eqAll; eqSym(:)]; %#ok<AGROW>
    chAll(:, end + 1) = chEst(:); %#ok<AGROW>
    snrs(end + 1) = 10 * log10(mean(abs(chEst) .^ 2) / nVar); %#ok<AGROW>
    cfos(end + 1, :) = [cfo1 cfo2]; %#ok<AGROW>      % coarse, fine (a false detection gives an outlier)
end
fprintf("802.11a/g 16-QAM 3/4: packets %d, bad %d, bit errors %d of %d, SNR %.1f dB, CFO %+.0f Hz, PAPR %.1f dB, false detections %d\n", ...
    npkt, nbad, nerr, npkt * numel(psdu), mean(snrs), median(sum(cfos, 2)), papr, nfalse);
result = struct("name", "802.11a/g OFDM", "frames", npkt, "bits", npkt * numel(psdu), "errors", nerr, ...
    "metric", sprintf("PER %d/%d, SNR %.1f dB, PAPR %.1f dB", nbad, npkt, mean(snrs), papr));

%% figure
fig = figure(Name="GlideLink 802.11a/g OFDM", Color="w", Position=[100 100 1300 800]);
tl = tiledlayout(fig, 2, 3, TileSpacing="compact");
title(tl, sprintf("802.11a/g OFDM, 16-QAM 3/4 (36 Mbit/s), 20 MSPS at %g MHz, over the air", fc / 1e6));
nexttile;
[pxx, f] = pwelch(y, hann(1024), 512, 1024, fs, "centered");
plot(f / 1e6, 10 * log10(pxx / max(pxx)), LineWidth=1.2);  grid on;  ylim([-60 3]);
xlabel("Frequency (MHz)");  ylabel("dB");  title("Received spectrum");
nexttile;
k = 1:round(1e-3 * fs);
plot(k / fs * 1e3, abs(y(k)), LineWidth=0.8);  grid on;
xlabel("Time (ms)");  title("|x|: packets and idle time (bursts)");
nexttile;
plot(real(eqAll(1:min(end, 20000))), imag(eqAll(1:min(end, 20000))), ".", MarkerSize=3);
axis equal;  grid on;  xlim([-1.5 1.5]);  ylim([-1.5 1.5]);  title("Equalised data subcarriers (16-QAM)");
nexttile;
sc = [-26:-1, 1:26];
plot(sc, 20 * log10(abs(chAll(:, 1:min(end, 20)))), LineWidth=0.8);  grid on;
xlabel("Subcarrier");  ylabel("|H| (dB)");  title("Channel estimate (L-LTF), 20 packets");
nexttile;
ph = unwrap(angle(chAll(:, 1:min(end, 20))));
plot(sc, ph - ph(26, :), LineWidth=0.8);  grid on;   % relative to subcarrier -1: the common phase
xlabel("Subcarrier");  ylabel("rad");  title("Channel phase (relative), 20 packets");  % differs per packet
nexttile;  axis off;
text(0, 0.85, sprintf("Packets decoded: %d", npkt), FontSize=13);
text(0, 0.68, sprintf("Packets with errors: %d", nbad), FontSize=13);
text(0, 0.51, sprintf("Bit errors: %d of %d", nerr, npkt * numel(psdu)), FontSize=13);
text(0, 0.34, sprintf("SNR (L-LTF): %.1f dB", mean(snrs)), FontSize=13);
text(0, 0.17, sprintf("Frequency offset: %+.0f Hz (median)", median(sum(cfos, 2))), FontSize=13);
text(0, 0.0, sprintf("TX PAPR: %.1f dB", papr), FontSize=13);
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_wlan_ofdm.png"));
end
