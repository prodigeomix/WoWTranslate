# WoWTranslate Lua-Side Forensic Audit — v3 (Wave 3 re-audit)

Date: 2026-08-25. Scope: the 12 authored/load-order Lua files per WoWTranslate.toc (v3.5.6 tree; `WoWTranslate_all.lua` skipped as build artifact). Platform: WoW 1.12.1 / Turtle WoW, Lua 5.0.
Method: full verification of the three wave-2 fixes (LUA-12/13/14) at every claimed site, regression check around each edit, then a fresh targeted sweep (all `AddMessage`/`SetText`/`AddLine` display sites inventoried across authored files; gsub replacement-string audit; glossary data skim; hook-chain spot re-check). Every finding cites file:line verified against the current tree. All 12 load-order files pass `luac -p`.

## Executive summary
**Loop does NOT close yet.** LUA-12 and LUA-14 are genuinely fixed and correct. LUA-13 is **partially** fixed: five of the surfaces named in wave 2 are now sanitized, but the LFT group-listing widget (`WoWTranslate_Hooks.lua:107`) — explicitly cited in wave 2's LUA-13 — still receives raw backend translation via `SetText`. The fresh sweep additionally found two adjacent surfaces of the same class that waves 1–2 did not cite: the translated tooltip **player-name** line and the nameplate **guild** overlay line both pass backend-derived names/guilds through `WT_StripColorCodes`-only transforms before `AddLine`/`SetText`, leaving `|H…|h` and `|n` escapes intact. All three residuals are consolidated below as LUA-18 (one class, three sites). No other new findings.

## Wave-2 fix verification

| Wave-2 id | Fix claimed | Verdict |
|---|---|---|
| LUA-12 | Sanitize all remaining AddMessage paths in `WT_ProcessItemCacheMessage` | **VERIFIED** — Hyperlink.lua:523 (no-translatable-content result), :532 (cache-hit `finalText`), :558 (API-success reconstruction), :563 (API-error `originalText` fallback) each wrap the backend-derived portion in `WT_SanitizeDisplayText`. See INFO note on :570. |
| LUA-13 | Sanitize non-chat display surfaces | **PARTIALLY VERIFIED** — Tooltip.lua:662–663 (guildDisplay+rankDisplay in resolve callback), :114/:118 (`WT_BuildSenderPrefix` resolved name + guildDisplay), :979 (nameplate `applyNameDisplay`), :1330 (right-click name lookup AddMessage), WoWTranslate.lua:296 (`/wt testout`) are correct. **Hooks.lua:107 was not fixed** — see LUA-18. Two further same-class sites surfaced (also LUA-18). |
| LUA-14 | Incoming dstLang reads `incomingToLang` | **VERIFIED** — API.lua:388 `local dstLang = (WoWTranslateDB and WoWTranslateDB.incomingToLang) or "en"`. Grep over all load-order files shows zero remaining readers of `WoWTranslateDB.targetLang` (the identifier `targetLang` survives only as a *local* derived from `outgoingToLang` in Hooks.lua:964/1040 and String.lua:83 — unrelated and correct). Wire dstLang, Hooks skip-gate (`detectedLang == incomingToLang`), and CacheKey direction now agree. |

No regressions introduced by the edits: surrounding control flow in `WT_ProcessItemCacheMessage` (Hyperlink.lua:502–572), `WT_ResolveGuildDisplayName` callbacks (Tooltip.lua:659–729), and `TranslateIncoming` dedup/pending bookkeeping (API.lua:370–418) are unchanged in structure; cache save still stores the *unsanitized* translation (correct — sanitizer is display-side only); `luac -p` passes on all 12 files.

## New findings (wave 3)

### CONFIRMED-RISK

**LUA-18 — Residual escape-injection surfaces for backend-derived text (incomplete LUA-13)**
Severity: MEDIUM | Three sites, one class: backend/cache-derived strings rendered on UI widgets without full escape stripping (`WT_SanitizeDisplayText`). `WT_StripColorCodes` removes only `|c…`/`|r`; `|H…|h…|h`, unterminated `|H`, and `|n` survive into `SetText`/`AddLine`, which do render color sequences (and `|n`) in 1.12 FontStrings. A malicious/poisoned backend or poisoned cache can recolor, garble, or forge markup on these surfaces.

1. **LFT group listing widget — raw, unfixed from wave 2** — WoWTranslate_Hooks.lua:107
   ```lua
   if widget then widget:SetText(translated) end
   ```
   `translated` arrives from `WoWTranslate_CacheGet` / glossary / `WoWTranslate_API.Translate` callbacks (Hooks.lua:120, 129, 145) with no sanitizer anywhere on the path. This site was explicitly part of wave-2 LUA-13 and is not addressed by the wave-3 edits.

2. **Translated tooltip player-name line — colors-only strip** — WoWTranslate_Tooltip.lua:668 → 677 (rendered at 726 `WT_InsertTooltipLines` / 486 prepend)
   ```lua
   local marked = WT_MarkTranslatedDisplayName(rawName, displayName, tooltip.wtUnit)
   ...
   table.insert(lines, marked)
   ```
   `displayName` is the raw backend translation (`WT_ResolvePlayerDisplayName`, Tooltip.lua:206–210, capitalized only), and `WT_MarkTranslatedDisplayName` (Tooltip.lua:95–105) applies `WT_StripColorCodes` + capitalization only. Not covered by the wave-3 fix, which sanitized only guildDisplay/rankDisplay inside the same callback (662–663).

3. **Nameplate guild overlay line — colors-only strip** — WoWTranslate_Tooltip.lua:1182 → 1191 (`guildFs:SetText(line)`), formatter at :1111–1118
   ```lua
   local plain = WT_StripColorCodes(displayGuild) or displayGuild
   local line = "<" .. plain .. ">"
   ```
   `displayGuild` comes from `WoWTranslate_ResolveGuildDisplayName` (backend translation of the guild name, Tooltip.lua:1206–1209) or directly from the nameplate cache (:1198). Same gap as the wave-2-cited nameplate *name* surface (now fixed at :979), one line type over.

Impact: UI-surface escape injection (fake colored markup, literal hyperlink-opener garbage, injected line breaks) on the LFT panel, target tooltips, and nameplates from untrusted backend output. Not clickable-link injection (hyperlinks are inert outside chat frames), hence MEDIUM not HIGH.
Fix: route `translated` at Hooks.lua:107 through `WT_SanitizeDisplayText`; apply it to `displayName` at Tooltip.lua:668 (or inside `WT_MarkTranslatedDisplayName`) and to `displayGuild` inside `WT_FormatNameplateGuildLine` (Tooltip.lua:1114). All three are single-line changes mirroring the existing pattern `(WT_SanitizeDisplayText and WT_SanitizeDisplayText(x) or x)`.

### INFO

**LUA-19 — Unsanitized passthrough branch in item-cache path (sender-original content, by design)** — WoWTranslate_Hyperlink.lua:568–570
```lua
local result = headerText
for _, seg in ipairs(segments) do result = result .. seg.content end
queued.WT_originalAddMessage(queued.frame, result, ...)
```
The "proxy unavailable" fallback posts the message without `WT_SanitizeDisplayText`, unlike its sibling branches (:517–524). Content here is exclusively the original sender's own line reassembled verbatim (header + untouched segment contents), i.e. byte-equivalent to what the un-hooked client would have displayed — no backend-derived text. Recorded as an intentional-passthrough consistency note; if defense-in-depth against crafted sender escapes is ever wanted, wrap it like :523 (accepting loss of genuine item links on this branch).

## Carried-over items (unchanged, per instructions)
- LUA-15 (SUSPECTED, LOW): reattachment pattern `%s*` gaps at Hyperlink.lua:476 — code unchanged, not materially worse.
- LUA-16 (INFO): pipe framing contract dependence — unchanged (API.lua:405).
- LUA-17 (SUSPECTED, LOW): CacheKey over-invalidation / missing per-call source lang — Cache.lua unchanged.
- Accepted: LUA-08, LUA-11.

## Clean areas (re-verified this wave)
- Full inventory of `AddMessage`/`SetText`/`AddLine`/`AddDoubleLine` call sites across the 11 authored files: every backend-derived chat path now sanitized (Hooks.lua:611/635/659/719 inputs; Hyperlink.lua:523/532/558/563; Tooltip.lua:1330; WoWTranslate.lua:120/296); remaining SetText sites are literals, config labels, or client-side values (Config.lua, Minimap.lua buttons, Tooltip.lua:420–421/486 orig-line passthrough).
- No dynamic third argument to `gsub` anywhere in authored files (audited every call: replacements are literals or `%1`-style captures); no `loadstring`/`RunScript`/`os.execute`/base64 blobs; glossary files are pure data tables + find-based lookups (no gsub, no executable patterns).
- Hook chains, SafeUTF8Truncate guard, cache LRU/eviction, debug-log cap, API queue caps, ClearPending flush — spot re-verified unchanged from wave 2.
- All 12 load-order Lua files pass `luac -p` after the wave-3 edits.

---
WAVE 3 (Lua side): 2026-08-25, scope = 12 authored/load-order Lua files + .toc, findings count = 1 new CONFIRMED-RISK (LUA-18, 3 sites; supersedes remainder of LUA-13) + 1 INFO (LUA-19); carried: LUA-15/16/17 documented, LUA-08/11 accepted. Wave-2 fixes: LUA-12 VERIFIED, LUA-14 VERIFIED, LUA-13 PARTIAL. Clean N — loop remains open until LUA-18 is fixed and a follow-up wave returns zero CONFIRMED findings.
