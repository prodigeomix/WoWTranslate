--[[
  tools/fuzz_utf8_properties.lua
  ==============================
  Native Lua 5.0 Property-Based Fuzzer for WT_SafeUTF8Truncate.
  Runs against pinned tools/bin/lua50/lua50.exe.
]]

dofile("tools/wow_api_mock.lua")

-- Load String module
local chunk, err = loadfile("WoWTranslate_String.lua")
if not chunk then
    print("[FAIL] Could not load WoWTranslate_String.lua: " .. tostring(err))
    os.exit(1)
end
chunk()

local ascii = { "a", "B", "1", " ", "!", "?", "/", "[", "]", "|", ":" }
local cyrillic = { "п", "р", "и", "в", "е", "т", "м", "и", "р" }
local cjk = { "你", "好", "世", "界", "魔", "兽", "乌", "龟", "服", "翻", "译" }
local emoji = { "🎮", "⚔️", "🛡️", "🔥", "🌟" }

math.randomseed(12345)

local function GenerateRandomString(maxChars)
    local len = math.random(1, maxChars)
    local parts = {}
    for i = 1, len do
        local cat = math.random(1, 4)
        if cat == 1 then
            table.insert(parts, ascii[math.random(1, table.getn(ascii))])
        elseif cat == 2 then
            table.insert(parts, cyrillic[math.random(1, table.getn(cyrillic))])
        elseif cat == 3 then
            table.insert(parts, cjk[math.random(1, table.getn(cjk))])
        else
            table.insert(parts, emoji[math.random(1, table.getn(emoji))])
        end
    end
    return table.concat(parts, "")
end

local iterations = 10000
for i = 1, iterations do
    local s = GenerateRandomString(50)
    local slen = string.len(s)
    local cap = math.random(0, slen + 5)

    local truncated = WT_SafeUTF8Truncate(s, cap)
    local tlen = string.len(truncated)

    -- Invariant 1: Monotonic Byte Bound
    if tlen > cap then
        print(string.format("[FAIL] Truncated length exceeded cap: %d > %d", tlen, cap))
        os.exit(1)
    end

    -- Invariant 2: Prefix Matching
    if tlen > 0 and string.find(s, truncated, 1, true) ~= 1 then
        print("[FAIL] Truncated string is not a prefix of original string!")
        os.exit(1)
    end

    -- Invariant 3: Wire Protocol Framing
    if cap <= 280 then
        local wire = "zh|en|" .. truncated
        local wlen = string.len(wire)
        if wlen > 300 then
            print(string.format("[FAIL] Wire envelope exceeded 300 bytes: %d", wlen))
            os.exit(1)
        end
    end
end

print(string.format("[PASS] 10,000 iterations verified in native Lua 5.0 with zero invariant breaches!"))
os.exit(0)
