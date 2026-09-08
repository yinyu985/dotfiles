local hs = hs
local hotkey = hs.hotkey
local task = hs.task
local alert = hs.alert
local pasteboard = hs.pasteboard
local json = hs.json
local timer = hs.timer
local screenRecordingState = hs.screenRecordingState
local menubar = hs.menubar
local image = hs.image
local base64 = hs.base64
local sound = hs.sound
local screen = hs.screen
local canvas = hs.canvas
local configdir = hs.configdir
local fs = hs.fs
local layout = require("ocr.apple.layout")
local log = (function()
    local function emit(prefix, level, message)
        local header = string.format("-- [%s] %-5s ", prefix, level)
        message = tostring(message):gsub("[\r\n]+", " ")
        print(header .. message:sub(1, 100 - #header))
    end

    local function new(prefix)
        local logger = {}
        function logger:info(message) emit(prefix, "INFO", message) end
        function logger:warn(message) emit(prefix, "WARN", message) end
        function logger:error(message) emit(prefix, "ERROR", message) end
        function logger:event(name, message) emit(prefix, string.upper(name):sub(1, 5), message) end
        function logger:infof(fmt, ...) self:info(string.format(fmt, ...)) end
        function logger:warnf(fmt, ...) self:warn(string.format(fmt, ...)) end
        function logger:errorf(fmt, ...) self:error(string.format(fmt, ...)) end
        function logger:eventf(name, fmt, ...) self:event(name, string.format(fmt, ...)) end
        return logger
    end

    return new("ocr")
end)()

local ocr = {}

local OCR_TIMEOUT_SECONDS = 30
local activeJob

local function characterCount(text)
    return utf8.len(text or "") or #(text or "")
end

-- ---------- Feedback config ----------
local successSoundName = "Hero"
local successSoundVolume = 0.35
local successFlashSeconds = 0.12
local successAlertSeconds = 1.2

local successAlertStyle = {
    fillColor = { red = 0.08, green = 0.42, blue = 0.22, alpha = 0.92 },
    strokeColor = { red = 0.75, green = 1.0, blue = 0.82, alpha = 0.95 },
    strokeWidth = 2,
    radius = 12,
    textColor = { white = 1, alpha = 1 },
    textSize = 24,
    fadeInDuration = 0.02,
    fadeOutDuration = 0.12,
}

local _successSound
local _feedbackCanvases = {}
local _feedbackTimers = {}

local function playSuccessSound()
    if not _successSound then
        local s = sound.getByName(successSoundName)
            or sound.getByName("Ping")
            or sound.getByName("Pop")
            or sound.getByName("Tink")
        if s then
            s:volume(successSoundVolume)
            _successSound = s
        end
    end
    if _successSound then
        _successSound:stop()
        _successSound:currentTime(0)
        _successSound:play()
    end
end

local function flashScreens()
    local screens = screen.allScreens()
    for _, scr in ipairs(screens) do
        local frame = scr:fullFrame()
        local c = canvas.new(frame)
        c[1] = {
            type = "rectangle",
            action = "fill",
            fillColor = { red = 0.15, green = 0.95, blue = 0.38, alpha = 0.18 },
            frame = { x = 0, y = 0, w = frame.w, h = frame.h },
        }
        c:level("screenSaver")
        c:show(0)
        table.insert(_feedbackCanvases, c)

        local t
        t = timer.doAfter(successFlashSeconds, function()
            c:delete(0.10)
            for i = #_feedbackCanvases, 1, -1 do
                if _feedbackCanvases[i] == c then table.remove(_feedbackCanvases, i) end
            end
            for i = #_feedbackTimers, 1, -1 do
                if _feedbackTimers[i] == t then table.remove(_feedbackTimers, i) end
            end
        end)
        table.insert(_feedbackTimers, t)
    end
end

local function successFeedback(text)
    local chars = characterCount(text)
    alert.closeAll(0.05)
    alert.show("已复制 " .. tostring(chars) .. " 个字符", successAlertStyle, successAlertSeconds)
    pcall(playSuccessSound)
    pcall(flashScreens)
end

local screenshotCommand = "/usr/sbin/screencapture"
local visionOCRCommand = configdir .. "/ocr/apple/visionocr"
local menuBarIconSvg = [[
<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
  <g fill="none" stroke="black" stroke-width="1.05" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">
    <path d="M2.4 5.1V3.6C2.4 2.9 2.9 2.4 3.6 2.4H5.1"/>
    <path d="M12.9 2.4H14.4C15.1 2.4 15.6 2.9 15.6 3.6V5.1"/>
    <path d="M15.6 12.9V14.4C15.6 15.1 15.1 15.6 14.4 15.6H12.9"/>
    <path d="M5.1 15.6H3.6C2.9 15.6 2.4 15.1 2.4 14.4V12.9"/>
    <circle cx="5.1" cy="9" r="1.9"/>
    <path d="M10.65 7H10.25C9.1 7 8.25 7.8 8.25 9C8.25 10.2 9.1 11 10.25 11H10.65"/>
    <path d="M12.1 11V7H13.55C14.35 7 14.9 7.5 14.9 8.2C14.9 8.95 14.35 9.45 13.55 9.45H12.1"/>
    <path d="M13.45 9.45L14.9 11"/>
  </g>
</svg>
]]

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function now() return timer.absoluteTime() / 1e6 end

local function cleanup(job)
  if job.ownedImage then os.remove(job.imagePath) end
  os.remove(job.responsePath)
end

local function finish(job, text, err, reason)
  cleanup(job)
  if job.finished then return end
  job.finished = true
  if job.timeout then job.timeout:stop() end
  if activeJob == job then activeJob = nil end
  if ocr.menuBar then ocr.menuBar:setTitle(ocr.iconAvailable and "" or "OCR") end
  if err then
    log:errorf("reason=%s elapsed_ms=%.1f", reason or "unknown", now() - job.started)
    alert.show(err, 3)
  elseif text == "" then
    log:warn("result=empty")
    alert.show("未识别到文字", 2)
  elseif text then
    if not pasteboard.setContents(text) then
      log:error("clipboard=write_failed")
      alert.show("无法写入剪贴板", 3)
      return
    end
    log:eventf("done", "chars=%d total_ms=%.1f", characterCount(text), now() - job.started)
    successFeedback(text)
  end
end

local function beginJob(imagePath, ownedImage)
  if activeJob then
    alert.show("OCR 正在进行中", 1)
    return nil
  end
  local job = { imagePath = imagePath, ownedImage = ownedImage, started = now(),
    responsePath = fs.temporaryDirectory() .. "hammerspoon_visionocr_" .. hs.host.uuid() .. ".json" }
  activeJob = job
  return job
end

function ocr.cancel()
  local job = activeJob
  if not job then return end
  if job.task then job.task:terminate() end
  finish(job)
  log:info("result=cancelled")
end

local function runOCR(job)
  if ocr.menuBar then ocr.menuBar:setTitle("…") end
  local started = now()
  local t = task.new(visionOCRCommand, function(exitCode, _, stderr)
    if job.finished then cleanup(job); return end
    if exitCode ~= 0 then
      log:errorf("visionocr exit=%d stderr=%s", exitCode, trim(stderr):sub(1, 48))
      finish(job, nil, "OCR 识别失败", "helper_exit")
      return
    end

    -- hs.task does not drain non-streaming stdout until the process exits.
    -- Read the completed file so large UTF-8 JSON cannot block that pipe.
    local response = io.open(job.responsePath, "rb")
    if not response then
      finish(job, nil, "OCR 结果读取失败", "result_missing")
      return
    end
    local payload = response:read("*a")
    response:close()
    local ok, result = pcall(json.decode, payload)
    if not ok or type(result) ~= "table" or type(result.items) ~= "table" then
      log:errorf("json_bytes=%d", #(payload or ""))
      finish(job, nil, "OCR 输出无效，请重新编译 helper", "invalid_json")
      return
    end

    local layoutOK, text, stats = pcall(layout.format, result.items)
    if not layoutOK then
      finish(job, nil, "OCR 排版失败", "layout_failed")
      return
    end
    log:eventf("layou", "items=%d rows=%d columns=%d", stats.items, stats.rows, stats.columns)
    local metadata = result.metadata or {}
    log:eventf("vision", "ms=%.1f process_ms=%.1f revision=%s", tonumber(metadata.recognitionMS) or 0,
      now() - started, tostring(metadata.revision or "unknown"))
    finish(job, text)
  end, { "--details", "--output", job.responsePath, "--", job.imagePath })

  job.task = t -- Retain the process until its completion callback runs.
  if not t or not t:start() then
    finish(job, nil, "OCR 无法启动，请运行 ocr/apple/build.sh", "helper_start_failed")
    return
  end
  job.timeout = timer.doAfter(OCR_TIMEOUT_SECONDS, function()
    if job.finished then return end
    t:terminate()
    finish(job, nil, "OCR 超时", "timeout")
  end)
end

-- Caller-owned images are never deleted.
function ocr.runOnImage(imagePath)
  if type(imagePath) ~= "string" or fs.attributes(imagePath, "mode") ~= "file" then
    alert.show("OCR 图片不存在", 2)
    return false
  end
  local job = beginJob(imagePath, false)
  if not job then return false end
  runOCR(job)
  return true
end

function ocr.captureSelectionAndRecognize()
  if not screenRecordingState(false) then
    screenRecordingState(true)
    alert.show("Screen capture denied", 3)
    return
  end

  local imagePath = fs.temporaryDirectory() .. "hammerspoon_visionocr_" .. hs.host.uuid() .. ".png"
  local job = beginJob(imagePath, true)
  if not job then return false end
  local t = task.new(screenshotCommand, function(exitCode, _, stderr)
    if job.finished then cleanup(job); return end
    local size = fs.attributes(imagePath, "size") or 0
    -- Escape and an empty selection are normal cancellation, not OCR errors.
    if size == 0 and (exitCode == 0 or trim(stderr) == "") then
      finish(job)
      log:info("capture=cancelled")
      return
    end
    if exitCode ~= 0 then
      log:errorf("screencapture exit=%d", exitCode)
      finish(job, nil, "截图失败", "capture_exit")
      return
    end

    log:infof("capture_bytes=%d", size)
    -- screencapture has exited, so its PNG is ready without an extra timer delay.
    runOCR(job)
  end, {"-i", "-x", "-t", "png", imagePath})

  job.task = t
  if not t or not t:start() then
    finish(job, nil, "截图无法启动", "capture_start_failed")
    return false
  end
  return true
end

local modifiers = {"ctrl"}
local triggerKey = "d"

if hotkey.assignable(modifiers, triggerKey) then
  ocr.hotkey = hotkey.bind(modifiers, triggerKey, nil, function()
    ocr.captureSelectionAndRecognize()
  end)
else
  alert.show("Ctrl+" .. triggerKey .. " is reserved", 3)
end

local function createMenuBarItem()
  local item = menubar.new(true, "ocr_menu_bar")
  if not item then
    alert.show("OCR menu bar item failed", 3)
    return nil
  end

  local icon = image.imageFromURL("data:image/svg+xml;base64," .. base64.encode(menuBarIconSvg))
  if icon then
    item:setIcon(icon, true)
    ocr.iconAvailable = true
  else
    item:setTitle("OCR")
  end

  item:setTooltip("Apple Vision OCR")
  item:setClickCallback(function()
    ocr.captureSelectionAndRecognize()
  end)

  return item
end

ocr.menuBar = createMenuBarItem()

function ocr.stop()
  ocr.cancel()
  if ocr.hotkey then ocr.hotkey:delete() end
  if ocr.menuBar then ocr.menuBar:delete(); ocr.menuBar = nil end
  for _, t in ipairs(_feedbackTimers) do t:stop() end
  for _, c in ipairs(_feedbackCanvases) do c:delete() end
  _feedbackTimers, _feedbackCanvases = {}, {}
  if _successSound then _successSound:stop() end
end

return ocr
