-- ~/.hammerspoon/ocr/remote/init.lua
-- 选区截图 / 剪贴板图片 → 远程 Vision 模型 OCR → 结果回写剪贴板
-- 跟原生 Vision 版（ocr/apple/init.lua）并存，用不同快捷键
local M = {}
local log = (function()
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
    return new("remote_ocr")
end)()
-- 持有正在跑的 task 引用，防止被 Lua GC 提前回收（GC 走了回调就再也不会触发）
M._inflightTasks = {}
M._feedbackCanvases = {}
M._feedbackTimers = {}
M._successSound = nil
M._activeKeyIndex = 1

local providerApiKeys = {}
do
    local ok, configured = pcall(require, "ocr.remote.secrets")
    if ok and type(configured) == "table" then providerApiKeys = configured end
end

-- ========== Providers ==========
-- Change only this value to switch providers. Models are tried in order; within
-- each model, a rate limit switches to the next key before trying the next model.
M.activeProvider = "google"
M.providers = {
    google = {
        name = "google",
        apiKeys = providerApiKeys.google or {},
        endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        models = {
            "gemini-3.5-flash-lite",
            "gemini-3.5-flash",
            "gemini-3.6-flash",
        },
        authHeader = "Authorization",
        authPrefix = "Bearer ",
        maxTokensField = "max_tokens",
    },
    aliyun = {
        name = "aliyun",
        apiKeys = providerApiKeys.aliyun or {},
        endpoint = "https://llm-35z9wf1e0wcl497y.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions",
        models = {
            "qwen3.8-flash",
        },
        authHeader = "Authorization",
        authPrefix = "Bearer ",
        maxTokensField = "max_tokens",
        enableThinking = false,
    },
    groq = {
        name = "groq",
        apiKeys = providerApiKeys.groq or {},
        endpoint = "https://api.groq.com/openai/v1/chat/completions",
        models = {
            "qwen/qwen3.6-27b",
        },
        authHeader = "Authorization",
        authPrefix = "Bearer ",
        maxTokensField = "max_completion_tokens",
        reasoningEffort = "none",
    },
    mistral = {
        name = "mistral",
        apiKeys = providerApiKeys.mistral or {},
        endpoint = "https://api.mistral.ai/v1/ocr",
        models = {
            "mistral-ocr-latest",
        },
        authHeader = "Authorization",
        authPrefix = "Bearer ",
        apiType = "mistral_ocr",
        tableFormat = "markdown",
    },
}
M.prompt = [[OCR only. Return plain UTF-8 text with no Markdown, code fences, or explanation. The English and Chinese rules below are identical instructions: execute them once and never duplicate the output.
ENGLISH
1. Transcribe every visible character exactly. Never translate, autocorrect, infer, calculate, normalize, omit, duplicate, or invent.
2. NUMBERS ARE CRITICAL: verify every digit individually. Preserve digit count, zeros, minus/plus signs, decimal points, commas, percent/currency symbols, and parentheses. If one character is unreadable, write `?` only at that position; never guess.
3. Preserve the original 2D layout and reading order. In every table, grid, form, or repeated multi-column region: one visual row = one output line; each visual column = one TSV field separated by one literal TAB. Keep columns attached to their rows, keep a consistent field count, and preserve blank cells as empty fields. Never transpose a table or move a column below its rows.
4. Outside grids, preserve top-to-bottom and left-to-right order, line breaks, blank lines, and indentation.
5. Before returning, silently recheck every number and row alignment.
中文
1. 只做忠实 OCR，逐字符抄录。禁止翻译、纠错、推断、计算、规范化、遗漏、重复或编造。
2. 数字最重要：每个数字必须逐位核对；完整保留位数、零、正负号、小数点、逗号、百分号、货币符号和括号。单个字符确实无法辨认时，只在原位置写 `?`，绝不猜测。
3. 保留原始二维位置和阅读顺序。表格、网格、表单及重复多列区域必须满足：一个视觉行对应一个输出行；每个视觉列对应一个 TSV 字段，字段之间必须使用真正的 Tab；列必须留在所属数据行内；相邻行字段数保持一致；空单元格保留为空字段。绝不转置表格，绝不把整列移到数据行下方。
4. 非网格内容保留从上到下、从左到右的顺序，以及原有换行、空行和缩进。
5. 输出前静默复核每个数字和每行对齐。`。
TSV layout example only; never copy it:]]
    .. "\nA\tB\tC\n1\t2\t3\n4\t5\t\n"
M.maxBase64Bytes = 9 * 1024 * 1024  -- Remote image payload limit is 10MB; leave overhead
M.imageFormat = "PNG"               -- 固定无损 PNG
M.maxImageLongEdge = 1200           -- 等比例缩放，减少视觉模型处理的像素数
M.maxImagePixels = 2 * 1000 * 1000
-- 官方 OCR 模型族 max_tokens 默认 4096；关掉 thinking 后纯 OCR 输出 4096 足够常见屏幕截图。
M.maxCompletionTokens = 4096
M.requestTimeoutSeconds = 90
M.maxEmptyResponseRetries = 1          -- 空响应额外重试次数；1 表示总共最多请求 2 次
M.successSoundName = "Glass"
M.successSoundVolume = 0.35
M.successAlertSeconds = 1.15
M.successFlashSeconds = 0.12
-- ===========================
local function notify(title, msg)
    hs.notify.new({ title = title, informativeText = msg or "" }):send()
end
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
local function playSuccessSound()
    if not M._successSound then
        local sound = hs.sound.getByName(M.successSoundName)
            or hs.sound.getByName("Ping")
            or hs.sound.getByName("Pop")
            or hs.sound.getByName("Tink")
        if sound then
            sound:volume(M.successSoundVolume)
            M._successSound = sound
        end
    end
    if M._successSound then
        M._successSound:stop()
        M._successSound:currentTime(0)
        M._successSound:play()
    end
end
local function flashScreens()
    local screens = hs.screen.allScreens()
    for _, screen in ipairs(screens) do
        local frame = screen:fullFrame()
        local canvas = hs.canvas.new(frame)
        canvas[1] = {
            type = "rectangle",
            action = "fill",
            fillColor = { red = 0.15, green = 0.95, blue = 0.38, alpha = 0.18 },
            frame = { x = 0, y = 0, w = frame.w, h = frame.h },
        }
        canvas:level("screenSaver")
        canvas:show(0)
        table.insert(M._feedbackCanvases, canvas)
        local timer
        timer = hs.timer.doAfter(M.successFlashSeconds, function()
            canvas:delete(0.10)
            for i = #M._feedbackCanvases, 1, -1 do
                if M._feedbackCanvases[i] == canvas then table.remove(M._feedbackCanvases, i) end
            end
            for i = #M._feedbackTimers, 1, -1 do
                if M._feedbackTimers[i] == timer then table.remove(M._feedbackTimers, i) end
            end
        end)
        table.insert(M._feedbackTimers, timer)
    end
end
local function successFeedback(text)
    local chars = text and #text or 0
    hs.alert.closeAll(0.05)
    hs.alert.show("copied: " .. tostring(chars) .. " words", successAlertStyle, M.successAlertSeconds)
    pcall(playSuccessSound)
    pcall(flashScreens)
end
local function fmtSeconds(value)
    value = tonumber(value)
    if not value then return "?" end
    return string.format("%.3f", value)
end
local function imageSize(img)
    local sz = img and img:size()
    local w = sz and tonumber(sz.w)
    local h = sz and tonumber(sz.h)
    if not w or not h or w <= 0 or h <= 0 then return nil end
    return { w = w, h = h }
end
local function resizeImage(img, ratio)
    local sz = imageSize(img)
    if not sz then return nil end
    local resized = img:setSize({
        w = math.max(1, math.floor(sz.w * ratio + 0.5)),
        h = math.max(1, math.floor(sz.h * ratio + 0.5)),
    }, true)
    return resized, imageSize(resized)
end
local function pngBytesToDataURL(pngBytes)
    if not pngBytes or pngBytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
    local base64 = hs.base64.encode(pngBytes):gsub("%s", "")
    if base64 == "" then return nil end
    return "data:image/png;base64," .. base64
end
local function pngPixelSize(pngBytes)
    if not pngBytes or #pngBytes < 24 or pngBytes:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return nil, nil
    end
    local function uint32be(offset)
        local a, b, c, d = pngBytes:byte(offset, offset + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    return uint32be(17), uint32be(21)
end
local function pngFileToDataURL(imagePath)
    local file = io.open(imagePath, "rb")
    if not file then return nil end
    local pngBytes = file:read("*a")
    file:close()
    local width, height = pngPixelSize(pngBytes)
    return pngBytesToDataURL(pngBytes), #pngBytes, width, height
end
-- 剪贴板图片兼容路径。热键截屏不使用此路径，直接发送 screencapture 产出的 PNG 文件。
local function imageToDataURL(img)
    local imagePath = "/tmp/remote_ocr_image_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000)) .. ".png"
    -- true：把 macOS 的 point size 按 1x 像素写出，避免 Retina backing
    -- 将目标 1922x1041 再编码成 3844x2082。
    if not img:saveToFile(imagePath, true, "PNG") then return nil end
    local dataUrl, pngBytes, width, height = pngFileToDataURL(imagePath)
    os.remove(imagePath)
    return dataUrl, pngBytes, width, height
end
local function downsampleForOCR(img)
    local sz = imageSize(img)
    if not sz then return img, nil, nil, nil, "unknown-size" end
    local ratio = 1
    local longEdge = math.max(sz.w, sz.h)
    local pixels = sz.w * sz.h
    if M.maxImageLongEdge and M.maxImageLongEdge > 0 and longEdge > M.maxImageLongEdge then
        ratio = math.min(ratio, M.maxImageLongEdge / longEdge)
    end
    if M.maxImagePixels and M.maxImagePixels > 0 and pixels > M.maxImagePixels then
        ratio = math.min(ratio, math.sqrt(M.maxImagePixels / pixels))
    end
    log:eventf("scale", "long_edge=%d max_long_edge=%d max_pixels=%d ratio=%.3f",
        longEdge, M.maxImageLongEdge or 0, M.maxImagePixels or 0, ratio)
    if ratio >= 0.995 then
        return img, sz, sz, 1, "kept"
    end
    local resized, outSize = resizeImage(img, ratio)
    return resized or img, sz, outSize or sz, ratio, "downsampled"
end
-- 编码成 data URL；先按分辨率降采样，再用 base64 上限做极端兜底。
local function encodeToDataURL(img)
    local encodeStart = hs.timer.absoluteTime()
    local outImg, originalSize, finalSize, ratio, mode = downsampleForOCR(img)
    local url, pngBytes, encodedWidth, encodedHeight
    if outImg then
        url, pngBytes, encodedWidth, encodedHeight = imageToDataURL(outImg)
    end
    if not url then return nil end
    local elapsedMs = (hs.timer.absoluteTime() - encodeStart) / 1000000
    if originalSize and finalSize then
        log:eventf("image", "mode=%s original=%.0fx%.0f final=%.0fx%.0f png_bytes=%s url_bytes=%d ms=%.1f",
            tostring(mode), originalSize.w, originalSize.h, finalSize.w, finalSize.h,
            tostring(pngBytes or "?"), #url, elapsedMs)
    else
        log:eventf("image", "mode=%s png_bytes=%s url_bytes=%d ms=%.1f",
            tostring(mode), tostring(pngBytes or "?"), #url, elapsedMs)
    end
    return url
end
local function finishRecognizedText(text)
    if not text or text == "" then
        notify("Remote OCR 失败", "没有可复制的识别文本")
        return
    end
    hs.pasteboard.setContents(text)
    log:eventf("done", "text_chars=%d", #text)
    successFeedback(text)
end
local requestWithKey
local requestWithModel
local function tryNextModel(requestContext, reason)
    local modelIndex = tonumber(requestContext.modelIndex or 1) or 1
    local models = requestContext.models or {}
    if modelIndex >= #models then return false end
    local nextModelIndex = modelIndex + 1
    log:warnf("model failed reason=%s switch=%d/%d",
        tostring(reason or "unknown"), nextModelIndex, #models)
    requestWithModel(
        requestContext.dataUrl,
        requestContext.provider,
        requestContext.keys,
        models,
        nextModelIndex
    )
    return true
end
local function handleResponse(body, requestContext)
    requestContext = requestContext or {}
    local ok, data = pcall(hs.json.decode, body)
    if not ok or type(data) ~= "table" then
        log:errorf("json decode failed raw=%s", (body or ""):sub(1, 300))
        if tryNextModel(requestContext, "invalid_json") then return end
        notify("Remote OCR 失败", "响应解析失败")
        return
    end
    if data.error then
        log:errorf("api error=%s", hs.inspect(data.error))
        if tryNextModel(requestContext, "api_error") then return end
        notify("Remote OCR 失败", tostring(data.error.message or data.error.type or "API error"))
        return
    end
    if requestContext.provider
        and requestContext.provider.apiType == "mistral_ocr" then
        local pages = type(data.pages) == "table" and data.pages or {}
        local parts = {}
        local tableCount = 0
        for _, page in ipairs(pages) do
            local markdown = type(page.markdown) == "string" and page.markdown or ""
            if markdown ~= "" then table.insert(parts, markdown) end
            for _, ocrTable in ipairs(type(page.tables) == "table" and page.tables or {}) do
                local content = type(ocrTable.content) == "string" and ocrTable.content or ""
                if content ~= "" and not markdown:find(content, 1, true) then
                    table.insert(parts, content)
                end
                tableCount = tableCount + 1
            end
        end
        local usage = type(data.usage_info) == "table" and data.usage_info or {}
        log:eventf("usage", "pages=%s tables=%d doc_bytes=%s",
            tostring(usage.pages_processed or #pages), tableCount,
            tostring(usage.doc_size_bytes or "?"))
        local text = table.concat(parts, "\n\n")
        if text == "" then
            local emptyRetry = tonumber(requestContext.emptyRetry or 0) or 0
            local maxEmptyRetries = tonumber(M.maxEmptyResponseRetries or 0) or 0
            log:warnf("empty OCR pages retry=%d/%d", emptyRetry, maxEmptyRetries)
            if emptyRetry < maxEmptyRetries then
                requestContext.emptyRetry = emptyRetry + 1
                requestWithKey(requestContext)
                return
            end
            if tryNextModel(requestContext, "empty") then return end
            notify("Remote OCR 失败", "Mistral OCR 返回空内容")
            return
        end
        finishRecognizedText(text)
        return
    end
    local usage = data.usage or {}
    log:eventf("usage", "prompt_tokens=%s completion_tokens=%s total_tokens=%s",
        tostring(usage.prompt_tokens or "?"),
        tostring(usage.completion_tokens or "?"),
        tostring(usage.total_tokens or "?"))
    if type(data.time_info) == "table" then
        log:eventf("time", "queue=%ss prompt=%ss completion=%ss total=%ss",
            fmtSeconds(data.time_info.queue_time),
            fmtSeconds(data.time_info.prompt_time),
            fmtSeconds(data.time_info.completion_time),
            fmtSeconds(data.time_info.total_time))
    end
    local choice = data.choices and data.choices[1]
    local text = choice and choice.message and choice.message.content
    if choice and choice.finish_reason == "length" then
        log:warnf("OCR output truncated at max_completion_tokens=%d", M.maxCompletionTokens)
        if tryNextModel(requestContext, "truncated") then return end
        notify("Remote OCR 失败", "OCR 输出达到 token 上限，已丢弃残缺结果")
        return
    end
    local normalizedText = type(text) == "string"
        and text:gsub("^%s+", ""):gsub("%s+$", "")
        or ""
    if normalizedText == "[NO_TEXT]" or normalizedText == "`[NO_TEXT]`" then
        log:warnf("model reported no visible text")
        notify("Remote OCR", "截图中未识别到文字")
        return
    end
    if normalizedText == "" then
        local emptyRetry = tonumber(requestContext.emptyRetry or 0) or 0
        local maxEmptyRetries = tonumber(M.maxEmptyResponseRetries or 0) or 0
        log:warnf("empty content retry=%d/%d raw=%s",
            emptyRetry, maxEmptyRetries, (body or ""):sub(1, 1000))
        if emptyRetry < maxEmptyRetries
            and requestContext.body
            and requestContext.keys
            and requestContext.keyIndex then
            local nextEmptyRetry = emptyRetry + 1
            log:warnf("empty content; retrying request (%d/%d)",
                nextEmptyRetry, maxEmptyRetries)
            requestContext.emptyRetry = nextEmptyRetry
            requestWithKey(requestContext)
            return
        end
        if tryNextModel(requestContext, "empty") then return end
        notify("Remote OCR 失败", "模型连续返回空内容")
        return
    end
    finishRecognizedText(text)
end
local function activeProviderConfig()
    local provider = M.providers and M.providers[M.activeProvider]
    if type(provider) ~= "table" then return nil end
    return provider
end
local function configuredApiKeys(provider)
    local keys = {}
    for _, value in ipairs((provider and provider.apiKeys) or {}) do
        local key = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if key ~= "" and not key:find("API_KEY", 1, true) then
            table.insert(keys, key)
        end
    end
    return keys
end
local function configuredModels(provider)
    local models = {}
    for _, value in ipairs((provider and provider.models) or {}) do
        local model = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if model ~= "" then table.insert(models, model) end
    end
    -- Keep old single-model provider entries compatible.
    if #models == 0 and provider and provider.model then
        local model = tostring(provider.model):gsub("^%s+", ""):gsub("%s+$", "")
        if model ~= "" then table.insert(models, model) end
    end
    return models
end
local function splitHttpResponse(response)
    response = response or ""
    local lastNewline = response:match(".*()\n")
    if not lastNewline then return response, nil end
    local status = tonumber(response:sub(lastNewline + 1):match("^%s*(%d%d%d)%s*$"))
    if not status then return response, nil end
    return response:sub(1, lastNewline - 1), status
end
local function isRateLimited(httpStatus, body)
    if httpStatus == 429 then return true end
    if not httpStatus or httpStatus < 400 then return false end
    local message = (body or ""):lower()
    return message:find("rate%s*limit")
        or message:find("too%s+many%s+requests")
        or message:find("high%s+traffic")
        or message:find("try%s+again%s+later")
        or message:find("try%s+later")
        or message:find("capacity%s+exceeded")
end
requestWithKey = function(requestContext)
    local body = requestContext.body
    local provider = requestContext.provider
    local keys = requestContext.keys
    local keyIndex = requestContext.keyIndex
    local keyAttempt = tonumber(requestContext.keyAttempt or 1) or 1
    local emptyRetry = tonumber(requestContext.emptyRetry or 0) or 0
    local modelIndex = tonumber(requestContext.modelIndex or 1) or 1
    local models = requestContext.models or {}
    -- body 几 MB 时 hs.http.asyncPost 容易闷头不回调；走 curl 最稳
    local bodyPath = "/tmp/remote_ocr_body_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000)) .. ".json"
    local f, ferr = io.open(bodyPath, "w")
    if not f then
        notify("Remote OCR 失败", "写临时文件失败: " .. tostring(ferr))
        return
    end
    f:write(body)
    f:close()
    local requestStart = hs.timer.absoluteTime()
    local task
    task = hs.task.new("/usr/bin/curl", function(exitCode, stdout, stderr)
        os.remove(bodyPath)
        M._inflightTasks[task] = nil  -- 完成后释放引用
        local responseBody, httpStatus = splitHttpResponse(stdout)
        local elapsedMs = (hs.timer.absoluteTime() - requestStart) / 1000000
        log:eventf("curl", "done exit=%s http=%s model=%d/%d key=%d/%d ms=%.1f",
            tostring(exitCode), tostring(httpStatus or "?"), modelIndex, #models,
            keyIndex, #keys, elapsedMs)
        if exitCode ~= 0 then
            if tryNextModel(requestContext, "curl_" .. tostring(exitCode)) then return end
            notify("Remote OCR 失败", "curl exit " .. tostring(exitCode) .. ": " .. (stderr or ""):sub(1, 200))
            return
        end
        if isRateLimited(httpStatus, responseBody) then
            if keyAttempt < #keys then
                local nextKeyIndex = (keyIndex % #keys) + 1
                M._activeKeyIndex = nextKeyIndex
                log:warnf("rate limited with key #%d; switching to key #%d", keyIndex, nextKeyIndex)
                requestContext.keyIndex = nextKeyIndex
                requestContext.keyAttempt = keyAttempt + 1
                requestWithKey(requestContext)
                return
            end
            if tryNextModel(requestContext, "http_" .. tostring(httpStatus or "rate")) then return end
            notify("Remote OCR 失败", "所有模型均被限流或暂时不可用")
            return
        end
        if httpStatus and (httpStatus < 200 or httpStatus >= 300) then
            if tryNextModel(requestContext, "http_" .. tostring(httpStatus)) then return end
        end
        handleResponse(responseBody, requestContext)
    end, {
        "-sS",
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", tostring(provider.authHeader) .. ": " .. tostring(provider.authPrefix) .. keys[keyIndex],
        "--data-binary", "@" .. bodyPath,
        "--max-time", tostring(M.requestTimeoutSeconds),
        "--write-out", "\n%{http_code}",
        provider.endpoint,
    })
    if not task then
        os.remove(bodyPath)
        notify("Remote OCR 失败", "无法启动 curl")
        return
    end
    M._inflightTasks[task] = true  -- 强引用住，避免 Lua GC 把它收掉导致回调丢失
    log:eventf("curl", "start model=%d/%d key=%d/%d empty=%d/%d",
        modelIndex, #models, keyIndex, #keys,
        emptyRetry, tonumber(M.maxEmptyResponseRetries or 0) or 0)
    task:start()
end
requestWithModel = function(dataUrl, provider, keys, models, modelIndex)
    local model = models[modelIndex]
    local payload
    if provider.apiType == "mistral_ocr" then
        payload = {
            model = model,
            document = {
                type = "image_url",
                image_url = dataUrl,
            },
            table_format = provider.tableFormat or "markdown",
        }
    else
        payload = {
            model = model,
            messages = {{
                role = "user",
                content = {
                    { type = "image_url", image_url = { url = dataUrl } },
                    { type = "text", text = M.prompt },
                },
            }},
            temperature = 0,
            stream = false,
        }
        payload[provider.maxTokensField or "max_tokens"] = M.maxCompletionTokens
        if provider.reasoningEffort then
            payload.reasoning_effort = provider.reasoningEffort
        end
        if provider.enableThinking ~= nil then
            payload.enable_thinking = provider.enableThinking
        end
    end
    local body = hs.json.encode(payload)
    log:eventf("req", "body_bytes=%d provider=%s model=%d/%d:%s",
        #body, tostring(provider.name), modelIndex, #models, tostring(model))
    M._activeKeyIndex = ((M._activeKeyIndex - 1) % #keys) + 1
    requestWithKey({
        body = body,
        dataUrl = dataUrl,
        provider = provider,
        keys = keys,
        keyIndex = M._activeKeyIndex,
        keyAttempt = 1,
        emptyRetry = 0,
        models = models,
        modelIndex = modelIndex,
    })
end
local function submitDataURL(dataUrl)
    local provider = activeProviderConfig()
    if not provider then
        notify("Remote OCR", "未知 Provider: " .. tostring(M.activeProvider))
        log:errorf("unknown provider=%s", tostring(M.activeProvider))
        return
    end
    local keys = configuredApiKeys(provider)
    if #keys == 0 then
        notify("Remote OCR", "请为 " .. tostring(provider.name) .. " 填写 API Key")
        return
    end
    local models = configuredModels(provider)
    if #models == 0 then
        notify("Remote OCR", "请为 " .. tostring(provider.name) .. " 填写模型")
        return
    end
    if M.maxBase64Bytes and M.maxBase64Bytes > 0 and #dataUrl > M.maxBase64Bytes then
        notify("Remote OCR", "图片超过上传大小限制，请缩小选区")
        log:warnf("image payload too large data_url_bytes=%d max=%d", #dataUrl, M.maxBase64Bytes)
        return
    end
    requestWithModel(dataUrl, provider, keys, models, 1)
end
local function callRemote(img)
    local dataUrl = encodeToDataURL(img)
    if not dataUrl then
        notify("Remote OCR", "图片编码失败")
        return
    end
    submitDataURL(dataUrl)
end
local function callRemotePNGFile(imagePath)
    -- 先把原始 PNG 完整读入内存，再删除截图文件。不要让 NSImage 持有一个
    -- 已被删除的文件路径；它可能延迟解码，造成尺寸正常但像素内容异常。
    local sourceDataUrl, sourcePngBytes, sourceWidth, sourceHeight = pngFileToDataURL(imagePath)
    os.remove(imagePath)
    if not sourceDataUrl then
        notify("Remote OCR", "截图 PNG 读取失败")
        return
    end
    log:eventf("image", "mode=capture-source pixels=%sx%s png_bytes=%d",
        tostring(sourceWidth or "?"), tostring(sourceHeight or "?"), sourcePngBytes or 0)
    local img = hs.image.imageFromURL(sourceDataUrl)
    if not img then
        notify("Remote OCR", "截图 PNG 解码失败")
        return
    end
    local dataUrl = encodeToDataURL(img)
    if not dataUrl then
        notify("Remote OCR", "截图 PNG 编码失败")
        return
    end
    submitDataURL(dataUrl)
end
-- screencapture -i -c 把截图写进剪贴板，读出来送到 Remote
local function readClipboardAndOCR()
    local img = hs.pasteboard.readImage()
    if not img then
        notify("Remote OCR", "未捕获到截图")
        return
    end
    callRemote(img)
end
-- 直接上传 screencapture 写出的原始 PNG，避免剪贴板图像的二次编码。
function M.ocrFromCapture()
    local capturePath = "/tmp/remote_ocr_capture_" .. tostring(os.time()) .. "_" .. tostring(math.random(100000)) .. ".png"
    local t = hs.task.new("/usr/sbin/screencapture", function(exitCode)
        if exitCode ~= 0 then
            os.remove(capturePath)
            return  -- 按 ESC 取消
        end
        callRemotePNGFile(capturePath)
    end, { "-i", "-t", "png", capturePath })
    if t then t:start() end
end
-- ========== 菜单栏图标 ==========
-- 形状照搬 ocr/apple/init.lua（取景框 + 「OCR」字样），描边换成橙色；
-- setIcon 的第二参传 false 才不会被当 template 自动转黑白
local menuBarIconSvg = [[
<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
  <g fill="none" stroke="#ff0000" stroke-width="1.05" stroke-linecap="round" stroke-linejoin="round" vector-effect="non-scaling-stroke">
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
local function createMenuBarItem()
    local item = hs.menubar.new(true, "remote_ocr_menu_bar")
    if not item then return nil end
    local icon = hs.image.imageFromURL("data:image/svg+xml;base64," .. hs.base64.encode(menuBarIconSvg))
    if icon then
        item:setIcon(icon, false)  -- false = 非 template，保留橙色
    else
        item:setTitle("OCR*")
    end
    item:setTooltip("Remote OCR")
    item:setClickCallback(function()
        M.ocrFromCapture()
    end)
    return item
end
M.menuBar = createMenuBarItem()
-- ========== 快捷键 ==========
hs.hotkey.bind({ "cmd", "shift" }, "O", M.ocrFromCapture)
return M
