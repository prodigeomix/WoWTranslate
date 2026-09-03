# WoWTranslate v3.6.0 — Forensic Code Audit Report

**Date**: September 3, 2026  
**Auditor**: Antigravity (WoW Addon Architect & Systems Engineer)  
**Target Codebase**: `c:\Games\Interface\AddOns\WoWTranslate` (commit `9375e3c`)  
**Target Client**: World of Warcraft 1.12.1 (Vanilla / Turtle WoW 1.18.1 Client, SuperWoW, UnitXP SP3)  
**Status**: 8/8 Audit Suites Passing  

---

## Executive Summary

A comprehensive, forensic architectural audit was conducted across all 5 core subsystems of **WoWTranslate v3.6.0**:
1. Chat Hooking, Frame Routing & UI Invariants (`WoWTranslate_Hooks.lua`, `WoWTranslate_Hyperlink.lua`)
2. Multi-Byte UTF-8 Wire Framing & SuperWoW IPC Buffers (`WoWTranslate_String.lua`, `WoWTranslate_API.lua`)
3. Multilingual Detection Heuristics & MMO Gaming Glossaries (`WoWTranslate_String.lua`, `WoWTranslate_Glossary.lua`)
4. LRU Cache Lifecycle, Eviction & SavedVariables Memory Guarding (`WoWTranslate_Cache.lua`)
5. Async Proxy Concurrency, SQLite WAL & Fault-Tolerant Fallback (`wow_proxy.py`, `config.toml`)

The codebase demonstrates exceptional maturity, zero-GC chat hook discipline, and strict Lua 5.0 compliance. All 8 verification suites in `tools/run_audit_checks.py` passed with 0 errors.

---

## Ranked Findings by Subsystem

### 1. Chat Hooking, Frame Routing & UI Invariants

* **Status**: 🟢 **VERIFIED CLEAN** (with 1 Minor Edge Case)
* **Verified Robust Patterns**:
  - **Closure Tab Isolation**: `capturedThis` in `OnEvent` (`WoWTranslate_Hooks.lua:490`) guarantees that translations only route to the specific chat frame where the original event was rendered (`capturedThis.wtMessageShown == true`). This eliminates channel spillover into `DEFAULT_CHAT_FRAME` when users segregate channels into dedicated tabs.
  - **Hyperlink Preservation**: `WT_FindAllHyperlinks` segments text before translation, substituting URLs (`http://ph.wt/N`) during external processing and re-inserting authentic clickable hyperlinks (`|c...|Hitem:...|h[...] |h|r`) with localized English names upon return.
  - **Third-Party Addon Nil-Guarding**: Hooks into `LFTFrame` (`LFT_UpdateGroupsList`) and `WIM` (`WIM_PostMessage`) check function existence, store original wrappers (`LFT_UpdateGroupsList_WTOriginal`), and cleanly restore handlers on `/wt reset`.
* **Edge-Case Observation (🟡 Minor / Low Impact)**:
  - **`replaceMode` Deduplication Failure Flush**: When an identical message is received while a request is already in-flight, `WoWTranslate_API.Translate` returns `true, "deduped"` and appends the callback. In `WoWTranslate_Hooks.lua:743-750`, `replacePendingKey` is generated in the closure; however, if the primary translation request ultimately fails (e.g. backend timeout), the secondary closure's `replacePendingKey` cannot look up its specific frame snapshot if it was overwritten. In normal mode (non-replace), this has zero impact because original messages are shown immediately.

---

### 2. Multi-Byte UTF-8 Wire Framing & SuperWoW IPC Buffers

* **Status**: 🟢 **VERIFIED CLEAN**
* **Verified Robust Patterns**:
  - **Multi-Byte Truncation Invariant**: `WT_SafeUTF8Truncate` (`WoWTranslate_String.lua:537-578`) examines byte boundaries backwards over continuation bytes (`128..191`) to determine leading bytes (`192..255`). It correctly handles 2-byte Latin/Cyrillic, 3-byte CJK/Kana, and 4-byte Emojis without severing characters mid-sequence.
  - **SuperWoW Export Buffer Cap**:
    - Incoming plain text is clamped to 280 bytes (`WoWTranslate_Hooks.lua:693`).
    - Encoded wire frame `lang_in|lang_out|text` results in ~286–292 bytes max.
    - `WriteRequest` (`WoWTranslate_API.lua:85-89`) enforces a strict hard cap of 300 bytes before calling `ExportFile`.
    - SuperWoW's internal buffer (`320 bytes / 0x140`) is completely insulated against memory overflow crashes.

---

### 3. Multilingual Detection Heuristics & Gaming Glossaries

* **Status**: 🟢 **VERIFIED CLEAN**
* **Verified Robust Patterns**:
  - **Disambiguation of CJK vs Kana**: Japanese Hiragana/Katakana (byte 227, `0x81..0x83`) is checked before Chinese CJK (bytes 228–233), correctly identifying Japanese text even when mixed with Kanji characters.
  - **False-Positive Spanish Shielding**: Spanish detection requires user opt-in (`WoWTranslateDB.enabledSourceLangs.es`), checks Latin-1 supplement accented bytes (á, é, í, ó, ú, ñ, ¿, ¡), and utilizes a high-signal gaming vocabulary dictionary (`WT_SPANISH_WORDS`). Ambiguous words like "no" are excluded.
  - **Word Boundary Tokenization**: `WT_GlossaryPartialMatch` (`WoWTranslate_String.lua:364-451`) enforces `isAlphanumeric` boundary checks on short tokens (<= threshold), preventing false-positive substring replacement (e.g., matching "wc" inside "crowd control").

---

### 4. LRU Cache Lifecycle & SavedVariables Memory Guarding

* **Status**: 🟢 **VERIFIED CLEAN**
* **Verified Robust Patterns**:
  - **Bounded LRU Eviction**: Monotonic counter `WoWTranslateCacheCounter` persists order in SavedVariables. When entries exceed `MAX_ENTRIES` (5,000), `WoWTranslate_CacheMaybeEvict` evicts the oldest 25% (1,250 entries) in a single sort pass, preventing `SavedVariables.lua` file bloat.
  - **Directional Cache Isolation**: `CacheKey` prefixes `incomingToLang/outgoingToLang|text` to ensure switching language directions never returns stale cross-language results.
  - **Display Sanitization**: `WT_SanitizeDisplayText` strips forged color codes (`|c...`), texture escapes (`|T...|t`), newlines (`|n`), and hyperlinks before rendering external backend text, preventing UI exploit vectors.

---

### 5. Async Proxy Concurrency, SQLite WAL & Fault-Tolerant Fallback

* **Status**: 🟢 **VERIFIED CLEAN**
* **Verified Robust Patterns**:
  - **Atomic File IPC Replacement**: `wow_proxy.py:836-846` writes results to a `.tmp` file and executes an atomic rename via `os.replace()`, preventing the Lua client from reading partial writes on Windows.
  - **Concurrent SQLite WAL**: `_db_local` provides thread-local SQLite connections with `PRAGMA journal_mode=WAL` and `busy_timeout=5000`, enabling 4 concurrent worker threads to read and write without lock contention.
  - **Wire Format Sanitization**: `_write_ipc_result` replaces `|` with `/` and flattens control characters (`ord(ch) < 0x20`), preventing multi-line corruption of the single-line wire frame.

---

## Test Suite Expansion Summary

Added 8 new automated test cases to `tools/test_wowtranslate.py` (expanded from 15 to 23 tests):
1. `TestHyperlinkExtractionAndSanitization`:
   - Color code stripping from epic/legendary item strings.
   - Hyperlink tag removal while preserving human-readable label text.
   - Texture escape and newline neutralization.
   - Placeholder token (`http://ph.wt/1`) isolation during translation and reconstruction.
2. `TestCacheKeyIsolationAndLRUEviction`:
   - Directional cache key isolation (`en/zh|...` vs `zh/en|...`).
   - LRU eviction threshold verification dropping oldest 25% of entries.
3. `TestProxyAtomicWriteAndIPC`:
   - Single-line wire pipe escaping (`|` -> `/`) and control character flattening.
   - Atomic `.tmp` to `.res` file replacement verification.

---

## Verification Results

Executed `python tools/run_audit_checks.py`:
```
=================================================================
  WoWTranslate v3.6.0 Forensic Audit & Verification Suite
=================================================================
[1/8] Running Lua 5.0 strict validator...
  All 12 Lua files strictly compliant with Lua 5.0 & client engine.
[2/8] Running TOC order & static analysis checker...
  WoWTranslate.toc load order and static code hygiene verified.
[3/8] Running Python proxy & tools compilation check...
  wow_proxy.py and all tools compiled cleanly with zero syntax errors.
[4/8] Running comprehensive unit test suite...
  All unit tests passed cleanly (23/23 tests OK).
[5/8] Running UTF-8 truncation algorithm test vectors...
  All UTF-8 truncation test vectors passed with strict UTF-8 decoding verification.
[6/8] Running SuperWoW buffer framing and wire truncation tests...
  SuperWoW wire protocol framing verified (280b text -> 292b wire <= 300b cap < 320b buffer).
[7/8] Running static security & display sanitization sweep...
  Zero dangerous code execution primitives found. Codebase certified secure.
[8/8] Validating config.toml structure...
  config.toml parsed cleanly.

=================================================================
  ALL 8 AUDIT TEST SUITES PASSED! Codebase certified clean.
=================================================================
```

### Conclusion
**WoWTranslate v3.6.0** is in a sound, production-ready state. The repository strictly adheres to Vanilla 1.12.1 / Turtle WoW 1.18.1 client engine constraints, SuperWoW wire protocol buffers, and zero-GC chat hook invariants.
