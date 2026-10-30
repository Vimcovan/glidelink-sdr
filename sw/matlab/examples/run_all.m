%RUN_ALL Every example over the air, one after the other, through the same bridge (no change on
% the boards between them), and a summary table.
%
%   addpath('D:/ClaudePrj/glidelink-sdr/sw/matlab');  run_all
%
% Each example leaves a struct "result" (name, frames, bits, errors, metric) and its figure.

here = fileparts(mfilename("fullpath"));
scripts = ["qpsk_ota", "fsk_narrowband", "css_chirp", "wlan_ofdm", "timed_bursts", "agc_modes"];
summary = table('Size', [0 5], 'VariableTypes', ["string", "double", "double", "double", "string"], ...
    'VariableNames', ["Scheme", "Frames", "Bits", "Errors", "Metrics"]);
for sname = scripts
    fprintf("\n=== %s ===\n", sname);
    try
        clear result
        run(fullfile(here, sname + ".m"));
        summary(end + 1, :) = {result.name, result.frames, result.bits, result.errors, string(result.metric)}; %#ok<SAGROW>
    catch err
        fprintf(2, "%s failed: %s\n", sname, err.message);
        summary(end + 1, :) = {sname, NaN, NaN, NaN, "FAILED: " + err.message}; %#ok<SAGROW>
    end
end
fprintf("\n");
disp(summary);
