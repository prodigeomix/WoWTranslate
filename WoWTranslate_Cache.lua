-- WoWTranslate_Cache.lua
-- Permanent translation cache using SavedVariables
-- Translations persist across sessions.
--
-- v0.14: Added size-based LRU eviction (H1 in audit). When the cache exceeds
--        MAX_ENTRIES, the oldest 25% of entries are dropped on the next Save.
--        A monotonically-increasing timestamp counter is used because Lua
--        tables don't preserve insertion order. The counter is persisted in
--        SavedVariables so eviction stays stable across sessions.

-- Maximum entries before LRU eviction kicks in.
local MAX_ENTRIES = 5000

-- When the cap is hit, drop this fraction (oldest first).
local EVICT_FRACTION = 0.25

-- Initialize cache (will be populated from SavedVariables on load)
WoWTranslateCache = WoWTranslateCache or {}
-- Per-entry timestamp (1-indexed counter; lower = older).
WoWTranslateCacheOrder = WoWTranslateCacheOrder or {}
WoWTranslateCacheCounter = WoWTranslateCacheCounter or 0

-- Cache statistics
local cacheHits = 0
local cacheMisses = 0

-- Check if a translation exists in cache.
-- Also bumps the entry's timestamp so frequently-used entries survive eviction.
function WoWTranslate_CacheGet(text)
    if WoWTranslateCache[text] then
        cacheHits = cacheHits + 1
        -- Refresh LRU position so hot entries survive eviction.
        WoWTranslateCacheCounter = WoWTranslateCacheCounter + 1
        WoWTranslateCacheOrder[text] = WoWTranslateCacheCounter
        return WoWTranslateCache[text], true
    end
    cacheMisses = cacheMisses + 1
    return nil, false
end

-- Save a translation to cache.  Triggers LRU eviction if over the cap.
function WoWTranslate_CacheSave(text, translation)
    if text and translation and text ~= "" and translation ~= "" then
        local isNew = (WoWTranslateCache[text] == nil)
        WoWTranslateCache[text] = translation
        WoWTranslateCacheCounter = WoWTranslateCacheCounter + 1
        WoWTranslateCacheOrder[text] = WoWTranslateCacheCounter
        if isNew then
            WoWTranslate_CacheMaybeEvict()
        end
        return true
    end
    return false
end

-- Count entries without scanning the order table (which may have stale keys
-- after eviction).  Used by /wt status.
function WoWTranslate_CacheStats()
    local count = 0
    for _ in pairs(WoWTranslateCache) do
        count = count + 1
    end
    return {
        entries = count,
        hits = cacheHits,
        misses = cacheMisses,
        hitRate = (cacheHits + cacheMisses > 0) and
                  (cacheHits / (cacheHits + cacheMisses) * 100) or 0
    }
end

-- Evict oldest EVICT_FRACTION of entries when over MAX_ENTRIES.
-- Builds a sortable array of (key, timestamp) pairs for the active entries only.
-- Stale order entries (for keys already gone) are cleaned up as a side effect.
function WoWTranslate_CacheMaybeEvict()
    local count = 0
    for _ in pairs(WoWTranslateCache) do
        count = count + 1
    end
    if count <= MAX_ENTRIES then return end

    -- Extract all timestamps into a flat array to avoid creating temporary table objects
    local timestamps = {}
    for key, _ in pairs(WoWTranslateCache) do
        local ts = WoWTranslateCacheOrder[key] or 0
        table.insert(timestamps, ts)
    end

    -- Sort to find the threshold timestamp
    table.sort(timestamps)

    -- Drop the oldest EVICT_FRACTION of them.
    local toEvict = math.floor(table.getn(timestamps) * EVICT_FRACTION)
    if toEvict <= 0 then return end
    
    local threshold = timestamps[toEvict]
    local keysToEvict = {}

    for key, _ in pairs(WoWTranslateCache) do
        local ts = WoWTranslateCacheOrder[key] or 0
        if ts <= threshold then
            table.insert(keysToEvict, key)
            if table.getn(keysToEvict) >= toEvict then break end
        end
    end

    for _, key in ipairs(keysToEvict) do
        WoWTranslateCache[key] = nil
        WoWTranslateCacheOrder[key] = nil
    end
end

-- Clear the cache (use with caution)
function WoWTranslate_CacheClear()
    WoWTranslateCache = {}
    WoWTranslateCacheOrder = {}
    WoWTranslateCacheCounter = 0
    cacheHits = 0
    cacheMisses = 0
end

-- Reset session statistics only
function WoWTranslate_CacheResetStats()
    cacheHits = 0
    cacheMisses = 0
end
