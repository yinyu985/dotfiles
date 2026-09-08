if hs.hotkey and hs.hotkey.setLogLevel then
    pcall(hs.hotkey.setLogLevel, "warning")
end

require("ocr.apple")
require("ocr.remote")
require("process_monitor")
