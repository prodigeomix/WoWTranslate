-- WoWTranslate_String.lua

-- ============================================================================
-- SOURCE LANGUAGE CHARACTER DETECTION
-- ============================================================================

-- Detects if text contains characters from the configured source language
-- Supports: zh (Chinese), ja (Japanese), ko (Korean), ru (Russian)
-- For Latin-based languages (en, de, fr, es, pt): detects non-ASCII characters

function WT_ContainsLanguageChars(text, lang)
    if not text then return false end

    -- English: pure ASCII text with >= 4 alpha characters.
    -- Any non-ASCII byte (>= 128) means the text contains CJK/Russian/etc., so it is
    -- NOT purely English. Without this guard, Chinese messages that mix in WoW
    -- abbreviations like "MC DPS LFG" (4+ Latin chars) would falsely be detected
    -- as "already English" and skip outgoing translation.
    if lang == "en" then
        local count = 0
        for i = 1, string.len(text) do
            local b = string.byte(text, i)
            if b >= 128 then
                return false  -- non-ASCII character: not a pure English message
            elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
                count = count + 1
            end
        end
        return count >= 4
    end

    for i = 1, string.len(text) do
        local byte = string.byte(text, i)

        if lang == "zh" then
            -- Chinese: CJK Unified Ideographs (U+4E00-U+9FFF)
            -- UTF-8: bytes 228-233 as first byte
            if byte >= 228 and byte <= 233 then
                return true
            end
        elseif lang == "ja" then
            -- Japanese: Hiragana, Katakana, and CJK
            -- Hiragana/Katakana: U+3040-U+30FF (UTF-8: 227 as first byte)
            -- CJK: same as Chinese
            if byte == 227 or (byte >= 228 and byte <= 233) then
                return true
            end
        elseif lang == "ko" then
            -- Korean: Hangul syllables U+AC00-U+D7AF
            -- UTF-8: bytes 234-237 as first byte (covers Hangul range)
            if byte >= 234 and byte <= 237 then
                return true
            end
        elseif lang == "ru" then
            -- Russian: Cyrillic U+0400-U+04FF
            -- UTF-8: bytes 208-209 as first byte
            if byte == 208 or byte == 209 then
                return true
            end
        else
            -- Latin-based languages (en, de, fr, es, pt)
            -- Detect extended ASCII / accented characters (UTF-8 multi-byte)
            -- Any byte >= 128 indicates non-ASCII (potential accented chars)
            if byte >= 192 and byte <= 223 then
                -- 2-byte UTF-8 sequence start (covers Latin Extended, etc.)
                return true
            end
        end
    end
    return false
end

-- Check if text contains characters that need translation based on incoming settings
function WT_ContainsSourceLanguage(text)
    if not text then return false end
    local sourceLang = WoWTranslateDB and WoWTranslateDB.incomingFromLang or "zh"
    return WT_ContainsLanguageChars(text, sourceLang)
end

-- Check if text contains outgoing target language (to prevent double-translation)
function WT_ContainsOutgoingTargetLanguage(text)
    if not text then return false end
    local targetLang = WoWTranslateDB and WoWTranslateDB.outgoingToLang or "zh"
    return WT_ContainsLanguageChars(text, targetLang)
end

-- Legacy function name for compatibility
function WT_ContainsChinese(text)
    return WT_ContainsLanguageChars(text, "zh")
end

-- Pattern-based preprocessing for incoming CJK messages.
-- Converts WoW-CN specific shorthands that the static glossary cannot handle.
function WT_PreprocessIncoming(text)
    if not text then return text end
    -- Normalize Chinese sentence terminators so Google returns a single translation
    -- segment instead of splitting on sentence boundaries (DLL only reads first segment).
    text = string.gsub(text, "\227\128\130", ", ")   -- 。 U+3002
    text = string.gsub(text, "\239\188\129", ", ")   -- ！ U+FF01
    text = string.gsub(text, "\239\188\159", ", ")   -- ？ U+FF1F
    text = string.gsub(text, "%.", ",")              -- English period
    text = string.gsub(text, "!", ",")               -- English exclamation
    text = string.gsub(text, "%?", ",")              -- English question mark
    -- Currency: XG = X gold, XY = X silver. Only when not followed by a letter
    -- so "YY" (Shadowfang Keep), "GM" etc. are not touched.
    -- Run BEFORE 88 handling so "88Y" → "88s" (silver), not "bye Y".
    text = string.gsub(text, "(%d+)G([^%a])", "%1g%2")
    text = string.gsub(text, "(%d+)G$", "%1g")
    text = string.gsub(text, "(%d+)Y([^%a])", "%1s%2")
    text = string.gsub(text, "(%d+)Y$", "%1s")
    -- 110 = patrol mob (China police emergency number used as WoW slang)
    text = string.gsub(text, "([^%w])110([^%w])", "%1patrol%2")
    text = string.gsub(text, "([^%w])110$",        "%1patrol")
    text = string.gsub(text, "^110([^%w])",         "patrol%1")
    text = string.gsub(text, "^110$",               "patrol")
    -- 88 = bye bye (CN internet send-off). Only when isolated (not part of e.g. "880").
    text = string.gsub(text, "([^%w])88([^%w])", "%1bye%2")
    text = string.gsub(text, "([^%w])88$",        "%1bye")
    text = string.gsub(text, "^88([^%w])",         "bye%1")
    text = string.gsub(text, "^88$",               "bye")
    -- 666 = "awesome / well played" (CN superlative slang). Isolated only.
    text = string.gsub(text, "([^%w])666([^%w])", "%1Good job!%2")
    text = string.gsub(text, "([^%w])666$",        "%1Good job!")
    text = string.gsub(text, "^666([^%w])",         "Good job!%1")
    text = string.gsub(text, "^666$",               "Good job!")
    -- 999 = res me (jiǔ = save/rescue, sounds like 9). Isolated only.
    text = string.gsub(text, "([^%w])999([^%w])", "%1res me%2")
    text = string.gsub(text, "([^%w])999$",        "%1res me")
    text = string.gsub(text, "^999([^%w])",         "res me%1")
    text = string.gsub(text, "^999$",               "res me")
    -- 11 = yāo yāo = affirmative / "yes yes". [^%w] boundary; note: may fire on
    -- "我要11个" (I want 11 of them) since CJK chars are not %w in Lua 5.0.
    text = string.gsub(text, "([^%w])11([^%w])", "%1yes%2")
    text = string.gsub(text, "([^%w])11$",        "%1yes")
    text = string.gsub(text, "^11([^%w])",         "yes%1")
    text = string.gsub(text, "^11$",               "yes")
    -- 密 (mì, U+5BC6, UTF-8 \229\175\134) = "whisper" in CN WoW slang.
    -- Two context-specific cases that the static glossary cannot cover safely:
    -- compound forms (密我/来密/求密/密密/etc.) are handled by the glossary.
    -- Case 1: entire message is just 密 (optionally with trailing punctuation).
    -- Anchoring to ^ and $ ensures this never fires inside 密码/保密/亲密.
    if string.find(text, "^\229\175\134[%. !?]*$") then
        return "whisper"
    end
    -- Case 2: 密 immediately followed by an ASCII player name (e.g. "密 Playerone").
    -- Player names on vanilla servers are ASCII-only [A-Z][a-z]+.
    local _s, _e, pname = string.find(text, "^\229\175\134%s*([%a][%a%d]+)$")
    if pname then
        return "whisper " .. pname
    end
    return text
end

-- Pattern-based preprocessing for outgoing English messages.
-- Converts standard WoW EN currency notation to CN server notation before API.
function WT_PreprocessOutgoing(text)
    if not text then return text end
    -- Gold: Xg → XG
    text = string.gsub(text, "(%d+)g([^%a])", "%1G%2")
    text = string.gsub(text, "(%d+)g$",        "%1G")
    -- Silver: Xs → XY
    -- With this, "3s CD" or "8s cast time" could wrongly become "3Y CD" but it is a good tradeoff since these are not used often in chat.
    text = string.gsub(text, "(%d+)s([^%a])", "%1Y%2")
    text = string.gsub(text, "(%d+)s$",        "%1Y")
    return text
end

-- Auto-detect which source language a message is in.
-- Returns "zh", "ja", "ko", "ru", or nil if no supported language found.
function WT_DetectSourceLanguage(text)
    if not text then return nil end
    local enabled = (WoWTranslateDB and WoWTranslateDB.enabledSourceLangs)
                    or { zh=true, ja=true, ko=true, ru=true }
    -- If table exists but every lang is nil/false, fall back to all-enabled
    if not enabled.zh and not enabled.ja and not enabled.ko and not enabled.ru then
        enabled = { zh=true, ja=true, ko=true, ru=true }
    end

    local hasKorean   = false
    local hasHiragana = false
    local hasCJK      = false
    local hasRussian  = false
    local asciiAlpha  = 0

    for i = 1, string.len(text) do
        local b = string.byte(text, i)
        if b >= 234 and b <= 237 then hasKorean = true
        elseif b == 227            then hasHiragana = true
        elseif b >= 228 and b <= 233 then hasCJK = true
        elseif b == 208 or b == 209  then hasRussian = true
        elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
            asciiAlpha = asciiAlpha + 1
        end
    end

    if enabled.ko and hasKorean   then return "ko" end
    -- Check zh BEFORE ja: Chinese punctuation (。、「」 etc.) uses UTF-8 byte 0xE3 (227),
    -- the same first byte as Japanese hiragana/katakana. Chinese messages containing
    -- both punctuation (byte 227 → hasHiragana) and characters (bytes 228-233 → hasCJK)
    -- must be treated as Chinese, not Japanese.
    if enabled.zh and hasCJK      then return "zh" end
    if enabled.ja and hasHiragana then return "ja" end
    if enabled.ru and hasRussian  then return "ru" end
    -- English: >= 4 ASCII alpha chars, no CJK/Korean/Japanese/Russian.
    -- Detection is unconditional (same-language skip prevents en→en no-ops).
    if asciiAlpha >= 4 and not (hasCJK or hasKorean or hasHiragana or hasRussian) then
        return "en"
    end
    return nil
end


-- ============================================================================
-- GLOSSARY PARTIAL MATCHING UTILITY
-- ============================================================================

function WT_GlossaryPartialMatch(text, glossaryTable, sortedKeys, boundaryThreshold, checkMultibyteBoundary)
    local lowerText = string.lower(text)

    local function isAlphanumeric(byte)
        return byte and (
            (byte >= 65 and byte <= 90) or
            (byte >= 97 and byte <= 122) or
            (byte >= 48 and byte <= 57)
        )
    end

    local matches = {}
    local textLen = string.len(lowerText)

    for _, key in ipairs(sortedKeys) do
        local keyLen = string.len(key)

        local requireBoundary = false
        if keyLen <= boundaryThreshold then
            requireBoundary = true
            if checkMultibyteBoundary then
                for i = 1, keyLen do
                    if string.byte(key, i) > 127 then
                        requireBoundary = false
                        break
                    end
                end
            end
        end

        local pos = 1
        while pos <= textLen do
            local startPos, endPos = string.find(lowerText, string.lower(key), pos, true)
            if not startPos then break end

            local ok = true

            if requireBoundary then
                local before = startPos > 1 and string.byte(lowerText, startPos - 1) or nil
                local after  = endPos < textLen and string.byte(lowerText, endPos + 1) or nil
                if isAlphanumeric(before) or isAlphanumeric(after) then
                    ok = false
                end
            end

            if ok then
                for _, m in ipairs(matches) do
                    if startPos <= m.endPos and endPos >= m.startPos then
                        ok = false
                        break
                    end
                end
            end

            if ok then
                table.insert(matches, {
                    startPos    = startPos,
                    endPos      = endPos,
                    replacement = glossaryTable[key]
                })
            end

            pos = endPos + 1
        end
    end

    if table.getn(matches) == 0 then
        return nil, nil
    end

    table.sort(matches, function(a, b) return a.startPos < b.startPos end)

    local parts = {}
    local lastEnd = 0
    for _, m in ipairs(matches) do
        if m.startPos > lastEnd + 1 then
            -- Note: For outgoing glossary, text case is preserved since we slice from the original text!
            table.insert(parts, string.sub(text, lastEnd + 1, m.startPos - 1))
        end
        table.insert(parts, m.replacement)
        lastEnd = m.endPos
    end
    if lastEnd < textLen then
        table.insert(parts, string.sub(text, lastEnd + 1))
    end

    return table.concat(parts, ""), "glossary_partial"
end


-- ============================================================================--
-- SEGMENT-LEVEL TRANSLATION PREPROCESSING & GLOSSARY MATCHING
-- ============================================================================

-- M9 fix: factor out the exact-then-partial glossary cascade so the same
-- logic isn't duplicated four times across WT_ProcessSegmentsIncoming and
-- WT_ProcessSegmentsOutgoing.  Returns the (possibly replaced) text.
local function WT_ApplyGlossaryCascade(text, exactFn, partialFn, preprocessFn)
    if preprocessFn then
        text = preprocessFn(text)
    end
    if exactFn then
        local exact = exactFn(text)
        if exact then return exact end
    end
    if partialFn then
        local partial = partialFn(text)
        if partial then return partial end
    end
    return text
end

-- Apply incoming preprocessing and glossary matching to each text segment individually.
-- This keeps the link placeholders (e.g. http://ph.wt/N) isolated and safe.
function WT_ProcessSegmentsIncoming(segments, detectedLang)
    for _, seg in ipairs(segments) do
        if seg.type == "text" then
            if detectedLang == "en" then
                -- EN -> ZH: outgoing glossary (no preprocessing on incoming EN path)
                seg.content = WT_ApplyGlossaryCascade(
                    seg.content,
                    WoWTranslate_CheckOutGlossaryExact,
                    WoWTranslate_CheckOutGlossaryPartial,
                    nil)
            else
                -- ZH -> EN (or other non-EN): preprocess + incoming glossary
                seg.content = WT_ApplyGlossaryCascade(
                    seg.content,
                    WoWTranslate_CheckGlossaryExact,
                    WoWTranslate_CheckGlossaryPartial,
                    WT_PreprocessIncoming)
            end
        end
    end
end

-- Apply outgoing preprocessing and glossary matching to each text segment individually.
-- This keeps the link placeholders (e.g. http://ph.wt/N) isolated and safe.
function WT_ProcessSegmentsOutgoing(segments, outFromLang)
    for _, seg in ipairs(segments) do
        if seg.type == "text" then
            if outFromLang == "en" then
                -- EN -> ZH: preprocess outgoing + outgoing glossary
                seg.content = WT_ApplyGlossaryCascade(
                    seg.content,
                    WoWTranslate_CheckOutGlossaryExact,
                    WoWTranslate_CheckOutGlossaryPartial,
                    WT_PreprocessOutgoing)
            else
                -- ZH -> EN (or other non-EN source): incoming glossary, no preprocessing
                seg.content = WT_ApplyGlossaryCascade(
                    seg.content,
                    WoWTranslate_CheckGlossaryExact,
                    WoWTranslate_CheckGlossaryPartial,
                    nil)
            end
        end
    end
end




