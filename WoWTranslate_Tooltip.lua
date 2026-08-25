-- WoWTranslate_Tooltip.lua

-- ============================================================================
-- PLAYER NAME TRANSLATION
-- ============================================================================

local NAME_CACHE_PREFIX = "\1wt_name:"

function WT_NameCacheKey(name)
    return NAME_CACHE_PREFIX .. name
end

function WT_ShouldTranslatePlayerName(name)
    if not name or name == "" then return false end
    local lang = WT_DetectSourceLanguage(name)
    if not lang then return false end
    local target = (WoWTranslateDB and WoWTranslateDB.incomingToLang) or "en"
    return lang ~= target
end

local TRANSLATED_NAME_MARK = "|cFFFFFF00*|r"

function WT_RgbHex(colorOrR, g, b, a)
    local r, gr, bl, al
    if type(colorOrR) == "table" then
        if colorOrR.r then r, gr, bl, al = colorOrR.r, colorOrR.g, colorOrR.b, (colorOrR.a or 1) end
    elseif tonumber(colorOrR) then
        r, gr, bl, al = colorOrR, g, b, (a or 1)
    end
    if not r then return "" end
    if r > 1 then r = 1 elseif r < 0 then r = 0 end
    if gr > 1 then gr = 1 elseif gr < 0 then gr = 0 end
    if bl > 1 then bl = 1 elseif bl < 0 then bl = 0 end
    if al > 1 then al = 1 elseif al < 0 then al = 0 end
    return string.format("|c%02x%02x%02x%02x", math.floor(al*255 + 0.5), math.floor(r*255 + 0.5), math.floor(gr*255 + 0.5), math.floor(bl*255 + 0.5))
end

function WT_ApplyNameCapitalization(name)
    if not name or name == "" then return name end
    if type(CapitalizeName) == "function" then return CapitalizeName(name) end
    local parts = {}
    for word in string.gfind(name, "%S+") do
        if string.len(word) > 0 then
            table.insert(parts, string.upper(string.sub(word,1,1)) .. string.lower(string.sub(word,2)))
        end
    end
    if table.getn(parts) == 0 then return name end
    return table.concat(parts, " ")
end

function WT_FindPlayerUnitByName(name)
    if not name or name == "" then return nil end
    local function matchUnit(unit)
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local un = UnitName(unit)
            local pvp = UnitPVPName(unit)
            if un == name or (pvp and pvp == name) then return unit end
        end
    end
    local unit = matchUnit("mouseover")
    if unit then return unit end
    unit = matchUnit("target")
    if unit then return unit end
    unit = matchUnit("player")
    if unit then return unit end
    -- L4 fix: use GetNumPartyMembers/GetNumRaidMembers so we don't probe
    -- 40+ empty unit ids when solo.  In WoW 1.12 these return 0 when not
    -- in a group/raid.
    local nParty = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    for i = 1, nParty do
        unit = matchUnit("party" .. i)
        if unit then return unit end
    end
    local nRaid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    for i = 1, nRaid do
        unit = matchUnit("raid" .. i)
        if unit then return unit end
    end
    return nil
end

function WT_ResolvePlayerClass(rawName, unit)
    if unit and UnitExists(unit) and UnitIsPlayer(unit) then
        local _, class = UnitClass(unit)
        if class then return class end
    end
    unit = WT_FindPlayerUnitByName(rawName)
    if unit then
        local _, class = UnitClass(unit)
        if class then return class end
    end
    return nil
end

function WT_MarkTranslatedDisplayName(rawName, displayName, unit)
    if not displayName or displayName == "" then return displayName end
    if not rawName or displayName == rawName then return displayName end
    local plain = WT_StripColorCodes(displayName)
    plain = WT_ApplyNameCapitalization(plain)
    local class = WT_ResolvePlayerClass(rawName, unit)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        return WT_RgbHex(RAID_CLASS_COLORS[class]) .. plain .. "|r" .. TRANSLATED_NAME_MARK
    end
    return plain .. TRANSLATED_NAME_MARK
end

-- Build [Name*] <Guild*>: prefix for [WT] chat lines.
-- When translatePlayerNames is off, resolvedName == rawName so WT_MarkTranslatedDisplayName
-- returns rawName with no *, giving the same output as the old static senderPrefix.
function WT_BuildSenderPrefix(rawName, resolvedName, channel, guildDisplay)
    if not rawName or rawName == "" then return "" end
    local unit = WT_FindPlayerUnitByName(rawName)
    local resolved = resolvedName or rawName
    local isTranslated = resolved ~= rawName
    local guildStr = ""
    if guildDisplay and guildDisplay ~= "" then
        guildStr = " <" .. guildDisplay .. "*>"
    end
    if channel then
        if isTranslated then
            -- ShaguTweaks chat-levels/social-colors patterns require [rawName]
            -- in the display to match, which breaks when we replace it. Instead,
            -- build class color and level ourselves: read level from ShaguTweaks'
            -- player cache (ShaguTweaks_cache.players[name].level) with UnitLevel
            -- as fallback, and apply difficulty color via GetDifficultyColor.
            local plain = WT_ApplyNameCapitalization(WT_StripColorCodes(resolved))
            -- Mirror social-colors.lua: use ShaguTweaks.GetUnitData for the class lookup
            -- since it has the same broad reach (unit frames + ShaguTweaks player cache)
            -- that lets social-colors color the raw name. Fall back to WT_ResolvePlayerClass.
            local classColor = nil
            if ShaguTweaks and type(ShaguTweaks.GetUnitData) == "function" then
                local class = ShaguTweaks.GetUnitData(rawName)
                if class and class ~= UNKNOWN then
                    classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
                end
            end
            if not classColor then
                local class = WT_ResolvePlayerClass(rawName, unit)
                classColor = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
            end
            local coloredName = classColor and (WT_RgbHex(classColor) .. plain .. "|r") or plain
            local levelStr = ""
            local shaguData = ShaguTweaks_cache and ShaguTweaks_cache["players"] and ShaguTweaks_cache["players"][rawName]
            local lvl = shaguData and shaguData.level
            if (not lvl or lvl <= 0) and unit then lvl = UnitLevel(unit) end
            if lvl and lvl > 0 then
                local dr, dg, db = GetDifficultyColor(lvl)
                levelStr = " " .. WT_RgbHex(dr, dg, db) .. tostring(lvl) .. "|r"
            end
            return "|Hplayer:" .. rawName .. "|h[" .. coloredName .. "]|h|r"
                .. TRANSLATED_NAME_MARK .. levelStr .. guildStr .. ": "
        else
            return "|Hplayer:" .. rawName .. "|h[" .. rawName .. "]|h|r" .. guildStr .. ": "
        end
    else
        local nameStr = WT_MarkTranslatedDisplayName(rawName, resolved, unit)
        return nameStr .. guildStr .. ": "
    end
end

function WT_ResolvePlayerDisplayName(rawName, callback)
    if not callback then return end
    if not WoWTranslateDB or not WoWTranslateDB.translatePlayerNames then
        callback(rawName)
        return
    end
    if not rawName or rawName == "" then
        callback(rawName)
        return
    end
    if not WT_ShouldTranslatePlayerName(rawName) then
        callback(rawName)
        return
    end
    local cacheKey = WT_NameCacheKey(rawName)
    local cached, found = WoWTranslate_CacheGet(cacheKey)
    if found then callback(cached); return end

    local nameLang = WT_DetectSourceLanguage(rawName)
    if not nameLang then callback(rawName); return end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        callback(rawName)
        return
    end

    local waiters = WT_pendingNameTranslations[rawName]
    if waiters then
        table.insert(waiters.callbacks, callback)
        return
    end

    waiters = { callbacks = { callback } }
    WT_pendingNameTranslations[rawName] = waiters

    local function finish(result)
        local w = WT_pendingNameTranslations[rawName]
        WT_pendingNameTranslations[rawName] = nil
        if w then
            for i = 1, table.getn(w.callbacks) do w.callbacks[i](result) end
        end
    end

    local ok = WoWTranslate_API.Translate(rawName, function(translation, err)
        if translation and translation ~= "" then
            local capitalized = WT_ApplyNameCapitalization(translation)
            WoWTranslate_CacheSave(cacheKey, capitalized)
            finish(capitalized)
        else
            finish(rawName)
        end
    end, nameLang)

    if not ok then
        -- Queue full; poll cache briefly so the waiter doesn't hang.
        -- H4 fix: Hide() the poll frame after we're done with it.  Old code
        -- cleared the OnUpdate script but left the Frame alive and visible,
        -- which over a long session accumulated many hidden frames (each
        -- frame participates in every OnUpdate dispatch in WoW 1.12).
        local retries = 0
        local pollFrame = CreateFrame("Frame")
        pollFrame:Hide()
        local elapsed = 0
        pollFrame:SetScript("OnUpdate", function()
            elapsed = elapsed + arg1
            if elapsed < 0.1 then return end
            elapsed = 0
            retries = retries + 1
            local c, hit = WoWTranslate_CacheGet(cacheKey)
            if hit then
                pollFrame:Hide()
                pollFrame:SetScript("OnUpdate", nil)
                finish(c)
            elseif retries >= 50 then
                pollFrame:Hide()
                pollFrame:SetScript("OnUpdate", nil)
                finish(rawName)
            end
        end)
        pollFrame:Show()
    end
end

-- callback(guildDisplay, rankDisplay, rawGuild):
--   guildDisplay = translated guild name, nil if not translatable
--   rankDisplay  = translated rank name,  nil if not translatable
--   rawGuild     = raw guild name always (so caller can show it alongside a translated rank)
-- tooltipGuildText: the guild name read directly from the <GuildName> tooltip line,
--   used to detect servers that return GetGuildInfo as (rank, guild) instead of (guild, rank).
function WT_ResolveGuildDisplayName(rawName, tooltipGuildText, callback)
    if not WoWTranslateDB or not WoWTranslateDB.translateGuildNames then
        callback(nil, nil, nil)
        return
    end
    local unit = WT_FindPlayerUnitByName(rawName)
    if not unit then callback(nil, nil, nil); return end
    local ret1, ret2 = GetGuildInfo(unit)
    if not ret1 or ret1 == "" then callback(nil, nil, nil); return end

    -- Detect and correct servers where GetGuildInfo returns (rankName, guildName) instead of
    -- the standard (guildName, rankName).  The tooltip <GuildName> line is authoritative.
    local guildName, guildRankName = ret1, ret2 or ""
    if tooltipGuildText and tooltipGuildText ~= "" and ret2 and ret2 ~= "" then
        if ret2 == tooltipGuildText and ret1 ~= tooltipGuildText then
            guildName, guildRankName = ret2, ret1
        end
    end

    local function hasTranslatable(s)
        return s and (WT_ContainsLanguageChars(s,"zh") or WT_ContainsLanguageChars(s,"ja")
            or WT_ContainsLanguageChars(s,"ko") or WT_ContainsLanguageChars(s,"ru"))
    end

    -- guildName is always passed as rawGuild so callers can show it untranslated when needed.
    local function resolveRank(guildDisplay)
        if not hasTranslatable(guildRankName) then callback(guildDisplay, nil, guildName); return end
        local rankCacheKey = WT_NameCacheKey("rank:" .. guildRankName)
        local rankCached, rankFound = WoWTranslate_CacheGet(rankCacheKey)
        if rankFound then callback(guildDisplay, rankCached, guildName); return end
        if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
            callback(guildDisplay, nil, guildName); return
        end
        local rLang = WT_DetectSourceLanguage(guildRankName)
        if not rLang then callback(guildDisplay, nil, guildName); return end
        local ok = WoWTranslate_API.Translate(guildRankName, function(translation, err)
            if translation and translation ~= "" then
                WoWTranslate_CacheSave(rankCacheKey, translation)
                callback(guildDisplay, translation, guildName)
            else
                callback(guildDisplay, nil, guildName)
            end
        end, rLang)
        if not ok then callback(guildDisplay, nil, guildName) end
    end

    if not hasTranslatable(guildName) then resolveRank(nil); return end

    local cacheKey = WT_NameCacheKey("guild:" .. guildName)
    local cached, found = WoWTranslate_CacheGet(cacheKey)
    if found then resolveRank(cached); return end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        callback(nil, nil, guildName); return
    end
    local gLang = WT_DetectSourceLanguage(guildName)
    if not gLang then resolveRank(nil); return end

    local ok = WoWTranslate_API.Translate(guildName, function(translation, err)
        if translation and translation ~= "" then
            WoWTranslate_CacheSave(cacheKey, translation)
            resolveRank(translation)
        else
            resolveRank(nil)
        end
    end, gLang)
    if not ok then callback(nil, nil, guildName) end
end

-- Global entry point for guild-name-only translation (used by OOC nameplate guild display).
-- callback(displayGuild) — displayGuild is nil when not translatable or queue full.
function WoWTranslate_ResolveGuildDisplayName(rawGuild, callback)
    if not rawGuild or rawGuild == "" then callback(nil); return end
    local function hasTranslatable(s)
        return s and (WT_ContainsLanguageChars(s,"zh") or WT_ContainsLanguageChars(s,"ja")
            or WT_ContainsLanguageChars(s,"ko") or WT_ContainsLanguageChars(s,"ru"))
    end
    if not hasTranslatable(rawGuild) then callback(nil); return end
    local cacheKey = WT_NameCacheKey("guild:" .. rawGuild)
    local cached, found = WoWTranslate_CacheGet(cacheKey)
    if found then callback(cached); return end
    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        callback(nil); return
    end
    local gLang = WT_DetectSourceLanguage(rawGuild)
    if not gLang then callback(nil); return end
    local ok = WoWTranslate_API.Translate(rawGuild, function(translation, err)
        if translation and translation ~= "" then
            WoWTranslate_CacheSave(cacheKey, translation)
            callback(translation)
        else
            callback(nil)
        end
    end, gLang)
    if not ok then callback(nil) end
end

-- ============================================================================
-- TOOLTIP NAME TRANSLATION
-- ============================================================================

local wtTooltipFrame = nil
local TOOLTIP_MAX_LINES = 30

function WT_TooltipIsShown(tooltip)
    if not tooltip or not tooltip.IsShown then return false end
    local shown = tooltip:IsShown()
    return shown == 1 or shown == true
end

function WT_CaptureTooltipStatusBarState(tooltip)
    if tooltip ~= GameTooltip then return end
    local bar = GameTooltipStatusBar
    if not bar then return end
    local shown = bar:IsShown()
    tooltip.wtStatusBarWasVisible = (shown == 1 or shown == true)
end

function WT_RestoreTooltipStatusBar(tooltip)
    if tooltip ~= GameTooltip or not tooltip.wtStatusBarWasVisible then return end
    if not WT_TooltipIsShown(tooltip) then return end
    local bar = GameTooltipStatusBar
    if not bar then return end
    local unit = tooltip.wtUnit
    if (not unit or not UnitExists(unit)) and UnitExists("mouseover") then unit = "mouseover" end
    if not unit or not UnitExists(unit) then return end
    local healthMax = UnitHealthMax(unit)
    if not healthMax or healthMax <= 0 then return end
    bar:SetMinMaxValues(0, healthMax)
    bar:SetValue(UnitHealth(unit))
    bar:Show()
    if bar.bg and bar.bg.Show then bar.bg:Show() end
    if bar.backdrop and bar.backdrop.Show then bar.backdrop:Show() end
    if WoWTranslate_OnTooltipLayoutRefresh then WoWTranslate_OnTooltipLayoutRefresh(tooltip, unit) end
end

function WT_GetTooltipTextFont(tooltip, lineIndex)
    lineIndex = lineIndex or 1
    if tooltip == GameTooltip then return getglobal("GameTooltipTextLeft" .. lineIndex) end
    if ItemRefTooltip and tooltip == ItemRefTooltip then
        return getglobal("ItemRefTooltipTextLeft" .. lineIndex)
    end
    if tooltip and tooltip.GetName then return getglobal(tooltip:GetName() .. "TextLeft" .. lineIndex) end
end

function WT_GetTooltipLinePair(tooltip, lineIndex)
    local tipName = tooltip and tooltip.GetName and tooltip:GetName()
    if not tipName then return nil, nil end
    return getglobal(tipName .. "TextLeft" .. lineIndex),
           getglobal(tipName .. "TextRight" .. lineIndex)
end

function WT_CaptureTooltipLine(left, right)
    local entry = { leftText="", rightText="", leftShown=false, rightShown=false }
    if left then
        entry.leftText = left:GetText() or ""
        entry.leftR, entry.leftG, entry.leftB = left:GetTextColor()
        entry.leftShown = entry.leftText ~= ""
    end
    if right then
        entry.rightText = right:GetText() or ""
        entry.rightR, entry.rightG, entry.rightB = right:GetTextColor()
        entry.rightShown = entry.rightText ~= ""
    end
    return entry
end

function WT_ClearTooltipLine(left, right)
    if left and left.Hide then left:SetText(""); left:Hide() end
    if right and right.Hide then right:SetText(""); right:Hide() end
end

function WT_SnapshotTooltipLines(tooltip)
    local numLines = 1
    if tooltip.NumLines then
        numLines = tooltip:NumLines()
        if numLines < 1 then numLines = 1 end
    end
    local snap = { numLines = numLines, lines = {} }
    for i = 1, numLines do
        local left, right = WT_GetTooltipLinePair(tooltip, i)
        snap.lines[i] = WT_CaptureTooltipLine(left, right)
    end
    return snap
end

function WT_WipeTooltipTextLines(tooltip)
    local tipName = tooltip and tooltip.GetName and tooltip:GetName()
    if not tipName then return end
    for i = 1, TOOLTIP_MAX_LINES do
        WT_ClearTooltipLine(getglobal(tipName.."TextLeft"..i), getglobal(tipName.."TextRight"..i))
    end
end

function WT_ClearTooltipNameHeader(tooltip)
    if not tooltip then return end
    if wtTooltipFrame and wtTooltipFrame.watchTooltip == tooltip then
        wtTooltipFrame.watchTooltip = nil
        wtTooltipFrame:SetScript("OnUpdate", nil)
    end
    if tooltip.ClearLines then tooltip:ClearLines() end
    WT_WipeTooltipTextLines(tooltip)
    tooltip.wtLineSnapshot = nil
    tooltip.wtLine1Text = nil
    tooltip.wtAddedNameLine = nil
    tooltip.wtWtInternalAddLine = nil
    tooltip.wtNameResolvePending = nil
    tooltip.wtStatusBarWasVisible = nil
end

function WT_ReplayTooltipLine(tooltip, entry)
    if not entry then return end
    local hasLeft  = entry.leftShown  and entry.leftText  and entry.leftText  ~= ""
    local hasRight = entry.rightShown and entry.rightText and entry.rightText ~= ""
    if hasRight and tooltip.AddDoubleLine then
        tooltip:AddDoubleLine(
            hasLeft and entry.leftText or "", entry.rightText,
            entry.leftR or 1, entry.leftG or 1, entry.leftB or 1,
            entry.rightR or 1, entry.rightG or 1, entry.rightB or 1)
    elseif hasLeft and tooltip.AddLine then
        tooltip:AddLine(entry.leftText, entry.leftR or 1, entry.leftG or 1, entry.leftB or 1)
    elseif hasRight and tooltip.AddLine then
        tooltip:AddLine(entry.rightText, entry.rightR or 1, entry.rightG or 1, entry.rightB or 1)
    end
end

-- Fallback for tooltips without ClearLines/AddLine: prepend only the first line.
function WT_InsertTooltipNamePrepend(tooltip, text)
    local left1 = WT_GetTooltipTextFont(tooltip, 1)
    if not left1 then return end
    local orig = left1:GetText() or ""
    if tooltip.wtLine1Text then return end
    tooltip.wtLine1Text = orig
    WT_CaptureTooltipStatusBarState(tooltip)
    left1:SetText(text .. "|n" .. orig)
    tooltip.wtAddedNameLine = true
    tooltip:Show()
    WT_RestoreTooltipStatusBar(tooltip)
end

-- Rebuild tooltip with translated lines prepended; original lines follow.
function WT_InsertTooltipLines(tooltip, lines)
    if not tooltip or tooltip.wtAddedNameLine then return end
    if not lines or table.getn(lines) == 0 then return end
    if not WT_TooltipIsShown(tooltip) then return end
    if not tooltip.ClearLines or not tooltip.AddLine then
        WT_InsertTooltipNamePrepend(tooltip, lines[1])
        return
    end
    tooltip.wtLineSnapshot = WT_SnapshotTooltipLines(tooltip)
    WT_CaptureTooltipStatusBarState(tooltip)
    tooltip.wtWtInternalAddLine = true
    tooltip:ClearLines()
    for i = 1, table.getn(lines) do
        tooltip:AddLine(lines[i], 1, 1, 1)
    end
    for i = 1, tooltip.wtLineSnapshot.numLines do
        WT_ReplayTooltipLine(tooltip, tooltip.wtLineSnapshot.lines[i])
    end
    tooltip.wtWtInternalAddLine = nil
    local numLines = (tooltip.NumLines and tooltip:NumLines()) or 0
    for i = numLines + 1, TOOLTIP_MAX_LINES do
        WT_ClearTooltipLine(WT_GetTooltipLinePair(tooltip, i))
    end
    tooltip.wtAddedNameLine = true
    tooltip:Show()
    WT_RestoreTooltipStatusBar(tooltip)
end

function WT_ArmTooltipLayoutWatch(tooltip)
    if not wtTooltipFrame or not tooltip then return end
    wtTooltipFrame.watchTooltip = tooltip
    wtTooltipFrame.watchLines = (tooltip.NumLines and tooltip:NumLines()) or 0
    wtTooltipFrame.watchElapsed = 0
    wtTooltipFrame.layoutDelay = 0
    wtTooltipFrame.layoutPending = true
    wtTooltipFrame:SetScript("OnUpdate", function()
        local tip = wtTooltipFrame.watchTooltip
        if not tip or not WT_TooltipIsShown(tip) or not tip.wtAddedNameLine then
            wtTooltipFrame.watchTooltip = nil
            wtTooltipFrame:SetScript("OnUpdate", nil)
            return
        end
        wtTooltipFrame.watchElapsed = wtTooltipFrame.watchElapsed + arg1
        local n = (tip.NumLines and tip:NumLines()) or 0
        if n ~= wtTooltipFrame.watchLines then
            wtTooltipFrame.watchLines = n
            wtTooltipFrame.layoutDelay = 0
            wtTooltipFrame.layoutPending = true
        elseif wtTooltipFrame.layoutPending then
            wtTooltipFrame.layoutDelay = wtTooltipFrame.layoutDelay + arg1
            if wtTooltipFrame.layoutDelay >= 0.12 then
                tip:Show()
                WT_RestoreTooltipStatusBar(tip)
                wtTooltipFrame.layoutPending = nil
                wtTooltipFrame.layoutDelay = 0
            end
        end
        if wtTooltipFrame.watchElapsed >= 1.0 then
            wtTooltipFrame.watchTooltip = nil
            wtTooltipFrame:SetScript("OnUpdate", nil)
        end
    end)
end

function WT_ParsePlayerHyperlink(link)
    if not link then return nil end
    if string.sub(link, 1, 7) ~= "player:" then return nil end
    local name = string.sub(link, 8)
    if name and name ~= "" then return name end
    return nil
end

function WT_FindPlayerUnitFromTooltipText(tipText)
    if not tipText or tipText == "" then return nil end
    local plain = WT_StripColorCodes(tipText)
    local function matchUnit(unit)
        if UnitExists(unit) and UnitIsPlayer(unit) then
            local name = UnitName(unit)
            local pvp  = UnitPVPName(unit)
            local clean = string.gsub(plain, "%s*<.*>%s*", "")
            if name and (clean == name or clean == pvp) then
                return unit, name, pvp
            end
        end
    end
    local unit, name, pvp = matchUnit("mouseover")
    if unit then return unit, name, pvp end
    unit, name, pvp = matchUnit("target")
    if unit then return unit, name, pvp end
    unit, name, pvp = matchUnit("player")
    if unit then return unit, name, pvp end
    for i = 1, 4 do unit, name, pvp = matchUnit("party"..i); if unit then return unit, name, pvp end end
    for i = 1, 40 do unit, name, pvp = matchUnit("raid"..i); if unit then return unit, name, pvp end end
    return nil
end

function WT_ResolveTooltipPlayerName(tooltip)
    if tooltip.wtPlayerName and tooltip.wtPlayerName ~= "" then
        local altName = nil
        if tooltip.wtUnit and UnitExists(tooltip.wtUnit) then altName = UnitPVPName(tooltip.wtUnit) end
        return tooltip.wtPlayerName, altName
    end
    if tooltip.wtUnit and UnitExists(tooltip.wtUnit) and UnitIsPlayer(tooltip.wtUnit) then
        local name = UnitName(tooltip.wtUnit)
        local pvp  = UnitPVPName(tooltip.wtUnit)
        if name and name ~= "" then tooltip.wtPlayerName = name; return name, pvp end
    end
    local fs = WT_GetTooltipTextFont(tooltip, 1)
    if fs and fs.GetText then
        local tipText = fs:GetText()
        local unit, name, pvp = WT_FindPlayerUnitFromTooltipText(tipText)
        if name then tooltip.wtUnit = unit; tooltip.wtPlayerName = name; return name, pvp end
        local plain = WT_StripColorCodes(tipText)
        if plain and plain ~= "" and WT_ShouldTranslatePlayerName(plain) then
            tooltip.wtPlayerName = plain; return plain, nil
        end
    end
    return nil
end

function WT_UpdateTooltipPlayerNames(tooltip)
    if not tooltip then return end
    if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
    if WoWTranslateDB.disableWhileAfk and WT_playerIsAFK then return end
    local doName  = WoWTranslateDB.translatePlayerNames
    local doGuild = WoWTranslateDB.translateGuildNames
    if not doName and not doGuild then return end
    if not WT_TooltipIsShown(tooltip) then return end
    if tooltip.wtAddedNameLine then return end

    local rawName = WT_ResolveTooltipPlayerName(tooltip)
    if not rawName or rawName == "" then return end
    -- Allow English-named players through when guild translation is enabled;
    -- WT_ResolveGuildDisplayName will decide whether their guild/rank needs translation.
    if not WT_ShouldTranslatePlayerName(rawName) and not doGuild then return end

    if tooltip.wtNameResolvePending == rawName then return end
    tooltip.wtNameResolvePending = rawName

    WT_ResolvePlayerDisplayName(rawName, function(displayName)
        tooltip.wtNameResolvePending = nil
        if not WT_TooltipIsShown(tooltip) then return end
        if tooltip.wtPlayerName ~= rawName then return end
        if tooltip.wtAddedNameLine then return end

        -- Synchronously read the tooltip guild line before any async call:
        -- captures guild color for display and the authoritative guild text
        -- for swap-detection inside WT_ResolveGuildDisplayName.
        local guildR, guildG, guildB
        local tooltipGuildText = ""
        local tipName = tooltip:GetName()
        if tipName then
            local numLines = (tooltip.NumLines and tooltip:NumLines()) or 0
            for i = 2, numLines do
                local left = getglobal(tipName .. "TextLeft" .. i)
                if left then
                    local t = left:GetText() or ""
                    if string.find(t, "^<") then
                        guildR, guildG, guildB = left:GetTextColor()
                        tooltipGuildText = string.sub(t, 2, string.len(t) - 1)
                        break
                    end
                end
            end
        end

        WT_ResolveGuildDisplayName(rawName, tooltipGuildText, function(guildDisplay, rankDisplay, rawGuild)
            if not WT_TooltipIsShown(tooltip) then return end
            if tooltip.wtAddedNameLine then return end

            local lines = {}
            local marked = WT_MarkTranslatedDisplayName(rawName, displayName, tooltip.wtUnit)

            local hasGuild = guildDisplay and guildDisplay ~= ""
            local hasRank  = rankDisplay  and rankDisplay  ~= ""
            -- Show raw guild (no *) alongside a translated rank when the guild itself
            -- needs no translation.
            local showRawGuild = (not hasGuild) and hasRank and rawGuild and rawGuild ~= ""

            if marked and marked ~= rawName then
                table.insert(lines, marked)
            elseif (hasGuild or hasRank) and rawName and rawName ~= "" then
                -- English name: passthrough with class color so it appears above guild/rank
                local class = WT_ResolvePlayerClass(rawName, tooltip.wtUnit)
                local nameOut = rawName
                if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
                    nameOut = WT_RgbHex(RAID_CLASS_COLORS[class]) .. rawName .. "|r"
                end
                table.insert(lines, nameOut)
            end

            if hasGuild or hasRank then
                local gColor = guildR and WT_RgbHex(guildR, guildG, guildB) or ""
                local rColor = "|cFFAAAAAA"  -- light grey matching OG rank appearance

                local guildLine = ""
                if hasGuild then
                    -- Echo check: Google Translate sometimes returns source text unchanged
                    local guildTranslated = rawGuild and (guildDisplay ~= rawGuild)
                    if guildTranslated then
                        if gColor ~= "" then
                            guildLine = gColor .. "<" .. guildDisplay .. "|r" .. TRANSLATED_NAME_MARK .. gColor .. ">|r"
                        else
                            guildLine = "<" .. guildDisplay .. TRANSLATED_NAME_MARK .. ">"
                        end
                    else
                        -- Translation echoed source (or rawGuild unknown): show without mark
                        if gColor ~= "" then
                            guildLine = gColor .. "<" .. guildDisplay .. ">|r"
                        else
                            guildLine = "<" .. guildDisplay .. ">"
                        end
                    end
                elseif showRawGuild then
                    -- Untranslated guild shown for context beside a translated rank; no *
                    if gColor ~= "" then
                        guildLine = gColor .. "<" .. rawGuild .. ">|r"
                    else
                        guildLine = "<" .. rawGuild .. ">"
                    end
                end
                if hasRank then
                    -- (Name[yellow*]) in rank grey; space only when guild part is present
                    local sep = (guildLine ~= "") and " " or ""
                    guildLine = guildLine .. sep .. rColor .. "(" .. rankDisplay .. "|r" .. TRANSLATED_NAME_MARK .. rColor .. ")|r"
                end
                table.insert(lines, guildLine)
            end
            if table.getn(lines) > 0 then
                WT_InsertTooltipLines(tooltip, lines)
                if tooltip.wtAddedNameLine then WT_ArmTooltipLayoutWatch(tooltip) end
            end
        end)
    end)
end


-- ============================================================================
-- NAMEPLATE PLAYER NAME TRANSLATION
-- ============================================================================

-- Works with ShaguPlates (ShaguTweaks.libnameplate + ShaguPlates.nameplates).
-- Vanilla 3D-engine nameplate names cannot be intercepted; ShaguPlates is required.
-- All behavior is gated on WoWTranslateDB.translateNameplates.

function WT_PlayerNameClassColorEnabled()
    return WoWTranslateDB and WoWTranslateDB.playerNameClassColor
end

function WT_StripTranslatedNameMark(text)
    if not text then return text end
    local plain = WT_StripColorCodes(text)
    if plain then plain = string.gsub(plain, "%*$", "") end
    return plain
end

function WT_StripOverheadDisplaySuffix(text)
    if not text then return text end
    local plain = WT_StripTranslatedNameMark(text)
    local p = string.find(plain, " %(", 1, true)
    if p then plain = string.sub(plain, 1, p - 1) end
    return plain
end

function WT_NormalizeTruncatedNameplateName(text)
    if not text then return text end
    local plain = WT_StripOverheadDisplaySuffix(text)
    if plain and string.sub(plain, -3) == "..." then
        plain = string.sub(plain, 1, -4)
    end
    return plain
end

function WT_OverheadDisplayMatchesRawName(text, rawName)
    if not text or not rawName or text == "" or rawName == "" then return false end
    if text == rawName then return true end
    return WT_StripOverheadDisplaySuffix(text) == rawName
end

-- Class from ShaguTweaks player scan (no unit id probes).
function WT_GetPlayerClassFromName(rawName)
    if not rawName or rawName == "" then return nil end
    if ShaguTweaks and ShaguTweaks.GetUnitData then
        local class = ShaguTweaks.GetUnitData(rawName)
        if class and class ~= "UNKNOWN" and class ~= UNKNOWN then return class end
    end
    return nil
end

-- Same color thresholds as ShaguPlates GetUnitType (reads original.healthbar).
function WT_GetShaguBarUnitType(r, g, b)
    if not r then return "ENEMY_NPC" end
    if r > .9 and g < .2 and b < .2 then return "ENEMY_NPC" end
    if r > .9 and g > .9 and b < .2 then return "NEUTRAL_NPC" end
    if r < .2 and g < .2 and b > .9 then return "FRIENDLY_PLAYER" end
    if r < .2 and g > .9 and b < .2 then return "FRIENDLY_NPC" end
    return "ENEMY_NPC"
end

-- Forward declarations; bodies follow after WT_GetNameplateOverlay.
local GetNameplateFactionRgb
local GetNameplateNameTextRgb
local IsNameplatePlayerForColor

function WT_GetNameplateOverlay(parent)
    if not parent then return nil end
    local overlay = parent.nameplate
    if overlay and overlay.name and overlay.name.GetText and overlay.name.SetText then
        return overlay
    end
end

function WT_GetNameplateHealthbar(parent)
    if not parent then return nil end
    local overlay = WT_GetNameplateOverlay(parent)
    if overlay and overlay.health and overlay.health.Hide then return overlay.health end
    if parent.wtHealthbar then return parent.wtHealthbar end
    if parent.GetChildren then
        local child = parent:GetChildren()
        if child then parent.wtHealthbar = child; return child end
    end
end

-- Hostility tint from the nameplate health bar (ShaguPlates original.healthbar).
GetNameplateFactionRgb = function(plate)
    local overlay = WT_GetNameplateOverlay(plate)
    local bar
    if overlay and overlay.original and overlay.original.healthbar
            and overlay.original.healthbar.GetStatusBarColor then
        bar = overlay.original.healthbar
    else
        bar = WT_GetNameplateHealthbar(plate)
    end
    if not bar or not bar.GetStatusBarColor then return 1, 0, 0 end
    local r, g, b = bar:GetStatusBarColor()
    if not r then return 1, 0, 0 end
    local ut = WT_GetShaguBarUnitType(r, g, b)
    if ut == "NEUTRAL_NPC" then return 1, 1, 0 end
    if ut == "FRIENDLY_NPC" then return 0, 1, 0 end
    return 1, 0, 0
end

-- True when nameplate belongs to a player character (not NPC).
IsNameplatePlayerForColor = function(plate, rawName)
    local overlay = WT_GetNameplateOverlay(plate)
    if not overlay then return false end
    if overlay.cache and overlay.cache.player == "NPC" then return false end
    if overlay.cache and overlay.cache.player == "PLAYER" then return true end
    local bar = overlay.original and overlay.original.healthbar
    if not bar or not bar.GetStatusBarColor then return false end
    local r, g, b = bar:GetStatusBarColor()
    local ut = WT_GetShaguBarUnitType(r, g, b)
    if ut == "FRIENDLY_NPC" or ut == "NEUTRAL_NPC" then return false end
    if ut == "FRIENDLY_PLAYER" then return true end
    if rawName and rawName ~= "" then
        if ShaguPlates_playerDB and ShaguPlates_playerDB[rawName] then return true end
        if WT_GetPlayerClassFromName(rawName) then return true end
    end
    return false
end

-- Class color for players, faction tint for NPCs; nil = let ShaguPlates color stand.
GetNameplateNameTextRgb = function(rawName, plate)
    if not plate or not WT_PlayerNameClassColorEnabled() then return nil end
    if not IsNameplatePlayerForColor(plate, rawName) then
        return GetNameplateFactionRgb(plate)
    end
    local overlay = WT_GetNameplateOverlay(plate)
    if overlay and overlay.original and overlay.original.name
            and overlay.original.name.GetTextColor then
        local br, bg, bb = overlay.original.name:GetTextColor()
        if br and br > .9 and bg and bg < .35 and bb and bb < .35 then
            return br, bg, bb
        end
    end
    local class = WT_GetPlayerClassFromName(rawName)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return c.r, c.g, c.b
    end
    return nil
end

function WT_FormatNameplateOverlayText(rawName, displayName)
    displayName = displayName or rawName
    local isTranslated = rawName and displayName ~= rawName
    local plain = WT_ApplyNameCapitalization(WT_StripColorCodes(isTranslated and displayName or rawName))
    if not isTranslated then return plain end
    return plain .. "*"
end

function WT_ApplyNameplateNameText(fs, formatted, parent, rawName, unit)
    if not fs or not formatted then return end
    local tr, tg, tb, ta = 1, 1, 1, 1
    local colorSet = false
    if WT_PlayerNameClassColorEnabled() and rawName and parent then
        local cr, cg, cb = GetNameplateNameTextRgb(rawName, parent)
        if cr then tr, tg, tb = cr, cg, cb; colorSet = true end
    end
    if not colorSet and parent then
        local overlay = parent.nameplate
        if overlay and overlay.original and overlay.original.name
                and overlay.original.name.GetTextColor then
            tr, tg, tb, ta = overlay.original.name:GetTextColor()
        elseif fs.GetTextColor then
            tr, tg, tb, ta = fs:GetTextColor()
        end
    elseif not colorSet and fs.GetTextColor then
        tr, tg, tb, ta = fs:GetTextColor()
    end
    fs:SetText(formatted)
    if fs.SetTextColor then fs:SetTextColor(tr, tg, tb, ta or 1) end
    if fs.GetStringWidth and fs.SetWidth then
        local w = fs:GetStringWidth()
        if w and w > 0 then fs:SetWidth(w + 8) end
    end
end

local wtNameplateShaguHooked = false
local wtShaguPlatesHooked    = false
local NAMEPLATE_NAME_UPDATE_INTERVAL = 0.2

function WT_NameplateNameUpdateDue(plate)
    if not plate then return true end
    local now = GetTime()
    if plate.wtNextNameUpdate and now < plate.wtNextNameUpdate then return false end
    plate.wtNextNameUpdate = now + NAMEPLATE_NAME_UPDATE_INTERVAL
    return true
end

function WT_GetNameplateDisplayNameFont(parent)
    local overlay = WT_GetNameplateOverlay(parent)
    if overlay then return overlay.name end
    return nil
end

function WT_ResolveNameplateRawName(plate)
    if not plate then return nil end
    local overlay = WT_GetNameplateOverlay(plate)
    if not overlay then return plate.wtRawName end
    if overlay.cache and overlay.cache.name and overlay.cache.name ~= "" then
        return WT_NormalizeTruncatedNameplateName(overlay.cache.name)
    end
    if overlay.original and overlay.original.name and overlay.original.name.GetText then
        local t = overlay.original.name:GetText()
        if t and t ~= "" then
            return WT_NormalizeTruncatedNameplateName(WT_StripOverheadDisplaySuffix(t))
        end
    end
    return nil
end

function WT_UpdateNameplateFromPlate(plate)
    if not plate then return end
    if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
    if not WoWTranslateDB.translateNameplates then return end
    if WoWTranslateDB.disableWhileAfk and WT_playerIsAFK then return end

    local overlay = WT_GetNameplateOverlay(plate)
    if not overlay then return end

    local rawName = WT_ResolveNameplateRawName(plate)
    if not rawName or rawName == "" then return end
    plate.wtRawName = rawName

    if WT_ShouldTranslatePlayerName(rawName) then
        local fs = overlay.name
        if fs and fs.GetText then
            if plate.wtLastDisplay then
                local cur = fs:GetText()
                if cur then
                    local plain = WT_NormalizeTruncatedNameplateName(cur)
                    if plain == rawName or WT_OverheadDisplayMatchesRawName(cur, rawName) then
                        plate.wtLastDisplay = nil
                    end
                end
            end
            local current = fs:GetText() or ""
            if not (plate.wtLastDisplay and current == plate.wtLastDisplay) then
                local cached, found = WoWTranslate_CacheGet(WT_NameCacheKey(rawName))
                local function applyNameDisplay(displayName)
                    if plate.wtRawName ~= rawName then return end
                    local formatted = WT_FormatNameplateOverlayText(rawName, displayName)
                    if plate.wtLastDisplay ~= formatted then
                        WT_ApplyNameplateNameText(fs, formatted, plate, rawName, nil)
                        plate.wtLastDisplay = formatted
                        if overlay.name and overlay.name.Show then overlay.name:Show() end
                    end
                end
                if found then
                    applyNameDisplay(cached)
                elseif not plate.wtResolvePending then
                    plate.wtResolvePending = true
                    WT_ResolvePlayerDisplayName(rawName, function(displayName)
                        plate.wtResolvePending = nil
                        if plate.wtRawName ~= rawName then return end
                        if displayName then applyNameDisplay(displayName) end
                    end)
                end
            end
        end
    end
end

function WT_ResetNameplatePlateState(plate)
    if not plate then return end
    plate.wtRawName             = nil
    plate.wtLastDisplay         = nil
    plate.wtResolvePending      = nil
    plate.wtNextNameUpdate      = nil
    plate.wtLastGuildDisplay    = nil
    plate.wtGuildResolvePending = nil
    plate.wtPendingRawGuild     = nil
    plate.wtOOCClutterHidden    = nil
    plate.wtClutterFrames       = nil
    plate.wtNameDetachedForOOC  = nil
    if plate.wtGuildLine and plate.wtGuildLine.Hide then plate.wtGuildLine:Hide() end
end


-- ============================================================================
-- OOC HEALTHBAR HIDE + GUILD DISPLAY (ShaguPlates only)
-- ============================================================================


-- In WoW 1.12.1 vanilla, nameplates lack unique unit IDs (e.g. nameplate1).
-- This checks whether the player character is currently affecting combat.
function WT_IsNameplateUnitInCombat(plate)
    if not UnitAffectingCombat then return true end
    local ok, c = pcall(UnitAffectingCombat, "player")
    return ok and c
end

-- ShaguPlates parents overlay.name under overlay.health; detach so the name
-- remains visible when the health bar is hidden out of combat.
function WT_EnsureOverlayNameDetached(parent)
    local overlay = WT_GetNameplateOverlay(parent)
    if not overlay or not overlay.name then return end
    if not WoWTranslateDB or not WoWTranslateDB.nameplateHideHealthOOC then
        parent.wtNameDetachedForOOC = nil; return
    end
    if WT_IsNameplateUnitInCombat(parent) then
        parent.wtNameDetachedForOOC = nil; return
    end
    if overlay.name:GetParent() ~= overlay then
        overlay.name:SetParent(overlay)
    end
    overlay.name:ClearAllPoints()
    overlay.name:SetPoint("TOP", overlay, "TOP", 0, 0)
    overlay.name:Show()
    parent.wtNameDetachedForOOC = true
end

-- Health bar, its backdrop, and level text — hidden together out of combat.
function WT_CollectNameplateClutterFrames(parent)
    local frames = {}
    local function add(f)
        if f and f.Hide and f.Show then table.insert(frames, f) end
    end
    local overlay = WT_GetNameplateOverlay(parent)
    if overlay then
        local bar = overlay.health
        add(bar)
        if bar and bar.backdrop then add(bar.backdrop) end
        if overlay.level and overlay.level.Hide then add(overlay.level) end
    end
    return frames
end

function WT_SetNameplateClutterVisible(plate, visible)
    local frames = plate.wtClutterFrames
    for i = 1, table.getn(frames) do
        if visible then frames[i]:Show() else frames[i]:Hide() end
    end
    plate.wtOOCClutterHidden = not visible or nil
end


-- ============================================================================
-- OOC GUILD DISPLAY (ShaguPlates only)
-- ============================================================================


local wtNameplateGuildByPlayer = {}
local WT_GUILD_MAP_CAP = 500

local function GuildMapInsert(rawName, guild)
    -- Simple size cap: clear the whole map when it grows unbounded over a
    -- long session (entries are cheap to re-resolve).
    local n = 0
    for _ in pairs(wtNameplateGuildByPlayer) do n = n + 1 end
    if n >= WT_GUILD_MAP_CAP then
        wtNameplateGuildByPlayer = {}
    end
    wtNameplateGuildByPlayer[rawName] = guild
end

function WT_LookupRawGuildForNameplate(rawName)
    if not rawName or rawName == "" then return nil end
    if wtNameplateGuildByPlayer[rawName] then return wtNameplateGuildByPlayer[rawName] end
    if ShaguPlates_playerDB and ShaguPlates_playerDB[rawName] then
        local g = ShaguPlates_playerDB[rawName].guild
        if g and g ~= "" then GuildMapInsert(rawName, g); return g end
    end
    local unit = WT_FindPlayerUnitByName(rawName)
    if unit and GetGuildInfo then
        local ok, guild = pcall(GetGuildInfo, unit)
        if ok and guild and guild ~= "" then
            GuildMapInsert(rawName, guild); return guild
        end
    end
    return nil
end

function WT_FormatNameplateGuildLine(rawGuild, displayGuild)
    displayGuild = displayGuild or rawGuild
    if not displayGuild or displayGuild == "" then return nil end
    local plain = WT_StripColorCodes(displayGuild) or displayGuild
    local line = "<" .. plain .. ">"
    if rawGuild and displayGuild ~= rawGuild then line = line .. "*" end
    return line
end

function WT_EnsureNameplateGuildFont(plate, nameFs)
    if plate.wtGuildLine and plate.wtGuildLine.SetText then return plate.wtGuildLine end
    local overlay = WT_GetNameplateOverlay(plate)
    local parent = overlay or plate
    local anchor = (overlay and overlay.name and overlay.name.GetText and overlay.name) or nameFs
    if not anchor then return nil end
    local fs = parent:CreateFontString(nil, "OVERLAY")
    if anchor.GetFont and fs.SetFont then
        local font, size, flags = anchor:GetFont()
        local small = (size and size > 8) and (size - 2) or 10
        if font then fs:SetFont(font, small, flags) end
    end
    fs:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    plate.wtGuildLine = fs
    return fs
end

function WT_HideNameplateGuildLine(plate)
    if not plate then return end
    if plate.wtGuildLine and plate.wtGuildLine.Hide then plate.wtGuildLine:Hide() end
    plate.wtLastGuildDisplay    = nil
    plate.wtGuildResolvePending = nil
    plate.wtPendingRawGuild     = nil
end

function WT_UpdateNameplateGuildOOC(plate)
    if not plate then return end
    if not WoWTranslateDB or not WoWTranslateDB.enabled or not WoWTranslateDB.nameplateGuildOOC then
        WT_HideNameplateGuildLine(plate); return
    end
    if WoWTranslateDB.disableWhileAfk and WT_playerIsAFK then
        WT_HideNameplateGuildLine(plate); return
    end
    if WT_IsNameplateUnitInCombat(plate) then
        WT_HideNameplateGuildLine(plate); return
    end

    local rawName = plate.wtRawName
    if not rawName or rawName == "" then WT_HideNameplateGuildLine(plate); return end
    if not IsNameplatePlayerForColor(plate, rawName) then
        WT_HideNameplateGuildLine(plate); return
    end

    local nameFs = WT_GetNameplateDisplayNameFont(plate)
    if not nameFs then return end

    WT_EnsureOverlayNameDetached(plate)

    local guildFs = WT_EnsureNameplateGuildFont(plate, nameFs)
    if not guildFs then return end

    local overlay = WT_GetNameplateOverlay(plate)
    local guildAnchor = (overlay and overlay.name) or nameFs
    guildFs:ClearAllPoints()
    guildFs:SetPoint("TOP", guildAnchor, "BOTTOM", 0, -2)

    local rawGuild = WT_LookupRawGuildForNameplate(rawName)
    if not rawGuild or rawGuild == "" then WT_HideNameplateGuildLine(plate); return end
    plate.wtPendingRawGuild = rawGuild

    local function showLine(displayGuild)
        if (plate.wtRawName or "") ~= rawName then return end
        local line = WT_FormatNameplateGuildLine(rawGuild, displayGuild)
        if not line then WT_HideNameplateGuildLine(plate); return end
        if plate.wtLastGuildDisplay == line then
            if guildFs.IsShown then
                local s = guildFs:IsShown()
                if s == 1 or s == true then return end
            end
        end
        plate.wtLastGuildDisplay = line
        guildFs:SetText(line)
        guildFs:Show()
    end

    if WoWTranslateDB.translateGuildNames and WoWTranslate_ResolveGuildDisplayName then
        local cacheKey = WT_NameCacheKey("guild:" .. rawGuild)
        local cached, found = WoWTranslate_CacheGet(cacheKey)
        if found then showLine(cached); return end
        if plate.wtGuildResolvePending == rawName then
            if plate.wtLastGuildDisplay then
                guildFs:SetText(plate.wtLastGuildDisplay); guildFs:Show()
            end
            return
        end
        plate.wtGuildResolvePending = rawName
        WoWTranslate_ResolveGuildDisplayName(rawGuild, function(displayGuild)
            plate.wtGuildResolvePending = nil
            showLine(displayGuild)
        end)
        return
    end

    showLine(rawGuild)
end

function WT_UpdateNameplateHealthbarVisibility(plate)
    if not plate then return end
    WT_EnsureOverlayNameDetached(plate)
    if not plate.wtClutterFrames or table.getn(plate.wtClutterFrames) == 0 then
        plate.wtClutterFrames = WT_CollectNameplateClutterFrames(plate)
    end
    if table.getn(plate.wtClutterFrames) > 0 then
        if not WoWTranslateDB or not WoWTranslateDB.nameplateHideHealthOOC then
            if plate.wtOOCClutterHidden then WT_SetNameplateClutterVisible(plate, true) end
        elseif WT_IsNameplateUnitInCombat(plate) then
            if plate.wtOOCClutterHidden then WT_SetNameplateClutterVisible(plate, true) end
        else
            WT_SetNameplateClutterVisible(plate, false)
        end
    end
    WT_UpdateNameplateGuildOOC(plate)
end

-- ============================================================================

function WoWTranslate_OnNameplateUpdate(plate)
    plate = plate or this
    if not plate then return end
    if not WT_GetNameplateOverlay(plate) then return end
    if not WT_NameplateNameUpdateDue(plate) then return end
    WT_UpdateNameplateFromPlate(plate)
    WT_UpdateNameplateHealthbarVisibility(plate)
end

function WoWTranslate_OnNameplateShow(plate)
    plate = plate or this
    if not plate then return end
    WT_ResetNameplatePlateState(plate)
end

function WT_HookShaguNameplates()
    local lib = ShaguTweaks and ShaguTweaks.libnameplate
    if not lib then return false end
    if not lib.wtWoWTranslateHooked then
        table.insert(lib.OnUpdate, function(plate)
            WoWTranslate_OnNameplateUpdate(plate)
        end)
        table.insert(lib.OnShow, function(plate)
            WoWTranslate_OnNameplateShow(plate)
        end)
        lib.wtWoWTranslateHooked = true
    end
    wtNameplateShaguHooked = true
    return true
end

function WT_HookShaguPlatesNameplates()
    if not ShaguPlates or not ShaguPlates.nameplates then return false end
    local np = ShaguPlates.nameplates
    if np.wtWoWTranslateWrapped then
        wtShaguPlatesHooked = true
        return true
    end
    local base = np.wtWoWTranslateBase or np.OnDataChanged
    if not base then return false end
    if not np.wtWoWTranslateBase then np.wtWoWTranslateBase = base end
    np.OnDataChanged = function(self, overlay)
        np.wtWoWTranslateBase(self, overlay)
        local parent = overlay and overlay.parent
        if not parent then return end
        if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
        if not WoWTranslateDB.translateNameplates then return end
        if WoWTranslateDB.disableWhileAfk and WT_playerIsAFK then return end
        parent.wtNextNameUpdate = nil
        WT_UpdateNameplateFromPlate(parent)
        WT_UpdateNameplateHealthbarVisibility(parent)
    end
    np.wtWoWTranslateWrapped = true
    wtShaguPlatesHooked = true
    return true
end

function WT_HookNameplates()
    if not WoWTranslateDB or not WoWTranslateDB.translateNameplates then return end
    WT_HookShaguNameplates()
    WT_HookShaguPlatesNameplates()
end
-- Forward reference: allows WoWTranslate_SetTranslateNameplates to hook ShaguPlates
-- when the feature is toggled on mid-session.
WT_wtNameplateScanStart = WT_HookNameplates


-- ============================================================================
-- PLAYER NAME TRANSLATION (Shift+RightClick on a chat name hyperlink)
-- ============================================================================

-- Wraps ChatFrame_OnHyperlinkShow.  When the user Shift+RightClicks a player
-- link we translate the name and print "[WT]: Name = Translation".
-- If Translate() can't queue (rate limited / DLL busy) we fall through so the
-- normal right-click context menu still opens — no silent failures.
-- M5 fix: save the original on a stable field so we can unhook later
-- (WT_UnhookHyperlinkShow) without losing other addons' wrappers.
function WT_HookHyperlinkShow()
    if not ChatFrame_OnHyperlinkShow then return end
    if ChatFrame_OnHyperlinkShow_WTOriginal then return end
    ChatFrame_OnHyperlinkShow_WTOriginal = ChatFrame_OnHyperlinkShow
    local origHyperlink = ChatFrame_OnHyperlinkShow_WTOriginal

    ChatFrame_OnHyperlinkShow = function(link, text, button)
        local capturedFrame = this
        if button == "RightButton" and IsShiftKeyDown() then
            -- link format is "player:CharacterName"
            local _, _, playerName = string.find(link, "^player:(.+)")
            if playerName and playerName ~= ""
               and WoWTranslate_API and WoWTranslate_API.IsAvailable() then
                local sent = WoWTranslate_API.Translate(playerName,
                    function(translation, err)
                        local frame = capturedFrame or DEFAULT_CHAT_FRAME
                        if translation and translation ~= "" and translation ~= playerName then
                            frame:AddMessage("|cFF00CCFF[WT]|r: " .. playerName .. " = " .. translation)
                        elseif err then
                            frame:AddMessage("|cFFFFFF00[WT]: name lookup failed: " .. tostring(err) .. "|r")
                        end
                    end, "auto")
                if sent then return end
                -- Translate() returned false: rate limited or queue full — fall through
            end
        end
        origHyperlink(link, text, button)
    end
end

-- M5 fix: restore the original ChatFrame_OnHyperlinkShow.  Useful if the
-- user wants to disable the Shift+RightClick lookup, and prevents our
-- wrapper from holding a stale reference to the original if another addon
-- updates ChatFrame_OnHyperlinkShow later.
function WT_UnhookHyperlinkShow()
    if not ChatFrame_OnHyperlinkShow_WTOriginal then return end
    if ChatFrame_OnHyperlinkShow then
        ChatFrame_OnHyperlinkShow = ChatFrame_OnHyperlinkShow_WTOriginal
    end
    ChatFrame_OnHyperlinkShow_WTOriginal = nil
end

function WT_OnPlayerLogin()
    WT_HookChatFrames()
    WT_HookHyperlinkShow()
    WT_HookTooltips()

    if not WoWTranslate_API.IsAvailable() then
        WoWTranslate_API.CheckDLL()
    end

    -- Install outgoing hook if enabled
    if WoWTranslateDB and WoWTranslateDB.outgoingEnabled then
        WT_InstallOutgoingHook()
    end

    -- Install LFT hook if enabled (LFT loads before WoWTranslate alphabetically)
    if WoWTranslateDB and WoWTranslateDB.translateGroupFinder then
        WT_HookLFT()
    end
end

