-- WoWTranslate_Globals.lua

-- ============================================================================
-- SAVED VARIABLES (initialized on load)
-- ============================================================================

WoWTranslateDB = WoWTranslateDB or {}
WoWTranslateDebugLog = WoWTranslateDebugLog or {}


-- ============================================================================
-- LOCAL STATE
-- ============================================================================

WT_DEBUG_MODE = false
WT_addonLoaded = false
WT_originalAddMessage = nil
WT_playerIsAFK = false
WT_dllWarnShown = false
WT_translationErrWarnShown = false
WT_hookCallCount = 0         -- incremented every time any hook body executes

WT_pendingMessages = {}
WT_messageCounter = 0

-- Maps capturedArg1 (raw message text) -> {frame -> true}
-- Collects every chat frame that showed the original Chinese message so the async
-- translation callback can post to all of them.  Multiple frames fire the same
-- OnEvent for one message; dedup lets only the first reach the DLL, but all frames
-- that displayed the original must also show the translation.
WT_frameTranslationTargets = {}

-- Outgoing translation state
WT_outgoingQueue = {}
WT_outgoingCounter = 0
WT_originalSendChatMessage = SendChatMessage

-- Waiters for in-flight player/guild name translations (rawName -> { callbacks = {} })
WT_pendingNameTranslations = {}

-- Forward reference: assigned after WT_HookNameplates is defined so
-- WoWTranslate_SetTranslateNameplates can start the scanner mid-session.
WT_wtNameplateScanStart = nil

-- Pre-translated prefixes for outgoing messages (zero API cost)
WT_TRANSLATED_PREFIXES = {
    zh = "[由WoWTranslate翻译]",
    en = "[Translated by WoWTranslate]",
    ko = "[WoWTranslate 번역]",
    ja = "[WoWTranslate翻訳]",
    ru = "[Переведено WoWTranslate]",
    de = "[Übersetzt von WoWTranslate]",
    fr = "[Traduit par WoWTranslate]",
    es = "[Traducido por WoWTranslate]",
    pt = "[Traduzido por WoWTranslate]",
}
WT_DEFAULT_PREFIX = "[Translated by WoWTranslate]"

-- Incoming channel detection state
WT_currentIncomingChannel = nil
WT_currentIsSystemEvent = false  -- True for system/emote/NPC events

WT_EVENT_TO_CHANNEL = {
    CHAT_MSG_SAY = "SAY",
    CHAT_MSG_YELL = "YELL",
    CHAT_MSG_WHISPER = "WHISPER",
    CHAT_MSG_PARTY = "PARTY",
    CHAT_MSG_GUILD = "GUILD",
    CHAT_MSG_OFFICER = "GUILD",
    CHAT_MSG_RAID = "RAID",
    CHAT_MSG_RAID_LEADER = "RAID",
    CHAT_MSG_RAID_WARNING = "RAID",
    CHAT_MSG_BATTLEGROUND = "BATTLEGROUND",
    CHAT_MSG_BATTLEGROUND_LEADER = "BATTLEGROUND",
    CHAT_MSG_CHANNEL = "CHANNEL",
    CHAT_MSG_HARDCORE = "HARDCORE",
}

-- Events to skip translation for (system msgs, emotes, NPC speech, notifications)
-- Only these specific events are skipped; unknown events (like WHISPER_INFORM) still translate
WT_SYSTEM_EVENTS = {
    CHAT_MSG_SYSTEM = true,
    CHAT_MSG_EMOTE = true,
    CHAT_MSG_TEXT_EMOTE = true,
    CHAT_MSG_MONSTER_SAY = true,
    CHAT_MSG_MONSTER_YELL = true,
    CHAT_MSG_MONSTER_EMOTE = true,
    CHAT_MSG_MONSTER_WHISPER = true,
    CHAT_MSG_CHANNEL_JOIN = true,
    CHAT_MSG_CHANNEL_LEAVE = true,
    CHAT_MSG_LOOT = true,
    CHAT_MSG_MONEY = true,
    CHAT_MSG_OPENING = true,
    CHAT_MSG_SKILL = true,
    CHAT_MSG_COMBAT_HONOR_GAIN = true,
    CHAT_MSG_COMBAT_XP_GAIN = true,
    CHAT_MSG_COMBAT_MISC_INFO = true,
}

WT_defaults = {
    enabled = true,
    debugMode = false,
    -- Outgoing translation settings
    outgoingEnabled = false,  -- Off by default
    outgoingChannels = {
        WHISPER = true,
        PARTY = true,
        GUILD = true,
        RAID = true,
        SAY = true,
        YELL = true,
        BATTLEGROUND = true,
        CHANNEL = true,
        HARDCORE = false,
        ENGLISH = false,
    },
    incomingChannels = {
        SAY = true,
        YELL = true,
        WHISPER = true,
        PARTY = true,
        GUILD = true,
        RAID = true,
        BATTLEGROUND = true,
        CHANNEL = true,
        HARDCORE = false,
        ENGLISH = false,
    },
    outgoingPrefix = "[Translated by WoWTranslate]",
    outgoingPrefixEnabled = true,
    outgoingDualLanguage = true, -- Sends both translated and original text: e.g. "嗨 (HELLO)"
    disableWhileAfk = false,
    translateSystemMessages = false,  -- Don't translate system msgs, emotes, NPC speech
    -- Language settings (any-to-any translation)
    enabledSourceLangs = { zh = true, ja = true, ko = true, ru = true, en = false },
    incomingToLang = "en",
    outgoingFromLang = "en",
    outgoingToLang = "zh",
    translationColor = "",       -- Hex RRGGBB for translated text body; empty = default chat color
    translationColorFollow = true,   -- If true, body color follows the source channel color
    replaceMode = false,         -- [EXPERIMENTAL] Replace original message with translation instead of appending
    translateGroupFinder = false, -- [EXPERIMENTAL] Translate LFT group finder titles/descriptions
    -- Name/guild translation
    translatePlayerNames = false,
    translateGuildNames = false,
    translateNameplates = false,
    outgoingButtonPos = { x = 100, y = 100 },
    showOutgoingButton = true,
    playerNameClassColor = true,
    nameplateGuildOOC = false,
    nameplateHideHealthOOC = false,
}


-- ============================================================================
-- LUA 5.0 COMPATIBILITY
-- ============================================================================

function WT_strsplit(delimiter, text, limit)
    if not text then return nil end
    if not delimiter or delimiter == "" then return text end

    local result = {}
    local count = 0
    local start = 1
    local delimStart, delimEnd = string.find(text, delimiter, start, true)

    while delimStart do
        count = count + 1
        if limit and count >= limit then
            break
        end
        table.insert(result, string.sub(text, start, delimStart - 1))
        start = delimEnd + 1
        delimStart, delimEnd = string.find(text, delimiter, start, true)
    end

    table.insert(result, string.sub(text, start))
    return unpack(result)
end


-- ============================================================================
-- DEBUG LOGGING
-- ============================================================================

function WT_DebugLog(a1, a2, a3, a4, a5)
    if not WT_DEBUG_MODE then return end

    local msg = ""
    if a1 then msg = msg .. tostring(a1) .. " " end
    if a2 then msg = msg .. tostring(a2) .. " " end
    if a3 then msg = msg .. tostring(a3) .. " " end
    if a4 then msg = msg .. tostring(a4) .. " " end
    if a5 then msg = msg .. tostring(a5) .. " " end

    local timestamp = string.format("%.1f", GetTime())
    local logEntry = "[" .. timestamp .. "] " .. msg

    if WT_originalAddMessage then
        WT_originalAddMessage(DEFAULT_CHAT_FRAME, "|cFFFFFF00[WT-DEBUG] " .. msg .. "|r")
    end

    table.insert(WoWTranslateDebugLog, logEntry)

    while table.getn(WoWTranslateDebugLog) > 500 do
        table.remove(WoWTranslateDebugLog, 1)
    end
end

