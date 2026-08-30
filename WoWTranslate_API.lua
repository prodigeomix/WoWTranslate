-- WoWTranslate_API.lua
-- Universal Multi-Transport API for WoWTranslate (v3.5.10)
-- Supports SuperWoW (Imports\req_*.txt), Standard Lua IO (WoWTranslate\IPC\), and UnitXP C++ DLL.
--
-- Transports:
--   1. SuperWoW / File IPC (via wow_proxy.py) [RECOMMENDED]:
--      Uses SuperWoW's ExportFile/ImportFile (Imports\req_{id}.txt -> Imports\res_{id}.txt)
--      or standard Lua io (WoWTranslate\IPC\requests\ -> results\)
--      Multi-backend (Ollama/DeepL/OpenAI/Google), SQLite cache, zero rate limits!
--
--   2. UnitXP DLL:
--      Calls UnitXP("WoWTranslate", "translate_async", ...) and UnitXP("WoWTranslate", "poll")
--
-- Signature: Translate() and TranslateOutgoing() return (bool, reason)
--   reason: "queue_full" | "rate_limited" | "deduped" | requestId

WoWTranslate_API = {}

-- Transport modes
local TRANSPORT_NONE     = 0
local TRANSPORT_SUPERWOW = 1
local TRANSPORT_LUAIO    = 2
local TRANSPORT_UNITXP   = 3
local currentTransport   = TRANSPORT_NONE

-- File IPC Paths (for standard Lua io)
local IPC_ROOT_CANDIDATES = {
    "WoWTranslate\\IPC\\",
    "Interface\\AddOns\\WoWTranslate\\IPC\\",
}
local activeIPCRoot = "WoWTranslate\\IPC\\"

-- State
local pendingRequests    = {}   -- id -> { callbacks = {}, text = str, timestamp = num, ... }
local pendingTexts       = {}   -- text -> id (deduplicates identical in-flight messages)
local requestCounter     = 0
local activePendingCount = 0
local pollFrame          = nil
local lastCallbackError  = nil

-- Backoff & Limits
local POLL_INTERVAL       = 0.05  -- 50ms for ultra-responsive translation
local REQUEST_TIMEOUT     = 30    -- 30s timeout
local MAX_PENDING         = 16    -- Max concurrent in-flight requests
local HEALTH_INTERVAL     = 15    -- Re-verify backend every 15s

local consecutiveErrors   = 0
local rateLimitedUntil    = 0
local rateLimitBackoff    = 5
local BACKOFF_TRIGGER     = 4
local BACKOFF_CAP         = 60

-- Ping/Pong state for File IPC
local pingPending         = false
local pingTimestamp       = 0

-- ============================================================================
-- TRANSPORT CAPABILITY CHECKS
-- ============================================================================

local function HasSuperWoW()
    return type(ExportFile) == "function" and type(ImportFile) == "function"
end

local function HasLuaIO()
    return type(io) == "table" and type(io.open) == "function"
end

local function HasUnitXP()
    if type(UnitXP) == "function" then
        local ok, res = pcall(function()
            return UnitXP("WoWTranslate", "ping")
        end)
        return ok and (res == "pong" or res == "ok" or res == true)
    end
    return false
end

-- ============================================================================
-- TRANSPORT READ / WRITE / DELETE PRIMITIVES
-- ============================================================================

local function WriteRequest(reqId, encoded)
    if currentTransport == TRANSPORT_SUPERWOW then
        if encoded and string.len(encoded) > 300 then
            if WT_SafeUTF8Truncate then
                encoded = WT_SafeUTF8Truncate(encoded, 300)
            end
        end
        local ok = pcall(ExportFile, "req_" .. reqId, encoded)
        return ok
    elseif currentTransport == TRANSPORT_LUAIO then
        local f = io.open(activeIPCRoot .. "requests\\" .. reqId .. ".req", "w")
        if f then
            f:write(encoded or "")
            f:close()
            return true
        end
    end
    return false
end

local function ReadResult(reqId)
    if currentTransport == TRANSPORT_SUPERWOW then
        local ok, content = pcall(ImportFile, "res_" .. reqId)
        if ok and content and content ~= "" and content ~= false then
            return content
        end
    elseif currentTransport == TRANSPORT_LUAIO then
        local p = activeIPCRoot .. "results\\" .. reqId .. ".res"
        local f = io.open(p, "r")
        if f then
            local content = f:read("*a")
            f:close()
            return content
        end
    end
    return nil
end

local function ClearRequest(reqId)
    if currentTransport == TRANSPORT_SUPERWOW then
        pcall(ExportFile, "res_" .. reqId, "")
        pcall(ExportFile, "req_" .. reqId, "")
    elseif currentTransport == TRANSPORT_LUAIO then
        if type(os) == "table" and type(os.remove) == "function" then
            pcall(os.remove, activeIPCRoot .. "results\\" .. reqId .. ".res")
            pcall(os.remove, activeIPCRoot .. "requests\\" .. reqId .. ".req")
        end
    end
end

-- ============================================================================
-- PROBE & HEALTH CHECKS
-- ============================================================================

local function ProbeSuperWoW()
    if not HasSuperWoW() then return false end
    -- Check if proxy_ready.txt exists in Imports
    local ok, content = pcall(ImportFile, "proxy_ready")
    if ok and content and content ~= "" and content ~= false then
        return true
    end
    -- Check pong
    local okPong, pong = pcall(ImportFile, "pong")
    if okPong and pong and pong ~= "" and pong ~= false then
        return true
    end
    -- Check if writing works
    local okWrite = pcall(ExportFile, "test_probe", "1")
    if okWrite then
        pcall(ExportFile, "test_probe", "")
        return true
    end
    return false
end

local function ProbeLuaIO()
    if not HasLuaIO() then return false end
    for _, root in ipairs(IPC_ROOT_CANDIDATES) do
        local f = io.open(root .. "proxy_ready", "r")
        if f then
            f:close()
            activeIPCRoot = root
            return true
        end
        local f2 = io.open(root .. "pong", "r")
        if f2 then
            f2:close()
            activeIPCRoot = root
            return true
        end
    end
    return false
end

local function SendPing()
    if currentTransport == TRANSPORT_SUPERWOW or (currentTransport == TRANSPORT_NONE and HasSuperWoW()) then
        pcall(ExportFile, "ping", tostring(GetTime()))
        pingPending = true
        pingTimestamp = GetTime()
    elseif currentTransport == TRANSPORT_LUAIO or (currentTransport == TRANSPORT_NONE and HasLuaIO()) then
        for _, root in ipairs(IPC_ROOT_CANDIDATES) do
            local f = io.open(root .. "ping", "w")
            if f then
                f:write(tostring(GetTime()))
                f:close()
            end
        end
        pingPending = true
        pingTimestamp = GetTime()
    end
end

local function CheckPong()
    if not pingPending then return end

    if currentTransport == TRANSPORT_SUPERWOW or HasSuperWoW() then
        local ok, pong = pcall(ImportFile, "pong")
        if ok and pong and pong ~= "" and pong ~= false then
            pcall(ExportFile, "pong", "")
            pcall(ExportFile, "ping", "")
            pingPending = false
            currentTransport = TRANSPORT_SUPERWOW
            consecutiveErrors = 0
            rateLimitBackoff = 5
            return
        end
    end

    if currentTransport == TRANSPORT_LUAIO or HasLuaIO() then
        for _, root in ipairs(IPC_ROOT_CANDIDATES) do
            local f = io.open(root .. "pong", "r")
            if f then
                f:close()
                if type(os) == "table" and type(os.remove) == "function" then
                    pcall(os.remove, root .. "pong")
                    pcall(os.remove, root .. "ping")
                end
                activeIPCRoot = root
                pingPending = false
                currentTransport = TRANSPORT_LUAIO
                consecutiveErrors = 0
                rateLimitBackoff = 5
                return
            end
        end
    end

    if GetTime() - pingTimestamp > 3 then
        pingPending = false
        if currentTransport == TRANSPORT_SUPERWOW or currentTransport == TRANSPORT_LUAIO then
            currentTransport = TRANSPORT_NONE
        end
    end
end

-- Public: Probe and update active transport
function WoWTranslate_API.CheckDLL()
    local wasNone = (currentTransport == TRANSPORT_NONE)
    local pref = WoWTranslateDB and WoWTranslateDB.preferredTransport or "auto"

    -- 1. If user preference is DLL only:
    if pref == "dll" then
        if HasUnitXP() then
            currentTransport = TRANSPORT_UNITXP
            if wasNone then
                WT_dllWarnShown = false
                WT_translationErrWarnShown = false
            end
            return true
        end
        currentTransport = TRANSPORT_NONE
        return false
    end

    -- 2. Check SuperWoW File IPC (Highest Priority for 1.12 clients with SuperWoW)
    if ProbeSuperWoW() then
        currentTransport = TRANSPORT_SUPERWOW
        if wasNone then
            WT_dllWarnShown = false
            WT_translationErrWarnShown = false
        end
        return true
    end

    -- 3. Check Standard Lua File IPC
    if ProbeLuaIO() then
        currentTransport = TRANSPORT_LUAIO
        if wasNone then
            WT_dllWarnShown = false
            WT_translationErrWarnShown = false
        end
        return true
    end

    -- 4. Fallback to UnitXP DLL if proxy is not detected and auto mode is enabled
    if pref == "auto" and HasUnitXP() then
        currentTransport = TRANSPORT_UNITXP
        if wasNone then
            WT_dllWarnShown = false
            WT_translationErrWarnShown = false
        end
        return true
    end

    -- Send ping to wake proxy
    SendPing()

    if currentTransport ~= TRANSPORT_NONE then
        return true
    end
    return false
end

function WoWTranslate_API.IsAvailable()
    return currentTransport ~= TRANSPORT_NONE
end

function WoWTranslate_API.GetTransport()
    return currentTransport
end

function WoWTranslate_API.SetPreferredTransport(mode)
    if not WoWTranslateDB then WoWTranslateDB = {} end
    WoWTranslateDB.preferredTransport = mode  -- "auto", "proxy", "dll"
    WoWTranslate_API.CheckDLL()
end

function WoWTranslate_API.GetTransportName()
    if currentTransport == TRANSPORT_SUPERWOW then
        return "SuperWoW File IPC (Proxy)"
    elseif currentTransport == TRANSPORT_LUAIO then
        return "Standard File IPC (Proxy)"
    elseif currentTransport == TRANSPORT_UNITXP then
        return "UnitXP DLL"
    else
        return "None"
    end
end

-- ============================================================================
-- DEMAND-BASED POLLING
-- ============================================================================

local function OnRequestQueued()
    activePendingCount = activePendingCount + 1
    WoWTranslate_API.StartPolling()
end

local function OnRequestCompleted()
    activePendingCount = activePendingCount - 1
    if activePendingCount < 0 then
        activePendingCount = 0
    end
end

local function FireCallbacks(req, translation, err)
    if not req then return end
    local cbs = req.callbacks or (req.callback and { req.callback }) or {}
    for _, cb in ipairs(cbs) do
        local ok, cbErr = pcall(cb, translation, err)
        if not ok then
            lastCallbackError = tostring(cbErr)
        end
    end
end

-- ============================================================================
-- TRANSLATION REQUESTS
-- ============================================================================

function WoWTranslate_API.Translate(text, callback, fromLang)
    if not WoWTranslate_API.IsAvailable() then
        WoWTranslate_API.CheckDLL()
        if not WoWTranslate_API.IsAvailable() then
            if callback then callback(nil, "Translation proxy/DLL not connected") end
            return false, "no_backend"
        end
    end

    if not text or text == "" then
        if callback then callback(nil, "Empty text") end
        return false, "empty_text"
    end

    if activePendingCount >= MAX_PENDING then
        return false, "queue_full"
    end

    if GetTime() < rateLimitedUntil then
        return false, "rate_limited"
    end

    -- Deduplication: if same text is already in flight across multiple chat frames,
    -- attach this callback to the existing request
    if pendingTexts[text] then
        local existingId = pendingTexts[text]
        local req = pendingRequests[existingId]
        if req then
            if callback then
                req.callbacks = req.callbacks or {}
                table.insert(req.callbacks, callback)
            end
            return true, "deduped"
        end
    end

    requestCounter = requestCounter + 1
    local reqId = "in_" .. tostring(requestCounter)

    local srcLang = fromLang or (WoWTranslateDB and WoWTranslateDB.incomingFromLang) or "zh"
    local dstLang = (WoWTranslateDB and WoWTranslateDB.incomingToLang) or "en"

    local reqData = {
        callbacks = callback and { callback } or {},
        text      = text,
        timestamp = GetTime(),
    }

    if currentTransport == TRANSPORT_UNITXP then
        local ok, err = pcall(function()
            UnitXP("WoWTranslate", "translate_async", reqId, text, srcLang, dstLang)
        end)
        if not ok then
            if callback then callback(nil, "UnitXP call failed: " .. tostring(err)) end
            return false, "unitxp_error"
        end
    else
        local encoded = srcLang .. "|" .. dstLang .. "|" .. text
        local ok = WriteRequest(reqId, encoded)
        if not ok then
            if callback then callback(nil, "IPC write failed") end
            return false, "ipc_write_failed"
        end
    end

    pendingRequests[reqId] = reqData
    pendingTexts[text]     = reqId

    OnRequestQueued()
    return true, reqId
end

function WoWTranslate_API.TranslateOutgoing(text, callback)
    if not WoWTranslate_API.IsAvailable() then
        WoWTranslate_API.CheckDLL()
        if not WoWTranslate_API.IsAvailable() then
            if callback then callback(nil, "Translation proxy/DLL not connected") end
            return false, "no_backend"
        end
    end

    if not text or text == "" then
        if callback then callback(nil, "Empty text") end
        return false, "empty_text"
    end

    if activePendingCount >= MAX_PENDING then
        if callback then callback(nil, "Queue full, try again shortly") end
        return false, "queue_full"
    end

    if GetTime() < rateLimitedUntil then
        if callback then
            callback(nil, "Rate limited. Launch start_proxy.bat to use the local proxy backend!")
        end
        return false, "rate_limited"
    end

    requestCounter = requestCounter + 1
    local reqId = "out_" .. tostring(requestCounter)

    local fromLang = (WoWTranslateDB and WoWTranslateDB.outgoingFromLang) or "en"
    local toLang   = (WoWTranslateDB and WoWTranslateDB.outgoingToLang)   or "zh"

    local reqData = {
        callbacks = callback and { callback } or {},
        text      = text,
        timestamp = GetTime(),
    }

    if currentTransport == TRANSPORT_UNITXP then
        local ok, err = pcall(function()
            UnitXP("WoWTranslate", "translate_async", reqId, text, fromLang, toLang)
        end)
        if not ok then
            if callback then callback(nil, "UnitXP call failed: " .. tostring(err)) end
            return false, "unitxp_error"
        end
    else
        local encoded = fromLang .. "|" .. toLang .. "|" .. text
        local ok = WriteRequest(reqId, encoded)
        if not ok then
            if callback then callback(nil, "IPC write failed") end
            return false, "ipc_write_failed"
        end
    end

    pendingRequests[reqId] = reqData
    OnRequestQueued()
    return true, reqId
end

-- ============================================================================
-- POLLING & RESULT PROCESSING
-- ============================================================================

local function PollUnitXP()
    local ok, result = pcall(function()
        return UnitXP("WoWTranslate", "poll")
    end)
    if not ok then
        currentTransport = TRANSPORT_NONE
        return
    end

    if ok and result and result ~= "" then
        -- Parse result: "requestId|translation|error"
        local firstPipe = string.find(result, "|", 1, true)
        if firstPipe then
            local reqId = string.sub(result, 1, firstPipe - 1)
            local remainder = string.sub(result, firstPipe + 1)
            local lastPipe = nil
            local searchPos = 1
            while true do
                local nextPipe = string.find(remainder, "|", searchPos, true)
                if not nextPipe then break end
                lastPipe = nextPipe
                searchPos = nextPipe + 1
            end

            local translation, err
            if lastPipe then
                translation = string.sub(remainder, 1, lastPipe - 1)
                err = string.sub(remainder, lastPipe + 1)
            else
                translation = remainder
                err = ""
            end

            local req = pendingRequests[reqId]
            if req then
                pendingRequests[reqId] = nil
                if req.text then pendingTexts[req.text] = nil end
                OnRequestCompleted()

                if err and err ~= "" then
                    consecutiveErrors = consecutiveErrors + 1
                    if consecutiveErrors >= BACKOFF_TRIGGER then
                        rateLimitedUntil = GetTime() + rateLimitBackoff
                        rateLimitBackoff = math.min(rateLimitBackoff * 2, BACKOFF_CAP)
                        consecutiveErrors = 0
                    end
                    FireCallbacks(req, nil, err)
                else
                    consecutiveErrors = 0
                    rateLimitBackoff = 5
                    translation = string.gsub(translation, "'%s+(%a)", "'%1")
                    FireCallbacks(req, translation, nil)
                end
            end
        end
    end
end

local function PollFileIPC()
    local completed = {}
    for reqId, req in pairs(pendingRequests) do
        local content = ReadResult(reqId)
        if content and content ~= "" and content ~= false then
            table.insert(completed, { reqId = reqId, req = req, content = content })
        end
    end

    for _, item in ipairs(completed) do
        local reqId = item.reqId
        local req = item.req
        local content = item.content

        ClearRequest(reqId)

        pendingRequests[reqId] = nil
        if req.text then pendingTexts[req.text] = nil end
        OnRequestCompleted()

        local firstPipe = string.find(content, "|", 1, true)
        local status = firstPipe and string.sub(content, 1, firstPipe - 1) or "err"
        local body   = firstPipe and string.sub(content, firstPipe + 1) or content

        if status == "ok" then
            consecutiveErrors = 0
            rateLimitBackoff = 5
            body = string.gsub(body, "'%s+(%a)", "'%1")
            FireCallbacks(req, body, nil)
        else
            consecutiveErrors = consecutiveErrors + 1
            if consecutiveErrors >= BACKOFF_TRIGGER then
                rateLimitedUntil = GetTime() + rateLimitBackoff
                rateLimitBackoff = math.min(rateLimitBackoff * 2, BACKOFF_CAP)
                consecutiveErrors = 0
            end
            FireCallbacks(req, nil, body)
        end
    end
end

local function ProcessTimeouts()
    local now = GetTime()
    local timedOut = {}
    for reqId, req in pairs(pendingRequests) do
        if now - req.timestamp > REQUEST_TIMEOUT then
            table.insert(timedOut, { reqId = reqId, req = req })
        end
    end

    for _, item in ipairs(timedOut) do
        local reqId = item.reqId
        local req = item.req
        ClearRequest(reqId)
        pendingRequests[reqId] = nil
        if req.text then pendingTexts[req.text] = nil end
        OnRequestCompleted()

        consecutiveErrors = consecutiveErrors + 1
        if consecutiveErrors >= BACKOFF_TRIGGER then
            rateLimitedUntil = GetTime() + rateLimitBackoff
            rateLimitBackoff = math.min(rateLimitBackoff * 2, BACKOFF_CAP)
            consecutiveErrors = 0
        end

        FireCallbacks(req, nil, "timeout")
    end
end

-- ============================================================================
-- POLLING FRAME LIFECYCLE
-- ============================================================================

local pollElapsed = 0
local healthElapsed = 0

local function OnUpdateHandler()
    local dt = arg1 or 0.1
    pollElapsed = pollElapsed + dt
    healthElapsed = healthElapsed + dt

    -- 1. Poll results
    if pollElapsed >= POLL_INTERVAL then
        pollElapsed = 0
        if currentTransport == TRANSPORT_UNITXP then
            PollUnitXP()
        elseif currentTransport == TRANSPORT_SUPERWOW or currentTransport == TRANSPORT_LUAIO then
            PollFileIPC()
        end
        ProcessTimeouts()
        if WT_CleanupOutgoingQueue then
            WT_CleanupOutgoingQueue()
        end
        CheckPong()
    end

    -- 2. Periodic health check
    if healthElapsed >= HEALTH_INTERVAL then
        healthElapsed = 0
        WoWTranslate_API.CheckDLL()
    end
end

function WoWTranslate_API.StartPolling()
    if not pollFrame then
        pollFrame = CreateFrame("Frame", "WoWTranslatePollFrame")
        pollFrame:SetScript("OnUpdate", OnUpdateHandler)
    end
    pollFrame:Show()
end

function WoWTranslate_API.StopPolling()
    -- Keep frame active for health checks and continuous polling
end

-- ============================================================================
-- DIAGNOSTICS & RESET
-- ============================================================================

function WoWTranslate_API.GetPendingCount()
    return activePendingCount
end

function WoWTranslate_API.GetRateLimitInfo()
    local now = GetTime()
    if now < rateLimitedUntil then
        return true, math.ceil(rateLimitedUntil - now)
    end
    return false, 0
end

function WoWTranslate_API.ResetBackoff()
    rateLimitedUntil = 0
    rateLimitBackoff = 5
    consecutiveErrors = 0
end

function WoWTranslate_API.GetLastCallbackError()
    return lastCallbackError
end

function WoWTranslate_API.ClearPending()
    local reqIds = {}
    for reqId, _ in pairs(pendingRequests) do
        table.insert(reqIds, reqId)
    end
    for _, reqId in ipairs(reqIds) do
        -- Fire each dropped request's callback with an error so replaceMode-
        -- suppressed originals flush immediately instead of waiting for the
        -- 30 s pending-message cleanup timer.
        local reqData = pendingRequests[reqId]
        if reqData and reqData.callbacks then
            for _, cb in ipairs(reqData.callbacks) do
                if type(cb) == "function" then
                    pcall(cb, nil, "reset")
                end
            end
        end
        ClearRequest(reqId)
    end
    pendingRequests    = {}
    pendingTexts       = {}
    activePendingCount = 0
end

function WoWTranslate_API.GetDiagnostics()
    local diag = {}
    diag.hasLuaIO = HasLuaIO()
    diag.hasSuperWoW = HasSuperWoW()
    diag.hasUnitXP = HasUnitXP()
    diag.unitxpPing = nil
    if diag.hasUnitXP then
        local ok, res = pcall(function() return UnitXP("WoWTranslate", "ping") end)
        diag.unitxpPing = ok and tostring(res) or "error"
    end
    diag.probeSuperWoW = ProbeSuperWoW()
    diag.probeLuaIO = ProbeLuaIO()
    diag.currentTransport = currentTransport
    diag.transportName = WoWTranslate_API.GetTransportName()
    diag.preferredTransport = WoWTranslateDB and WoWTranslateDB.preferredTransport or "auto"
    
    diag.canWriteSuperWoW = false
    if diag.hasSuperWoW then
        local okWrite = pcall(ExportFile, "diag_probe", "diag_ok")
        if okWrite then
            local okRead, val = pcall(ImportFile, "diag_probe")
            if okRead and val == "diag_ok" then
                diag.canWriteSuperWoW = true
            end
            pcall(ExportFile, "diag_probe", "")
        end
    end
    return diag
end

-- Auto-initialize on load
WoWTranslate_API.CheckDLL()
WoWTranslate_API.StartPolling()
