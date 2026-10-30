%OFFICIAL_WLAN_IMAGE The MathWorks example "Image Transmission and Reception Using 802.11 Waveform
% and SDR" (WLAN Toolbox) on the two GlideLink boards.
%
% The example's processing, step by step with the same WLAN Toolbox functions (written out here, the
% example's own helperInterpretLSIG comes from the installed example):
%   TX: peppers.png scaled by 0.2 -> 2304-byte MSDUs -> wlanMACFrame (data frames, sequence numbers)
%       -> wlanWaveformGenerator, 802.11a MCS 6 (64-QAM 2/3), 20 us idle, random scrambler
%       initialisation per packet, oversampled 1.5 (30 MSPS), scaled to 0.8 peak.
%   RX: twice the waveform captured -> FIR rate converter 30 -> 20 MSPS -> per packet:
%       wlanPacketDetect, coarse CFO, wlanSymbolTimingEstimate, fine CFO, L-LTF channel and noise
%       estimate, wlanFormatDetect, L-SIG (helperInterpretLSIG), wlanNonHTDataRecover, EVM,
%       wlanMPDUDecode (FCS); the MSDUs ordered by sequence number -> image, BER.
% Ours instead of sdrtx / sdrrx (Pluto) with transmitRepeat / capture: glidelink.Radio txCyclic / rx.
% Channel 5 in the 2.4 GHz band as in the example (2432 MHz; the boards' antennas are for 915 MHz,
% and other WiFi is on the air there: its packets are detected and skipped).

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
channelNumber = 5;  frequencyBand = 2.4;  txAtten = 0;  rxGain = 40;   % (915 MHz antennas: full TX power at 2.4 GHz)
glidelink.officialExample("wlan/SDRImageTransmissionReceptionUsing80211WaveformExample");

%% transmitter: image -> MPDUs -> 802.11a packets
fData = imread("peppers.png");
scale = 0.2;
origSize = size(fData);
scaledSize = max(floor(scale .* origSize(1:2)), 1);
heightIx = min(round(((1:scaledSize(1)) - 0.5) ./ scale + 0.5), origSize(1));
widthIx = min(round(((1:scaledSize(2)) - 0.5) ./ scale + 0.5), origSize(2));
fData = fData(heightIx, widthIx, :);
imsize = size(fData);
txImage = fData(:);
msduLength = 2304;
numMSDUs = ceil(numel(txImage) / msduLength);
txData = [txImage; zeros(numMSDUs * msduLength - numel(txImage), 1)];
txDataBits = double(int2bit(txData, 8, false));
data = zeros(0, 1);
for i = 0:numMSDUs - 1
    cfgMAC = wlanMACFrameConfig(FrameType="Data", SequenceNumber=i);
    [psdu, lengthMPDU] = wlanMACFrame(txData(i * msduLength + (1:msduLength)), cfgMAC, OutputFormat="bits");
    data = [data; psdu]; %#ok<AGROW>
end
nonHTcfg = wlanNonHTConfig(MCS=6, NumTransmitAntennas=1, PSDULength=lengthMPDU);
chanBW = nonHTcfg.ChannelBandwidth;
osf = 1.5;
sampleRate = wlanSampleRate(nonHTcfg);
txWaveform = wlanWaveformGenerator(data, nonHTcfg, NumPackets=numMSDUs, IdleTime=20e-6, ...
    ScramblerInitialization=randi([1 127], numMSDUs, 1), OversamplingFactor=osf);
txWaveform = txWaveform * (0.8 / max(abs(txWaveform)));
fc = wlanChannelFrequency(channelNumber, frequencyBand);
if exist("fcOverride", "var")                        % another centre frequency, e.g. 915e6
    fc = fcOverride;
end
if exist("txAttenOverride", "var")
    txAtten = txAttenOverride;
end

%% boards: the TX board repeats the packets, the RX board captures twice their length
clear tx rx
tx = glidelink.Radio(txHost);  rx = glidelink.Radio(rxHost);
tx.config(Rate=sampleRate * osf, Freq=fc, Bandwidth=18e6, TxAtten=txAtten);
rx.config(Rate=sampleRate * osf, RxFreq=fc, TxFreq=fc + 40e6, Bandwidth=18e6, ...
    RxGainMode="manual", RxGain=rxGain);              % RX board's TX LO away (it would leak in)
tx.txCyclic(txWaveform);  pause(0.5);
rxWaveform = rx.rx(2 * numel(txWaveform));
tx.txStop();
clear tx rx

%% receiver: back to 20 MSPS
ofdmInfo = wlanNonHTOFDMInfo("NonHT-Data", nonHTcfg);
SCS = sampleRate / ofdmInfo.FFTLength;
txbw = max(abs(ofdmInfo.ActiveFrequencyIndices)) * 2 * SCS;
[L, M] = rat(1 / osf);
b = designMultirateFIR(L, M, 2 * ((sampleRate - txbw) / sampleRate) / max([L M]), 40);
rx20 = dsp.FIRRateConverter(L, M, b);
rxWaveform = rx20(rxWaveform);
rxCapture = rxWaveform;                               % for the spectrum

%% receiver: packets
ind = wlanFieldIndices(nonHTcfg);
Ns = ind.LSIG(2) - ind.LSIG(1) + 1;
lstfLen = double(ind.LSTF(2));
minPktLen = lstfLen * 5;
searchOffset = 0;  packetSeq = [];  rxBit = {};  fcsOk = false(0);  eqAll = [];  evms = [];
nOther = 0;  nFcsFail = 0;
evmCalculator = comm.EVM(AveragingDimensions=[1 2 3]);
while searchOffset + minPktLen <= numel(rxWaveform)
    pktOffset = wlanPacketDetect(rxWaveform, chanBW, searchOffset, 0.5);
    pktOffset = searchOffset + pktOffset;
    if isempty(pktOffset) || pktOffset + double(ind.LSIG(2)) > numel(rxWaveform)
        break
    end
    nonHT = rxWaveform(pktOffset + (ind.LSTF(1):ind.LSIG(2)));
    coarseFreqOffset = wlanCoarseCFOEstimate(nonHT, chanBW);
    nonHT = frequencyOffset(nonHT, sampleRate, -coarseFreqOffset);
    pktOffset = pktOffset + wlanSymbolTimingEstimate(nonHT, chanBW);
    if pktOffset < 0 || pktOffset + minPktLen > numel(rxWaveform)
        searchOffset = pktOffset + 1.5 * lstfLen;
        continue
    end
    nonHT = frequencyOffset(rxWaveform(pktOffset + (1:7 * Ns)), sampleRate, -coarseFreqOffset);
    fineFreqOffset = wlanFineCFOEstimate(nonHT(ind.LLTF(1):ind.LLTF(2)), chanBW);
    nonHT = frequencyOffset(nonHT, sampleRate, -fineFreqOffset);
    cfoCorrection = coarseFreqOffset + fineFreqOffset;
    demodLLTF = wlanLLTFDemodulate(nonHT(ind.LLTF(1):ind.LLTF(2)), chanBW);
    chanEstLLTF = wlanLLTFChannelEstimate(demodLLTF, chanBW);
    noiseVarNonHT = wlanLLTFNoiseEstimate(demodLLTF);
    format = wlanFormatDetect(nonHT(ind.LLTF(2) + (1:3 * Ns)), chanEstLLTF, noiseVarNonHT, chanBW);
    [recLSIGBits, failCheck] = wlanLSIGRecover(nonHT(ind.LSIG(1):ind.LSIG(2)), chanEstLLTF, ...
        noiseVarNonHT, chanBW);
    if ~strcmp(format, "Non-HT") || failCheck         % another WLAN's packet or a false detection
        nOther = nOther + 1;
        searchOffset = pktOffset + 1.5 * lstfLen;
        continue
    end
    [lsigMCS, lsigLen, rxSamples] = helperInterpretLSIG(recLSIGBits, sampleRate);
    if rxSamples + pktOffset > numel(rxWaveform)
        break
    end
    rxWaveform(pktOffset + (1:rxSamples)) = frequencyOffset(rxWaveform(pktOffset + (1:rxSamples)), ...
        sampleRate, -cfoCorrection);
    rxNonHTcfg = wlanNonHTConfig(MCS=lsigMCS, PSDULength=lsigLen);
    indNonHTData = wlanFieldIndices(rxNonHTcfg, "NonHT-Data");
    [rxPSDU, eqSym] = wlanNonHTDataRecover(rxWaveform(pktOffset + (indNonHTData(1):indNonHTData(2))), ...
        chanEstLLTF, noiseVarNonHT, rxNonHTcfg);
    evms(end + 1) = evmCalculator(wlanClosestReferenceSymbol(eqSym, rxNonHTcfg), eqSym); %#ok<SAGROW>
    eqAll = [eqAll; eqSym(:)]; %#ok<AGROW>
    [cfgMACRx, msdu, status] = wlanMPDUDecode(rxPSDU, rxNonHTcfg);
    if strcmp(status, "Success") && (~strcmp(cfgMACRx.FrameType, "Data") || numel(msdu) ~= 1 || ...
            size(msdu{1}, 1) ~= msduLength)           % a valid frame of another WLAN (beacon, ACK...)
        nOther = nOther + 1;
        searchOffset = pktOffset + double(indNonHTData(2));
        continue
    end
    ok = strcmp(status, "Success");
    if ok
        seq = cfgMACRx.SequenceNumber;
        bits = int2bit(hex2dec(cell2mat(msdu)), 8, false);
    else                                              % as the example: no retransmissions, so the
        nFcsFail = nFcsFail + strcmp(status, "FCSFailed");   % MSDU and sequence number are taken
        seq = bit2int(rxPSDU(23 * 8 + 1:25 * 8 - 4), 12, false);   % from the frame anyway
        bits = double(rxPSDU(24 * 8 + 1:end - 4 * 8));
    end
    searchOffset = pktOffset + double(indNonHTData(2));
    % The example stops at the first repeated sequence number. The capture holds every packet twice:
    % here the whole capture is used, a copy that passed the FCS replaces one that did not.
    packetSeq(end + 1) = seq; %#ok<SAGROW>
    rxBit{end + 1} = bits; %#ok<SAGROW>
    fcsOk(numel(packetSeq)) = ok; %#ok<SAGROW>
end
rx20.release();

%% image and BER (MSDUs in sequence order)
rxData = nan(msduLength * 8, numMSDUs);
haveOk = false(1, numMSDUs);
for k = 1:numel(packetSeq)
    s = packetSeq(k) + 1;
    if s <= numMSDUs && numel(rxBit{k}) == msduLength * 8 && (isnan(rxData(1, s)) || (fcsOk(k) && ~haveOk(s)))
        rxData(:, s) = rxBit{k};
        haveOk(s) = fcsOk(k);
    end
end
got = ~isnan(rxData);
nErr = sum(rxData(got) ~= reshape(txDataBits(got(:)), [], 1));
ber = nErr / nnz(got);
decData = nan(numMSDUs * msduLength, 1);
okBytes = all(got, 1);
if any(okBytes)
    decData(repelem(okBytes, msduLength)) = bit2int(reshape(rxData(:, okBytes), 8, []), 8, false)';
end
rxImage = reshape(uint8(decData(1:numel(txImage))), imsize);
fprintf("802.11a image over the air: %d of %d packets, FCS failures %d, BER %.2e (%d of %d bits), EVM %.1f %%, other packets skipped %d\n", ...
    nnz(okBytes), numMSDUs, nFcsFail, ber, nErr, nnz(got), mean(evms), nOther);
result = struct("name", "official 802.11 image", "frames", nnz(okBytes), "bits", nnz(got), ...
    "errors", nErr, "metric", sprintf("EVM %.1f %%, %d of %d packets", mean(evms), nnz(okBytes), numMSDUs));

%% figure
fig = figure(Name="MathWorks 802.11 image example on GlideLink", Color="w", Position=[100 100 1300 650]);
tl = tiledlayout(fig, 2, 3, TileSpacing="compact");
title(tl, sprintf("Image over 802.11a MCS 6 (MathWorks WLAN example), channel %d (%g MHz), GlideLink boards", ...
    channelNumber, fc / 1e6));
nexttile([1 1]);  imshow(fData);  title("Transmitted image");
nexttile([1 1]);  imshow(rxImage);  title(sprintf("Received: %d of %d packets, BER %.1e", nnz(okBytes), numMSDUs, ber));
nexttile([2 1]);
plot(real(eqAll(1:min(end, 30000))), imag(eqAll(1:min(end, 30000))), ".", MarkerSize=3);  hold on;
ref = wlanReferenceSymbols("64QAM");  plot(real(ref), imag(ref), "r+");
axis equal;  grid on;  title(sprintf("Equalized data symbols (64-QAM), EVM %.1f %%", mean(evms)));
nexttile([1 2]);
[pxx, f] = pwelch(rxCapture, hann(1024), 512, 1024, sampleRate, "centered");
plot(f / 1e6, 10 * log10(pxx / max(pxx)), LineWidth=1);  grid on;  ylim([-60 3]);
xlabel("Frequency (MHz)");  ylabel("dB");  title("Received baseband spectrum (20 MSPS)");
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_official_wlan_image.png"));
end
