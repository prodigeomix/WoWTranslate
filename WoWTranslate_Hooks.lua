-- WoWTranslate_Hooks.lua

-- ============================================================================
-- CHAT FRAME HOOKING
-- ============================================================================

-- C3 fix: forward-declare WT_nextSendChatMessage as an upvalue so all
-- functions in this file (defined before OR after the install/uninstall
-- functions) share the same storage.  Without this, the `local` declared
-- later in the file would not be visible to WT_SafeSendChatMessage, which
-- is defined earlier — they'd silently use different storage locations.
local WT_nextSendChatMessage


-- Maps event to ChatTypeInfo key so we can read the native channel color.
-- CHAT_MSG_CHANNEL requires special handling (channel slot number determines the key).
local EVENT_TO_CHATTYPE = {
    CHAT_MSG_SAY                 = "SAY",
    CHAT_MSG_YELL                = "YELL",
    CHAT_MSG_WHISPER             = "WHISPER",
    CHAT_MSG_WHISPER_INFORM      = "WHISPER",
    CHAT_MSG_PARTY               = "PARTY",
    CHAT_MSG_GUILD               = "GUILD",
    CHAT_MSG_OFFICER             = "OFFICER",
    CHAT_MSG_RAID                = "RAID",
    CHAT_MSG_RAID_LEADER         = "RAID",
    CHAT_MSG_RAID_WARNING        = "RAID",
    CHAT_MSG_BATTLEGROUND        = "BATTLEGROUND",
    CHAT_MSG_BATTLEGROUND_LEADER = "BATTLEGROUND",
    CHAT_MSG_HARDCORE            = "HARDCORE",
}

-- Returns a 6-char uppercase hex string from ChatTypeInfo, or nil if not found.
function WT_GetChatTypeColorHex(event, channelStr)
    local chatType = EVENT_TO_CHATTYPE[event]
    if not chatType and event == "CHAT_MSG_CHANNEL" then
        local _, _, cap = string.find(channelStr or "", "^(%d+)%.")
        local num = cap and tonumber(cap)
        chatType = num and ("CHANNEL" .. num) or "CHANNEL"
    end
    if chatType and ChatTypeInfo and ChatTypeInfo[chatType] then
        local info = ChatTypeInfo[chatType]
        local r = info.r or 1
        local g = info.g or 1
        local b = info.b or 1
        return string.format("%02X%02X%02X",
            math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5),
            math.floor(b * 255 + 0.5))
    end
    return nil
end

-- Per-event display tags for the [WT-X] prefix shown with each translation.
-- CHAT_MSG_CHANNEL is handled dynamically from arg4 (channel name string).
local EVENT_CHANNEL_TAGS = {
    CHAT_MSG_SAY                  = "WT-Say",
    CHAT_MSG_YELL                 = "WT-Yell",
    CHAT_MSG_WHISPER              = "WT-Whisper",
    CHAT_MSG_WHISPER_INFORM       = "WT-Whisper",
    CHAT_MSG_PARTY                = "WT-Party",
    CHAT_MSG_GUILD                = "WT-Guild",
    CHAT_MSG_OFFICER              = "WT-Officer",
    CHAT_MSG_RAID                 = "WT-Raid",
    CHAT_MSG_RAID_LEADER          = "WT-Raid",
    CHAT_MSG_RAID_WARNING         = "WT-Raid",
    CHAT_MSG_BATTLEGROUND         = "WT-BG",
    CHAT_MSG_BATTLEGROUND_LEADER  = "WT-BG",
    CHAT_MSG_HARDCORE             = "WT-Hardcore",
}

-- Returns the [WT-X] tag string for a given event.
-- For CHAT_MSG_CHANNEL, channelStr is arg4 (e.g. "2. Trade" or "World").
function WT_GetChannelTag(event, channelStr)
    local tag = EVENT_CHANNEL_TAGS[event]
    if tag then return tag end
    if event == "CHAT_MSG_CHANNEL" then
        if channelStr and channelStr ~= "" then
            -- Strip leading "N. " number prefix that WoW prepends to channel names
            local name = string.gsub(channelStr, "^%d+%.%s*", "")
            if name and name ~= "" then return "WT-" .. name end
        end
        return "WT-Channel"
    end
    return "WT"
end


-- ============================================================================
-- GROUP FINDER (LFT) TRANSLATION
-- ============================================================================

-- Translates the title and description of each visible LFT group entry.
-- Hooks LFT_UpdateGroupsList (post-render); requires LFT addon to be loaded.
-- Gated on WoWTranslateDB.translateGroupFinder.

local lftHooked = false

-- After async translation resolves, find the entry frame still displaying
-- the same group and update the text widget.
function WT_LFT_ApplyTranslation(entryId, isTitle, translated)
    for i = 1, 8 do
        local btn = _G["LFTFrameGroupEntry"..i]
        if btn and btn:IsShown() and btn.data and btn.data.id == entryId then
            local suffix = isTitle and "Text" or "SubText"
            local widget = _G["LFTFrameGroupEntry"..i..suffix]
            if widget then widget:SetText(WT_SanitizeDisplayText and WT_SanitizeDisplayText(translated) or translated) end
        end
    end
end

function WT_LFT_TranslateField(entryId, rawText, isTitle)
    if not rawText or rawText == "" then return end
    local detectedLang = WT_DetectSourceLanguage(rawText)
    if not detectedLang then return end

    -- Cache hit: instant, no API call needed
    local cached, found = WoWTranslate_CacheGet(rawText)
    if found then
        WT_LFT_ApplyTranslation(entryId, isTitle, cached)
        return
    end

    -- Exact glossary hit: full-text WoW slang match
    if WoWTranslate_CheckGlossaryExact then
        local glossaryResult = WoWTranslate_CheckGlossaryExact(rawText)
        if glossaryResult then
            WoWTranslate_CacheSave(rawText, glossaryResult)
            WT_LFT_ApplyTranslation(entryId, isTitle, glossaryResult)
            return
        end
    end

    -- Partial glossary preprocessing then API translation
    local textToTranslate = rawText
    if WoWTranslate_CheckGlossaryPartial then
        local partial = WoWTranslate_CheckGlossaryPartial(rawText)
        if partial then textToTranslate = partial end
    end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then return end
    WoWTranslate_API.Translate(textToTranslate, function(translation, err)
        if translation and translation ~= "" then
            WoWTranslate_CacheSave(rawText, translation)
            WT_LFT_ApplyTranslation(entryId, isTitle, translation)
        end
    end, detectedLang)
end

function WT_LFT_ScanVisibleEntries()
    if not WoWTranslateDB or not WoWTranslateDB.translateGroupFinder then return end
    if not WoWTranslateDB.enabled then return end
    for i = 1, 8 do
        local btn = _G["LFTFrameGroupEntry"..i]
        if btn and btn:IsShown() and btn.data then
            local entry = btn.data
            WT_LFT_TranslateField(entry.id, entry.title, true)
            WT_LFT_TranslateField(entry.id, entry.description, false)
        end
    end
end

function WT_HookLFT()
    if lftHooked then return end
    if not LFT_UpdateGroupsList then return end
    -- M5 fix: save the original on a stable field so we can unhook later
    -- (and so re-hooking after LFT is updated doesn't double-wrap).
    if not LFT_UpdateGroupsList_WTOriginal then
        LFT_UpdateGroupsList_WTOriginal = LFT_UpdateGroupsList
    end
    local originalUpdate = LFT_UpdateGroupsList_WTOriginal
    LFT_UpdateGroupsList = function()
        originalUpdate()
        WT_LFT_ScanVisibleEntries()
    end
    lftHooked = true
end

-- M5 fix: restore the original LFT_UpdateGroupsList when the user disables
-- translateGroupFinder.  Without this, our wrapper stays installed forever
-- and references the original (pre-update) function even if LFT is updated.
function WT_UnhookLFT()
    if not lftHooked then return end
    if LFT_UpdateGroupsList_WTOriginal then
        LFT_UpdateGroupsList = LFT_UpdateGroupsList_WTOriginal
        LFT_UpdateGroupsList_WTOriginal = nil
    end
    lftHooked = false
end


-- ============================================================================
function WT_HookGameTooltip()
    if not GameTooltip then return end
    if GameTooltip.WoWTranslateTooltipHooked then return end
    GameTooltip.WoWTranslateTooltipHooked = true
    if not GameTooltip.WoWTranslateOrigSetUnit then
        GameTooltip.WoWTranslateOrigSetUnit = GameTooltip.SetUnit
    end
    if GameTooltip.SetHyperlink and not GameTooltip.WoWTranslateOrigSetHyperlink then
        GameTooltip.WoWTranslateOrigSetHyperlink = GameTooltip.SetHyperlink
    end
    local origSetUnit = GameTooltip.WoWTranslateOrigSetUnit
    function GameTooltip:SetUnit(unit)
        WT_ClearTooltipNameHeader(GameTooltip)
        GameTooltip.wtUnit = unit
        GameTooltip.wtPlayerName = nil
        GameTooltip.wtNameResolvePending = nil
        if unit and UnitExists(unit) and UnitIsPlayer(unit) then
            GameTooltip.wtPlayerName = UnitName(unit)
        end
        if origSetUnit then return origSetUnit(self, unit) end
    end
    if GameTooltip.WoWTranslateOrigSetHyperlink then
        local origSetHyperlink = GameTooltip.WoWTranslateOrigSetHyperlink
        function GameTooltip:SetHyperlink(link)
            WT_ClearTooltipNameHeader(GameTooltip)
            GameTooltip.wtUnit = nil
            GameTooltip.wtPlayerName = WT_ParsePlayerHyperlink(link)
            GameTooltip.wtNameResolvePending = nil
            if origSetHyperlink then return origSetHyperlink(self, link) end
        end
    end
    if not wtTooltipFrame then wtTooltipFrame = getglobal("WoWTranslateTooltipFrame") end
    if not wtTooltipFrame then
        wtTooltipFrame = CreateFrame("Frame", "WoWTranslateTooltipFrame", GameTooltip)
        local function DeferUpdateGameTooltip()
            if not WT_TooltipIsShown(GameTooltip) then return end
            if GameTooltip.wtAddedNameLine or GameTooltip.wtNameResolvePending then return end
            WT_UpdateTooltipPlayerNames(GameTooltip)
        end
        local function ArmTooltipDefer()
            wtTooltipFrame.elapsed = 0
            wtTooltipFrame:SetScript("OnUpdate", function()
                if not WT_TooltipIsShown(GameTooltip) then
                    wtTooltipFrame.elapsed = 0
                    wtTooltipFrame:SetScript("OnUpdate", nil)
                    return
                end
                if GameTooltip.wtAddedNameLine or GameTooltip.wtNameResolvePending then
                    wtTooltipFrame:SetScript("OnUpdate", nil)
                    return
                end
                wtTooltipFrame.elapsed = wtTooltipFrame.elapsed + arg1
                if wtTooltipFrame.elapsed < 0.4 then return end
                wtTooltipFrame:SetScript("OnUpdate", nil)
                DeferUpdateGameTooltip()
            end)
        end
        wtTooltipFrame:SetScript("OnShow", function() ArmTooltipDefer() end)
        if not GameTooltip.WoWTranslateOrigOnHide then
            GameTooltip.WoWTranslateOrigOnHide = GameTooltip:GetScript("OnHide")
        end
        local origOnHide = GameTooltip.WoWTranslateOrigOnHide
        GameTooltip:SetScript("OnHide", function()
            WT_ClearTooltipNameHeader(GameTooltip)
            GameTooltip.wtUnit = nil
            GameTooltip.wtPlayerName = nil
            GameTooltip.wtNameResolvePending = nil
            if origOnHide then origOnHide() end
        end)
    end
end

function WT_HookItemRefTooltip()
    if not ItemRefTooltip then return end
    if ItemRefTooltip.WoWTranslateTooltipHooked then return end
    ItemRefTooltip.WoWTranslateTooltipHooked = true
    if ItemRefTooltip.SetHyperlink and not ItemRefTooltip.WoWTranslateOrigSetHyperlink then
        ItemRefTooltip.WoWTranslateOrigSetHyperlink = ItemRefTooltip.SetHyperlink
    end
    if ItemRefTooltip.WoWTranslateOrigSetHyperlink then
        local origSetHyperlink = ItemRefTooltip.WoWTranslateOrigSetHyperlink
        function ItemRefTooltip:SetHyperlink(link)
            WT_ClearTooltipNameHeader(ItemRefTooltip)
            ItemRefTooltip.wtUnit = nil
            ItemRefTooltip.wtPlayerName = WT_ParsePlayerHyperlink(link)
            ItemRefTooltip.wtNameResolvePending = nil
            if origSetHyperlink then return origSetHyperlink(self, link) end
        end
    end
    local refFrame = getglobal("WoWTranslateItemRefTooltipFrame")
    if not refFrame then
        refFrame = CreateFrame("Frame", "WoWTranslateItemRefTooltipFrame", ItemRefTooltip)
        refFrame:SetScript("OnShow", function()
            refFrame.elapsed = 0
            refFrame:SetScript("OnUpdate", function()
                if not WT_TooltipIsShown(ItemRefTooltip) then
                    refFrame:SetScript("OnUpdate", nil); return
                end
                if ItemRefTooltip.wtAddedNameLine or ItemRefTooltip.wtNameResolvePending then
                    refFrame:SetScript("OnUpdate", nil); return
                end
                refFrame.elapsed = refFrame.elapsed + arg1
                if refFrame.elapsed < 0.25 then return end
                refFrame:SetScript("OnUpdate", nil)
                WT_UpdateTooltipPlayerNames(ItemRefTooltip)
            end)
        end)
        if not ItemRefTooltip.WoWTranslateOrigOnHide then
            ItemRefTooltip.WoWTranslateOrigOnHide = ItemRefTooltip:GetScript("OnHide")
        end
        local refOrigOnHide = ItemRefTooltip.WoWTranslateOrigOnHide
        ItemRefTooltip:SetScript("OnHide", function()
            WT_ClearTooltipNameHeader(ItemRefTooltip)
            ItemRefTooltip.wtPlayerName = nil
            ItemRefTooltip.wtNameResolvePending = nil
            if refOrigOnHide then refOrigOnHide() end
        end)
    end
end

function WT_HookTooltips()
    WT_HookGameTooltip()
    WT_HookItemRefTooltip()
    WT_HookNameplates()
end


-- ============================================================================
-- OUTGOING TOGGLE BUTTON
-- ============================================================================

local outgoingButton = nil

function WT_UpdateOutgoingButton()
    if not outgoingButton then return end
    if WoWTranslateDB and WoWTranslateDB.outgoingEnabled then
        outgoingButton:SetText("|cFF00FF00OUT:ON|r")
    else
        outgoingButton:SetText("|cFFFF4444OUT:OFF|r")
    end
end

function WT_CreateOutgoingButton()
    if outgoingButton then return end
    local f = CreateFrame("Button", "WoWTranslateOutgoingButton", UIParent)
    outgoingButton = f
    f:SetWidth(48)
    f:SetHeight(15)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "",
        tile = true, tileSize = 8, edgeSize = 0,
        insets = { left=0, right=0, top=0, bottom=0 },
    })
    f:SetBackdropColor(0, 0, 0, 0.7)

    local pos = WoWTranslateDB and WoWTranslateDB.outgoingButtonPos or { x=100, y=100 }
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetAllPoints(f)
    f.label = label

    f:SetScript("OnMouseDown", function()
        -- Toggle on click release (OnMouseUp handles it); just visual feedback.
    end)
    f:SetScript("OnMouseUp", function()
        if arg1 == "LeftButton" then
            local nowEnabled = not (WoWTranslateDB and WoWTranslateDB.outgoingEnabled)
            WoWTranslate_SetOutgoingEnabled(nowEnabled)
        end
    end)
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local x = f:GetLeft()
        local y = f:GetBottom()
        if WoWTranslateDB then
            WoWTranslateDB.outgoingButtonPos = { x = x, y = y }
        end
    end)

    -- Expose SetText on the frame so WT_UpdateOutgoingButton works cleanly.
    function f:SetText(text) self.label:SetText(text) end

    if WoWTranslateDB and WoWTranslateDB.showOutgoingButton == false then
        f:Hide()
    else
        f:Show()
    end
    WT_UpdateOutgoingButton()
end

function WT_ApplyOutgoingButtonVisibility()
    if not outgoingButton then return end
    if WoWTranslateDB and WoWTranslateDB.showOutgoingButton == false then
        outgoingButton:Hide()
    else
        outgoingButton:Show()
    end
end

-- ============================================================================
function WT_SafeAddMessage(func, self, text, r, g, b, id, holdTime)
    if holdTime ~= nil then return func(self, text, r, g, b, id, holdTime)
    elseif id ~= nil then return func(self, text, r, g, b, id)
    elseif b ~= nil then return func(self, text, r, g, b)
    elseif g ~= nil then return func(self, text, r, g)
    elseif r ~= nil then return func(self, text, r)
    else return func(self, text)
    end
end

local function SafeUTF8Truncate(str, maxBytes)
    if WT_SafeUTF8Truncate then
        return WT_SafeUTF8Truncate(str, maxBytes)
    end
    if not str then return "" end
    if not maxBytes or maxBytes <= 0 then return "" end
    local len = string.len(str)
    if len <= maxBytes then return str end

    local cut = maxBytes
    local back = 0
    while cut > 0 and back < 4 do
        local b = string.byte(str, cut)
        if b < 128 then
            return string.sub(str, 1, cut)
        elseif b >= 192 then
            local needed = (b >= 240 and 3) or (b >= 224 and 2) or 1
            if back == needed then
                return string.sub(str, 1, cut + back)
            else
                if cut <= 1 then return "" end
                return string.sub(str, 1, cut - 1)
            end
        else
            cut = cut - 1
            back = back + 1
        end
    end
    if cut <= 0 then return "" end
    return string.sub(str, 1, cut)
end

local function WT_ChatFrame_AddMessage_Hook(self, text, r, g, b, id, holdTime)
    self.wtMessageShown = true
    self.AddMessage = self.wtOrigAddMsg
    if WoWTranslateDB and WoWTranslateDB.replaceMode then
        self.wtPendingArgs = { text = text, r = r, g = g, b = b, id = id, holdTime = holdTime }
    else
        WT_SafeAddMessage(self.wtOrigAddMsg, self, text, r, g, b, id, holdTime)
    end
end

local function WT_ChatFrame_FlushOriginal(self)
    if self.wtPendingArgs then
        local p = self.wtPendingArgs
        self.wtPendingArgs = nil
        WT_SafeAddMessage(self.wtOrigAddMsg, self, p.text, p.r, p.g, p.b, p.id, p.holdTime)
    end
end

-- force=true clears WoWTranslateHooked so all frames are re-hooked (used by /wt reset).
-- origScript is saved on the frame so re-hooking always wraps the real WoW handler,
-- never a previously-installed WoWTranslate wrapper (no double-wrapping).
function WT_HookChatFrames(force)
    if not WT_originalAddMessage and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        WT_originalAddMessage = DEFAULT_CHAT_FRAME.AddMessage
    end

    for i = 1, NUM_CHAT_WINDOWS do
        local frameName = "ChatFrame" .. i
        local frame = getglobal(frameName)

        if frame then
            if force then frame.WoWTranslateHooked = false end

            if not frame.WoWTranslateHooked then
                local origScript = frame.WoWTranslate_OrigScript or frame:GetScript("OnEvent")
                if not origScript then
                    WT_DebugLog("No OnEvent script on", frameName)
                else
                    frame.WoWTranslate_OrigScript = origScript
                    frame.WoWTranslateHooked = true

                    frame:SetScript("OnEvent", function()
                        WT_hookCallCount = WT_hookCallCount + 1

                        local capturedEvent = event
                        local capturedArg1  = arg1
                        local capturedArg2  = arg2
                        local capturedArg4  = arg4
                        local capturedThis  = this

                        local _ok, _err = pcall(function()
                            capturedThis.wtMessageShown = false
                            capturedThis.wtOrigAddMsg = capturedThis.AddMessage
                            capturedThis.wtPendingArgs = nil
                            capturedThis.AddMessage = WT_ChatFrame_AddMessage_Hook

                            local origOk, origErr = pcall(origScript)
                                                        
                            capturedThis.AddMessage = capturedThis.wtOrigAddMsg

                            if not origOk then
                                WT_DebugLog("origScript error:", tostring(origErr))
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end

                            local wimWhisperUser = nil

                            if not capturedThis.wtMessageShown then
                                if (capturedEvent == "CHAT_MSG_WHISPER" or capturedEvent == "CHAT_MSG_WHISPER_INFORM") and
                                   type(WIM_Data) == "table" and WIM_Data.enableWIM and
                                   WIM_Data.supressWisps ~= false and
                                   type(WIM_PostMessage) == "function" and
                                   capturedArg2 and capturedArg2 ~= "" then
                                    wimWhisperUser = capturedArg2
                                else
                                    WT_ChatFrame_FlushOriginal(capturedThis)
                                    return
                                end
                            end

                            if not WoWTranslateDB or not WoWTranslateDB.enabled then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end
                            if WoWTranslateDB.disableWhileAfk and WT_playerIsAFK then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end

                            local channel  = WT_EVENT_TO_CHANNEL[capturedEvent]
                            local isSystem = WT_SYSTEM_EVENTS[capturedEvent]
                            if not channel and not isSystem then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end
                            if isSystem and not WoWTranslateDB.translateSystemMessages then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end

                            if channel then
                                local inChannels = WoWTranslateDB.incomingChannels
                                local effectiveChannel = channel
                                if channel == "CHANNEL" and capturedArg4 then
                                    local chanName = string.gsub(capturedArg4, "^%d+%.%s*", "")
                                    local lowerChan = string.lower(chanName)
                                    if string.find(lowerChan, "^english") then
                                        effectiveChannel = "ENGLISH"
                                    elseif lowerChan == "lft" or lowerChan == "vqueue" or string.find(lowerChan, "^pfquest") or lowerChan == "xtensionxtooltip2" then
                                        WT_ChatFrame_FlushOriginal(capturedThis)
                                        return
                                    end
                                end
                                if inChannels and not inChannels[effectiveChannel] then
                                    WT_ChatFrame_FlushOriginal(capturedThis)
                                    return
                                end
                            end

                            if not capturedArg1 or capturedArg1 == "" then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end
                            if capturedArg2 and UnitName and capturedArg2 == UnitName("player") then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end
                            if string.sub(capturedArg1, 1, 1) == "#" then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end
                            if string.find(capturedArg1, "^Meeting:[CR]:") or 
                               string.find(capturedArg1, "^BGTBL,") or
                               string.find(capturedArg1, "^Atlas: Version:") or
                               string.find(capturedArg1, "^Bath:V:") or
                               string.find(capturedArg1, "%[Translated by chat translator addon%]") or
                               string.find(capturedArg1, "WoWTranslate", 1, true) or
                               string.find(capturedArg1, "^Session: V: ") then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end

                            local detectedLang = WT_DetectSourceLanguage(capturedArg1)
                            WT_DebugLog("Event:", capturedEvent, "lang=", tostring(detectedLang), "msg=", string.sub(capturedArg1, 1, 30))
                            if not detectedLang then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end
                            local incomingTargetLang = (WoWTranslateDB and WoWTranslateDB.incomingToLang) or "en"
                            if detectedLang == incomingTargetLang then
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end

                            local resolvedSenderName = capturedArg2
                            local resolvedGuildName  = nil

                            local channelTag   = WT_GetChannelTag(capturedEvent, capturedArg4)
                            local msgColor     = (WoWTranslateDB and WoWTranslateDB.translationColor) or ""
                            local chanColorHex = WT_GetChatTypeColorHex(capturedEvent, capturedArg4)
                            local chanNamePart = string.sub(channelTag, 1, 3) == "WT-" and string.sub(channelTag, 4) or nil

                            local function BuildWTMsg(body)
                                local prefix
                                if chanColorHex and chanNamePart then
                                    prefix = "|cFF00FFFF[WT-|r|cFF" .. chanColorHex .. chanNamePart .. "]|r"
                                else
                                    prefix = "|cFF00FFFF[" .. channelTag .. "]|r"
                                end
                                local bodyHex = msgColor
                                if WoWTranslateDB and WoWTranslateDB.translationColorFollow then
                                    bodyHex = chanColorHex or ""
                                end
                                local displayBody = bodyHex ~= "" and ("|cFF" .. bodyHex .. body .. "|r") or body
                                local sp = WT_BuildSenderPrefix(capturedArg2, resolvedSenderName, channel, resolvedGuildName)
                                return prefix .. " " .. sp .. displayBody
                            end

                            local function ResolveNamesAndPost(body, postFn)
                                WT_ResolvePlayerDisplayName(capturedArg2, function(dName)
                                    resolvedSenderName = dName
                                    resolvedGuildName  = nil
                                    postFn(BuildWTMsg(body))
                                end)
                            end

                            local segments = WT_SplitIntoSegments(capturedArg1)
                             
                            -- Apply incoming preprocessing and glossary to segments individually
                            WT_ProcessSegmentsIncoming(segments, detectedLang)

                            if not WT_HasTranslatableContent(segments) then
                                local reconstructed = ""
                                for _, seg in ipairs(segments) do
                                    reconstructed = reconstructed .. seg.content
                                end
                                ResolveNamesAndPost(reconstructed, function(wtMsg)
                                    if wimWhisperUser and type(WIM_PostMessage) == "function" then
                                        WIM_PostMessage(wimWhisperUser, wtMsg, 3)
                                    else
                                        capturedThis:AddMessage(wtMsg)
                                    end
                                end)
                                return
                            end

                            local plainText = WT_BuildTranslatableText(segments)

                            if not wimWhisperUser then
                                if not WT_frameTranslationTargets[capturedArg1] then
                                    WT_frameTranslationTargets[capturedArg1] = {}
                                end
                                WT_frameTranslationTargets[capturedArg1][capturedThis] = true
                            end

                            local cached, found = WoWTranslate_CacheGet(capturedArg1)
                            if found then
                                WT_DebugLog("Cache hit")
                                local safeCached = WT_SanitizeDisplayText and WT_SanitizeDisplayText(cached) or cached
                                local reconstructed = WT_ReconstructMessage(segments, safeCached)
                                WT_frameTranslationTargets[capturedArg1] = nil
                                ResolveNamesAndPost(reconstructed, function(wtMsg)
                                    if wimWhisperUser and type(WIM_PostMessage) == "function" then
                                        WIM_PostMessage(wimWhisperUser, wtMsg, 3)
                                    else
                                        capturedThis:AddMessage(wtMsg)
                                    end
                                end)
                                return
                            end

                            local textToTranslate = plainText

                            if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
                                if not WT_dllWarnShown then
                                    WT_dllWarnShown = true
                                    capturedThis:AddMessage("|cFFFFFF00[WoWTranslate] Translation service not connected - run /wt status (start_proxy.bat)|r")
                                end
                                WT_ChatFrame_FlushOriginal(capturedThis)
                                return
                            end

                            local replacePendingKey = nil
                            local replacePendingData = nil
                            if capturedThis.wtPendingArgs then
                                local p = capturedThis.wtPendingArgs
                                replacePendingData = {
                                    WT_originalAddMessage = capturedThis.wtOrigAddMsg,
                                    frame              = capturedThis,
                                    originalText       = p.text,
                                    r = p.r, g = p.g, b = p.b,
                                    id = p.id, holdTime = p.holdTime,
                                    }
                                capturedThis.wtPendingArgs = nil
                            end

                            -- Cap at 280 bytes so encoded request ('zh|en|' + text) is <= 292 bytes,
                            -- strictly fitting within SuperWoW's 320-byte ExportFile buffer.
                            textToTranslate = SafeUTF8Truncate(textToTranslate, 280)

                            local apiQueued, rejectReason = WoWTranslate_API.Translate(textToTranslate, function(translation, err)
                                if translation and translation ~= "" then
                                    WT_DebugLog("Translation:", string.sub(translation, 1, 50))
                                    WT_translationErrWarnShown = false
                                    -- C8 fix: cache under BOTH the full message (so the
                                    -- next occurrence hits) AND the truncated text (so
                                    -- the same truncation elsewhere hits immediately).
                                    WoWTranslate_CacheSave(capturedArg1, translation)
                                    if textToTranslate ~= capturedArg1 then
                                        WoWTranslate_CacheSave(textToTranslate, translation)
                                    end
                                    local safeTranslation = WT_SanitizeDisplayText and WT_SanitizeDisplayText(translation) or translation
                                    local reconstructed = WT_ReconstructMessage(segments, safeTranslation)
                                    if replacePendingKey then
                                        WT_pendingMessages[replacePendingKey] = nil
                                    end
                                    local targets = WT_frameTranslationTargets[capturedArg1]
                                    WT_frameTranslationTargets[capturedArg1] = nil
                                    ResolveNamesAndPost(reconstructed, function(wtMsg)
                                        if wimWhisperUser and type(WIM_PostMessage) == "function" then
                                            WIM_PostMessage(wimWhisperUser, wtMsg, 3)
                                        elseif targets then
                                            local targetList = {}
                                            for targetFrame in pairs(targets) do
                                                table.insert(targetList, targetFrame)
                                            end
                                            for _, targetFrame in ipairs(targetList) do
                                                targetFrame:AddMessage(wtMsg)
                                            end
                                        else
                                            DEFAULT_CHAT_FRAME:AddMessage(wtMsg)
                                        end
                                    end)
                                else
                                    WT_DebugLog("Translation error:", tostring(err))
                                    WT_frameTranslationTargets[capturedArg1] = nil
                                    if replacePendingKey then
                                        local rp = WT_pendingMessages[replacePendingKey]
                                        if rp then
                                            WT_pendingMessages[replacePendingKey] = nil
                                            WT_SafeAddMessage(rp.WT_originalAddMessage, rp.frame, rp.originalText,
                                                rp.r, rp.g, rp.b, rp.id, rp.holdTime)
                                        end
                                    end
                                    if not WT_translationErrWarnShown then
                                        WT_translationErrWarnShown = true
                                        capturedThis:AddMessage("|cFFFFFF00[WoWTranslate] Translation failing (" .. tostring(err) .. ") - try /wt reset|r")
                                    end
                                end
                            end, detectedLang)
                            -- C6 fix: when Translate() rejects the request, flush the
                            -- original so the user still sees the message (in replaceMode
                            -- the original was suppressed into wtPendingArgs; without
                            -- this flush it would never be shown).  For "deduped" we
                            -- leave the original suppressed — another frame's callback
                            -- will broadcast the translation to all registered targets,
                            -- including this one.
                            if not apiQueued then
                                if rejectReason ~= "deduped" then
                                    -- queue_full or rate_limited: remove ourselves from
                                    -- the target map (another frame's callback would
                                    -- otherwise post a duplicate to us) and flush.
                                    if WT_frameTranslationTargets[capturedArg1] then
                                        WT_frameTranslationTargets[capturedArg1][capturedThis] = nil
                                    end
                                    WT_ChatFrame_FlushOriginal(capturedThis)
                                end
                            elseif replacePendingData then
                                replacePendingKey = "r|" .. tostring(capturedThis) .. "|" .. capturedArg1
                                -- Monotonic suffix prevents identical-text collisions from
                                -- overwriting a still-pending original (which would lose it).
                                WT_pendingKeyCounter = (WT_pendingKeyCounter or 0) + 1
                                replacePendingKey = replacePendingKey .. "|" .. tostring(WT_pendingKeyCounter)
                                replacePendingData.timestamp = GetTime()
                                WT_pendingMessages[replacePendingKey] = replacePendingData
                            end
                        end)
                        if not _ok then WT_DebugLog("OnEvent hook error:", tostring(_err)) end
                    end)

                    WT_DebugLog("Hooked", frameName, "via SetScript")
                end
            end
        end
    end
end

function WT_CleanupPendingMessages()
    local now = GetTime()
    local timedOut = {}
    for msgId, pending in pairs(WT_pendingMessages) do
        if now - pending.timestamp > 30 then
            table.insert(timedOut, { msgId = msgId, pending = pending })
        end
    end
    for _, item in ipairs(timedOut) do
        local msgId = item.msgId
        local pending = item.pending
        WT_DebugLog("Message timed out:", msgId)
        WT_pendingMessages[msgId] = nil
        WT_SafeAddMessage(pending.WT_originalAddMessage, pending.frame, pending.originalText, pending.r, pending.g, pending.b, pending.id, pending.holdTime)
    end
end


-- ============================================================================
-- OUTGOING TRANSLATION (English -> Chinese)
-- ============================================================================


function WT_SafeSendChatMessage(msg, chatType, language, channel)
    -- C3 fix: call through the chain (WT_nextSendChatMessage) when our hook
    -- is installed, so other addons' wrappers stay in the chain.  Fall back
    -- to the original snapshot if our hook is not installed.
    local sendFn = WT_nextSendChatMessage or WT_originalSendChatMessage
    if channel ~= nil then
        return sendFn(msg, chatType, language, channel)
    elseif language ~= nil then
        return sendFn(msg, chatType, language)
    elseif chatType ~= nil then
        return sendFn(msg, chatType)
    else
        return sendFn(msg)
    end
end

-- Clean up queued outgoing messages after timeout
function WT_CleanupOutgoingQueue()
    local now = GetTime()
    local timedOut = {}
    for queueId, item in pairs(WT_outgoingQueue) do
        if now - item.timestamp > 30 then
            table.insert(timedOut, { queueId = queueId, item = item })
        end
    end
    for _, entry in ipairs(timedOut) do
        local queueId = entry.queueId
        local item = entry.item
        WT_DebugLog("Outgoing message timed out:", queueId)
        WT_outgoingQueue[queueId] = nil
        if WT_originalAddMessage then
            WT_SafeAddMessage(WT_originalAddMessage, DEFAULT_CHAT_FRAME, "|cFFFF0000[WoWTranslate] Translation timed out, sending original|r")
        end
        WT_SafeSendChatMessage(item.originalMsg, item.chatType, item.language, item.channel)
    end
end

-- Hooked SendChatMessage for outgoing translation
function WT_HookedSendChatMessage(msg, chatType, language, channel)
    -- Handle nil chatType (WoW 1.12 compatibility)
    if not chatType then
        WT_DebugLog("chatType is nil, sending original")
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip if outgoing disabled
    if not WoWTranslateDB or not WoWTranslateDB.outgoingEnabled then
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip translation while AFK
    if WoWTranslateDB.disableWhileAfk and WT_playerIsAFK then
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip if channel not enabled
    if not WoWTranslateDB.outgoingChannels then
        WT_DebugLog("Channel not enabled for outgoing:", chatType)
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end
    local effectiveOutChannel = chatType
    if chatType == "CHANNEL" and channel then
        -- GetChannelName(number) does not reliably return the name in WoW 1.12;
        -- iterate GetChannelList() instead (returns id, name, id, name, ...).
        local list = {GetChannelList()}
        for i = 1, table.getn(list), 2 do
            if list[i] == channel then
                if string.find(string.lower(list[i+1] or ""), "^english") then
                    effectiveOutChannel = "ENGLISH"
                end
                break
            end
        end
    end
    if not WoWTranslateDB.outgoingChannels[effectiveOutChannel] then
        WT_DebugLog("Channel not enabled for outgoing:", effectiveOutChannel)
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip empty messages
    if not msg or msg == "" then
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip macro directives (#showtooltip, #show, etc.)
    if string.sub(msg, 1, 1) == "#" then
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip dot-commands sent by addons (e.g. .server info from PizzaWorldBuffs)
    if string.sub(msg, 1, 1) == "." then
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip addon inter-communication messages (PizzaWorldBuffs, Atlas-CFM, etc.)
    -- These follow the format: ADDONNAME:VERSION:DATA
    if string.find(msg, "^[A-Za-z][A-Za-z0-9_]*:%d+:") then
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip if already contains target language (don't double-translate)
    if WT_ContainsOutgoingTargetLanguage(msg) then
        WT_DebugLog("Message already contains target language, skipping outgoing translation")
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip if DLL not available
    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        WT_DebugLog("DLL not available for outgoing translation")
        return WT_SafeSendChatMessage(msg, chatType, language, channel)
    end

    -- Check exact match on the segment-level translatable text (L9 fix).
    -- Running the exact-match check on the raw msg with hyperlinks caused
    -- WT_ReconstructMessage to fail to find placeholders for links, since
    -- the glossary result was a translation of the raw msg, not the
    -- segmented text.  Now we segment first, then check exact match on
    -- the assembled translatable text.
    local outFromLang = WoWTranslateDB.outgoingFromLang or "en"

    -- Split message into segments (text and hyperlinks) to preserve links
    local segments = WT_SplitIntoSegments(msg)
    WT_DebugLog("Outgoing segments:", table.getn(segments))

    -- Process outgoing segments individually before translation
    WT_ProcessSegmentsOutgoing(segments, outFromLang)

    -- Build text to translate (hyperlinks replaced with URL placeholders)
    local textToTranslate = WT_BuildTranslatableText(segments)
    WT_DebugLog("Outgoing to translate:", textToTranslate)

    -- Exact glossary check on the SEGMENTED text (post-preprocessing).
    local exactGlossaryResult = nil
    if outFromLang == "en" then
        if WoWTranslate_CheckOutGlossaryExact then
            exactGlossaryResult = WoWTranslate_CheckOutGlossaryExact(textToTranslate)
        end
    else
        if WoWTranslate_CheckGlossaryExact then
            exactGlossaryResult = WoWTranslate_CheckGlossaryExact(textToTranslate)
        end
    end

    -- If exact glossary match was found, reconstruct and send immediately without calling DLL
    if exactGlossaryResult then
        local reconstructed = WT_ReconstructMessage(segments, exactGlossaryResult)
        WT_DebugLog("Outgoing exact glossary reconstructed:", reconstructed)

        local finalMsg
        if WoWTranslateDB.outgoingPrefixEnabled then
            local userPrefix = WoWTranslateDB.outgoingPrefix or WT_DEFAULT_PREFIX
            local prefix
            if userPrefix == WT_DEFAULT_PREFIX then
                local targetLang = WoWTranslateDB.outgoingToLang or "zh"
                prefix = WT_TRANSLATED_PREFIXES[targetLang] or userPrefix
            else
                prefix = userPrefix
            end
            finalMsg = prefix .. " " .. reconstructed
        else
            finalMsg = reconstructed
        end

        -- C7 fix: use SafeUTF8Truncate so we don't split a multi-byte
        -- UTF-8 sequence when the final message exceeds the 255-byte cap.
        if string.len(finalMsg) > 255 then
            finalMsg = SafeUTF8Truncate(finalMsg, 252) .. "..."
        end

        WT_SafeSendChatMessage(finalMsg, chatType, language, channel)

        if WT_originalAddMessage then
            WT_SafeAddMessage(WT_originalAddMessage, DEFAULT_CHAT_FRAME, "|cFF00FF00[WoWTranslate] Sent:|r " .. finalMsg)
        end
        return
    end

    -- Queue for translation
    WT_outgoingCounter = WT_outgoingCounter + 1
    local queueId = tostring(WT_outgoingCounter)

    WT_outgoingQueue[queueId] = {
        originalMsg = msg,
        segments = segments,  -- Store segments for reconstruction
        chatType = chatType,
        language = language,
        channel = channel,
        timestamp = GetTime()
    }

    -- Show local feedback
    if WT_originalAddMessage then
        WT_SafeAddMessage(WT_originalAddMessage, DEFAULT_CHAT_FRAME, "|cFFFFFF00[WoWTranslate] Translating...|r")
    end

    WT_DebugLog("Outgoing queued:", queueId, msg)

    -- Request translation (send only the text portions, not hyperlinks)
    WoWTranslate_API.TranslateOutgoing(textToTranslate, function(translation, err)
        local queued = WT_outgoingQueue[queueId]
        if not queued then
            WT_DebugLog("Outgoing callback but queue item gone:", queueId)
            return
        end
        WT_outgoingQueue[queueId] = nil

        if translation then
            WT_DebugLog("Outgoing translation received:", translation)

            -- Sanitize backend-derived translation before reconstructing with original hyperlinks
            local safeTranslation = WT_SanitizeDisplayText and WT_SanitizeDisplayText(translation) or translation
            local reconstructed = WT_ReconstructMessage(queued.segments, safeTranslation)
            WT_DebugLog("Outgoing reconstructed:", reconstructed)

            -- Dual-language mode: include both translation and original text
            local messageBody = reconstructed
            local dualEnabled = true
            if WoWTranslateDB and WoWTranslateDB.outgoingDualLanguage ~= nil then
                dualEnabled = WoWTranslateDB.outgoingDualLanguage
            end
            if dualEnabled and queued.originalMsg and queued.originalMsg ~= "" and reconstructed ~= queued.originalMsg then
                messageBody = reconstructed .. " (" .. queued.originalMsg .. ")"
            end

            -- Build message, optionally prepending the prefix
            local finalMsg
            if WoWTranslateDB and WoWTranslateDB.outgoingPrefixEnabled then
                local userPrefix = WoWTranslateDB.outgoingPrefix or WT_DEFAULT_PREFIX
                local prefix
                if userPrefix == WT_DEFAULT_PREFIX then
                    local targetLang = WoWTranslateDB.outgoingToLang or "zh"
                    prefix = WT_TRANSLATED_PREFIXES[targetLang] or userPrefix
                else
                    prefix = userPrefix
                end
                finalMsg = prefix .. " " .. messageBody
            else
                finalMsg = messageBody
            end

            -- C7 fix: use SafeUTF8Truncate so we don't split a multi-byte
            -- UTF-8 sequence when the final message exceeds the 255-byte cap.
            if string.len(finalMsg) > 255 then
                finalMsg = SafeUTF8Truncate(finalMsg, 252) .. "..."
            end

            WT_SafeSendChatMessage(finalMsg, queued.chatType, queued.language, queued.channel)

            if WT_originalAddMessage then
                WT_SafeAddMessage(WT_originalAddMessage, DEFAULT_CHAT_FRAME, "|cFF00FF00[WoWTranslate] Sent:|r " .. finalMsg)
            end
        else
            -- Translation failed - send original
            WT_DebugLog("Outgoing translation failed:", err)
            if WT_originalAddMessage then
                WT_SafeAddMessage(WT_originalAddMessage, DEFAULT_CHAT_FRAME, "|cFFFF0000[WoWTranslate] Translation failed, sending original|r")
            end
            WT_SafeSendChatMessage(queued.originalMsg, queued.chatType, queued.language, queued.channel)
        end
    end)
end

-- ============================================================================
-- OUTGOING HOOK (chain pattern — C3 fix)
-- ============================================================================
-- We chain-hook SendChatMessage instead of overwriting it.  When we install,
-- we capture whatever function is currently installed (which may itself be
-- another addon's wrapper) and call through it.  When we uninstall, we
-- restore that captured function.  This way we don't clobber later-loaded
-- addons and they don't clobber us.

-- Track if hook is installed (for diagnostics)
local outgoingHookInstalled = false
-- WT_nextSendChatMessage is forward-declared at the top of this file so all
-- functions share the same upvalue.  It holds the function that was installed
-- on SendChatMessage at install time (could be the Blizzard global or another
-- addon's wrapper); we call through it so other addons stay in the chain.

-- Install the outgoing message hook
function WT_InstallOutgoingHook()
    if outgoingHookInstalled then return end
    WT_DebugLog("Installing outgoing SendChatMessage hook (chain)")
    -- Capture whatever is currently installed — could be the Blizzard global
    -- or another addon's wrapper.  We call through it so its behavior is
    -- preserved.
    WT_nextSendChatMessage = SendChatMessage
    SendChatMessage = WT_HookedSendChatMessage
    outgoingHookInstalled = true
end

-- Remove the outgoing message hook
function WT_RemoveOutgoingHook()
    if not outgoingHookInstalled then return end
    -- Only restore if our wrapper is still on top.  If another addon wrapped
    -- on top of us, we leave their wrapper in place (they own the global now)
    -- but mark ourselves as uninstalled so WT_IsOutgoingHookActive reports
    -- false and we stop calling through the chain.
    WT_DebugLog("Removing outgoing SendChatMessage hook")
    if SendChatMessage == WT_HookedSendChatMessage then
        SendChatMessage = WT_nextSendChatMessage or WT_originalSendChatMessage
    end
    WT_nextSendChatMessage = nil
    outgoingHookInstalled = false
end

-- Check if hook is active (for diagnostics)
function WT_IsOutgoingHookActive()
    return outgoingHookInstalled and SendChatMessage == WT_HookedSendChatMessage
end

