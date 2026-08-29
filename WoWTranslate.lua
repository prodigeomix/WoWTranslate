-- WoWTranslate.lua
-- Main addon file: chat hooks, display, coordination, and slash commands
-- Real-time translation for WoW 1.12.1 (Vanilla / Turtle WoW)

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================

SLASH_WOWTRANSLATE1 = "/wt"
SLASH_WOWTRANSLATE2 = "/wowtranslate"

SlashCmdList["WOWTRANSLATE"] = function(msg)
    if not WoWTranslateDB then
        WoWTranslateDB = {}
        WT_InitializeSettings()
    end

    local cmd, arg = WT_strsplit(" ", msg, 2)
    cmd = string.lower(cmd or "")

    if cmd == "on" or cmd == "enable" then
        WoWTranslateDB.enabled = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Enabled|r")

    elseif cmd == "off" or cmd == "disable" then
        WoWTranslateDB.enabled = false
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Disabled|r")

    elseif cmd == "status" then
        local isAvail = WoWTranslate_API.IsAvailable()
        local transportStr
        if isAvail then
            transportStr = "|cFF00FF00" .. WoWTranslate_API.GetTransportName() .. " (Connected)|r"
        else
            transportStr = "|cFFFF0000Not Connected (Start wow_proxy.py or start_proxy.bat)|r"
        end

        local cacheStats = WoWTranslate_CacheStats()
        local glossaryCount = WoWTranslate_GetGlossaryCount()
        local outGlossaryCount = WoWTranslate_GetOutGlossaryCount and WoWTranslate_GetOutGlossaryCount() or 0
        local pendingCount = WoWTranslate_API.GetPendingCount()

        local queuedCount = 0
        for _ in pairs(WT_pendingMessages) do
            queuedCount = queuedCount + 1
        end

        local outgoingQueuedCount = 0
        for _ in pairs(WT_outgoingQueue) do
            outgoingQueuedCount = outgoingQueuedCount + 1
        end

        local outgoingStatus = WoWTranslateDB.outgoingEnabled
            and "|cFF00FF00ON|r"
            or "|cFFFF0000OFF|r"

        local hookStatus = WT_IsOutgoingHookActive()
            and "|cFF00FF00ACTIVE|r"
            or "|cFFFF0000INACTIVE|r"

        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Status:")
        DEFAULT_CHAT_FRAME:AddMessage("  Backend: " .. transportStr)
        DEFAULT_CHAT_FRAME:AddMessage("  Incoming: " .. (WoWTranslateDB.enabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
        DEFAULT_CHAT_FRAME:AddMessage("  Outgoing: " .. outgoingStatus)
        DEFAULT_CHAT_FRAME:AddMessage("  Outgoing Hook: " .. hookStatus)
        DEFAULT_CHAT_FRAME:AddMessage("  Incoming Glossary: " .. glossaryCount .. " entries")
        DEFAULT_CHAT_FRAME:AddMessage("  Outgoing Glossary: " .. outGlossaryCount .. " entries")
        DEFAULT_CHAT_FRAME:AddMessage("  Cached Translations: " .. cacheStats.entries)
        DEFAULT_CHAT_FRAME:AddMessage("  Cache Hit Rate: " .. string.format("%.1f%%", cacheStats.hitRate))
        DEFAULT_CHAT_FRAME:AddMessage("  Pending API Requests: " .. pendingCount)
        DEFAULT_CHAT_FRAME:AddMessage("  Queued Incoming: " .. queuedCount)
        DEFAULT_CHAT_FRAME:AddMessage("  Queued Outgoing: " .. outgoingQueuedCount)

        local cbErr = WoWTranslate_API.GetLastCallbackError and WoWTranslate_API.GetLastCallbackError()
        if cbErr then
            DEFAULT_CHAT_FRAME:AddMessage("  |cFFFF4444Last callback error:|r " .. cbErr)
        end
        local rlActive, rlRemaining = WoWTranslate_API.GetRateLimitInfo()
        if rlActive then
            DEFAULT_CHAT_FRAME:AddMessage("  |cFFFF4444API backoff active:|r " .. rlRemaining .. "s remaining (use /wt reset to clear)")
        end

    elseif cmd == "test" then
        local testText = (arg and arg ~= "") and arg or "\228\189\160\229\165\189"  -- Default: 你好 (Hello)
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing incoming translation: " .. testText)

        local cached, found = WoWTranslate_CacheGet(testText)
        if found then
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Cache hit: " .. cached)
            return
        end

        -- Check incoming exact glossary
        local glossaryResult = nil
        if WoWTranslate_CheckGlossaryExact then
            glossaryResult = WoWTranslate_CheckGlossaryExact(testText)
        end

        if glossaryResult then
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Glossary hit: " .. glossaryResult)
            WoWTranslate_CacheSave(testText, glossaryResult)
            return
        end

        if not WoWTranslate_API.IsAvailable() then
            WoWTranslate_API.CheckDLL()
        end

        if not WoWTranslate_API.IsAvailable() then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Translation service not connected. Please start wow_proxy.py or start_proxy.bat!|r")
            return
        end

        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Requesting translation via " .. WoWTranslate_API.GetTransportName() .. "...")
        WoWTranslate_API.Translate(testText, function(result, err)
            if result then
                DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Result:|r " .. (WT_SanitizeDisplayText and WT_SanitizeDisplayText(result) or result))
                WoWTranslate_CacheSave(testText, result)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Error: " .. (err or "unknown") .. "|r")
            end
        end)

    elseif cmd == "clearcache" then
        WoWTranslate_CacheClear()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[WoWTranslate] Cache cleared|r")

    elseif cmd == "debug" then
        WT_DEBUG_MODE = not WT_DEBUG_MODE
        WoWTranslateDB.debugMode = WT_DEBUG_MODE
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Debug mode: " .. (WT_DEBUG_MODE and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))

    elseif cmd == "log" then
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Recent log entries:")
        local logs = WoWTranslateDebugLog or {}
        local start = math.max(1, table.getn(logs) - 19)
        for i = start, table.getn(logs) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. logs[i])
        end

    elseif cmd == "clearlog" then
        WoWTranslateDebugLog = {}
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Debug log cleared")

    elseif cmd == "testlink" then
        local testMsg = "|cffffffff|Hplayer:TestName|h[TestName]|h|r says hello"
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing hyperlink parse:")
        DEFAULT_CHAT_FRAME:AddMessage("  Input: " .. testMsg)
        local segs = WT_SplitIntoSegments(testMsg)
        for idx, seg in ipairs(segs) do
            DEFAULT_CHAT_FRAME:AddMessage("  Seg " .. idx .. " [" .. seg.type .. "]: " .. seg.content)
        end

    elseif cmd == "testitem" then
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing item localization...")
        local itemId = 2589  -- Default: Linen Cloth
        if arg and arg ~= "" then
            itemId = tonumber(arg) or 2589
        end
        DEFAULT_CHAT_FRAME:AddMessage("  Item ID: " .. tostring(itemId))
        local itemName = GetItemInfo(itemId)
        if itemName then
            DEFAULT_CHAT_FRAME:AddMessage("  GetItemInfo returned: " .. itemName)
            local testLink = "|cffa335ee|Hitem:" .. itemId .. ":0:0:0|h[测试物品]|h|r"
            DEFAULT_CHAT_FRAME:AddMessage("  Test link: " .. testLink)
            local localized = WT_LocalizeHyperlink(testLink)
            DEFAULT_CHAT_FRAME:AddMessage("  Localized: " .. localized)
        else
            DEFAULT_CHAT_FRAME:AddMessage("  GetItemInfo returned nil - item not in client cache yet")
            DEFAULT_CHAT_FRAME:AddMessage("  (Request sent to server; hovering over the item or querying again will resolve)")
            WT_TriggerItemCache(itemId)
        end

    elseif cmd == "testquest" then
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing quest localization...")
        local questId = 913  -- Default: Stranglethorn Fever
        if arg and arg ~= "" then
            questId = tonumber(arg) or 913
        end
        DEFAULT_CHAT_FRAME:AddMessage("  Quest ID: " .. tostring(questId))

        if not pfDB or not pfDB["quests"] then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000  pfQuest database not found!|r")
            DEFAULT_CHAT_FRAME:AddMessage("  Quest localization requires pfQuest addon to be installed")
            return
        end

        local questName = WT_GetEnglishQuestName(questId)
        if questName then
            DEFAULT_CHAT_FRAME:AddMessage("  WT_GetEnglishQuestName returned: " .. questName)
            local testLink = "|cffffff00|Hquest:" .. questId .. ":60|h[测试任务]|h|r"
            DEFAULT_CHAT_FRAME:AddMessage("  Test link: " .. testLink)
            local localized = WT_LocalizeHyperlink(testLink)
            DEFAULT_CHAT_FRAME:AddMessage("  Localized: " .. localized)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000  Quest not found in pfQuest database|r")
        end

    -- =====================================================================
    -- OUTGOING TRANSLATION COMMANDS
    -- =====================================================================
    elseif cmd == "outgoing" or cmd == "out" then
        if arg == "on" or arg == "enable" then
            WoWTranslate_SetOutgoingEnabled(true)
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Outgoing translation enabled|r")
        elseif arg == "off" or arg == "disable" then
            WoWTranslate_SetOutgoingEnabled(false)
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Outgoing translation disabled|r")
        else
            WoWTranslate_SetOutgoingEnabled(not WoWTranslateDB.outgoingEnabled)
            local status = WoWTranslateDB.outgoingEnabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Outgoing translation: " .. status)
        end

    elseif cmd == "outchannel" then
        if not WoWTranslateDB.outgoingChannels then
            WoWTranslateDB.outgoingChannels = WT_defaults.outgoingChannels
        end

        if arg and arg ~= "" then
            local channelType = string.upper(arg)
            if WoWTranslateDB.outgoingChannels[channelType] ~= nil then
                WoWTranslateDB.outgoingChannels[channelType] = not WoWTranslateDB.outgoingChannels[channelType]
                local newStatus = WoWTranslateDB.outgoingChannels[channelType] and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
                DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Outgoing " .. channelType .. ": " .. newStatus)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Unknown channel: " .. channelType .. "|r")
                DEFAULT_CHAT_FRAME:AddMessage("  Valid channels: WHISPER, PARTY, GUILD, RAID, SAY, YELL, BATTLEGROUND, CHANNEL")
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Outgoing channel settings:")
            for channelType, enabled in pairs(WoWTranslateDB.outgoingChannels) do
                local status = enabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
                DEFAULT_CHAT_FRAME:AddMessage("  " .. channelType .. ": " .. status)
            end
            DEFAULT_CHAT_FRAME:AddMessage("  Usage: /wt outchannel <WHISPER|PARTY|GUILD|RAID|SAY|YELL|BATTLEGROUND|CHANNEL>")
        end

    elseif cmd == "prefix" then
        if arg and arg ~= "" then
            WoWTranslateDB.outgoingPrefix = arg
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Outgoing prefix set to: " .. arg)
        else
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Current prefix: " .. (WoWTranslateDB.outgoingPrefix or "[Translated by WoWTranslate]"))
            DEFAULT_CHAT_FRAME:AddMessage("  Usage: /wt prefix <text>")
        end

    elseif cmd == "testout" then
        local testText = (arg and arg ~= "") and arg or "Hello, is anyone running MC?"
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing outgoing translation:")
        DEFAULT_CHAT_FRAME:AddMessage("  Input: " .. testText)

        local textToTranslate = testText
        local outFromLang = WoWTranslateDB and WoWTranslateDB.outgoingFromLang or "en"
        local glossaryResult = nil

        if outFromLang == "en" then
            if WT_PreprocessOutgoing then
                textToTranslate = WT_PreprocessOutgoing(textToTranslate)
            end
            if WoWTranslate_CheckOutGlossaryExact then
                glossaryResult = WoWTranslate_CheckOutGlossaryExact(textToTranslate)
            end
        else
            if WoWTranslate_CheckGlossaryExact then
                glossaryResult = WoWTranslate_CheckGlossaryExact(textToTranslate)
            end
        end

        if glossaryResult then
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Glossary hit: " .. glossaryResult)
            return
        end

        if not WoWTranslate_API.IsAvailable() then
            WoWTranslate_API.CheckDLL()
        end

        if not WoWTranslate_API.IsAvailable() then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Translation service not connected. Please start wow_proxy.py or start_proxy.bat!|r")
            return
        end

        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Requesting translation via " .. WoWTranslate_API.GetTransportName() .. "...")
        WoWTranslate_API.TranslateOutgoing(testText, function(result, err)
            if result then
                DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Translation:|r " .. (WT_SanitizeDisplayText and WT_SanitizeDisplayText(result) or result))
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Error: " .. (err or "unknown") .. "|r")
            end
        end)

    -- =====================================================================
    -- RECOVERY & CONFIGURATION UI COMMANDS
    -- =====================================================================
    elseif cmd == "reset" then
        local cleared = WoWTranslate_API.GetPendingCount()
        WoWTranslate_API.ClearPending()
        WoWTranslate_API.ResetBackoff()
        WT_dllWarnShown = false
        WT_translationErrWarnShown = false
        WT_HookChatFrames(true)
        local ok = WoWTranslate_API.CheckDLL()
        if ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Reset OK — hooks reinstalled, transport: " .. WoWTranslate_API.GetTransportName() .. ", cleared " .. cleared .. " stale request(s)|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[WoWTranslate] Reset: hooks reinstalled. Backend not detected — make sure wow_proxy.py is running!|r")
        end

    elseif cmd == "hooktest" then
        local hookedCount = 0
        local totalFrames = 0
        for i = 1, NUM_CHAT_WINDOWS do
            local f = getglobal("ChatFrame" .. i)
            if f then
                totalFrames = totalFrames + 1
                if f.WoWTranslateHooked then
                    hookedCount = hookedCount + 1
                end
            end
        end

        if hookedCount == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF4444[WT hooktest] NO frames hooked (0/" .. totalFrames .. ")|r")
        elseif hookedCount < totalFrames then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8800[WT hooktest] Partially hooked: " .. hookedCount .. "/" .. totalFrames .. " frames|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WT hooktest] All " .. hookedCount .. "/" .. totalFrames .. " frames hooked via SetScript(OnEvent)|r")
        end
        DEFAULT_CHAT_FRAME:AddMessage("[WT hooktest] Hook call count: " .. tostring(WT_hookCallCount))

    elseif cmd == "transport" then
        if arg == "proxy" or arg == "file" or arg == "ipc" then
            WoWTranslate_API.SetPreferredTransport("proxy")
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Preferred transport set to: |cFF00FF00File IPC Proxy|r")
        elseif arg == "dll" or arg == "unitxp" then
            WoWTranslate_API.SetPreferredTransport("dll")
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Preferred transport set to: |cFF00FF00UnitXP DLL|r")
        elseif arg == "auto" then
            WoWTranslate_API.SetPreferredTransport("auto")
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Preferred transport set to: |cFF00FF00Auto-Detect (Proxy preferred)|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Current transport: |cFF00FF00" .. WoWTranslate_API.GetTransportName() .. "|r")
            DEFAULT_CHAT_FRAME:AddMessage("  Preference: " .. (WoWTranslateDB.preferredTransport or "auto"))
            DEFAULT_CHAT_FRAME:AddMessage("  Usage: /wt transport <proxy|dll|auto>")
        end

    elseif cmd == "diag" then
        local diag = WoWTranslate_API.GetDiagnostics()
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Diagnostics:")
        DEFAULT_CHAT_FRAME:AddMessage("  Lua io.open: " .. (diag.hasLuaIO and "|cFF00FF00YES|r" or "|cFFFF0000NO (Sandboxed)|r") .. " | SuperWoW IO: " .. (diag.hasSuperWoW and "|cFF00FF00YES|r" or "|cFFFF0000NO|r"))
        DEFAULT_CHAT_FRAME:AddMessage("  SuperWoW Probe: " .. (diag.probeSuperWoW and "|cFF00FF00PASS|r" or "|cFFFF0000FAIL|r") .. " | IO Test: " .. (diag.canWriteSuperWoW and "|cFF00FF00PASS|r" or "|cFFFF0000FAIL|r"))
        DEFAULT_CHAT_FRAME:AddMessage("  UnitXP func: " .. (diag.hasUnitXP and "|cFF00FF00YES|r" or "|cFFFF0000NO|r") .. " | Ping: " .. tostring(diag.unitxpPing))
        DEFAULT_CHAT_FRAME:AddMessage("  Active Transport: |cFF00FF00" .. tostring(diag.transportName) .. "|r")
        DEFAULT_CHAT_FRAME:AddMessage("  Preferred Transport: " .. tostring(diag.preferredTransport))

    elseif cmd == "show" or cmd == "config" or cmd == "options" then
        WoWTranslate_ShowConfig()

    elseif cmd == "hide" then
        WoWTranslate_HideConfig()

    else
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt show - Open configuration panel")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt hide - Close configuration panel")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt on|off - Enable/disable incoming translation")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt status - Show full status & connected backend")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt transport [proxy|dll|auto] - Switch transport backend")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt diag - Show transport & I/O diagnostics")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt hooktest - Verify chat frame hook integrity")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt test [text] - Test incoming translation")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt testout [text] - Test outgoing translation")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt reset - Reset hooks, rate limit & clear stuck queues")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt clearcache - Clear translation cache")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt debug - Toggle debug mode")
        DEFAULT_CHAT_FRAME:AddMessage("  -- Outgoing Translation --")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt out [on|off] - Toggle/set outgoing translation (alias: /wt outgoing)")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt outchannel [channel] - Show/toggle outgoing channels")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt prefix <text> - Set outgoing message prefix")
    end
end

-- ============================================================================
-- ADDON INITIALIZATION
-- ============================================================================

WT_OnPlayerLogin = WT_OnPlayerLogin or function()
    WT_DebugLog("WT_OnPlayerLogin stub called — real definition will overwrite on load")
end

function WT_InitializeSettings()
    if not WoWTranslateDB then WoWTranslateDB = {} end
    if not WoWTranslateDebugLog then WoWTranslateDebugLog = {} end
    if type(WoWTranslateCache) ~= "table" then WoWTranslateCache = {} end
    if type(WoWTranslateCacheOrder) ~= "table" then WoWTranslateCacheOrder = {} end
    if type(WoWTranslateCacheCounter) ~= "number" then WoWTranslateCacheCounter = 0 end

    for key, value in pairs(WT_defaults) do
        if WoWTranslateDB[key] == nil then
            WoWTranslateDB[key] = value
        end
    end

    if WoWTranslateDB.outgoingPrefix == "[Translated]" then
        WoWTranslateDB.outgoingPrefix = "[Translated by WoWTranslate]"
    end

    if WoWTranslateDB.outgoingChannels then
        if WoWTranslateDB.outgoingChannels.BATTLEGROUND == nil then WoWTranslateDB.outgoingChannels.BATTLEGROUND = true end
        if WoWTranslateDB.outgoingChannels.CHANNEL == nil then WoWTranslateDB.outgoingChannels.CHANNEL = true end
        if WoWTranslateDB.outgoingChannels.HARDCORE == nil then WoWTranslateDB.outgoingChannels.HARDCORE = false end
        if WoWTranslateDB.outgoingChannels.ENGLISH == nil then WoWTranslateDB.outgoingChannels.ENGLISH = false end
    end

    if not WoWTranslateDB.incomingChannels then
        WoWTranslateDB.incomingChannels = {}
        for k, v in pairs(WT_defaults.incomingChannels) do
            WoWTranslateDB.incomingChannels[k] = v
        end
    end
    if WoWTranslateDB.incomingChannels.HARDCORE == nil then WoWTranslateDB.incomingChannels.HARDCORE = true end
    if WoWTranslateDB.incomingChannels.ENGLISH == nil then WoWTranslateDB.incomingChannels.ENGLISH = false end

    if WoWTranslateDB.translationColorFollow == nil then WoWTranslateDB.translationColorFollow = true end

    WT_DEBUG_MODE = WoWTranslateDB.debugMode or false

    WoWTranslateDB.apiKey = nil
    WoWTranslateDB.incomingFromLang = nil

    if WoWTranslateDB.enabledSourceLangs == nil then
        WoWTranslateDB.enabledSourceLangs = { zh=true, ja=true, ko=true, ru=true }
    end
    if WoWTranslateDB.enabledSourceLangs.en == nil then
        WoWTranslateDB.enabledSourceLangs.en = false
    end

    if WoWTranslateDB.translatePlayerNames == nil then WoWTranslateDB.translatePlayerNames = true end
    if WoWTranslateDB.translateGuildNames == nil then WoWTranslateDB.translateGuildNames = true end
    if WoWTranslateDB.translateNameplates == nil then WoWTranslateDB.translateNameplates = true end
    if WoWTranslateDB.translateGroupFinder == nil then WoWTranslateDB.translateGroupFinder = true end
    if WoWTranslateDB.outgoingButtonPos == nil then WoWTranslateDB.outgoingButtonPos = { x = 100, y = 100 } end
    if WoWTranslateDB.showOutgoingButton == nil then WoWTranslateDB.showOutgoingButton = true end
end

function WT_OnAddonLoaded()
    if WT_addonLoaded then return end
    WT_addonLoaded = true

    WT_InitializeSettings()

    if WoWTranslate_MinimapButton_Init then
        pcall(WoWTranslate_MinimapButton_Init)
    end

    WT_HookTooltips()
    WT_CreateOutgoingButton()

    local isAvail = WoWTranslate_API.CheckDLL()
    local statusText
    if isAvail then
        statusText = "|cFF00FF00" .. WoWTranslate_API.GetTransportName() .. " OK|r"
    else
        statusText = "|cFFFFFF00Backend not connected (Run start_proxy.bat)|r"
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFWoWTranslate|r v3.5.8 - " .. statusText .. " | /wt show")
end

-- ============================================================================
-- EVENT FRAME & TIMERS
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_FLAGS_CHANGED")

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "WoWTranslate" then
        WT_OnAddonLoaded()
    elseif event == "PLAYER_LOGIN" then
        WT_OnPlayerLogin()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not WoWTranslate_API.IsAvailable() then
            WoWTranslate_API.CheckDLL()
        end
    elseif event == "PLAYER_FLAGS_CHANGED" and arg1 == "player" then
        if UnitIsAFK then
            WT_playerIsAFK = (UnitIsAFK("player") == 1) or (UnitIsAFK("player") == true)
        end
    end
end)

local cleanupFrame = CreateFrame("Frame")
local cleanupElapsed = 0
cleanupFrame:SetScript("OnUpdate", function()
    cleanupElapsed = cleanupElapsed + arg1
    if cleanupElapsed >= 5 then
        cleanupElapsed = 0
        WT_CleanupPendingMessages()
        WT_CleanupOutgoingQueue()
    end
end)

-- Watchdog: ensures chat frame hooks stay active without unnecessary re-wrapping
local hookWatchdogElapsed = 0
local hookWatchdogFrame = CreateFrame("Frame")
hookWatchdogFrame:SetScript("OnUpdate", function()
    hookWatchdogElapsed = hookWatchdogElapsed + arg1
    if hookWatchdogElapsed < 60 then return end
    hookWatchdogElapsed = 0

    local needsRehook = false
    for i = 1, NUM_CHAT_WINDOWS do
        local f = getglobal("ChatFrame" .. i)
        if f and not f.WoWTranslateHooked then
            needsRehook = true
            break
        end
    end
    if needsRehook then
        pcall(WT_HookChatFrames, true)
    end
end)
