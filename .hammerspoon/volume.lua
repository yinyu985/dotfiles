local hs = hs
local M = {}

local HOST = "192.168.31.164"
local PORT = 6095
local BASE_URL = "http://" .. HOST .. ":" .. PORT
local VERIFY_EVERY = 5
local RETRY_SECONDS = 10

local log = {}
local function emit(level, fmt, ...)
    print(string.format("-- [volume] %-5s %s", level, string.format(fmt, ...)))
end
function log:info(fmt, ...) emit("INFO", fmt, ...) end
function log:warn(fmt, ...) emit("WARN", fmt, ...) end
function log:error(fmt, ...) emit("ERROR", fmt, ...) end

if _G.redmiDisplayPanel then _G.redmiDisplayPanel.stop() end
_G.redmiDisplayPanel = M

local s = {
    connected = false,
    visible = false,
    ready = false,
    actual = nil,
    actualRaw = nil,
    estimatedRaw = nil,
    max = nil,
    target = nil,
    targetRaw = nil,
    adjusting = false,
    error = nil,
    request = nil,
    stepsSinceRead = 0,
    sessionStarted = nil,
    keysSent = 0,
    lastDuration = nil,
    lastFinalError = nil,
    recoveries = 0,
}

local requestBusy = false
local stopped = false
local view, port, menu, retryTimer, pollTimer
local render, drive, readVolume

local function clamp(n, lo, hi)
    return math.max(lo, math.min(hi, math.floor(n + 0.5)))
end

local function now()
    return hs.timer.absoluteTime() / 1000000000
end

local function decode(body)
    local ok, value = pcall(hs.json.decode, body or "")
    return ok and type(value) == "table" and value or nil
end

local function percentFor(raw)
    if not raw or not s.max or s.max < 1 then return nil end
    return clamp(raw * 100 / s.max, 0, 100)
end

local function rawFor(percent)
    if not s.max or s.max < 1 then return nil end
    return clamp(percent * s.max / 100, 0, s.max)
end

local function stopRetry()
    if retryTimer then retryTimer:stop(); retryTimer = nil end
end

local function request(path, kind, callback)
    if stopped or requestBusy then return false end
    requestBusy = true
    s.request = kind
    render()
    hs.http.asyncGet(BASE_URL .. path, { ["Cache-Control"] = "no-cache" }, function(code, body)
        requestBusy = false
        s.request = nil
        if stopped then return end
        callback(tonumber(code) or -1, tostring(body or ""))
    end)
    return true
end

local function scheduleRetry()
    if stopped or retryTimer then return end
    retryTimer = hs.timer.doAfter(RETRY_SECONDS, function()
        retryTimer = nil
        if not stopped and not requestBusy then readVolume("retry") end
    end)
end

local function markUnavailable()
    s.connected = false
    s.adjusting = s.targetRaw ~= nil
    s.error = "显示器暂不可达，正在后台重试"
    render()
    scheduleRetry()
end

local function finishTarget()
    local wanted = s.targetRaw
    local elapsed = s.sessionStarted and (now() - s.sessionStarted) or 0
    s.lastDuration = elapsed
    s.lastFinalError = wanted and s.actualRaw and math.abs(wanted - s.actualRaw) or nil
    log:info("done target=%s actual=%s keys=%d sec=%.2f",
        tostring(wanted), tostring(s.actualRaw), s.keysSent, elapsed)
    s.target = nil
    s.targetRaw = nil
    s.adjusting = false
    s.sessionStarted = nil
    s.stepsSinceRead = 0
    s.error = nil
    render()
end

local function handleRead(code, body)
    local root = decode(body)
    local data = root and root.data
    local raw = data and tonumber(data.volume)
    local maximum = data and tonumber(data.maxVolume)
    local valid = code == 200 and root and root.status == 0 and root.msg == "success"
        and raw and maximum and maximum >= 1

    if not valid then
        markUnavailable()
        return
    end

    local wasDisconnected = not s.connected
    stopRetry()
    s.connected = true
    s.max = math.floor(maximum)
    s.actualRaw = clamp(raw, 0, s.max)
    s.estimatedRaw = s.actualRaw
    s.actual = percentFor(s.actualRaw)
    s.stepsSinceRead = 0
    s.error = nil
    if wasDisconnected then
        s.recoveries = s.recoveries + 1
        log:info("connected volume=%d max=%d", s.actualRaw, s.max)
    end

    if s.target ~= nil and s.targetRaw == nil then s.targetRaw = rawFor(s.target) end
    if s.targetRaw ~= nil then
        s.targetRaw = clamp(s.targetRaw, 0, s.max)
        s.target = percentFor(s.targetRaw)
        if s.actualRaw == s.targetRaw then finishTarget() else drive() end
    else
        s.adjusting = false
        render()
    end
end

readVolume = function()
    if stopped or requestBusy then return false end
    return request("/controller?action=getvolume", "read", function(code, body)
        handleRead(code, body)
    end)
end

local function handleKey(code, body, direction)
    local root = decode(body)
    local applied = code == 200 and root and root.status == 0 and root.msg == "success"
    if not applied then
        log:warn("key uncertain dir=%d http=%s", direction, tostring(code))
        s.error = "按键结果不确定，正在读取真实音量"
        s.connected = false
        render()
        readVolume("key-uncertain")
        return
    end

    s.estimatedRaw = clamp((s.estimatedRaw or s.actualRaw or 0) + direction, 0, s.max)
    s.keysSent = s.keysSent + 1
    s.stepsSinceRead = s.stepsSinceRead + 1

    if s.targetRaw == nil then
        readVolume("cancelled")
    elseif s.estimatedRaw == s.targetRaw or s.stepsSinceRead >= VERIFY_EVERY then
        readVolume(s.estimatedRaw == s.targetRaw and "final" or "checkpoint")
    else
        drive()
    end
end

drive = function()
    if stopped or requestBusy or s.targetRaw == nil then return end
    if not s.connected or not s.estimatedRaw or not s.max then
        readVolume("drive")
        return
    end

    local delta = s.targetRaw - s.estimatedRaw
    if delta == 0 then
        readVolume("confirm")
        return
    end

    local direction = delta > 0 and 1 or -1
    local key = direction > 0 and "volumeup" or "volumedown"
    s.adjusting = true
    s.error = nil
    render()
    request("/controller?action=keyevent&keycode=" .. key, "key", function(code, body)
        handleKey(code, body, direction)
    end)
end

function M.setTarget(value)
    value = tonumber(value)
    if stopped or not value or value ~= value then return false end
    stopRetry()
    value = clamp(value, 0, 100)
    if not s.sessionStarted then
        s.sessionStarted = now()
        s.keysSent = 0
    end
    s.target = value
    s.targetRaw = rawFor(value)
    s.adjusting = true
    log:info("target=%d actual=%s", value, tostring(s.actual))
    render()
    if not requestBusy then
        if s.targetRaw == nil or not s.connected then readVolume("target") else drive() end
    end
    return true
end

function M.adjustStep(direction)
    direction = tonumber(direction)
    if stopped or not direction or direction == 0 then return false end
    if not s.max or not (s.estimatedRaw or s.actualRaw) then
        readVolume("step")
        return false
    end
    local base = s.targetRaw or s.estimatedRaw or s.actualRaw
    local raw = clamp(base + (direction > 0 and 1 or -1), 0, s.max)
    if not s.sessionStarted then
        s.sessionStarted = now()
        s.keysSent = 0
    end
    s.targetRaw = raw
    s.target = percentFor(raw)
    s.adjusting = true
    render()
    if not requestBusy then drive() end
    return true
end

function M.refresh()
    stopRetry()
    if not requestBusy then readVolume("manual") end
end

local HTML = [=[
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{color-scheme:light dark;--shell:#edf1f7;--card:#fff;--ink:#172033;--muted:#748096;--line:#dce3ee;--blue:#1769e0;--track:#dfe6f0;--warn:#a55b00}
@media(prefers-color-scheme:dark){:root{--shell:#20242c;--card:#2b303a;--ink:#f2f5fb;--muted:#aeb8ca;--line:#414957;--blue:#75aaff;--track:#424b5a;--warn:#ffc16b}}
*{box-sizing:border-box}html,body{margin:0;background:transparent;overflow:hidden}body{font:13px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:var(--ink);-webkit-user-select:none;user-select:none}.panel{padding:12px;background:var(--card);border:1px solid var(--line);border-radius:5px}.card{padding:0;background:transparent}.head,.title,.values,.target-wrap{display:flex;align-items:center}.head{justify-content:space-between;gap:12px}.title{gap:7px;font-weight:600}.values{gap:6px;font-variant-numeric:tabular-nums;white-space:nowrap}.actual{font-weight:650}.target-wrap{gap:6px}.arrow{color:var(--muted)}.target{color:var(--blue);font-weight:650}.dot{width:7px;height:7px;border-radius:50%;background:#9aa4b5}.dot[data-mode=online]{background:#28a66a}.dot[data-mode=busy]{background:var(--blue)}.dot[data-mode=offline]{background:#d27a1d}input[type=range]{width:100%;height:6px;margin:15px 0 13px;padding:0;border:0;border-radius:6px;-webkit-appearance:none;appearance:none;background:linear-gradient(to right,var(--blue) 0%,var(--blue) var(--fill,0%),var(--track) var(--fill,0%),var(--track) 100%);cursor:pointer}input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:18px;height:18px;border-radius:50%;background:var(--card);border:2px solid var(--blue);box-shadow:0 1px 5px #0003}.actions{display:grid;grid-template-columns:1fr 1fr;gap:7px}button{height:31px;border:1px solid var(--line);border-radius:3px;background:var(--card);color:var(--ink);font:500 13px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;cursor:pointer}button:hover{background:var(--shell)}button:disabled,input:disabled{opacity:.4;cursor:default}button:focus-visible,input:focus-visible{outline:2px solid var(--blue);outline-offset:2px}.notice{margin:8px 2px 1px;color:var(--warn);font-size:11px;line-height:1.35}[hidden]{display:none!important}
</style></head><body><main class="panel" aria-label="显示器音量">
<section class="card"><div class="head"><div class="title"><span class="dot" id="state" data-mode="offline"></span><span>音量</span></div><div class="values"><span class="actual" id="actual">—</span><span class="target-wrap" id="target-wrap" hidden><span class="arrow">→</span><span class="target" id="target">—</span></span></div></div>
<input id="volume" type="range" min="0" max="100" value="0" aria-label="目标音量" disabled>
<div class="actions"><button id="minus" aria-label="减音量" disabled>减音量</button><button id="plus" aria-label="加音量" disabled>加音量</button></div></section>
<div class="notice" id="notice" role="status" hidden></div>
</main><script>(()=>{const slider=document.getElementById('volume'),actual=document.getElementById('actual'),target=document.getElementById('target'),targetWrap=document.getElementById('target-wrap'),state=document.getElementById('state'),notice=document.getElementById('notice');let dragging=false,lastCommit=null;function post(action,value){window.webkit.messageHandlers.redmiPanel.postMessage({action,value});}function fill(value){slider.value=value;slider.style.setProperty('--fill',value+'%');}function preview(){fill(+slider.value);target.textContent=slider.value+'%';targetWrap.hidden=false;}function commit(){if(!dragging&&lastCommit===+slider.value)return;dragging=false;lastCommit=+slider.value;post('target',lastCommit);}slider.addEventListener('pointerdown',()=>{dragging=true;});slider.addEventListener('input',preview);slider.addEventListener('change',commit);slider.addEventListener('pointerup',()=>{if(dragging)commit();});slider.addEventListener('keydown',e=>{if(['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End','PageUp','PageDown'].includes(e.key))dragging=true;});document.getElementById('minus').onclick=()=>post('step',-1);document.getElementById('plus').onclick=()=>post('step',1);document.addEventListener('keydown',e=>{if(e.key==='Escape')post('close');});window.receiveState=s=>{actual.textContent=s.actual==null?'—':s.actual+'%';if(!dragging){const shown=s.target==null?s.actual:s.target;if(shown!=null)fill(shown);target.textContent=s.target==null?'—':s.target+'%';targetWrap.hidden=s.target==null;lastCommit=s.target;}const usable=s.actual!=null;slider.disabled=!usable;document.getElementById('minus').disabled=document.getElementById('plus').disabled=!usable;const mode=!s.connected?'offline':s.adjusting?'busy':'online';state.dataset.mode=mode;state.title=mode==='offline'?'自动重连中':mode==='busy'?'正在调整':'已连接';state.setAttribute('aria-label',state.title);notice.hidden=!s.error;notice.textContent=s.error||'';post('resize',Math.ceil(document.querySelector('.panel').getBoundingClientRect().height));};post('ready');})();</script></body></html>
]=]

render = function()
    if stopped or not view or not s.ready then return end
    view:evaluateJavaScript("window.receiveState(" .. hs.json.encode({
        connected = s.connected,
        actual = s.actual,
        target = s.target,
        adjusting = s.adjusting,
        error = s.error,
    }) .. ")")
end

function M.hide()
    s.visible = false
    s.target = nil
    s.targetRaw = nil
    s.adjusting = false
    s.sessionStarted = nil
    stopRetry()
    if view then view:hide() end
    render()
end

local opening = false
local function createView()
    if view then return end
    port = hs.webview.usercontent.new("redmiPanel"):setCallback(function(message)
        local b = message.body or message
        if type(b) ~= "table" or stopped then return end
        if b.action == "ready" then s.ready = true; render()
        elseif b.action == "target" then M.setTarget(b.value)
        elseif b.action == "step" then M.adjustStep(b.value)
        elseif b.action == "close" then M.hide()
        elseif b.action == "resize" and type(b.value) == "number" then
            local f = view:frame(); f.h = clamp(b.value, 105, 180); view:frame(f)
        end
    end)
    view = hs.webview.new({ x = 0, y = 0, w = 286, h = 120 },
        { javaScriptCanOpenWindowsAutomatically = false }, port)
        :windowStyle({ "borderless" }):allowTextEntry(true):allowNewWindows(false)
        :transparent(true):shadow(true):level(hs.drawing.windowLevels.floating)
        :windowTitle("REDMI 显示器音量")
        :windowCallback(function(action, _, focus)
            if action == "focusChange" and not focus and s.visible and not opening then M.hide() end
        end)
    view:html(HTML)
end

function M.show()
    if stopped then return end
    createView()
    local screen = hs.mouse.getCurrentScreen():frame()
    local anchor = menu and menu:frame()
    local f = view:frame()
    local center = anchor and (anchor.x + anchor.w / 2) or (screen.x + screen.w - f.w / 2 - 12)
    f.x = math.max(screen.x + 8, math.min(center - f.w / 2, screen.x + screen.w - f.w - 8))
    f.y = screen.y
    view:frame(f)
    s.visible = true
    opening = true
    hs.timer.doAfter(0.3, function() opening = false end)
    view:show():bringToFront()
    local window = view:hswindow(); if window then window:focus() end
    M.refresh()
end

function M.toggle()
    if s.visible then M.hide() else M.show() end
end

function M.status()
    return {
        host = HOST,
        connected = s.connected,
        actual = s.actual,
        actualRaw = s.actualRaw,
        max = s.max,
        target = s.target,
        targetRaw = s.targetRaw,
        adjusting = s.adjusting,
        request = s.request,
        error = s.error,
        keysSent = s.keysSent,
        lastDuration = s.lastDuration,
        lastFinalError = s.lastFinalError,
        recoveries = s.recoveries,
    }
end

function M.stop()
    stopped = true
    stopRetry()
    if pollTimer then pollTimer:stop(); pollTimer = nil end
    s.target = nil
    s.targetRaw = nil
    if view then view:delete(); view = nil end
    if menu then menu:delete(); menu = nil end
end

menu = hs.menubar.new(true, "redmiDisplayPanel")
if menu then
    -- Xiaomi 2021 logo: https://commons.wikimedia.org/wiki/File:Xiaomi_logo_(2021-).svg
    local svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-200.008 -199.727 512 512">'
        .. '<path fill="#FF6900" d="M258.626-146.231c-48.304-48.118-117.759-53.496-202.634-53.496-84.982 0-154.542 5.44-202.826 53.688-48.277 48.228-53.174 117.676-53.174 202.561 0 84.899 4.897 154.368 53.194 202.613 48.281 48.255 117.833 53.139 202.806 53.139 84.974 0 154.514-4.884 202.795-53.139 48.294-48.254 53.205-117.714 53.205-202.613 0-84.994-4.964-154.517-53.366-202.753z"/>'
        .. '<path fill="#FFF" d="M204.546-41.122a3.2 3.2 0 0 1 3.223 3.161v189.386a3.2 3.2 0 0 1-3.223 3.139H163.05a3.2 3.2 0 0 1-3.228-3.139V-37.961a3.2 3.2 0 0 1 3.228-3.161h41.496zM24.468-41.122c31.303 0 64.033 1.435 80.176 17.589 15.871 15.897 17.59 47.549 17.656 78.286v96.671a3.2 3.2 0 0 1-3.219 3.139h-41.49a3.2 3.2 0 0 1-3.229-3.139V53.09c-.044-17.167-1.031-34.81-9.884-43.692C56.858 1.757 42.639.007 27.853-.356h-75.21a3.2 3.2 0 0 0-3.208 3.136v148.645a3.2 3.2 0 0 1-3.237 3.139h-41.516a3.2 3.2 0 0 1-3.201-3.139V-37.961a3.2 3.2 0 0 1 3.201-3.161H24.468zm9.287 75.427a3.2 3.2 0 0 1 3.201 3.143v113.977a3.2 3.2 0 0 1-3.201 3.139H-9.829a3.2 3.2 0 0 1-3.228-3.139V37.448a3.2 3.2 0 0 1 3.228-3.143h43.584z"/></svg>'
    local icon = hs.image.imageFromURL("data:image/svg+xml;base64," .. hs.base64.encode(svg))
    if icon then menu:setIcon(icon:setSize({ w = 18, h = 18 }), false) else menu:setTitle("mi") end
    menu:setTooltip("REDMI 显示器音量"):setClickCallback(M.toggle)
else
    log:error("menubar=unavailable")
end

pollTimer = hs.timer.doEvery(5, function()
    if stopped or requestBusy or retryTimer then return end
    if s.targetRaw ~= nil then drive()
    elseif not s.connected or s.visible then readVolume("poll") end
end)
readVolume("startup")
log:info("ready host=%s port=%d mode=6095", HOST, PORT)
return M
