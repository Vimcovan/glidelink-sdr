%QPSK_OTA QPSK over the air between the two GlideLink boards, from MATLAB (docs/matlab_plan.md, Q2).
%
% 2.5 MSPS: below 2.08 MSPS the AD9361 driver needs its own FIR setup.
% Needs: the bridge on both boards (sw/bridge/glidelink_bridge.py; the offline services stopped),
% any image (it routes the RF through host port 0). Communications Toolbox.
%
% The TX board repeats one QPSK waveform (RRC, 4 samples per symbol): a known 64-symbol preamble
% and 2000 PRBS payload symbols per frame. The RX board captures 1 s; MATLAB does the receiver:
% coarse frequency correction -> matched filter -> symbol timing -> carrier recovery -> frame
% search on the preamble (also resolves the 90-degree ambiguity) -> bit errors and EVM.

txHost = "192.168.4.1";  rxHost = "192.168.3.1";
fs = 2.5e6;  fc = 915e6;  sps = 4;  beta = 0.35;  span = 10;
txAtten = 30;                                    % dB: try 10 .. 60
rxGain = 40;                                     % dB, fixed (an AGC changing the gain during the
                                                 % capture spreads the points along the radius)

%% waveform
rng(7);  pre = pskmod(randi([0 3], 64, 1), 4, pi/4);
rng(1);  bits = randi([0 1], 2 * 2000, 1);
payload = pskmod(bits, 4, pi/4, "gray", InputType="bit");
frame = [pre; payload];
txFilt = comm.RaisedCosineTransmitFilter(RolloffFactor=beta, FilterSpanInSymbols=span, ...
    OutputSamplesPerSymbol=sps);
x = txFilt(repmat(frame, 3, 1));                 % three frames: the middle one is periodic
n = numel(frame) * sps;
x = x(n + 1:2 * n);                              % one period of the steady state
x = 0.7 * x / max(abs(x));

%% boards
clear tx rx                                      % connections of an earlier run
tx = glidelink.Radio(txHost);
rx = glidelink.Radio(rxHost);
tx.config(Rate=fs, Freq=fc, Bandwidth=2 * fs, TxAtten=txAtten);
s = rx.config(Rate=fs, Freq=fc, Bandwidth=2 * fs, RxGain=rxGain);
tx.txCyclic(x);
pause(0.5);
y = rx.rx(fs);                                   % 1 s of samples
s = rx.config();                                 % settings as read back
tx.txStop();
clear tx rx                                      % close the connections to the bridges

%% receiver
y = y - mean(y);
y = y / rms(y);
cfc = comm.CoarseFrequencyCompensator(Modulation="QPSK", SampleRate=fs, FrequencyResolution=50);
[yc, cfo] = cfc(y);
rxFilt = comm.RaisedCosineReceiveFilter(RolloffFactor=beta, FilterSpanInSymbols=span, ...
    InputSamplesPerSymbol=sps, DecimationFactor=1);
ym = rxFilt(yc);
sync = comm.SymbolSynchronizer(SamplesPerSymbol=sps, TimingErrorDetector="Gardner (non-data-aided)");
ys = sync(ym);
car = comm.CarrierSynchronizer(Modulation="QPSK", SamplesPerSymbol=1, NormalizedLoopBandwidth=0.005);
z = car(ys);

% frames: preamble correlation; skip the first 20000 symbols (loops converging)
z = z(20001:end);
c = abs(conv(z, flipud(conj(pre)), "valid"));
L = numel(frame);
[~, k0] = max(c(1:L));
starts = k0:L:numel(z) - L + 1;
nerr = 0;  nbit = 0;  zs = [];  ref = [];
for k = starts
    seg = z(k:k + L - 1);
    h = (pre' * seg(1:64)) / (pre' * pre);       % complex gain on the preamble: phase (incl. the
    seg = seg / h;                               % 90-degree ambiguity) and amplitude of this frame
    p = seg(65:end);
    b = pskdemod(p, 4, pi/4, "gray", OutputType="bit");
    nerr = nerr + sum(b ~= bits);  nbit = nbit + numel(bits);
    zs = [zs; p]; %#ok<AGROW>
    ref = [ref; payload]; %#ok<AGROW>
end
g = 1;                                           % frames are already scaled to the reference points
evm = 100 * sqrt(mean(abs(g * zs - ref) .^ 2) / mean(abs(ref) .^ 2));
ber = nerr / max(nbit, 1);
fprintf("frames %d, bits %d, errors %d (BER %.2e), EVM %.1f %% (%.1f dB), CFO %+.0f Hz, RX gain %.0f dB\n", ...
    numel(starts), nbit, nerr, ber, evm, 20 * log10(evm / 100), cfo, s.rx_gain);

%% figure
fig = figure(Name="GlideLink QPSK over the air", Color="w", Position=[100 100 1200 800]);
tl = tiledlayout(fig, 2, 2, TileSpacing="compact");
title(tl, sprintf("QPSK %g ksym/s over the air, %g MHz, TX attenuation %g dB", fs / sps / 1e3, fc / 1e6, txAtten));
nexttile;
[pxx, f] = pwelch(y, hann(1024), 512, 1024, fs, "centered");
plot(f / 1e3, 10 * log10(pxx / max(pxx)), LineWidth=1.2);  grid on;
xlabel("Frequency offset (kHz)");  ylabel("dB");  title("Received spectrum");  ylim([-70 3]);
nexttile;
raw = ym(sps * 20000:sps:sps * 20000 + 4 * sps * 2000);
plot(real(raw), imag(raw), ".", MarkerSize=4);  axis equal;  grid on;
title("Before timing / carrier recovery");  xlim([-2 2]);  ylim([-2 2]);
nexttile;
show = g * zs(max(1, end - 8000):end);
plot(real(show), imag(show), ".", MarkerSize=4);  axis equal;  grid on;
title("After synchronisation");  xlim([-1.5 1.5]);  ylim([-1.5 1.5]);
nexttile;  axis off;
text(0, 0.8, sprintf("Frames: %d", numel(starts)), FontSize=14);
text(0, 0.62, sprintf("Bit errors: %d of %d  (BER %.2e)", nerr, nbit, ber), FontSize=14);
text(0, 0.44, sprintf("EVM: %.1f %%  (%.1f dB)", evm, 20 * log10(evm / 100)), FontSize=14);
text(0, 0.26, sprintf("Frequency offset: %+.0f Hz", cfo), FontSize=14);
text(0, 0.08, sprintf("RX gain: %.0f dB", s.rx_gain), FontSize=14);
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_qpsk_ota.png"));
end
