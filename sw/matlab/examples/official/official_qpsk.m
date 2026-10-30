%OFFICIAL_QPSK The MathWorks examples "QPSK Transmitter / Receiver with USRP Hardware" and "QPSK
% Transmitter / Receiver with ADALM-PLUTO Radio" on the two GlideLink boards.
%
% The examples' own parameter scripts and signal processing are used as they are: the init
% functions (sdruqpsk*_init / plutoradioqpsk*_init), QPSKTransmitter (Barker header, scrambled
% "Hello world ###" messages, RRC) and QPSKReceiver (AGC, RRC, coarse and fine frequency
% compensation, Gardner timing recovery, frame synchronisation, descrambling, BER). Only the radio
% is ours: glidelink.Radio instead of comm.SDRuTransmitter / comm.SDRuReceiver or sdrtx / sdrrx.
%   - TX: the transmitter's scrambler runs on across frames and repeats every 3 frames, so 3 frames
%     (after the first, whose filter starts from zero) sent cyclically on the TX board are the same
%     signal as the example's continuous stream.
%   - RX: the RX board captures captureTime seconds contiguously, then the frames go through the
%     receiver one after the other, as the example's receive loop does.
% The files of the examples come from the installed support packages (glidelink.officialExample).

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
if ~exist("variant", "var")
    variant = "usrp";    % "usrp": the USRP example's parameters (1 MSPS, FFT-based coarse frequency)
                         % "pluto": the Pluto example's, symbol rate 0.2 -> 0.5 MBd (the Pluto's FPGA
                         %   decimates below 0.52 MSPS, the GlideLink AD9361 path starts there)
end
fc = 915e6;  txAtten = 40;  rxGain = 30;  captureTime = 2;
printData = false;       % true: print the decoded messages, as the examples' printReceivedData

%% the examples' parameters and objects
if variant == "usrp"
    glidelink.officialExample("usrpradio/QPSKTransmitterWithUSRPHardwareExample");
    glidelink.officialExample("usrpradio/QPSKReceiverWithUSRPHardwareExample");
    fs = 1e6;                                         % the example's sampleRate
    pt = sdruqpsktransmitter_init("B210", "", fs, fc, 0, 1);   % platform: only its master clock is set
    pr = sdruqpskreceiver_init("B210", "", fs, fc, 0, captureTime, false);
    frameLength = pr.USRPFrameLength;
else
    glidelink.officialExample("plutoradio/QPSKTransmitterWithADALMPLUTORadioExample");
    glidelink.officialExample("plutoradio/QPSKReceiverWithADALMPLUTORadioExample");
    pt = plutoradioqpsktransmitter_init;  pr = plutoradioqpskreceiver_init;
    for name = ["pt", "pr"]
        p = eval(name);
        p.Rsym = 0.5e6;  p.Tsym = 1 / p.Rsym;  p.Fs = p.Rsym * p.Interpolation;
        p.PlutoFrontEndSampleRate = p.Fs;
        eval(name + " = p;");
    end
    fs = pr.Fs;  frameLength = pr.PlutoFrameLength;
end
hTx = QPSKTransmitter( ...
    UpsamplingFactor=pt.Interpolation, RolloffFactor=pt.RolloffFactor, ...
    RaisedCosineFilterSpan=pt.RaisedCosineFilterSpan, MessageBits=pt.MessageBits, ...
    MessageLength=pt.MessageLength, NumberOfMessage=pt.NumberOfMessage, ...
    ScramblerBase=pt.ScramblerBase, ScramblerPolynomial=pt.ScramblerPolynomial, ...
    ScramblerInitialConditions=pt.ScramblerInitialConditions);
rxArgs = {"ModulationOrder", pr.ModulationOrder, "SampleRate", pr.Fs, "DecimationFactor", pr.Decimation, ...
    "FrameSize", pr.FrameSize, "HeaderLength", pr.HeaderLength, "NumberOfMessage", pr.NumberOfMessage, ...
    "PayloadLength", pr.PayloadLength, "DesiredPower", pr.DesiredPower, "AveragingLength", pr.AveragingLength, ...
    "MaxPowerGain", pr.MaxPowerGain, "RolloffFactor", pr.RolloffFactor, ...
    "RaisedCosineFilterSpan", pr.RaisedCosineFilterSpan, "InputSamplesPerSymbol", pr.Interpolation, ...
    "MaximumFrequencyOffset", pr.MaximumFrequencyOffset, ...
    "PostFilterOversampling", pr.Interpolation / pr.Decimation, ...
    "PhaseRecoveryLoopBandwidth", pr.PhaseRecoveryLoopBandwidth, ...
    "PhaseRecoveryDampingFactor", pr.PhaseRecoveryDampingFactor, ...
    "TimingRecoveryDampingFactor", pr.TimingRecoveryDampingFactor, ...
    "TimingRecoveryLoopBandwidth", pr.TimingRecoveryLoopBandwidth, ...
    "TimingErrorDetectorGain", pr.TimingErrorDetectorGain, "DescramblerBase", pr.ScramblerBase, ...
    "DescramblerPolynomial", pr.ScramblerPolynomial, ...
    "DescramblerInitialConditions", pr.ScramblerInitialConditions, "BerMask", pr.BerMask, ...
    "PrintOption", printData};
if variant == "usrp"
    qpskRx = QPSKReceiver(rxArgs{:}, "PreambleDetectorThreshold", pr.PreambleDetectorThreshold, ...
        "CFCAlgorithm", pr.CFCAlgorithm);
else
    qpskRx = QPSKReceiver(rxArgs{:}, "PreambleDetectionThreshold", pr.PreambleDetectionThreshold);
end

%% boards
hTx();                                                % frame 1: the RRC filter starts from zero
x = [hTx(); hTx(); hTx()];                            % frames 2-4, one scrambler period: frame 4 has
                                                      % frame 1's bits, so its filter tail runs into
                                                      % frame 2 seamlessly when repeated
x = 0.7 * x / max(abs(x));
clear tx rx
tx = glidelink.Radio(txHost);  rx = glidelink.Radio(rxHost);
tx.config(Rate=fs, Freq=fc, Bandwidth=2 * fs, TxAtten=txAtten);
rx.config(Rate=fs, Freq=fc, Bandwidth=2 * fs, RxGainMode="manual", RxGain=rxGain);
tx.txCyclic(x);  pause(0.5);
y = rx.rx(round(captureTime * fs));
tx.txStop();
clear tx rx

%% the example's receive loop, over the captured frames
nFrames = floor(numel(y) / frameLength);
ber = zeros(nFrames, 3);  eq = [];
for k = 1:nFrames
    [~, ~, fineComp, BER] = qpskRx(y((k - 1) * frameLength + (1:frameLength)));
    ber(k, :) = BER(1:3);
    if k > nFrames / 2
        eq = [eq; fineComp]; %#ok<AGROW>
    end
end
release(qpskRx);
BER = ber(end, :);
fprintf("QPSK (%s example): %d frames, error rate %g, detected errors %d, compared bits %d\n", ...
    variant, nFrames, BER(1), BER(2), BER(3));
result = struct("name", "official QPSK (" + variant + ")", "frames", nFrames, "bits", BER(3), ...
    "errors", BER(2), "metric", sprintf("BER %.2e", BER(1)));

%% figure
fig = figure(Name="MathWorks QPSK example on GlideLink", Color="w", Position=[100 100 1200 450]);
tl = tiledlayout(fig, 1, 3, TileSpacing="compact");
title(tl, sprintf("MathWorks QPSK %s example, %g MSPS at %g MHz, GlideLink boards", variant, fs / 1e6, fc / 1e6));
nexttile;
[pxx, f] = pwelch(y, hann(1024), 512, 1024, fs, "centered");
plot(f / 1e3, 10 * log10(pxx / max(pxx)), LineWidth=1.2);  grid on;  ylim([-60 3]);
xlabel("Frequency (kHz)");  ylabel("dB");  title("Received spectrum");
nexttile;
plot(real(eq(1:min(end, 20000))), imag(eq(1:min(end, 20000))), ".", MarkerSize=3);
axis equal;  grid on;  title("After fine frequency compensation");
nexttile;
semilogy(1:nFrames, max(ber(:, 1), 1e-7), "o-");  grid on;  ylim([1e-7 1]);
xlabel("Frame");  ylabel("Cumulative error rate");  title("BER (the example's BER block)");
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_official_qpsk.png"));
end
