-- WoWTranslate_Hyperlink.lua

-- ============================================================================
-- HYPERLINK LOCALIZATION
-- ============================================================================

-- Parse hyperlinks and replace Chinese display names with English equivalents
-- using the client's GetItemInfo() API

-- Queue for messages waiting on item cache
WT_itemCacheQueue = {}
WT_itemCacheCounter = 0

-- Hidden tooltip for forcing item cache population
WT_itemCacheTooltip = CreateFrame("GameTooltip", "WoWTranslateItemCacheTooltip", nil, "GameTooltipTemplate")
WT_itemCacheTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- Force item data to be requested from server using SetHyperlink
-- This is more reliable than just calling GetItemInfo()
function WT_TriggerItemCache(itemId)
    local itemString = "item:" .. itemId .. ":0:0:0"
    WT_itemCacheTooltip:SetHyperlink(itemString)
    WT_DebugLog("Triggered cache for item:", itemId)
end

-- Extract all item IDs from a text string
function WT_ExtractItemIds(text)
    local itemIds = {}
    local pos = 1

    while pos <= string.len(text) do
        -- Look for item links: |Hitem:ITEMID:
        local linkStart = string.find(text, "|Hitem:", pos, true)
        if not linkStart then
            break
        end

        -- Find the item ID (numbers after "item:")
        local idStart = linkStart + 7  -- length of "|Hitem:"
        local idEnd = string.find(text, ":", idStart, true)
        if idEnd then
            local itemIdStr = string.sub(text, idStart, idEnd - 1)
            local itemId = tonumber(itemIdStr)
            WT_DebugLog("Extracted item ID:", itemIdStr, "->", itemId or "INVALID")
            if itemId then
                table.insert(itemIds, itemId)
            end
        end

        pos = linkStart + 1
    end

    WT_DebugLog("Total item IDs extracted:", table.getn(itemIds))
    return itemIds
end

-- Check if all item IDs are cached, trigger cache for uncached ones
-- Returns: allCached (boolean), uncachedIds (table)
function WT_CheckItemCache(itemIds, triggerCache)
    local uncachedIds = {}

    for _, itemId in ipairs(itemIds) do
        local name, link = GetItemInfo(itemId)
        if not name then
            table.insert(uncachedIds, itemId)
            -- Use SetHyperlink to force server to send item data
            if triggerCache then
                WT_TriggerItemCache(itemId)
            end
        end
    end

    return table.getn(uncachedIds) == 0, uncachedIds
end

-- Parse a hyperlink to extract its components
-- Returns: linkType, linkData, displayText, colorCode (or nils if parse fails)
function WT_ParseHyperlink(link)
    local colorCode = nil
    local linkType = nil
    local linkData = nil
    local displayText = nil

    -- Check for colored link: |cFFRRGGBB|H...
    -- M7 fix: use the start position returned by string.find instead of
    -- hardcoding 3/10 — that broke if the link had leading whitespace.
    local colorStart, colorEnd = string.find(link, "^|c%x%x%x%x%x%x%x%x")
    if colorStart then
        -- Extract the 8 hex chars (FFRRGGBB) that follow the |c prefix.
        colorCode = string.sub(link, colorStart + 2, colorEnd)
    end

    -- Find |H to start of link data
    local hStart, hEnd = string.find(link, "|H")
    if not hStart then return nil end

    -- Find |h[ to find end of link data and start of display text
    local displayStart, displayStartEnd = string.find(link, "|h%[", hEnd)
    if not displayStart then return nil end

    -- Extract type:data between |H and |h[
    local typeData = string.sub(link, hEnd + 1, displayStart - 1)

    -- Split type:data by first colon
    local colonPos = string.find(typeData, ":")
    if colonPos then
        linkType = string.sub(typeData, 1, colonPos - 1)
        linkData = string.sub(typeData, colonPos + 1)
    else
        linkType = typeData
        linkData = ""
    end

    -- Find ]|h to get display text
    local displayEnd = string.find(link, "%]|h", displayStartEnd)
    if not displayEnd then return nil end

    displayText = string.sub(link, displayStartEnd + 1, displayEnd - 1)

    return linkType, linkData, displayText, colorCode
end

-- M8 fix: WT_GetItemIdFromLinkData and WT_GetQuestIdFromLinkData were
-- identical copies of the same "first colon field" logic.  Collapse them
-- into one helper and keep the two public wrappers for backward compat.
local function WT_GetFirstColonField(linkData)
    if not linkData or linkData == "" then return nil end
    local colonPos = string.find(linkData, ":")
    if colonPos then
        return tonumber(string.sub(linkData, 1, colonPos - 1))
    else
        return tonumber(linkData)
    end
end

-- Extract item ID from link data (format: itemId:enchantId:suffixId:uniqueId)
function WT_GetItemIdFromLinkData(linkData)
    return WT_GetFirstColonField(linkData)
end

-- Extract quest ID from link data (format: questId:questLevel)
function WT_GetQuestIdFromLinkData(linkData)
    return WT_GetFirstColonField(linkData)
end

-- Get English quest name from pfQuest database
-- Returns nil if pfQuest not loaded or quest not found
function WT_GetEnglishQuestName(questId)
    if not pfDB or not pfDB["quests"] then
        return nil  -- pfQuest not loaded
    end

    -- Try custom quests first (more specific)
    local customQuests = pfDB["quests"]["enUS-turtle"]
    if customQuests and customQuests[questId] then
        local entry = customQuests[questId]
        if type(entry) == "table" and entry["T"] then
            return entry["T"]
        end
        -- "_" means deleted, fall through to vanilla
    end

    -- Try vanilla quests
    local vanillaQuests = pfDB["quests"]["enUS"]
    if vanillaQuests and vanillaQuests[questId] then
        local entry = vanillaQuests[questId]
        if type(entry) == "table" and entry["T"] then
            return entry["T"]
        end
    end

    return nil  -- Quest not in database
end

-- Localize a hyperlink by replacing the display text with the English name
-- Currently supports: items (via GetItemInfo)
-- Falls back to original if localization not available
function WT_LocalizeHyperlink(link)
    WT_DebugLog("WT_LocalizeHyperlink called:", string.sub(link, 1, 40))

    local linkType, linkData, displayText, colorCode = WT_ParseHyperlink(link)

    if not linkType then
        WT_DebugLog("  Parse failed, returning original")
        return link  -- Couldn't parse, return original
    end

    WT_DebugLog("  Parsed:", linkType, linkData and string.sub(linkData, 1, 20) or "nil")

    if linkType == "item" then
        local itemId = WT_GetItemIdFromLinkData(linkData)
        WT_DebugLog("  Item ID:", itemId)
        if itemId then
            -- GetItemInfo returns: name, link, quality, iLevel, ...
            local itemName, itemLink = GetItemInfo(itemId)
            WT_DebugLog("  GetItemInfo returned:", itemName or "nil")

            if itemName then
                -- Always rebuild the link manually to ensure correct structure
                -- Use original color code from the Chinese link, just replace the name
                local result
                if colorCode then
                    result = "|c" .. colorCode .. "|H" .. linkType .. ":" .. linkData .. "|h[" .. itemName .. "]|h|r"
                else
                    result = "|H" .. linkType .. ":" .. linkData .. "|h[" .. itemName .. "]|h"
                end
                WT_DebugLog("  Rebuilt link with English name")
                return result
            else
                -- Item not in client cache yet; trigger a server request so next
                -- occurrence of this item link will resolve to the English name.
                WT_TriggerItemCache(itemId)
            end
        end
    elseif linkType == "quest" then
        local questId = WT_GetQuestIdFromLinkData(linkData)
        WT_DebugLog("  Quest ID:", questId)
        if questId then
            local questName = WT_GetEnglishQuestName(questId)
            WT_DebugLog("  WT_GetEnglishQuestName returned:", questName or "nil")

            if questName then
                local result
                if colorCode then
                    result = "|c" .. colorCode .. "|H" .. linkType .. ":" .. linkData .. "|h[" .. questName .. "]|h|r"
                else
                    result = "|H" .. linkType .. ":" .. linkData .. "|h[" .. questName .. "]|h"
                end
                WT_DebugLog("  Rebuilt quest link with English name")
                return result
            end
        end
    else
        WT_DebugLog("  Not an item or quest link, skipping localization")
    end
    -- Quest localization uses pfQuest database (if available)
    -- Spell localization not supported in vanilla WoW 1.12 (no GetSpellInfo API)

    WT_DebugLog("  No localized name, returning original")
    return link  -- No localized name found, return original
end


-- ============================================================================
-- ROBUST HYPERLINK EXTRACTION
-- ============================================================================

-- WoW 1.12 hyperlink format: |cFFRRGGBB|Htype:data|h[DisplayText]|h|r
-- Key: Extract FULL hyperlinks including color codes as single units

-- Find all hyperlinks in text, returning their positions and content
function WT_FindAllHyperlinks(text)
    local hyperlinks = {}
    local pos = 1

    while pos <= string.len(text) do
        -- Look for hyperlink start - either |c (colored) or |H (plain)
        local colorStart = string.find(text, "|c%x%x%x%x%x%x%x%x|H", pos)
        local plainStart = string.find(text, "|H", pos)

        local linkStart = nil
        local hasColor = false

        -- Determine which comes first
        if colorStart and (not plainStart or colorStart <= plainStart) then
            linkStart = colorStart
            hasColor = true
        elseif plainStart then
            -- Make sure this |H isn't part of a colored link we already found
            if not colorStart or plainStart < colorStart then
                linkStart = plainStart
                hasColor = false
            end
        end

        if not linkStart then
            break
        end

        -- Find the end of the hyperlink: |h[...]|h followed by optional |r
        -- Pattern: find |h[ then find ]|h
        local displayStart = string.find(text, "|h%[", linkStart)
        if not displayStart then
            pos = linkStart + 1
        else
            -- Find closing ]|h
            local displayEnd = string.find(text, "%]|h", displayStart)
            if not displayEnd then
                pos = linkStart + 1
            else
                local linkEnd = displayEnd + 2  -- Position after ]|h

                -- Check for |r after the link
                if string.sub(text, linkEnd + 1, linkEnd + 2) == "|r" then
                    linkEnd = linkEnd + 2
                end

                -- If we have color, make sure we started from |c
                local actualStart = linkStart
                if hasColor then
                    actualStart = colorStart
                end

                local fullLink = string.sub(text, actualStart, linkEnd)

                WT_DebugLog("Found hyperlink:", string.sub(fullLink, 1, 80))

                table.insert(hyperlinks, {
                    startPos = actualStart,
                    endPos = linkEnd,
                    content = fullLink
                })

                pos = linkEnd + 1
            end
        end
    end

    return hyperlinks
end

-- Split message into segments: text and hyperlinks
-- Returns array of {type="text"|"link", content=string}
function WT_SplitIntoSegments(text)
    local segments = {}
    local hyperlinks = WT_FindAllHyperlinks(text)

    if table.getn(hyperlinks) == 0 then
        -- No hyperlinks, entire text is translatable
        if text ~= "" then
            table.insert(segments, {type = "text", content = text})
        end
        return segments
    end

    local lastEnd = 0
    for _, link in ipairs(hyperlinks) do
        -- Add text before this hyperlink
        if link.startPos > lastEnd + 1 then
            local textBefore = string.sub(text, lastEnd + 1, link.startPos - 1)
            if textBefore ~= "" then
                table.insert(segments, {type = "text", content = textBefore})
            end
        end

        -- Add the hyperlink (with localized display name if available)
        table.insert(segments, {type = "link", content = WT_LocalizeHyperlink(link.content)})
        lastEnd = link.endPos
    end

    -- Add text after last hyperlink
    if lastEnd < string.len(text) then
        local textAfter = string.sub(text, lastEnd + 1)
        if textAfter ~= "" then
            table.insert(segments, {type = "text", content = textAfter})
        end
    end

    return segments
end

-- Check if any text segments contain source language characters
function WT_HasTranslatableContent(segments)
    for _, seg in ipairs(segments) do
        if seg.type == "text" and WT_DetectSourceLanguage(seg.content) then
            return true
        end
    end
    return false
end

-- Strip WoW color codes from text before sending to translation API.
-- |cFFRRGGBB...text...|r sequences are not valid UTF-8 markup and confuse Google.
-- The pipe character in translations would also break the requestId|result|error wire format.
function WT_StripColorCodes(text)
    if not text then return text end
    -- WoW color codes are always |c followed by exactly 8 hex characters.
    local result = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    result = string.gsub(result, "|r", "")
    return result
end

-- Split a fully-formatted chat line into header and message body.
-- The header is everything up to and including the first ": " separator
-- (e.g. "|cFF...[PlayerName]|r says: ").  The body is what follows.
-- If no separator is found the header is empty and body is the full text.
function WT_SplitHeaderAndMessage(text)
    local pos1 = string.find(text, ": ", 1, true)
    local pos2 = string.find(text, "\239\188\154", 1, true) -- UTF-8 fullwidth colon
    local pos3 = string.find(text, "\163\186", 1, true)     -- GBK colon

    local bestPos = nil
    local bestLen = 0
    if pos1 then bestPos = pos1; bestLen = 2 end
    if pos2 and (not bestPos or pos2 < bestPos) then bestPos = pos2; bestLen = 3 end
    if pos3 and (not bestPos or pos3 < bestPos) then bestPos = pos3; bestLen = 2 end

    if not bestPos then
        return "", text
    end

    local header = string.sub(text, 1, bestPos + bestLen - 1)
    local msg    = string.sub(text, bestPos + bestLen)
    return header, msg
end

-- Build text to translate: only text segments, hyperlinks become URL placeholders
-- URLs are preserved by Google Translate because they're recognized as web addresses
function WT_BuildTranslatableText(segments)
    local parts = {}
    local linkIndex = 0

    for _, seg in ipairs(segments) do
        if seg.type == "text" then
            table.insert(parts, WT_StripColorCodes(seg.content))
        else
            linkIndex = linkIndex + 1
            -- Space-pad the placeholder so Google never merges it with adjacent CJK bytes.
            -- Without spaces, "来人http://ph.wt/1" is treated as one URL and the Chinese
            -- is left untranslated.  The spaces are benign — WT_ReconstructMessage uses a
            -- substring search so it finds "http://ph.wt/N" inside " http://ph.wt/N ".
            table.insert(parts, " http://ph.wt/" .. linkIndex .. " ")
        end
    end

    return table.concat(parts, "")
end

-- Reconstruct message from translated text and original segments
function WT_ReconstructMessage(segments, translatedText)
    local result = {}
    local workText = translatedText

    -- Count links
    local linkCount = 0
    local linkContents = {}
    for _, seg in ipairs(segments) do
        if seg.type == "link" then
            linkCount = linkCount + 1
            linkContents[linkCount] = seg.content
        end
    end

    if linkCount == 0 then
        return translatedText
    end

    -- Replace each URL placeholder with the original hyperlink
    for i = 1, linkCount do
        local found = false

        WT_DebugLog("Link", i, "content:", string.sub(linkContents[i] or "nil", 1, 80))

        -- Match variations of http://ph.wt/N produced by Google Translate's spacing/punctuation mangling.
        -- We use a Lua pattern to handle inserted spaces, commas, optional 's', etc.
        local pattern = "http[s]*[:]*[%s]*//[%s]*ph[%s%,%.]*wt[%s/]*" .. tostring(i)
        
        local startPos, endPos = string.find(workText, pattern)
        if startPos then
            workText = string.sub(workText, 1, startPos - 1) .. linkContents[i] .. string.sub(workText, endPos + 1)
            found = true
            WT_DebugLog("Replaced placeholder for link:", i)
        end

        if not found then
            WT_DebugLog("Placeholder not found for link:", i)
            -- Append the link at the end as fallback
            workText = workText .. " " .. linkContents[i]
        end
    end

    return workText
end


-- ============================================================================
-- ITEM CACHE POLLING
-- ============================================================================

-- Process messages waiting for item cache data

function WT_ProcessItemCacheMessage(queued)
    local text = queued.text
    local detectedLang = WT_DetectSourceLanguage(text) or "zh"

    -- Split header from body (same approach as the main hook)
    local headerText, msgBody = WT_SplitHeaderAndMessage(text)

    -- Segment only the message body
    local segments = WT_SplitIntoSegments(msgBody)

    -- Apply incoming preprocessing and glossary to segments individually
    WT_ProcessSegmentsIncoming(segments, detectedLang)

    WT_DebugLog("Processing cached item message, segments:", table.getn(segments))

    if not WT_HasTranslatableContent(segments) then
        -- Body has no translatable content; show with localized hyperlinks
        local result = headerText
        for _, seg in ipairs(segments) do
            result = result .. seg.content
        end
        queued.WT_originalAddMessage(queued.frame, result, queued.r, queued.g, queued.b, queued.id, queued.holdTime)
        return
    end

    local textToTranslate = WT_BuildTranslatableText(segments)

    local cached, found = WoWTranslate_CacheGet(msgBody)
    if found then
        WT_DebugLog("Cache hit for item message")
        local finalText = headerText .. WT_ReconstructMessage(segments, cached)
        queued.WT_originalAddMessage(queued.frame, finalText, queued.r, queued.g, queued.b, queued.id, queued.holdTime)
        return
    end

    if WoWTranslate_API and WoWTranslate_API.IsAvailable() then
        WT_DebugLog("Requesting translation for item message")
        WT_messageCounter = WT_messageCounter + 1
        local msgId = tostring(WT_messageCounter)
        WT_pendingMessages[msgId] = {
            frame = queued.frame,
            WT_originalAddMessage = queued.WT_originalAddMessage,
            originalText = text,
            headerText = headerText,
            msgBody = msgBody,
            segments = segments,
            r = queued.r, g = queued.g, b = queued.b,
            id = queued.id, holdTime = queued.holdTime,
            timestamp = GetTime()
        }
        WoWTranslate_API.Translate(textToTranslate, function(translation, err)
            local pending = WT_pendingMessages[msgId]
            if pending then
                WT_pendingMessages[msgId] = nil
                if translation and translation ~= "" then
                    WT_DebugLog("API returned for item msg:", string.sub(translation, 1, 50))
                    local finalText = pending.headerText .. WT_ReconstructMessage(pending.segments, translation)
                    WoWTranslate_CacheSave(pending.msgBody, translation)
                    pcall(pending.WT_originalAddMessage, pending.frame, finalText, pending.r, pending.g, pending.b, pending.id, pending.holdTime)
                else
                    WT_DebugLog("API error for item msg:", tostring(err))
                    pcall(pending.WT_originalAddMessage, pending.frame, pending.originalText, pending.r, pending.g, pending.b, pending.id, pending.holdTime)
                end
            end
        end, detectedLang)
    else
        local result = headerText
        for _, seg in ipairs(segments) do result = result .. seg.content end
        queued.WT_originalAddMessage(queued.frame, result, queued.r, queued.g, queued.b, queued.id, queued.holdTime)
    end
end

local itemCacheFrame = CreateFrame("Frame")
local itemCacheElapsed = 0
local ITEM_CACHE_POLL_INTERVAL = 0.05  -- Poll every 50ms
local ITEM_CACHE_MAX_WAIT = 3.0        -- Max wait 3 seconds
local ITEM_CACHE_RETRY_INTERVAL = 0.5  -- Retry triggering cache every 500ms

itemCacheFrame:SetScript("OnUpdate", function()
    itemCacheElapsed = itemCacheElapsed + arg1
    if itemCacheElapsed < ITEM_CACHE_POLL_INTERVAL then
        return
    end
    itemCacheElapsed = 0

    -- H2 fix: pcall the body so a throw inside WT_ProcessItemCacheMessage
    -- (or WT_CheckItemCache) doesn't kill this OnUpdate permanently.  An
    -- unhandled throw would leave the entry in the queue forever and the
    -- message would never be shown to the user.
    for cacheId, queued in pairs(WT_itemCacheQueue) do
        local ok, err = pcall(function()
            local allCached = WT_CheckItemCache(queued.itemIds, false)  -- Just check, don't trigger
            local elapsed = GetTime() - queued.timestamp

            if allCached then
                WT_DebugLog("Items cached, processing message:", cacheId)
                WT_itemCacheQueue[cacheId] = nil
                WT_ProcessItemCacheMessage(queued)
            elseif elapsed > ITEM_CACHE_MAX_WAIT then
                -- Timeout - process anyway with whatever we have
                local _, stillUncached = WT_CheckItemCache(queued.itemIds, false)
                WT_DebugLog("Item cache timeout after", elapsed, "sec, uncached:", table.getn(stillUncached))
                for _, uid in ipairs(stillUncached) do
                    WT_DebugLog("  Still uncached item ID:", uid)
                end
                WT_itemCacheQueue[cacheId] = nil
                WT_ProcessItemCacheMessage(queued)
            else
                -- Retry triggering cache periodically for stubborn items
                if not queued.lastRetry or (GetTime() - queued.lastRetry) > ITEM_CACHE_RETRY_INTERVAL then
                    queued.lastRetry = GetTime()
                    queued.retries = (queued.retries or 0) + 1
                    if queued.retries <= 5 then  -- Max 5 retries
                        local _, stillUncached = WT_CheckItemCache(queued.itemIds, true)  -- Trigger cache again
                        if table.getn(stillUncached) > 0 then
                            WT_DebugLog("Retry", queued.retries, "- triggering cache for", table.getn(stillUncached), "items")
                        end
                    end
                end
            end
        end)
        if not ok then
            WT_DebugLog("itemCacheFrame OnUpdate error for", cacheId, ":", tostring(err))
            -- Drop the broken entry so we don't loop on it forever.
            WT_itemCacheQueue[cacheId] = nil
        end
    end
end)
