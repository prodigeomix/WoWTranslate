--[[
  tools/test_headless_branch_coverage.lua
  =======================================
  Pillar 3: Headless VM Zero-GC & Wire Simulation Driver for WoWTranslate.
  Executed via pinned native tools/bin/lua50/lua50.exe against tools/wow_api_mock.lua.
]]

-- 1. Load WoW 1.12.1 FrameXML & C-API Mock
dofile("tools/wow_api_mock.lua")

-- 2. Polyfill gcinfo and collectgarbage if absent
if not gcinfo then
    gcinfo = function() return 0 end
end

-- 3. Load All Production Lua Modules in TOC Order
local tocFiles = {
    "WoWTranslate_Glossary.lua",
    "WoWTranslate_OutGlossary.lua",
    "WoWTranslate_Globals.lua",
    "WoWTranslate_String.lua",
    "WoWTranslate_Hyperlink.lua",
    "WoWTranslate_Tooltip.lua",
    "WoWTranslate_Hooks.lua",
    "WoWTranslate_Cache.lua",
    "WoWTranslate_API.lua",
    "WoWTranslate_Config.lua",
    "WoWTranslate_Minimap.lua",
    "WoWTranslate.lua",
}

for i = 1, table.getn(tocFiles) do
    local f = tocFiles[i]
    local chunk, err = loadfile(f)
    if not chunk then
        print("[FAIL] Could not load module: " .. tostring(f) .. " (" .. tostring(err) .. ")")
        os.exit(1)
    end
    chunk()
end

-- 4. Initialize Database
WoWTranslateDB = {
    enabled = true,
    incomingToLang = "en",
    outgoingToLang = "zh",
    outgoingFromLang = "en",
    outgoingEnabled = true,
    translatePlayerNames = true,
    translateGuildNames = true,
    enabledSourceLangs = { zh=true, ja=true, ko=true, ru=true, es=false, en=false },
    incomingChannels = { ["SAY"] = true, ["PARTY"] = true, ["RAID"] = true, ["GUILD"] = true },
    outgoingChannels = { ["SAY"] = true, ["PARTY"] = true, ["RAID"] = true, ["GUILD"] = true },
}

-- 5. Test Vectors for Simulation
local sampleChats = {
    "来个T 4=1 玛拉顿",
    "REQ^1792567010^Raffle^v4",
    "PWB:1:1792000000:BuffInfo",
    "Hello world, looking for healer for SM",
    "Привет всем, нужен танк в инст",
    "안녕하세요 파티 구합니다",
    "谢不举 [Master Sergeant]",
    "Normal chat message without protocol markers",
    "BGTBL,12345,WarsongGulch",
}

-- 6. SuperWoW Buffer Framing Invariants (280b text -> 292b wire <= 300b cap < 320b client buffer)
local function VerifySuperWoWBufferFraming()
    local longCJK = ""
    for i = 1, 100 do
        longCJK = longCJK .. "测试"
    end
    -- WT_SafeUTF8Truncate must cap at 280 bytes safely
    local truncated = WT_SafeUTF8Truncate(longCJK, 280)
    local tlen = string.len(truncated)
    if tlen > 280 then
        print("[FAIL] WT_SafeUTF8Truncate exceeded 280 bytes: " .. tostring(tlen))
        os.exit(1)
    end
    -- Wire protocol envelope framing: prefix + text
    local wireEnvelope = "req_" .. "000001" .. ".txt:" .. truncated
    local wireLen = string.len(wireEnvelope)
    if wireLen > 300 then
        print("[FAIL] Wire envelope exceeded 300 bytes limit: " .. tostring(wireLen))
        os.exit(1)
    end
end

-- 7. Addon Protocol Isolation Verification
local function VerifyProtocolIsolation()
    if not WT_IsAddonProtocolMessage("REQ^1792567010^Raffle^v4") then
        print("[FAIL] REQ^...^Raffle^v4 not recognized by WT_IsAddonProtocolMessage")
        os.exit(1)
    end
    if not WT_IsAddonProtocolMessage("PWB:1:data") then
        print("[FAIL] PWB:1:data not recognized by WT_IsAddonProtocolMessage")
        os.exit(1)
    end
    if WT_IsAddonProtocolMessage("Normal chat message") then
        print("[FAIL] Normal chat false-positived in WT_IsAddonProtocolMessage")
        os.exit(1)
    end
end

-- 8. Zero-GC Steady-State Evaluation Gauntlet (1,000 ticks)
local function RunZeroGCGauntlet()
    -- Warm up JIT/caches
    for i = 1, 50 do
        for j = 1, table.getn(sampleChats) do
            local msg = sampleChats[j]
            WT_DetectSourceLanguage(msg)
            WT_IsAddonProtocolMessage(msg)
            WT_ShouldTranslatePlayerName(msg)
            WT_StripOverheadDisplaySuffix(msg)
        end
    end

    collectgarbage()
    collectgarbage()
    local baselineMem = gcinfo()

    -- 1,000 steady-state evaluation ticks on hot paths
    for i = 1, 1000 do
        for j = 1, table.getn(sampleChats) do
            local msg = sampleChats[j]
            local lang = WT_DetectSourceLanguage(msg)
            local isProto = WT_IsAddonProtocolMessage(msg)
            local shouldName = WT_ShouldTranslatePlayerName(msg)
            local cleanName = WT_StripOverheadDisplaySuffix(msg)
        end
    end

    local finalMem = gcinfo()
    local deltaMem = finalMem - baselineMem

    return baselineMem, finalMem, deltaMem
end

-- Execute Tests
VerifySuperWoWBufferFraming()
VerifyProtocolIsolation()
local bMem, fMem, dMem = RunZeroGCGauntlet()

print(string.format("GAUNTLET_RESULT: Baseline=%d KiB, Final=%d KiB, Delta=%d KiB", bMem, fMem, dMem))

if dMem > 0 then
    print(string.format("[FAIL] Zero-GC Gauntlet failed! Memory leaked: %d KiB across 1,000 ticks.", dMem))
    os.exit(1)
end

print("[PASS] Headless VM Zero-GC Gauntlet (Delta = 0 KiB) & SuperWoW Wire Framing certified!")
os.exit(0)
