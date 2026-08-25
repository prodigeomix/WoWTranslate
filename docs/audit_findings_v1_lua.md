# WoWTranslate Lua-Side Forensic Audit — v1 (Lua files only)

Date: 2026-08-25. Scope: the 10 authored Lua files (WoWTranslate_all.lua skipped as build artifact; Glossary data files anomaly-grepped only). Platform: WoW 1.12.1 / Turtle WoW, Lua 5.0.
Method: full read of every scoped file; every finding cites file:line verified against working tree. Python proxy covered by parallel audit.

## Executive summary
No code-execution primitives (no loadstring/RunScript/os.execute anywhere), no secrets handling, no network egress from Lua (all IPC is local file writes with counter-based reqIds — no path traversal). The dominant risk is **unescaped translation/glossary output being passed raw to AddMessage**, allowing chat escape-sequence injection (`|c`, `|H`, `|r`) from a compromised/malicious backend or glossary entry. The dominant correctness bug is the **language-less translation cache**. Remaining findings are low-severity robustness issues. Hook-chain hygiene (SendChatMessage chaining, origScript saved on frame, pcall guards) is solid.

## Findings

### CONFIRMED-RISK

**LUA-01 — Chat escape injection via unsanitized translation output**
- Severity: HIGH | File: WoWTranslate_Hooks.lua:611
```lua
local displayBody = bodyHex ~= "" and ("|cFF" .. bodyHex .. body .. "|r") or body
```
`body` is the proxy/API translation result, inserted raw into `AddMessage` (via `BuildWTMsg`/postFn, lines 600–735). Nothing strips WoW escape sequences from *results* — `WT_StripColorCodes` (WoWTranslate_Hyperlink.lua:375–381) is applied only to text sent *to* the API. A malicious or MITM'd backend (or a poisoned cache/glossary entry, which are persisted in SavedVariables) can emit `|cFF...`, `|Hitem:...|h[...]​|h|r`, or `|Hplayer:` sequences to forge item links, recolor/fake system-styled text, or break the `|cFF` wrapper's framing. Also reachable at:
- WoWTranslate_Hyperlink.lua:512–513 (`headerText .. WT_ReconstructMessage(...)` → AddMessage)
- WoWTranslate_Hooks.lua:720–731 (`targetFrame:AddMessage(wtMsg)` fan-out)
- WoWTranslate.lua:120 (`DEFAULT_CHAT_FRAME:AddMessage("...Result:|r " .. result)` in `/wt test`)
Fix: sanitize results with a strip/escape pass (remove `|c%x%x%x%x%x%x%x%x`, `|H...|h...|h`, stray `|r`) before any AddMessage of backend-derived text.

**LUA-02 — IPC wire format corrupted by "|" in message text**
- Severity: MEDIUM | File: WoWTranslate_API.lua:405 (and 467)
```lua
local encoded = srcLang .. "|" .. dstLang .. "|" .. text
```
Request framing uses unescaped `|`. Any translated-direction message containing a literal `|` shifts the fields the proxy parses (lang/text confusion); there is no escaping on either side. Result parsing (API.lua:562–564) tolerates pipes in the body, but the request side does not. Contract mismatch visible from Lua. Fix: length-prefix or escape pipes in `text`.

### CONFIRMED-BUG

**LUA-03 — Translation cache is language-agnostic (wrong-direction hits)**
- Severity: MEDIUM | File: WoWTranslate_Cache.lua:42–47
```lua
function WoWTranslate_CacheSave(text, translation)
    ...
        WoWTranslateCache[text] = translation
```
Keys are raw source text only — no source/target language pair (audit spec B.7). After switching `incomingToLang`/`outgoingToLang` (Config UI language selectors), `WoWTranslate_CacheGet` serves translations for the previous direction indefinitely; entries persist across sessions via SavedVariables. Fix: include langs in the cache key or purge on language change.

**LUA-04 — replaceMode pending-key collision loses the suppressed original**
- Severity: LOW | File: WoWTranslate_Hooks.lua:768
```lua
replacePendingKey = "r|" .. tostring(capturedThis) .. "|" .. capturedArg1
```
If the same frame receives the identical message twice while the first translation is still in flight, the second registration overwrites `WT_pendingMessages[key]`; when callbacks fire, only one original is flushed — in replaceMode the first original was suppressed into `wtPendingArgs` and is now unrecoverable (message permanently hidden until the 30 s cleanup timer flushes nothing, since the entry was replaced). Fix: append a monotonic counter to the key.

### SUSPECTED

**LUA-05 — Literal "auto" sent as source-language code**
- Severity: LOW | File: WoWTranslate_Tooltip.lua:637
```lua
end, "auto")
```
`WT_HookHyperlinkShow` passes `"auto"` as `fromLang`; Translate encodes it verbatim into the IPC request (`API.lua:405`). If the proxy/DLL expects a concrete language code, shift+right-click name lookups silently fail or mistranslate. Verify against the proxy's accepted values.

**LUA-06 — Placeholder reattachment pattern is spoofable**
- Severity: LOW | File: WoWTranslate_Hyperlink.lua:456
```lua
local pattern = "http[s]*[:]*[%s]*//[%s]*ph[%s%,%.]*wt[%s/]*" .. tostring(i)
```
The matcher is extremely loose (arbitrary spaces/punctuation between tokens). A remote sender can craft text such as `http : // ph , wt 1` that, once the message contains ≥1 real link, gets consumed and replaced during reconstruction — letting them delete arbitrary spans of their own translated text or splice link placement. Impact bounded (replacement content comes from the same message), but it is remote-input-driven text substitution.

**LUA-07 — Unbounded per-session guild-name map**
- Severity: LOW | File: WoWTranslate_Tooltip.lua:1075
```lua
local wtNameplateGuildByPlayer = {}
```
Grows one entry per distinct player name seen on nameplates for the whole session; never evicted (unlike the capped debug log and LRU cache). Memory-only, slow growth — hygiene issue.

### INFO

**LUA-08 — Adjacent slang tokens missed due to boundary-char consumption** — WoWTranslate_String.lua:122–141 (also 117–120). Patterns like `([^%w])88([^%w])` consume their delimiter characters, so `"88 88 88"` translates only the first token (the second match lacks a leading `[^%w]`). Cosmetic preprocessing gap; the anchored `^88$` variants cover single-token messages.

**LUA-09 — %02x on floats truncates instead of rounds** — WoWTranslate_Tooltip.lua:35 `string.format("|c%02x%02x%02x%02x", al*255, r*255, ...)`. Relies on Lua 5.0 casting doubles to int for `%x`; fractional channel values truncate (e.g. 219.5→219). Cosmetic color drift only; wrap in math.floor(+0.5) for exactness.

**LUA-10 — /wt reset drops in-flight requests without callback** — WoWTranslate_API.lua:683–694 `ClearPending()` empties `pendingRequests` without firing callbacks; replaceMode-suppressed originals therefore wait for the 30 s `WT_CleanupPendingMessages` timer (Hooks.lua:783) instead of failing fast.

**LUA-11 — Local tampering surface of IPC results (accepted trust model)** — WoWTranslate_API.lua:98–114 `ReadResult` trusts any `res_<id>.res` content for a pending id; any local process can inject translations. Consistent with the documented localhost-proxy trust model; noted for completeness.

## Clean areas (verified, no findings)
- No `loadstring`/`RunScript`/dynamic compile in any Lua file; glossary data files contain only tables + two lookup functions (anomaly grep clean).
- reqIds are internal counters (`in_N`/`out_N`) — no path traversal in IPC filenames (API.lua:83–126).
- Hook chains: SendChatMessage chain-capture/restore correct (Hooks.lua:1038–1114); chat-frame hook saves real OnEvent on the frame, pcalls origScript, restores AddMessage on both paths (Hooks.lua:478–502); LFT/hyperlink hooks save originals on stable fields with unhook support.
- SafeUTF8Truncate correctly handles continuation-byte backoff including malformed-UTF-8 edge (Hooks.lua:410–435).
- Cache has size-capped LRU eviction; debug log capped at 500.
- API has queue cap (16), timeout sweep, exponential backoff, pcall around all callbacks.

---
WAVE 1 (Lua side): 2026-08-25, scope = 10 authored Lua files, findings count = 11 (2 CONFIRMED-RISK, 2 CONFIRMED-BUG, 3 SUSPECTED, 4 INFO), clean N.

## Wave 1 remediation (applied 2026-08-25)
- LUA-01 FIXED: new WT_SanitizeDisplayText() in Hyperlink.lua; applied at all 5 AddMessage paths for backend-derived text (Hooks BuildWTMsg body, 3x ResolveNamesAndPost inputs, /wt test result).
- LUA-02 FIXED Python-side: language-code validation at proxy request intake rejects malformed framing; text-body pipes already tolerated by Lua result parser and stripped by proxy.
- LUA-03 FIXED: CacheKey now includes incomingToLang/outgoingToLang direction.
- LUA-04 FIXED: monotonic WT_pendingKeyCounter appended to replacePendingKey.
- LUA-05 FIXED proxy-side: from_lang="auto" mapped to LLM instruction ("auto-detect"), DeepL native "auto", Google sl=auto (already valid).
- LUA-06 FIXED: placeholder reattachment pattern tightened to contiguous ph.wt host.
- LUA-07 FIXED: guild-name map capped at 500 entries.
- LUA-08 NOT FIXED (cosmetic preprocessing gap; anchored variants cover single tokens) — accepted.
- LUA-09 FIXED: math.floor(+0.5) rounding on %02x color channels.
- LUA-10 FIXED: ClearPending fires dropped callbacks with "reset" error.
- LUA-11 ACCEPTED (documented localhost trust model).
All edited files pass luac -p (Lua 5.1 parse). wow_proxy.py passes py_compile.
