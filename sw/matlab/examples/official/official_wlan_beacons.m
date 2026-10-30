%OFFICIAL_WLAN_BEACONS The MathWorks example "WLAN Beacon Receiver Using Software-Defined Radio"
% (WLAN Toolbox) on a GlideLink board (receive only): the access points around, from their beacons.
%
% The example's configurations ("DSSS, band 2.4": 11 MSPS, channels 1-14; "OFDM, band 2.4": 20 MSPS,
% channels 1-13; "OFDM, band 5") and its processing: per channel 3 beacon intervals (the example: 1) are
% captured, then packet after packet goes through the example's recoverDSSSBits / recoverOFDMBits
% (detection, synchronisation, demodulation, decoding) and wlanMPDUDecode; each beacon gives SSID,
% BSSID, SNR (OFDM) and the channels from its information elements, and a beacon whose primary
% channel is not the scanned one (seen through the adjacent channel) is dropped, as in the example.
% Ours instead of the example's hSDRReceiver (Pluto / USRP): glidelink.Radio, capturing at the
% baseband rate. The vendor lookup (it downloads the IEEE OUI table) is left out.
% The boards' antennas are for 915 MHz: only the stronger access points come through.

rxHost = "192.168.3.1";
if ~exist("config", "var")
    config = "DSSS, band 2.4";
end
rxGain = 60;
glidelink.officialExample("wlan/SDRBeaconReceiverExample");
switch config
    case "DSSS, band 2.4", band = 2.4;  fs = 11e6;  channels = 1:14;
    case "OFDM, band 2.4", band = 2.4;  fs = 20e6;  channels = 1:13;
    case "OFDM, band 5",   band = 5;    fs = 20e6;  channels = [36:4:64 100:4:144 149:4:165];
end
dsss = startsWith(config, "DSSS");
captureTime = 3 * 102.4e-3;                       % 3 beacon intervals (the example: 1); each
                                                      % access point gets 3 chances to be heard

clear rx
rx = glidelink.Radio(rxHost);
APs = table('Size', [0 7], 'VariableTypes', ["string", "string", "double", "double", "double", "string", "double"], ...
    'VariableNames', ["SSID", "BSSID", "SNR_dB", "Channel", "OperatingChannel", "Mode", "Beacons"]);
spec = zeros(numel(channels), 256);  nPkt = zeros(1, numel(channels));
for i = 1:numel(channels)
    fc = wlanChannelFrequency(channels(i), band);
    rx.config(Rate=fs, RxFreq=fc, TxFreq=fc + 50e6, Bandwidth=min(18e6, fs), ...
        RxGainMode="manual", RxGain=rxGain);          % (the board's TX LO away from its RX LO)
    pause(0.1);
    capturedData = rx.rx(round(captureTime * fs));
    spec(i, :) = 10 * log10(pwelch(capturedData, hann(256), 128, 256, fs, "centered"))';
    searchOffset = 0;
    while searchOffset < numel(capturedData)
        if dsss
            [bitsData, ~, searchOffset, res] = recoverDSSSBits(capturedData, searchOffset);
        else
            [bitsData, ~, searchOffset, res] = recoverOFDMBits(capturedData, searchOffset);
        end
        if isempty(bitsData)
            continue
        end
        nPkt(i) = nPkt(i) + 1;
        [cfgMAC, ~, status] = wlanMPDUDecode(bitsData, SuppressWarnings=true);
        if status ~= "Success" || ~matches(cfgMAC.FrameType, "Beacon")
            continue
        end
        [mode, operating, primary] = beaconChannels(cfgMAC.ManagementConfig.InformationElements);
        if ~isempty(primary) && primary ~= channels(i)
            continue                                  % heard through the adjacent channel
        end
        ssid = string(cfgMAC.ManagementConfig.SSID);
        if ssid == ""
            ssid = "Hidden";
        end
        bssid = string(cfgMAC.Address3);
        snr = NaN;
        if ~dsss
            snr = res.LLTFSNR;
        end
        k = find(APs.BSSID == bssid & APs.Channel == channels(i), 1);
        if isempty(k)
            APs(end + 1, :) = {ssid, bssid, snr, channels(i), operating, mode, 1}; %#ok<SAGROW>
            fprintf("%s beacon detected on channel %d in band %.1f\n", ssid, channels(i), band);
        else
            APs.Beacons(k) = APs.Beacons(k) + 1;
        end
    end
end
rx.config(Freq=915e6);
clear rx
disp(APs);
result = struct("name", "official WLAN beacons (" + config + ")", "frames", sum(nPkt), "bits", NaN, ...
    "errors", 0, "metric", sprintf("%d access points, %d packets decoded", height(APs), sum(nPkt)));
disp(result.metric);

%% figure
fig = figure(Name="MathWorks WLAN beacon receiver example on GlideLink", Color="w", Position=[100 100 1300 500]);
tl = tiledlayout(fig, 1, 2, TileSpacing="compact");
title(tl, sprintf("WLAN beacon receiver (MathWorks example), %s, GlideLink board", config));
nexttile;
f = ((0:255) - 128) / 256 * fs;
imagesc(f / 1e6, channels, spec - max(spec(:)));  axis xy;  colorbar;  clim([-50 0]);
xlabel("Frequency offset (MHz)");  ylabel("Channel");  title("Spectrum per channel (dB)");
nexttile;  axis off;
lines = compose("ch %2d  %-24s %s  %d beacons", APs.Channel, extractBefore(APs.SSID + blanks(24), 25), APs.BSSID, APs.Beacons);
if isempty(lines)
    lines = "no beacons";
end
text(0, 1, ["Access points (" + height(APs) + ")"; lines(1:min(end, 24))], VerticalAlignment="top", ...
    FontName="Consolas", FontSize=9, Interpreter="none");
if ~usejava("desktop")
    exportgraphics(fig, fullfile(tempdir, "glidelink_official_wlan_beacons.png"));
end

function [mode, operating, primary] = beaconChannels(ie)
% the mode and the channels from the beacon's information elements (as the example's determineMode:
% HT operation (61) gives the primary channel, else the DS parameter set (3))
ids = cell2mat(ie(:, 1));  ids = ids(:, 1);
primary = [];  operating = NaN;
if any(ids == 191) || any(ids == 255)
    mode = "802.11ac/ax";
elseif any(ids == 45)
    mode = "802.11n";
elseif any(ids == 3)
    mode = "802.11b/g";
else
    mode = "802.11a/g";
end
if any(ids == 61)
    ht = ie{find(ids == 61, 1), 2};  primary = double(ht(1));  operating = primary;
elseif any(ids == 3)
    primary = double(ie{find(ids == 3, 1), 2});  operating = primary;
end
end
