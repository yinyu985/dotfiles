local hs = hs
local timer = hs.timer
local task = hs.task
local alert = hs.alert
local caffeinate = hs.caffeinate
local menubar = hs.menubar
local styledtext = hs.styledtext
local console = (function()
    local function emit(prefix, level, message)
        print(string.format("-- [%s] %-5s %s", prefix, level, message))
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

    return new("procmon")
end)()

-- ============================================================
-- Process Resource Monitor (Hammerspoon)
--
-- Attribution priority:
--   1. lsappinfo: pid -> bundle_path -> outermost .app name
--   2. Path rules: /opt/oneagent/ -> AliEntSafe
--   3. ps command path: extract .app name from executable path
--   4. ppid/pgid inheritance: walk process tree upward
--   5. Fallback: executable filename
--
-- Action: menubar top list, user kills/restarts from hover submenu
-- All external commands run async via hs.task (no main thread blocking)
-- ============================================================

local procmon = {}

-- ---------- SVG icon ----------
local ICON_SVG = [[<svg xmlns="http://www.w3.org/2000/svg" width="19" height="19" viewBox="0 0 24 24">
        <path d="M0 0h24v24H0z" fill="none" />
        <path fill="#fff" d="M15 1v3h-1v1h-1v1h-2V3h1V2h1V1zm6 16v1h-1v2h-1v1h-1v1h-1v1h-2v-1h-5v1H8v-1H7v-1H6v-1H5v-1H4v-2H3v-7h1V8h1V7h2V6h3v1h4V6h3v1h2v1h1v1h-1v1h-1v5h1v1h1v1z" />
</svg>
]]
local ICON_CACHE = "/tmp/procmon_icon.svg"

-- ---------- Config ----------
local CONFIG = {
    build_id        = "2026-06-24-menubar-kill-v2",
    interval        = 5,
    log_file        = "/tmp/process_monitor.log",
    csv_file        = "/tmp/process_monitor_data.csv",
    status_file     = "/tmp/process_monitor_status.txt",
    csv_max_bytes   = 20 * 1024 * 1024,
    csv_top_n       = 15,
    menu_top_n      = 10,
    top_sample_interval = 60,
    lsappinfo_cache_seconds = 30,

    growth_detection = {
        baseline_window_seconds  = 30 * 60,
        min_baseline_samples     = 60,
        growth_ratio             = 1.5,
        min_growth_delta_mb      = 96,
        consecutive_hits         = 3,
        idle_reset_seconds       = 10 * 60,
        resume_warmup_samples    = 60,
    },

    restart_cooldown = 300,
    notify_repeat_seconds = 300,

    focus_guard_apps = {
        Kiro                     = true,
        Qoder                    = true,
        iTerm                    = true,
        ["iTerm2"]               = true,
        iDingTalk                = true,
        ["Brave Browser"]        = true,
        Helium                   = true,
        ["Google Chrome"]        = true,
        Safari                   = true,
        Firefox                  = true,
        Arc                      = true,
        ["Microsoft Edge"]       = true,
        OrbStack                 = true,
    },

    path_owner_rules = {
        { prefix = "/opt/oneagent/", owner = "AliEntSafe" },
    },
}

-- ---------- State ----------
local restart_history = {}
local csv_initialized = false
local monitor_timer = nil
local memory_history = {}
local growth_hits = {}
local last_event_kind = {}
local last_notify_time = {}
local active_tasks = {}
local collecting = false  -- guard against overlapping collections
local menu_item = nil
local last_snapshot = nil
local collect = nil

local top_mem_cache = { data = nil, expires_at = 0 }
local lsappinfo_cache = { pid_map = nil, expires_at = 0 }
local idle_state = { active = false, warmup_until = 0, last_idle_seconds = 0 }

-- ---------- Util ----------

local function timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function csv_timestamp()
    return os.date("%Y%m%dT%H%M%S")
end

local function log(msg)
    local line = string.format("[%s] %s", timestamp(), msg)
    local tag, body = msg:match("^%[([%w_%-]+)%]%s*(.*)$")
    if tag == "err" then
        console:error(body)
    elseif tag then
        console:event(tag, body)
    else
        console:info(msg)
    end
    local f = io.open(CONFIG.log_file, "a")
    if f then f:write(line .. "\n"); f:close() end
end

local function reset_log_file()
    local f = io.open(CONFIG.log_file, "w")
    if f then f:close() end
end

local function write_text_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content); f:close()
    return true
end

local function run_task(executable, args, callback)
    local id = tostring(math.random(100000, 999999))
    local finished = false
    local timeout_timer = nil

    local function finish(exitCode, stdout, stderr)
        if finished then return end
        finished = true
        if timeout_timer then
            timeout_timer:stop()
            timeout_timer = nil
        end
        active_tasks[id] = nil
        if callback then callback(exitCode, stdout or "", stderr or "") end
    end

    local on_exit = function(exitCode, stdout, stderr)
        finish(exitCode, stdout, stderr)
    end

    local t = task.new(executable, on_exit, args or {})
    if t then
        active_tasks[id] = t
        if t:start() then
            timeout_timer = timer.doAfter(15, function()
                if active_tasks[id] and active_tasks[id].terminate then
                    log("[err] task timeout: " .. tostring(executable))
                    active_tasks[id]:terminate()
                    finish(-1, "", "timeout")
                end
            end)
            return true
        end
        active_tasks[id] = nil
        log("[err] failed to start task: " .. tostring(executable))
    else
        log("[err] failed to create task: " .. tostring(executable))
    end
    return false
end

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

local function run_capture_task(executable, args, callback)
    local id = tostring(math.random(100000, 999999)) .. "_" .. tostring(os.time())
    local out_path = "/tmp/procmon_capture_" .. id .. ".out"
    local err_path = "/tmp/procmon_capture_" .. id .. ".err"
    local parts = { shell_quote(executable) }
    for _, arg in ipairs(args or {}) do parts[#parts + 1] = shell_quote(arg) end
    local cmd = table.concat(parts, " ") .. " > " .. shell_quote(out_path) .. " 2> " .. shell_quote(err_path)
    return run_task("/bin/bash", {"-c", cmd}, function(rc)
        local stdout = read_file(out_path)
        local stderr = read_file(err_path)
        os.remove(out_path)
        os.remove(err_path)
        if callback then callback(rc, stdout, stderr) end
    end)
end

local function pid_args(stats)
    local args = {}
    for pid in pairs((stats and stats.pids) or {}) do
        args[#args + 1] = tostring(pid)
    end
    table.sort(args, function(a, b) return tonumber(a) < tonumber(b) end)
    return args
end

local function format_mb(mb)
    mb = tonumber(mb) or 0
    if mb >= 1024 then return string.format("%.1fG", mb / 1024) end
    return string.format("%dM", math.floor(mb + 0.5))
end

local MENU_NAME_MAX_CELLS = 19

local MENU_ROW_STYLE = {
    font = { name = "Menlo", size = 13 },
    baselineOffset = 1,
    paragraphStyle = {
        lineBreak = "truncateTail",
        tabStops = {
            { location = 34, tabStopType = "left" },
            { location = 234, tabStopType = "right" },
        },
        defaultTabInterval = 500,
    },
}

local function menu_text(s)
    if styledtext then return styledtext.new(s, MENU_ROW_STYLE) end
    return s
end

local function char_display_cells(cp)
    if (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) then
        return 2
    end
    return 1
end

local function display_cells(s)
    local cells = 0
    for _, cp in utf8.codes(tostring(s or "")) do
        cells = cells + char_display_cells(cp)
    end
    return cells
end

local function compact_name(name, max_cells)
    name = tostring(name or "")
    max_cells = max_cells or MENU_NAME_MAX_CELLS
    if display_cells(name) <= max_cells then return name end

    local out = {}
    local ellipsis = "..."
    local limit = math.max(1, max_cells - 3)
    local cells = 0

    for _, cp in utf8.codes(name) do
        local w = char_display_cells(cp)
        if cells + w > limit then return table.concat(out) .. ellipsis end
        out[#out + 1] = utf8.char(cp)
        cells = cells + w
    end

    return table.concat(out)
end

local function menu_row_title(rank, name, value)
    return string.format("%2d.\t%s\t%s", rank, compact_name(name), value)
end

local function format_cpu_value(item)
    local s = item.stats or {}
    return string.format("%.1f%%", s.cpu or 0)
end

local function format_mem_value(item)
    local s = item.stats or {}
    return format_mb(s.mem_mb or 0)
end

local function sorted_copy(app_sorted, metric)
    local out = {}
    for i, item in ipairs(app_sorted or {}) do out[i] = item end
    table.sort(out, function(a, b)
        local av = (a.stats and a.stats[metric]) or 0
        local bv = (b.stats and b.stats[metric]) or 0
        if av == bv then return a.name < b.name end
        return av > bv
    end)
    return out
end

-- ---------- CSV ----------

local function init_csv()
    if csv_initialized then return end
    local f = io.open(CONFIG.csv_file, "r")
    local need_header = true
    if f then
        local c = f:read(1)
        if c then need_header = false end
        f:close()
    end
    if need_header then
        f = io.open(CONFIG.csv_file, "w")
        if f then
            f:write("timestamp,app_name,process_count,cpu_percent,mem_mb,mem_percent\n")
            f:close()
        end
    end
    csv_initialized = true
end

local function enforce_csv_limit()
    local f = io.open(CONFIG.csv_file, "r")
    if not f then return end
    local size = f:seek("end") or 0
    f:close()
    if size <= CONFIG.csv_max_bytes then return end
    f = io.open(CONFIG.csv_file, "w")
    if f then
        f:write("timestamp,app_name,process_count,cpu_percent,mem_mb,mem_percent\n")
        f:close()
        log(string.format("[csv] exceeded %dMB limit, reset",
            math.floor(CONFIG.csv_max_bytes / 1024 / 1024)))
    end
end

local function append_csv_batch(ts, app_sorted)
    enforce_csv_limit()
    local f = io.open(CONFIG.csv_file, "a")
    if not f then return end
    local limit = CONFIG.csv_top_n or 15
    for i = 1, math.min(#app_sorted, limit) do
        local item = app_sorted[i]
        local s = item.stats
        local safe = item.name:find(",") and ('"' .. item.name .. '"') or item.name
        f:write(string.format("%s,%s,%d,%.1f,%d,%.1f\n",
            ts, safe, s.count, s.cpu, s.mem_mb, s.mem_percent))
    end
    f:close()
end

-- ---------- Math ----------

local function median(values)
    if not values or #values == 0 then return nil end
    local sorted = {}
    for i, v in ipairs(values) do sorted[i] = v end
    table.sort(sorted)
    local mid = math.floor(#sorted / 2) + 1
    if #sorted % 2 == 1 then return sorted[mid] end
    return (sorted[mid - 1] + sorted[mid]) / 2
end

-- ---------- top mem parsing ----------

local function parse_top_mem_to_mb(raw)
    if not raw or raw == "" then return nil end
    local value, unit = raw:match("^([%d%.]+)([KMGTP])$")
    if not value or not unit then return nil end
    local mult = { K = 1/1024, M = 1, G = 1024, T = 1024*1024 }
    local n = tonumber(value)
    local m = mult[unit]
    if not n or not m then return nil end
    return math.floor(n * m + 0.5)
end

local function parse_top_output(stdout)
    if not stdout or #stdout == 0 then return nil end
    local mem_by_pid = {}
    for line in stdout:gmatch("[^\r\n]+") do
        local pid, mem = line:match("^%s*(%d+)%s+([%d%.]+[KMGTP])%s+")
        if pid and mem then
            local mb = parse_top_mem_to_mb(mem)
            if mb then mem_by_pid[tonumber(pid)] = mb end
        end
    end
    if next(mem_by_pid) then return mem_by_pid end
    return nil
end

-- ---------- lsappinfo attribution ----------

local function extract_outermost_app(bundle_path)
    if not bundle_path then return nil end
    return bundle_path:match("([^/]+)%.app")
end

local function extract_innermost_app(bundle_path)
    if not bundle_path then return nil end
    local last = nil
    for name in bundle_path:gmatch("([^/]+)%.app") do last = name end
    return last
end

local function parse_lsappinfo(output)
    local pid_map = {}
    local entries = {}
    local current = nil
    for line in output:gmatch("[^\r\n]+") do
        local display_name = line:match('^%s*%d+%)%s+"([^"]*)"')
        if display_name then
            current = { display_name = display_name }
            entries[#entries + 1] = current
        end
        if current then
            local bp = line:match('bundle path="([^"]*)"')
            if bp then current.bundle_path = bp end
            local pid = line:match("pid = (%d+)")
            if pid then current.pid = tonumber(pid) end
        end
    end

    local known_apps = {}
    local user_path_prefixes = {
        "/Applications/", "/opt/", "/Users/",
        "/Library/Input Methods/", "/private/var/",
    }
    for _, entry in ipairs(entries) do
        if entry.bundle_path and entry.pid then
            local outermost = extract_outermost_app(entry.bundle_path)
            if outermost then
                for _, prefix in ipairs(user_path_prefixes) do
                    if entry.bundle_path:sub(1, #prefix) == prefix then
                        known_apps[entry.display_name] = outermost
                        break
                    end
                end
            end
        end
    end

    local known_sorted = {}
    for display, owner in pairs(known_apps) do
        known_sorted[#known_sorted + 1] = { display = display, owner = owner }
    end
    table.sort(known_sorted, function(a, b) return #a.display > #b.display end)

    for _, entry in ipairs(entries) do
        if entry.pid then
            local owner_app, target_label, source = nil, nil, nil

            if entry.bundle_path then
                for _, prefix in ipairs(user_path_prefixes) do
                    if entry.bundle_path:sub(1, #prefix) == prefix then
                        owner_app = extract_outermost_app(entry.bundle_path)
                        target_label = extract_innermost_app(entry.bundle_path) or owner_app
                        source = "lsappinfo-path"
                        break
                    end
                end
            end

            if not owner_app then
                for _, kv in ipairs(known_sorted) do
                    if entry.display_name ~= kv.display
                        and entry.display_name:sub(1, #kv.display) == kv.display then
                        owner_app = kv.owner
                        local suffix = entry.display_name:sub(#kv.display + 1)
                        suffix = suffix:match("^%s*(.+)") or suffix
                        target_label = (suffix and suffix ~= "") and suffix or entry.display_name
                        source = "lsappinfo-prefix"
                        break
                    end
                end
            end

            if owner_app then
                pid_map[entry.pid] = {
                    owner_app = owner_app,
                    target_label = target_label or owner_app,
                    source = source,
                }
            end
        end
    end
    return pid_map
end

-- ---------- Command path attribution ----------

local function extract_app_from_command(command)
    if not command or command == "" then return nil end
    -- 便宜的预筛：绝大多数命令行里没有 .app，先 plain find 挡掉，避免在惰性捕获上回溯
    if not command:find(".app", 1, true) then return nil end
    local app = command:match("^%s*(.-%.app)/Contents/")
    if not app then app = command:match("^%s*(.-%.app)$") end
    if not app then return nil end
    return app:match("([^/]+)%.app$")
end

local function extract_inner_app_from_command(command)
    if not command or command == "" then return nil end
    if not command:find(".app", 1, true) then return nil end
    local last = nil
    for name in command:gmatch("([^/]+)%.app") do last = name end
    return last
end

local function extract_executable_name(command)
    if not command or command == "" then return nil end
    local token = command:match("^%s*([^%s]+)")
    if not token then return nil end
    local name = token:match("([^/]+)$") or token
    if name:find("=") or name:match("^sun%.") or name:match("^%-") then return nil end
    return name
end

local function match_path_owner_rule(command)
    if not command then return nil, nil end
    for _, rule in ipairs(CONFIG.path_owner_rules or {}) do
        if command:sub(1, #rule.prefix) == rule.prefix then
            return rule.owner, extract_executable_name(command) or "unknown"
        end
    end
    return nil, nil
end

local function is_ignored_command(command)
    if not command or command == "" then return true end
    if command:match("^/System/") then return true end
    if command:match("^/usr/lib/") then return true end
    if command:match("^/usr/sbin/") then return true end
    if command:match("^/Library/Apple/") then return true end
    if command:match("^/sbin/") then return true end
    if command:match("^/usr/libexec/") then return true end
    if command:match("^/usr/bin/") then return true end
    if command:match("taskgated") or command:match("kernelmanagerd") then return true end
    return false
end

local function is_monitored_command(command)
    if not command then return false end
    if command:match("^/Applications/") then return true end
    if command:match("^/Library/Input Methods/") then return true end
    if command:match("^/opt/") then return true end
    if command:match("^/Users/") then return true end
    if command:match("^/private/var/") then return true end
    return false
end

local function is_inheritance_boundary(command)
    if not command or command == "" then return true end
    if command:match("^/bin/") then return true end
    if command:match("^/usr/") then return true end
    if command:match("^/sbin/") then return true end
    if command:match("^/System/Library/") then return true end
    return false
end

-- ---------- Process tree attribution ----------

local function resolve_owner_by_tree(pid, processes, cache, visiting)
    if cache[pid] ~= nil then return cache[pid] or nil end
    local proc = processes[pid]
    if not proc then return nil end
    if visiting[pid] then return nil end
    visiting[pid] = true
    local app_name = extract_app_from_command(proc.command)
    if not app_name and proc.ppid and proc.ppid > 0 and proc.ppid ~= pid then
        local parent = processes[proc.ppid]
        if parent and not is_inheritance_boundary(parent.command) then
            app_name = resolve_owner_by_tree(proc.ppid, processes, cache, visiting)
        end
    end
    if not app_name and proc.pgid and proc.pgid > 0 and proc.pgid ~= pid then
        local leader = processes[proc.pgid]
        if leader then app_name = extract_app_from_command(leader.command) end
    end
    visiting[pid] = nil
    cache[pid] = app_name or false
    return app_name
end

-- ---------- Memory trend ----------

local function record_memory_sample(key, mem_mb, now)
    local settings = CONFIG.growth_detection
    local keep_after = now - settings.baseline_window_seconds
    local samples = memory_history[key] or {}
    local pruned = {}
    for _, s in ipairs(samples) do
        if s.ts >= keep_after then pruned[#pruned + 1] = s end
    end
    pruned[#pruned + 1] = { ts = now, mem_mb = mem_mb }
    memory_history[key] = pruned
end

local function evaluate_growth(key, now)
    local settings = CONFIG.growth_detection
    local samples = memory_history[key]
    if not samples or #samples == 0 then return nil end
    local baseline_values = {}
    local current_mem = nil
    for _, s in ipairs(samples) do
        if s.ts < now then baseline_values[#baseline_values + 1] = s.mem_mb
        elseif s.ts == now then current_mem = s.mem_mb end
    end
    if #baseline_values < settings.min_baseline_samples or not current_mem then return nil end
    local bm = median(baseline_values)
    if not bm then return nil end
    local ratio = current_mem / math.max(bm, 1)
    local delta = current_mem - bm
    return {
        baseline_median = bm, current_mem = current_mem,
        growth_ratio = ratio, growth_delta_mb = delta,
        exceeded = ratio >= settings.growth_ratio and delta >= (settings.min_growth_delta_mb or 0),
        baseline_sample_count = #baseline_values,
    }
end

local function reset_all_growth_state()
    memory_history = {}; growth_hits = {}; last_event_kind = {}
end

local function reset_growth_state(key)
    memory_history[key] = nil; growth_hits[key] = nil; last_event_kind[key] = nil
end

-- ---------- Idle detection ----------

local function update_idle_state(now)
    local settings = CONFIG.growth_detection
    local idle_seconds = math.floor(
        (caffeinate and caffeinate.getIdleTime and caffeinate.getIdleTime()) or 0)
    local threshold = settings.idle_reset_seconds or 0
    local is_idle = threshold > 0 and idle_seconds >= threshold
    idle_state.last_idle_seconds = idle_seconds
    if is_idle and not idle_state.active then
        idle_state.active = true; idle_state.warmup_until = 0
        reset_all_growth_state()
        log(string.format("[idle] user idle %ds, baseline cleared", idle_seconds))
    elseif not is_idle and idle_state.active then
        idle_state.active = false
        idle_state.warmup_until = now + ((settings.resume_warmup_samples or 0) * CONFIG.interval)
        reset_all_growth_state()
        log(string.format("[resume] user back, observe-only for %.0f min",
            math.max(idle_state.warmup_until - now, 0) / 60))
    end
end

local function detection_mode(now)
    if idle_state.active then return "idle" end
    if idle_state.warmup_until and now < idle_state.warmup_until then return "warmup" end
    return "active"
end

-- ---------- Action: kill app + restart ----------

-- Chromium-based browsers accept --restore-last-session at launch.
-- Safari is NOT included: it's not Chromium and uses its own setting
-- ("Safari opens with: All windows from last session").
local BROWSER_RESTORE_ARGS = {
    ["Google Chrome"]  = true,
    ["Brave Browser"]  = true,
    ["Microsoft Edge"] = true,
    ["Arc"]            = true,
}

local function graceful_quit_app(app_name, callback)
    local script = string.format('tell application "%s" to quit', app_name:gsub('"', '\\"'))
    run_task("/usr/bin/osascript", {"-e", script}, function()
        timer.doAfter(1, callback)
    end)
end

local function live_pids_from_output(stdout)
    local live = {}
    local seen = {}
    for pid in tostring(stdout or ""):gmatch("%d+") do
        if not seen[pid] then
            live[#live + 1] = pid
            seen[pid] = true
        end
    end
    table.sort(live, function(a, b) return tonumber(a) < tonumber(b) end)
    return live
end

local function query_live_pids(pids, callback)
    if not pids or #pids == 0 then
        if callback then callback({}) end
        return
    end
    run_capture_task("/bin/ps", {"-p", table.concat(pids, ","), "-o", "pid="}, function(_, stdout)
        if callback then callback(live_pids_from_output(stdout)) end
    end)
end

local function wait_for_pids_exit(pids, timeout_seconds, callback)
    if not pids or #pids == 0 then
        if callback then callback(true, {}) end
        return
    end

    local deadline = hs.timer.secondsSinceEpoch() + (timeout_seconds or 0)
    local function poll()
        query_live_pids(pids, function(live)
            if #live == 0 then
                callback(true, {})
                return
            end
            if hs.timer.secondsSinceEpoch() >= deadline then
                callback(false, live)
                return
            end
            timer.doAfter(0.5, poll)
        end)
    end

    poll()
end

local function signal_pids(pids, signal, callback)
    if not pids or #pids == 0 then
        if callback then callback(0) end
        return
    end

    local args = {}
    if signal then args[#args + 1] = signal end
    for _, pid in ipairs(pids) do args[#args + 1] = tostring(pid) end
    run_task("/bin/kill", args, function(rc)
        if callback then callback(rc) end
    end)
end

local function launch_app(app_name, app_path)
    local open_args = { app_path }
    if BROWSER_RESTORE_ARGS[app_name] then
        open_args[#open_args + 1] = "--args"
        open_args[#open_args + 1] = "--restore-last-session"
    end
    run_task("/usr/bin/open", open_args, function(rc)
        if rc == 0 then log(string.format("[action] %s restarted", app_name))
        else log(string.format("[action] %s restart failed (exit=%d)", app_name, rc)) end
    end)
end

local function restart_app(app_name, stats, reason)
    local check_paths = {
        "/Applications/" .. app_name .. ".app",
        "/Library/Input Methods/" .. app_name .. ".app",
    }
    local app_path = nil
    for _, p in ipairs(check_paths) do
        local f = io.open(p .. "/Contents/Info.plist", "r")
        if f then f:close(); app_path = p; break end
    end
    if not app_path then
        log(string.format("[err] %s.app not found, skip", app_name))
        return false
    end
    local restart_pids = pid_args(stats)
    log(string.format("[action] %s: %s", app_name, reason))
    if #restart_pids > 0 then
        log(string.format("[action] quit -> wait pids=%s -> force kill if needed -> open",
            table.concat(restart_pids, ",")))
    else
        log("[action] quit -> open (no tracked pids)")
    end

    graceful_quit_app(app_name, function()
        wait_for_pids_exit(restart_pids, 4, function(exited, live)
            if exited then
                launch_app(app_name, app_path)
                return
            end

            log(string.format("[action] %s still alive after quit, sending TERM to pids=%s",
                app_name, table.concat(live, ",")))
            signal_pids(live, nil, function()
                wait_for_pids_exit(live, 3, function(exited_after_term, live_after_term)
                    if exited_after_term then
                        launch_app(app_name, app_path)
                        return
                    end

                    log(string.format("[action] %s still alive after TERM, sending KILL to pids=%s",
                        app_name, table.concat(live_after_term, ",")))
                    signal_pids(live_after_term, "-KILL", function()
                        wait_for_pids_exit(live_after_term, 2, function(_, live_after_kill)
                            if #live_after_kill > 0 then
                                log(string.format("[err] %s still has live pids after KILL: %s",
                                    app_name, table.concat(live_after_kill, ",")))
                            end
                            launch_app(app_name, app_path)
                        end)
                    end)
                end)
            end)
        end)
    end)
    return true
end

local function kill_app(app_name, stats, reason)
    local args = pid_args(stats)
    if #args == 0 then
        alert.show("No live pids for " .. app_name, 2)
        return false
    end

    log(string.format("[action] kill %s: %s (%d pids)", app_name, reason or "menu", #args))
    run_task("/bin/kill", args, function(rc)
        if rc == 0 then
            reset_growth_state(app_name)
            alert.show("Killed " .. app_name, 2)
            log(string.format("[action] %s killed", app_name))
            timer.doAfter(1, function()
                if collect then collect() end
            end)
        else
            alert.show("Kill failed: " .. app_name, 3)
            log(string.format("[err] kill failed for %s (exit=%s)", app_name, tostring(rc)))
        end
    end)
    return true
end

-- ---------- Status page ----------

local function recent_trend_text(key, limit)
    local samples = memory_history[key] or {}
    local start = math.max(1, #samples - limit + 1)
    local parts = {}
    for i = start, #samples do parts[#parts + 1] = tostring(samples[i].mem_mb) end
    return table.concat(parts, " ")
end

local function is_focus_guard(app_name)
    return CONFIG.focus_guard_apps[app_name] == true
end

local function is_app_focused(app_name)
    local app = hs.application.find(app_name, true)
    if app and app:isFrontmost() then return true end
    return false
end

local function render_status(ts, app_sorted, now)
    local mode = detection_mode(now)
    local lines = {
        "Process Monitor Snapshot",
        string.format("Updated: %s", ts),
        string.format("Build: %s", CONFIG.build_id),
        "Attribution: lsappinfo + path rules + ps path + tree",
        string.format("Rule: total_mem > median(30m)*%.2f & delta>=%dMB x%d",
            CONFIG.growth_detection.growth_ratio,
            CONFIG.growth_detection.min_growth_delta_mb,
            CONFIG.growth_detection.consecutive_hits),
        "Action: menubar top list (hover app -> Kill/Restart)",
        string.format("Idle: >= %d min | CSV: top %d",
            math.floor((CONFIG.growth_detection.idle_reset_seconds or 0) / 60),
            CONFIG.csv_top_n or 15),
        "",
    }
    if mode == "idle" then
        lines[#lines + 1] = string.format("Mode: IDLE (%ds)", idle_state.last_idle_seconds or 0)
        lines[#lines + 1] = ""
    elseif mode == "warmup" then
        lines[#lines + 1] = string.format("Mode: WARMUP until %s",
            os.date("%H:%M:%S", idle_state.warmup_until))
        lines[#lines + 1] = ""
    end
    if #app_sorted == 0 then
        lines[#lines + 1] = "No monitored processes."
        return table.concat(lines, "\n") .. "\n"
    end
    for _, item in ipairs(app_sorted) do
        local app = item.name
        local s = item.stats
        local trend = item.trend
        local hits = growth_hits[app] or 0
        local action = "observe"
        if is_focus_guard(app) then
            if trend and trend.exceeded then
                action = is_app_focused(app) and "alert/focused" or "alert/bg"
            else
                action = "guard"
            end
        elseif s.source == "fallback" then
            action = "observe"
        else
            action = (trend and trend.exceeded) and "alert" or "ready"
        end
        lines[#lines + 1] = string.format("%s  [%s]", app, action)
        if trend then
            lines[#lines + 1] = string.format(
                "  total=%5dMB  baseline=%5.0fMB  delta=%+5.0fMB  ratio=%.2fx  hits=%d/%d",
                s.mem_mb, trend.baseline_median, trend.growth_delta_mb,
                trend.growth_ratio, hits, CONFIG.growth_detection.consecutive_hits)
        else
            lines[#lines + 1] = string.format(
                "  total=%5dMB  hits=%d/%d  (baseline: %d samples)",
                s.mem_mb, hits, CONFIG.growth_detection.consecutive_hits,
                #(memory_history[app] or {}))
        end
        lines[#lines + 1] = string.format("  procs=%3d  cpu=%6.1f%%  mem=%5.1f%%  src=%s",
            s.count, s.cpu, s.mem_percent, s.source or "?")
        lines[#lines + 1] = string.format("  trend_mb=%s", recent_trend_text(app, 12))
        if s.targets and next(s.targets) then
            local tl = {}
            for tn, ts2 in pairs(s.targets) do tl[#tl + 1] = { name = tn, s = ts2 } end
            table.sort(tl, function(a, b) return a.s.mem_mb > b.s.mem_mb end)
            for _, t in ipairs(tl) do
                lines[#lines + 1] = string.format("    |- %s: %dMB  procs=%d  cpu=%.1f%%",
                    t.name, t.s.mem_mb, t.s.count, t.s.cpu)
            end
        end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n") .. "\n"
end

-- ---------- Menubar ----------

local function open_activity_monitor()
    run_task("/usr/bin/open", {"-a", "Activity Monitor"})
end

local function build_app_menu(item)
    local app_name = item.name
    local stats = item.stats or {}
    return {
        {
            title = string.format("Kill %s", app_name),
            fn = function() kill_app(app_name, stats, "menubar") end,
        },
        {
            title = string.format("Restart %s", app_name),
            fn = function()
                if restart_app(app_name, stats, "menubar restart") then
                    reset_growth_state(app_name)
                    timer.doAfter(3, function()
                        if collect then collect() end
                    end)
                end
            end,
        },
    }
end

local function append_top_section(menu, title, items, value_formatter)
    menu[#menu + 1] = { title = title, disabled = true }
    if #items == 0 then
        menu[#menu + 1] = { title = "  No processes", disabled = true }
        return
    end
    local limit = CONFIG.menu_top_n or 10
    for i = 1, math.min(#items, limit) do
        local item = items[i]
        local value = value_formatter(item)
        menu[#menu + 1] = {
            title = menu_text(menu_row_title(i, item.name, value)),
            menu = build_app_menu(item),
        }
    end
end

local function render_menu(snapshot)
    local menu = {}
    if not snapshot or not snapshot.app_sorted then
        return {
            { title = "Collecting...", disabled = true },
            { title = "Refresh Now", fn = function() if collect then collect() end end },
            { title = "Open Activity Monitor", fn = open_activity_monitor },
        }
    end

    local app_sorted = snapshot.app_sorted
    local top_cpu = sorted_copy(app_sorted, "cpu")
    local top_mem = sorted_copy(app_sorted, "mem_mb")

    menu[#menu + 1] = { title = "Updated: " .. snapshot.ts, disabled = true }
    menu[#menu + 1] = { title = "Mode: " .. snapshot.mode, disabled = true }
    menu[#menu + 1] = { title = "-" }
    append_top_section(menu, "Top CPU", top_cpu, format_cpu_value)
    menu[#menu + 1] = { title = "-" }
    append_top_section(menu, "Top MEM", top_mem, format_mem_value)
    menu[#menu + 1] = { title = "-" }
    menu[#menu + 1] = { title = "Refresh Now", fn = function() if collect then collect() end end }
    menu[#menu + 1] = { title = "Open Activity Monitor", fn = open_activity_monitor }
    menu[#menu + 1] = { title = "Open Status File", fn = function() run_task("/usr/bin/open", {CONFIG.status_file}) end }
    menu[#menu + 1] = { title = "Open Log File", fn = function() run_task("/usr/bin/open", {CONFIG.log_file}) end }
    return menu
end

-- 不再每周期重建菜单：把渲染函数交给 menubar，Hammerspoon 只在用户点击时调用它。
local function update_snapshot(snapshot)
    if snapshot then last_snapshot = snapshot end
end

local function create_menu_item()
    if not menubar then return end
    if not menu_item then
        menu_item = menubar.new(true, "procmon_menu_bar")
        if not menu_item then
            alert.show("procmon menu bar item failed", 3)
            return
        end

        -- Write embedded SVG to temp file and load as icon
        local f = io.open(ICON_CACHE, "w")
        if f then
            f:write(ICON_SVG)
            f:close()
            local icon = hs.image.imageFromPath(ICON_CACHE)
            if icon then menu_item:setIcon(icon, true) end
        end
    end

    menu_item:setTitle("")
    menu_item:setTooltip("Process Monitor")
    menu_item:setMenu(function() return render_menu(last_snapshot) end)
end

-- ---------- Core: process ps output ----------

local function process_data(ps_output, top_mem_by_pid, lsappinfo_map)
    local processes = {}
    for line in ps_output:gmatch("[^\r\n]+") do
        local pid, ppid, pgid, cpu, mem_pct, rss, command =
            line:match("^%s*(%d+)%s+(%d+)%s+(%d+)%s+([%d%.]+)%s+([%d%.]+)%s+(%d+)%s+(.+)%s*$")
        if pid and command then
            local npid = tonumber(pid)
            local dominated = lsappinfo_map[npid] ~= nil
            local has_rule = match_path_owner_rule(command) ~= nil
            local monitorable = not is_ignored_command(command) and is_monitored_command(command)
            if dominated or has_rule or monitorable then
                processes[npid] = {
                    pid = npid, ppid = tonumber(ppid), pgid = tonumber(pgid),
                    cpu = tonumber(cpu), mem_pct = tonumber(mem_pct),
                    mem_mb = (top_mem_by_pid and top_mem_by_pid[npid])
                        or math.floor(tonumber(rss) / 1024),
                    command = command,
                }
            end
        end
    end

    local app_stats = {}
    local tree_cache = {}
    local visiting = {}

    for pid, proc in pairs(processes) do
        local owner_app, target_label, source = nil, nil, nil

        local lsa = lsappinfo_map[pid]
        if lsa then
            owner_app = lsa.owner_app
            target_label = lsa.target_label or owner_app
            source = lsa.source
        end
        if not owner_app then
            local ro, rt = match_path_owner_rule(proc.command)
            if ro then owner_app = ro; target_label = rt; source = "path-rule" end
        end
        if not owner_app then
            owner_app = extract_app_from_command(proc.command)
            if owner_app then
                target_label = extract_inner_app_from_command(proc.command) or owner_app
                source = "command-path"
            end
        end
        if not owner_app then
            owner_app = resolve_owner_by_tree(pid, processes, tree_cache, visiting)
            if owner_app then
                target_label = extract_executable_name(proc.command) or "unknown"
                source = "tree"
            end
        end
        if not owner_app then
            local exe = extract_executable_name(proc.command)
            owner_app = (exe and exe ~= "") and exe or "unknown"
            target_label = owner_app
            source = "fallback"
        end

        if not app_stats[owner_app] then
            app_stats[owner_app] = {
                mem_mb = 0, cpu = 0, mem_percent = 0,
                count = 0, pids = {}, targets = {}, source = source,
            }
        end
        local s = app_stats[owner_app]
        s.mem_mb = s.mem_mb + proc.mem_mb
        s.cpu = s.cpu + proc.cpu
        s.mem_percent = s.mem_percent + proc.mem_pct
        s.count = s.count + 1
        s.pids[pid] = true
        -- source priority
        if source == "lsappinfo-path" or source == "lsappinfo-prefix" then
            s.source = source
        elseif source == "path-rule" and s.source ~= "lsappinfo-path" and s.source ~= "lsappinfo-prefix" then
            s.source = source
        elseif s.source == "fallback" and source ~= "fallback" then
            s.source = source
        end
        if not s.targets[target_label] then
            s.targets[target_label] = { mem_mb = 0, cpu = 0, count = 0 }
        end
        local t = s.targets[target_label]
        t.mem_mb = t.mem_mb + proc.mem_mb
        t.cpu = t.cpu + proc.cpu
        t.count = t.count + 1
    end

    -- record samples & evaluate
    local ts = timestamp()
    local now = os.time()
    update_idle_state(now)
    for app_name, s in pairs(app_stats) do
        record_memory_sample(app_name, s.mem_mb, now)
    end

    local app_sorted = {}
    for name, stats in pairs(app_stats) do
        app_sorted[#app_sorted + 1] = { name = name, stats = stats, trend = evaluate_growth(name, now) }
    end
    table.sort(app_sorted, function(a, b) return a.stats.mem_mb > b.stats.mem_mb end)

    local mode = detection_mode(now)

    -- action logic: alert on growth, manual action lives in the menubar
    for _, item in ipairs(app_sorted) do
        local app_name = item.name
        local s = item.stats
        local trend = item.trend
        if not trend then
            -- not enough samples
        elseif mode ~= "active" then
            growth_hits[app_name] = 0
            if last_event_kind[app_name] ~= mode then
                log(string.format("[skip] %s: %s, paused", app_name,
                    mode == "idle" and "user idle" or "rebuilding baseline"))
                last_event_kind[app_name] = mode
            end
        elseif trend.exceeded then
            local prev = growth_hits[app_name] or 0
            growth_hits[app_name] = math.min(prev + 1, CONFIG.growth_detection.consecutive_hits)
            local reason = string.format("now %.0fMB, baseline %.0fMB, +%.0fMB / %.2fx",
                trend.current_mem, trend.baseline_median, trend.growth_delta_mb, trend.growth_ratio)

            if s.source == "fallback" then
                if last_event_kind[app_name] ~= "observe_fallback" then
                    log(string.format("[skip] %s: %s (fallback)", app_name, reason))
                    last_event_kind[app_name] = "observe_fallback"
                end
            elseif growth_hits[app_name] < CONFIG.growth_detection.consecutive_hits then
                local ek = "trend_" .. tostring(growth_hits[app_name])
                if last_event_kind[app_name] ~= ek then
                    log(string.format("[trend] %s: %s, hit %d/%d", app_name, reason,
                        growth_hits[app_name], CONFIG.growth_detection.consecutive_hits))
                    last_event_kind[app_name] = ek
                end
            else
                -- threshold reached: notify, repeat every notify_repeat_seconds
                local last_t = last_notify_time[app_name] or 0
                if now - last_t >= (CONFIG.notify_repeat_seconds or 300) then
                    local focused_tag = ""
                    if is_focus_guard(app_name) then
                        focused_tag = is_app_focused(app_name) and " [focused]" or " [background]"
                    end
                    log(string.format("[alert] %s: %s%s", app_name, reason, focused_tag))
                    hs.notify.new({
                        title = "procmon: " .. app_name .. " memory growth",
                        informativeText = string.format("%.0fMB (+%.0fMB / %.1fx)%s",
                            trend.current_mem, trend.growth_delta_mb, trend.growth_ratio, focused_tag),
                        withdrawAfter = 60,
                    }):send()
                    last_notify_time[app_name] = now
                    last_event_kind[app_name] = "notified"
                end
            end
        else
            growth_hits[app_name] = 0
            last_event_kind[app_name] = nil
            last_notify_time[app_name] = nil
        end
    end

    for key in pairs(growth_hits) do
        if not app_stats[key] then
            growth_hits[key] = nil
            last_event_kind[key] = nil
            last_notify_time[key] = nil
            memory_history[key] = nil
        end
    end

    append_csv_batch(csv_timestamp(), app_sorted)
    local status_text = render_status(ts, app_sorted, now)
    if not write_text_file(CONFIG.status_file, status_text) then
        log("[err] failed to write status")
    end
    update_snapshot({
        ts = ts,
        mode = mode,
        app_sorted = app_sorted,
    })
end

-- ---------- Async collect pipeline ----------
-- Pipeline: ps (async) -> top (async, if cache expired) -> lsappinfo (async, if cache expired) -> process_data

collect = function()
    if collecting then return end  -- skip if previous cycle still running
    collecting = true

    -- Step 1: async ps
    run_capture_task("/bin/ps", {"-axo", "pid=,ppid=,pgid=,%cpu=,%mem=,rss=,command="}, function(rc, ps_out)
        if rc ~= 0 or not ps_out or #ps_out == 0 then
            log("[err] ps failed (rc=" .. tostring(rc) .. ")")
            collecting = false
            return
        end

        -- Step 2: async top (if cache expired)
        local now = os.time()
        if top_mem_cache.data and top_mem_cache.expires_at > now then
            -- cache hit, skip to step 3
            local step3
            step3 = function()
                -- Step 3: async lsappinfo (if cache expired)
                if lsappinfo_cache.pid_map and lsappinfo_cache.expires_at > now then
                    -- cache hit, go to process
                    local ok, err = pcall(process_data, ps_out, top_mem_cache.data, lsappinfo_cache.pid_map)
                    if not ok then log("[err] processing: " .. tostring(err)) end
                    collecting = false
                else
                    run_capture_task("/usr/bin/lsappinfo", {"list"}, function(rc3, lsa_out)
                        if rc3 == 0 and lsa_out and #lsa_out > 0 then
                            lsappinfo_cache.pid_map = parse_lsappinfo(lsa_out)
                            lsappinfo_cache.expires_at = os.time() + (CONFIG.lsappinfo_cache_seconds or 30)
                        end
                        local ok, err = pcall(process_data, ps_out, top_mem_cache.data, lsappinfo_cache.pid_map or {})
                        if not ok then log("[err] processing: " .. tostring(err)) end
                        collecting = false
                    end)
                end
            end
            step3()
        else
            -- need fresh top
            run_capture_task("/usr/bin/top", {"-l", "1", "-stats", "pid,mem,command"}, function(rc2, top_out)
                if rc2 == 0 and top_out and #top_out > 0 then
                    local parsed = parse_top_output(top_out)
                    if parsed then
                        top_mem_cache.data = parsed
                        top_mem_cache.expires_at = os.time() + math.max(CONFIG.top_sample_interval, 1)
                    end
                end
                -- Step 3: async lsappinfo
                if lsappinfo_cache.pid_map and lsappinfo_cache.expires_at > os.time() then
                    local ok, err = pcall(process_data, ps_out, top_mem_cache.data, lsappinfo_cache.pid_map)
                    if not ok then log("[err] processing: " .. tostring(err)) end
                    collecting = false
                else
                    run_capture_task("/usr/bin/lsappinfo", {"list"}, function(rc3, lsa_out)
                        if rc3 == 0 and lsa_out and #lsa_out > 0 then
                            lsappinfo_cache.pid_map = parse_lsappinfo(lsa_out)
                            lsappinfo_cache.expires_at = os.time() + (CONFIG.lsappinfo_cache_seconds or 30)
                        end
                        local ok, err = pcall(process_data, ps_out, top_mem_cache.data, lsappinfo_cache.pid_map or {})
                        if not ok then log("[err] processing: " .. tostring(err)) end
                        collecting = false
                    end)
                end
            end)
        end
    end)
end

-- ---------- Start / Stop ----------

function procmon.start()
    if monitor_timer then monitor_timer:stop(); monitor_timer = nil end
    init_csv()
    reset_log_file()
    create_menu_item()
    log("procmon started")
    log(string.format("interval: %ds (fully async)", CONFIG.interval))
    log("attr: lsappinfo + path-rules + ps + tree")
    log(string.format("csv: top %d -> %s", CONFIG.csv_top_n or 15, CONFIG.csv_file))
    log("log: " .. CONFIG.log_file)
    log("status: " .. CONFIG.status_file)
    timer.doAfter(0.5, collect)
    monitor_timer = timer.doEvery(CONFIG.interval, collect)
end

function procmon.stop()
    if monitor_timer then
        monitor_timer:stop(); monitor_timer = nil
        log("procmon stopped")
        if menu_item then
            menu_item:setTitle("proc off")
            menu_item:setMenu({ { title = "procmon stopped", disabled = true } })
        end
        alert.show("procmon stopped", 2)
    end
end

procmon.start()
return procmon
