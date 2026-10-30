%RUN_AGC Every communication example over the air twice: with the fixed RX gain of the script, and
% with the AGC configured for its waveform (agcMode / agcParams in each script: which AGC, which
% parameters and why). A table of the results with the gain the AD9361 ended up with.
%
%   addpath('D:/ClaudePrj/glidelink-sdr/sw/matlab');  run_agc

here = fileparts(mfilename("fullpath"));
scripts = ["qpsk_ota", "fsk_narrowband", "css_chirp", "wlan_ofdm", "timed_bursts"];
modes = ["manual", "agc"];
agcSummary = table('Size', [0 7], 'VariableTypes', ["string", "string", "double", "double", "double", "double", ...
    "string"], 'VariableNames', ["Scheme", "Gain", "RxGain_dB", "Frames", "Bits", "Errors", "Metrics"]);
for sname = scripts
    for gainMode = modes
        fprintf("\n=== %s, %s ===\n", sname, gainMode);
        try
            clear result sr agcMode agcParams
            run(fullfile(here, sname + ".m"));
            agcSummary(end + 1, :) = {result.name, string(sr.rx_gain_mode), sr.rx_gain, result.frames, result.bits, ...
                result.errors, string(result.metric)}; %#ok<SAGROW>
        catch err
            fprintf(2, "%s (%s) failed: %s\n", sname, gainMode, err.message);
            agcSummary(end + 1, :) = {sname, gainMode, NaN, NaN, NaN, NaN, "FAILED: " + err.message}; %#ok<SAGROW>
        end
    end
end
clear gainMode                                       % the scripts' default (fixed gain) again
fprintf("\n");
disp(agcSummary);
