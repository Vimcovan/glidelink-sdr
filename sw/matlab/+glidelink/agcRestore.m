function agcRestore(r, restore)
%AGCRESTORE Write back the AGC parameters saved by glidelink.agcSetup, re-initialise the AD9361 with
% them, then select the gain mode (and in manual mode the gain) that was set before.
isg = cellfun(@(c) string(c) == "@gain", restore(:, 1));
params = restore(~isg, :);
for i = 1:size(params, 1)
    r.attr(params{i, 1}, params{i, 2});
end
if ~isempty(params)
    r.attr("initialize", 1);
end
g = restore{isg, 2};
if g(1) == "manual"
    r.config(RxGainMode="manual", RxGain=double(g(2)));
else
    r.config(RxGainMode=g(1));
end
end
