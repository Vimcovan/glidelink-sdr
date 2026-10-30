function restore = agcSetup(r, mode, params)
%AGCSETUP Configure the AD9361 AGC of radio r for a waveform and select the gain mode.
%   restore = glidelink.agcSetup(r, "slow_attack", {"adi,agc-inner-thresh-high", 8; ...})
%   params   n x 2 cell: driver parameter name, value (UG-570 "Gain control"; the names and
%            defaults are those of the ADI driver's device tree binding)
%   restore  the previous values and gain mode / gain: glidelink.agcRestore(r, restore) puts them back
% The parameters are written, the AD9361 is re-initialised with them (the bridge keeps rate, LOs
% and bandwidth across it), then the gain mode is selected.
s = r.config();
restore = cell(size(params));
for i = 1:size(params, 1)
    restore{i, 1} = params{i, 1};
    restore{i, 2} = r.attr(params{i, 1});
    r.attr(params{i, 1}, params{i, 2});
end
if ~isempty(params)
    r.attr("initialize", 1);
end
r.config(RxGainMode=mode);
restore(end + 1, :) = {"@gain", [string(s.rx_gain_mode), s.rx_gain]};
end
