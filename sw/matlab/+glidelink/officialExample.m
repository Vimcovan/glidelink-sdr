function folder = officialExample(id)
%OFFICIALEXAMPLE Files of a MathWorks example, fetched from the installed support package and put on
% the path: folder = glidelink.officialExample("plutoradio/QPSKReceiverWithADALMPLUTORadioExample").
% The files stay in sw/matlab/official/<example> (not in the repository: they are MathWorks code
% and come with the support package); a second call only adds the folder to the path.
folder = fullfile(fileparts(fileparts(mfilename("fullpath"))), "official", extractAfter(id, "/"));
if ~isfolder(folder) || isempty(dir(fullfile(folder, "*.m*")))
    here = pwd;
    openExample(id, workDir=folder);                % also changes to that folder
    cd(here);
end
addpath(folder);
end
