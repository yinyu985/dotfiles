if hs.hotkey and hs.hotkey.setLogLevel then
    pcall(hs.hotkey.setLogLevel, "warning")
end

require("ocr.apple")
require("ocr.remote")
require("process_monitor")

if hs.host.localizedName() == "yy的Mac mini" then
    require("volume")
elseif _G.redmiDisplayPanel then
    _G.redmiDisplayPanel.stop()
end
