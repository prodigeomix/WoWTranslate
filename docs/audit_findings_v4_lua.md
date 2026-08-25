# WoWTranslate Lua-Side Forensic Audit — v4 (Wave 4 verification)

Date: 2026-08-25. Scope: the 12 authored/load-order Lua files per WoWTranslate.toc (v3.5.7 tree; `WoWTranslate_all.lua` skipped as build artifact). Platform: WoW 1.12.1 / Turtle WoW, Lua 5.0.
Method: narrow verification pass — line-level verification of each of LUA-18's three fix sites (fix present, correct placement in transform order, no regressions to surrounding logic), plus a targeted re-sweep of every `SetText`/`AddLine`/`AddDoubleLine`/`AddMessage` call site across the load-order files for any remaining unsanitized backend-derived display path.

## Executive summary
**CLEAN — loop closes for the Lua side.** All three LUA-18 sites are genuinely fixed and correct. No regressions introduced by the edits; no other unsanitized backend-derived display path found. Zero new CONFIRMED findings this wave.

## Wave-3 (LUA-18) fix verification

| Site | Fix claimed | Verdict |
|---|---|---|
| 1. LFT group listing widget | Sanitize `translated` before `SetText` at Hooks.lua:107 | **VERIFIED** — `WoWTranslate_Hooks.lua:107`: `if widget then widget:SetText(WT_SanitizeDisplayText and WT_SanitizeDisplayText(translated) or translated) end`. This is the single choke point through which all three sources flow (`WT_LFT_TranslateField` cache hit :118, glossary, API callback), so cache-, glossary-, and backend-derived text are all covered. |
| 2. Translated tooltip player-name line / chat sender prefix | Sanitize inside `WT_MarkTranslatedDisplayName`, after strip, before capitalization | **VERIFIED** — `WoWTranslate_Tooltip.lua:98–99`: `local plain = WT_StripColorCodes(displayName)` then `plain = WT_SanitizeDisplayText and WT_SanitizeDisplayText(plain) or plain`, followed by `WT_ApplyNameCapitalization(plain)` (:100). Correct order — capitalization operates on fully stripped text and cannot resurrect escapes. Covers both consumers: tooltip name line (:669 → insert :671+) and chat sender prefix (`WT_BuildSenderPrefix` :159). The sibling sanitizations of `resolved` (:115) and `guildDisplay` (:119) remain intact. |
| 3. Nameplate guild overlay line | Sanitize inside `WT_FormatNameplateGuildLine`, after strip | **VERIFIED** — `WoWTranslate_Tooltip.lua:1115–1116`: strip then `plain = WT_SanitizeDisplayText and WT_SanitizeDisplayText(plain) or plain` before building `"<" .. plain .. ">"`. The nameplate render path (:1184 → `guildFs:SetText(line)` :1193) therefore receives sanitized text; the cached-replay branch (:1203) replays only previously formatted (already sanitized) lines. |

No regressions: surrounding control flow unchanged in all three functions; the nameplate *name* overlay remains sanitized at its own site (Tooltip.lua:980 `applyNameDisplay` wraps `displayName` before formatting); cache storage still holds unsanitized translations (sanitizer stays display-side only — correct).

## Targeted sweep (no other unsanitized paths)
Re-inventoried every `SetText`/`AddLine`/`AddDoubleLine`/`AddMessage` call site across the 12 load-order files:
- Chat: Hooks.lua:611/635/659/719, Hyperlink.lua:523/532/558/563, Tooltip.lua:1332, WoWTranslate.lua:120 — all sanitized (LUA-19 :568–570 passthrough remains a known accepted INFO).
- Tooltips/nameplates/LFT: Tooltip.lua:487 (orig client-side line passthrough), :669/:726 (via fixed `WT_MarkTranslatedDisplayName`), :908 (via sanitized `applyNameDisplay` input :980), :1193/:1203 (via fixed formatter), Hooks.lua:107 (fixed) — all covered.
- Remaining SetText/AddMessage sites are literals, config labels, status/debug output of client-side values (Config.lua, Minimap.lua, WoWTranslate.lua status/test commands), or `SetText("")` clears. No new findings.

## Carried-over items (unchanged)
- LUA-15 (SUSPECTED, LOW): Hyperlink.lua:476 `%s*` gaps — code unchanged.
- LUA-16 (INFO): pipe framing contract dependence — unchanged.
- LUA-17 (SUSPECTED, LOW): CacheKey over-invalidation — Cache.lua unchanged.
- LUA-18: FIXED (all three sites verified above).
- LUA-19 (INFO): intentional byte-identical original-text passthrough — unchanged, documented.
- Accepted: LUA-08, LUA-11.

## Syntax check
All 12 load-order Lua files pass `luac -p` on the current tree.

---
WAVE 4 (Lua side): 2026-08-25, scope = 12 authored/load-order Lua files + .toc, findings count = 0 CONFIRMED. Wave-3 fixes: LUA-18 VERIFIED (all 3 sites). Carried: LUA-15/16/17 documented, LUA-19 INFO, LUA-08/11 accepted. Clean — loop closed for the v3.5.7 commit.
