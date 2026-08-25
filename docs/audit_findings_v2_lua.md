# WoWTranslate Lua-Side Forensic Audit — v2 (Wave 2 re-audit)

Date: 2026-08-25. Scope: the 12 authored/load-order Lua files per WoWTranslate.toc (WoWTranslate_all.lua skipped as build artifact; Glossary data files anomaly-grepped). Platform: WoW 1.12.1 / Turtle WoW, Lua 5.0.
Method: full re-read of every scoped file; every finding cites file:line verified against the current working tree. Python proxy covered by parallel audit. All scoped files pass `luac -p` (Lua 5.1).

## Executive summary
All four major wave-1 Lua fixes are genuinely present and correct (WT_SanitizeDisplayText exists and guards the original 5 chat AddMessage paths; CacheKey is direction-aware; the pending-key collision fix is monotonic; ClearPending now flushes dropped callbacks). However, wave 2 finds **the sanitizer was not applied to every display surface**: the item-cache message path (`WT_ProcessItemCacheMessage`) posts backend-derived reconstructions to chat completely unsanitized, and several non-chat surfaces (name lookup printout, tooltip name/guild/rank lines, LFT widgets, nameplates, `/wt testout`) insert backend-derived text raw. A second new confirmed bug: **incoming translation requests target `WoWTranslateDB.targetLang`, a key nothing ever writes** — the Config UI writes `incomingToLang`, so the configured incoming target language is silently ignored (always defaults to `"en"`), while the skip-check in Hooks.lua compares against `incomingToLang`. Everything else is hygiene-level.

## Wave-1 fix verification

| Wave-1 id | Fix claimed | Verdict |
|---|---|---|
| LUA-01 | WT_SanitizeDisplayText at 5 AddMessage paths | **VERIFIED at the 5 claimed paths** (Hooks.lua:611–612 BuildWTMsg body; 635, 659, 719 ResolveNamesAndPost inputs; WoWTranslate.lua:120 `/wt test`) — but see LUA-12/LUA-13: other backend-text display paths were missed |
| LUA-02 | Pipe framing fixed Python-side | VERIFIED Lua-side unchanged by design (API.lua:405, 467 still send `lang|lang|text`); relies on proxy intake validation — cross-boundary contract note recorded as LUA-16 (INFO) |
| LUA-03 | Direction-aware CacheKey | **VERIFIED** — Cache.lua:29–37, key = `incomingToLang .. "/" .. outgoingToLang .. "|" .. text`; Get/Save both use it |
| LUA-04 | Monotonic pendingKeyCounter | **VERIFIED** — Hooks.lua:772–773 appends global monotonic counter; initialized Globals.lua:24 |
| LUA-05 | "auto" handled proxy-side | VERIFIED as documented — Lua still passes `"auto"` (Tooltip.lua:1328); proxy maps it |
| LUA-06 | Placeholder pattern tightened | PARTIALLY VERIFIED — Hyperlink.lua:476 host is contiguous, but see LUA-15: scheme/host tokens still accept arbitrary internal whitespace |
| LUA-07 | Guild-name map capped | **VERIFIED** — Tooltip.lua:1075–1086, cap 500 with reset-on-full |
| LUA-09 | %02x rounding | **VERIFIED** — Tooltip.lua:35 `math.floor(x*255 + 0.5)` |
| LUA-10 | ClearPending fires dropped callbacks | **VERIFIED** — API.lua:688–699 pcalls each dropped callback with `(nil, "reset")` |

LUA-08 (accepted cosmetic gap) and LUA-11 (accepted localhost trust model) remain as accepted.

## New findings (wave 2)

### CONFIRMED-RISK

**LUA-12 — Item-cache chat path bypasses WT_SanitizeDisplayText entirely**
- Severity: HIGH | File: WoWTranslate_Hyperlink.lua:558 (also 532)
```lua
local finalText = pending.headerText .. WT_ReconstructMessage(pending.segments, translation)
...
pcall(pending.WT_originalAddMessage, pending.frame, finalText, ...)
```
`WT_ProcessItemCacheMessage` is a complete parallel incoming-message pipeline (messages whose item links had to be server-resolved) and its success path posts `headerText .. reconstruction` — where `translation` is raw proxy output — through `WT_originalAddMessage` with **no** `WT_SanitizeDisplayText` call anywhere in the function (lines 502–572; same for the cache-hit branch at line 532). This is exactly the LUA-01 injection vector (forged `|c`/`|Hitem:`/`|Hplayer:` sequences from a malicious backend or poisoned cache) surviving on a sixth AddMessage path. Fix: wrap the reconstructed body (and ideally headerText) in `WT_SanitizeDisplayText` before line 523/532/533/558/560/563.

**LUA-13 — Backend-derived text displayed raw on non-chat surfaces (names, guilds, ranks, LFT, nameplates, /wt testout)**
- Severity: MEDIUM | Files:
  - WoWTranslate_Tooltip.lua:1324
    ```lua
    frame:AddMessage("|cFF00CCFF[WT]|r: " .. playerName .. " = " .. translation)
    ```
  - WoWTranslate_Tooltip.lua:692, 694, 699, 715 — translated `guildDisplay`/`rankDisplay` concatenated into tooltip lines passed to `tooltip:AddLine` (via WT_InsertTooltipLines, line 720) without sanitization; a poisoned cache/backend entry can inject escapes into the tooltip render.
  - WoWTranslate_Tooltip.lua:901 `fs:SetText(formatted)` — nameplate font string built from backend `displayName` (via WT_FormatNameplateOverlayText → WT_StripColorCodes only strips colors, leaves `|H…|h`, `|T…|t`, `||` intact).
  - WoWTranslate_Hooks.lua:107 `widget:SetText(translated)` — LFT group title/description set from raw API translation.
  - WoWTranslate.lua:296 `"|cFF00FF00[WoWTranslate] Translation:|r " .. result` — `/wt testout` prints backend result raw (its sibling `/wt test` was sanitized in wave 1).
`WT_StripColorCodes` removes only `|c……`/`|r`; hyperlink/texture/newline escapes survive. Impact: UI-surface escape injection from backend/poisoned-cache content (fake item links in tooltips, colored/garbled nameplates). Fix: route all of these through `WT_SanitizeDisplayText` (or a SetText-safe variant).

### CONFIRMED-BUG

**LUA-14 — Incoming target-language setting ignored: requests use never-written `WoWTranslateDB.targetLang`**
- Severity: MEDIUM | File: WoWTranslate_API.lua:388
```lua
local dstLang = (WoWTranslateDB and WoWTranslateDB.targetLang) or "en"
```
`targetLang` is read here and nowhere else in the authored tree — grep over all load-order files shows zero writers; the Config UI language selector writes `incomingToLang` (Config.lua:325 `CreateLangSelector("To:", …, "incomingToLang")`, saved via SaveTempConfig). Consequences: (a) every incoming translation request is issued with dst=`"en"` regardless of the user's chosen incoming target; (b) inconsistent gating in Hooks.lua:586–587, which skips translation when `detectedLang == incomingToLang` — so with incomingToLang="zh", Chinese messages are skipped (correct-looking) but Japanese/Russian messages get translated to English, not Chinese; (c) CacheKey (Cache.lua:35) keys on `incomingToLang`, so the cache and the wire disagree. Fix: use `WoWTranslateDB.incomingToLang or "en"` at API.lua:388.

### SUSPECTED

**LUA-15 — Reattachment pattern still tolerates whitespace inside scheme/host tokens**
- Severity: LOW | File: WoWTranslate_Hyperlink.lua:476
```lua
local pattern = "https*:%s*//%s*ph%.?%s*wt%s*/%s*" .. tostring(i)
```
The wave-1 tightening made the host contiguous *tokens* but left `%s*` gaps between them, so crafted remote text like `http: // ph wt /1` (all inside one real sender's own message, requiring ≥1 genuine link in the message) still matches and consumes that span during reconstruction. Impact remains bounded (replacement content comes from the same message's extracted links), hence LOW/SUSPECTED rather than a regression. Fix: restrict to optional single spaces, e.g. `"https?: ?// ?ph%.?wt ?/ ?"..i` or match only the exact placeholder plus Google-typical punctuation.

**LUA-17 — CacheKey omits effective source/direction context of the individual call**
- Severity: LOW | File: WoWTranslate_Cache.lua:35
```lua
local to = tostring(tostring(db.incomingToLang or "?") .. "/" .. tostring(db.outgoingToLang or "?"))
```
The key bundles both directions into every entry, which is safe against wrong-direction hits but (a) evicts/invalidates ALL cached incoming translations whenever either selector changes (over-invalidation, wasteful not harmful) and (b) does not include the per-call source lang — e.g. `WT_HookHyperlinkShow` requests translate with fromLang="auto" while chat requests use detected langs; identical strings in different source languages share one entry. Practically near-impossible to collide (same string, different source scripts) — noted for completeness.

### INFO

**LUA-16 — IPC wire format still `srcLang|dstLang|text` with no Lua-side escaping (accepted, contract-dependent)**
- File: WoWTranslate_API.lua:405, 467 — `local encoded = srcLang .. "|" .. dstLang .. "|" .. text`. Unchanged from wave 1 by design; safety now depends wholly on the proxy's request-intake validation (wave-1 LUA-02 fix). Any third-party/proxy replacement that does not validate the framing reintroduces field confusion. Recommend documenting the invariant next to the encoder.

## Clean areas (re-verified this wave)
- No `loadstring`/`RunScript`/`os.execute`/`io.popen`/base64 blobs in any authored file or glossary data file.
- Glossary files contain only data tables + lookup functions; anomaly grep clean.
- Hook chains unchanged and sound: SendChatMessage chain capture/restore (Hooks.lua:1089–1113), origScript saved per frame with pcall and restore on both paths (Hooks.lua:487–500), LFT/hyperlink hooks save originals on stable fields with unhook support.
- SafeUTF8Truncate malformed-UTF-8 guard intact (Hooks.lua:410–435).
- Cache LRU eviction logic correct incl. threshold tie handling; debug log capped at 500.
- API queue cap, timeout sweep, backoff, pcall-guarded callbacks, and the new ClearPending callback flush all verified.
- All 12 load-order Lua files pass `luac -p`.

---
WAVE 2 (Lua side): 2026-08-25, scope = 12 authored/load-order Lua files + .toc, findings count = 6 new (2 CONFIRMED-RISK, 1 CONFIRMED-BUG, 2 SUSPECTED, 1 INFO) + 2 wave-1 items still open as accepted (LUA-08, LUA-11), clean N. Wave-1 fixes: 9 of 11 verified present and correct; LUA-01 verified only on its originally-cited paths — incomplete coverage surfaced as LUA-12/LUA-13.
