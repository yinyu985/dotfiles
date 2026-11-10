-- App Toggle: 按一下呼出应用（必要时先启动），再按一下隐藏整个应用。
--
-- 实现要点：
--   1. 用 hs.application:hide() 隐藏整个应用，不退出进程，工作状态原样保留。
--   2. hs.application:hide() 的返回值不可信：源码里设完 app.hidden = YES 就立刻读
--      app.isHidden，拿到的是 Launch Services 异步更新前的旧值，恒为 false。
--      所以成败一律靠 isFrontmost() / isHidden() 回读判断，不信返回值。
--   3. 解目标应用的窗口无法移动（AXPosition 假成功、AXFrame 报 -25200），
--      所以只做应用级显隐，不做任何 setFrame / 位移。

local app = hs.application
local hotkey = hs.hotkey
local alert = hs.alert
local timer = hs.timer
local watcher = app.watcher

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

    return new("apptoggle")
end)()

local M = {}

local LAUNCH_WAIT = 0.6     -- 新启动应用等待其窗口/前台就绪
local VERIFY_WAIT = 0.12    -- hide/activate 后回读校验的延迟

local hotkeys = {}
local registered = {}       -- combo -> bundleID，防重复注册
local pending = {}          -- combo -> 最近一次按键时间，防连击
local cameFrom = nil        -- 呼出前的前台 bundleID，隐藏时把焦点还回去

-- ---------------------------------------------------------------- 配置

-- 新增应用只需追加一条，不要复制逻辑。
-- modifiers: cmd / ctrl / alt / shift 任意组合；key 为 hs.keycodes.map 的键名。
M.apps = {
    {
        bundleID = "com.deepseek.dsh",
        modifiers = { "ctrl" },
        key = "space",
    },
}

-- ---------------------------------------------------------------- 工具

local function bundleInstalled(bundleID)
    -- pathForBundleID 是 hs.application 的模块函数，返回 nil 表示没安装
    if type(app.pathForBundleID) ~= "function" then return true end
    return app.pathForBundleID(bundleID) ~= nil
end

-- 读应用的真实隐藏态。优先 AX 的 kAXHiddenAttribute：实测该应用的
-- NSRunningApplication.isHidden / isActive 恒为 0，不反映真实状态，
-- 只有 AX 属性可靠。AX 不可用时退回 isFrontmost。
local function axElement(bundleID)
    if type(hs.axuielement) ~= "table" then return nil end
    local ok, el = pcall(hs.axuielement.applicationElement, bundleID)
    if ok then return el end
    return nil
end

local function isHiddenNow(a)
    local el = axElement(a:bundleID())
    if el then
        local ok, v = pcall(function() return el:attributeValue("AXHidden") end)
        if ok and v ~= nil then return v == true end
    end
    return not a:isFrontmost()
end

-- 最小化窗口在激活后不会自己弹出来，这里只做 unminimize，不碰位置和大小
local function unminimize(a)
    local n = 0
    for _, w in ipairs(a:allWindows()) do
        local ok, isMin = pcall(function() return w:isMinimized() end)
        if ok and isMin then
            local done = pcall(function() w:unminimize() end)
            if done then n = n + 1 end
        end
    end
    return n
end

-- 真正把应用拉到前台。实测（本机 macOS 15）几种方式里只有 open -b 稳定生效：
--   launchOrFocusByBundleID / activateWithOptions(...)  → 窗口出现但前台仍是别的 app
--   AX kAXFrontmostAttribute                            → 同样拿不到焦点
--   hs.task.new(...)                                    → 建任务失败，不可用
--   hs.execute("/usr/bin/open -b <id>")                 → 每次都拿到焦点
-- 激活失效时窗口“出现了但没切过去”，看起来就像切了一下桌面又切回来。
local function activate(bundleID, label)
    local cmd = string.format("/usr/bin/open -b %q", bundleID)
    local ok, _, status = pcall(hs.execute, cmd)
    if not ok then
        log:errorf("open failed bundle=%s", bundleID)
        return false
    end
    log:event(label or "focus", string.format("bundle=%s status=%s", bundleID, tostring(status)))
    return true
end

local function bringToFront(bundleID)
    return activate(bundleID, "focus")
end

-- 隐藏后把焦点还给“按热键之前你在用的那个 App”。
-- 不还的话 macOS 会随便挑下一个 App，若它在别的桌面就会把整个屏幕切过去。
local function restoreFocus()
    local bid = cameFrom
    if not bid then return end
    cameFrom = nil
    activate(bid, "restore")
end

local function revealApp(a)
    local bid = a:bundleID()
    local hadHidden = isHiddenNow(a)
    local hadMin = unminimize(a)

    -- 记录呼出前的前台 App（即用户当前桌面上正在用的那个）
    local prev = app.frontmostApplication()
    if prev and prev:bundleID() and prev:bundleID() ~= bid then
        cameFrom = prev:bundleID()
    end

    if hadHidden then a:unhide() end
    bringToFront(bid)

    timer.doAfter(VERIFY_WAIT, function()
        local fresh = app.get(bid)
        if not fresh then return end
        if isHiddenNow(fresh) then
            fresh:unhide()
            bringToFront(bid)
        end
        log:event("shown", string.format("bundle=%s hidden_before=%s min=%d",
            bid, tostring(hadHidden), hadMin))
    end)
end

local function concealApp(a)
    local bid = a:bundleID()

    -- 顺序很重要：先把焦点还给来源 App，再隐藏。
    -- 反过来的话 hide 会触发焦点交接，macOS 可能挑中别的桌面上的 App，
    -- 整个屏幕就被切过去了（用户看到的就是“切桌面”）。
    restoreFocus()

    a:hide()  -- 返回值恒为 false，不采信，靠回读判断
    timer.doAfter(VERIFY_WAIT, function()
        local fresh = app.get(bid)
        if not fresh then return end
        if isHiddenNow(fresh) then
            log:event("hidden", "bundle=" .. bid)
            return
        end
        -- 实测：刚激活完立刻 hide 会被丢弃，补一次
        fresh:hide()
        timer.doAfter(VERIFY_WAIT, function()
            local again = app.get(bid)
            if again and not isHiddenNow(again) then
                log:errorf("hide ineffective bundle=%s", bid)
                alert.show("App Toggle: 隐藏失败 " .. bid, 2)
            else
                log:event("hidden", "bundle=" .. bid .. " retry=true")
            end
        end)
    end)
end

-- ---------------------------------------------------------------- 核心

function M.toggleApp(bundleID)
    if type(bundleID) ~= "string" or bundleID == "" then
        log:error("toggleApp requires bundleID")
        return
    end

    local a = app.get(bundleID)

    if a == nil then
        if not bundleInstalled(bundleID) then
            log:errorf("unknown bundle=%s", bundleID)
            alert.show("App Toggle: 找不到应用 " .. bundleID, 2)
            return
        end
        log:event("launch", "bundle=" .. bundleID)
        bringToFront(bundleID)
        -- 异步等待：新实例的窗口还没建好，此时再 hide 会失败
        timer.doAfter(LAUNCH_WAIT, function()
            local fresh = app.get(bundleID)
            if fresh then
                revealApp(fresh)
            else
                log:errorf("launch failed bundle=%s", bundleID)
                alert.show("App Toggle: 启动失败 " .. bundleID, 2)
            end
        end)
        return
    end

    -- 三段判断：隐藏中 → 呼出；在前台 → 隐藏；可见但在后面 → 先叫到前面。
    -- 不能只用“是否隐藏”二选一：窗口在所有桌面都可见，你在别的桌面按第一下时
    -- 它其实在后台，直接 hide 会让人莫名其妙。
    if isHiddenNow(a) then
        revealApp(a)
        return
    end
    local front = app.frontmostApplication()
    if front and front:bundleID() == bundleID then
        concealApp(a)
    else
        revealApp(a)
    end
end

-- ---------------------------------------------------------------- 注册

local function comboKey(mods, key)
    local parts = {}
    for _, m in ipairs(mods) do parts[#parts + 1] = string.lower(m) end
    parts[#parts + 1] = string.lower(key)
    table.sort(parts)
    return table.concat(parts, "+")
end

local function comboLabel(mods, key)
    local parts = {}
    for _, m in ipairs(mods) do parts[#parts + 1] = m end
    parts[#parts + 1] = string.upper(key)
    return table.concat(parts, "+")
end

local function register(spec, seen)
    local bundleID, key = spec.bundleID, spec.key
    local mods = spec.modifiers or {}

    if type(bundleID) ~= "string" or bundleID == "" then
        log:error("entry missing bundleID")
        return
    end
    if type(key) ~= "string" or key == "" then
        log:errorf("entry missing key bundle=%s", bundleID)
        return
    end

    local id, label = comboKey(mods, key), comboLabel(mods, key)
    if seen[id] then
        log:warnf("duplicate hotkey %s keep=%s drop=%s", label, seen[id], bundleID)
        return
    end
    if registered[id] then
        log:warnf("already bound %s bundle=%s", label, registered[id])
        return
    end

    if not hotkey.assignable(mods, key) then
        log:errorf("hotkey reserved by system %s bundle=%s", label, bundleID)
        alert.show("App Toggle: " .. label .. " 被系统占用", 2)
        return
    end

    local ok, hk = pcall(hotkey.bind, mods, key, nil, function()
        local now = timer.secondsSinceEpoch()
        if pending[id] and now - pending[id] < 0.3 then return end
        pending[id] = now
        local success, err = pcall(M.toggleApp, bundleID)
        if not success then
            log:errorf("toggle error bundle=%s err=%s", bundleID, tostring(err))
        end
    end)
    if not ok or not hk then
        log:errorf("bind failed %s bundle=%s", label, bundleID)
        alert.show("App Toggle: " .. label .. " 注册失败", 2)
        return
    end

    seen[id] = bundleID
    registered[id] = bundleID
    hotkeys[#hotkeys + 1] = hk
    log:infof("bound %s bundle=%s", label, bundleID)
end

function M.start(entries)
    entries = entries or M.apps
    local seen = {}
    for _, spec in ipairs(entries) do
        register(spec, seen)
    end
    log:infof("apptoggle started rules=%d", #entries)
    return M
end

function M.stop()
    for _, hk in ipairs(hotkeys) do hk:delete() end
    hotkeys, registered, pending = {}, {}, {}
    log:info("apptoggle stopped")
end

-- 运行期改配置后调用，无需重启 Hammerspoon
function M.reload(entries)
    M.stop()
    return M.start(entries)
end

return M