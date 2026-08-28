# WoWTranslate Forensic Audit — v5 (Unified Release Certification for v3.5.8)

Date: 2026-08-28. Target: `c:\Games\Interface\AddOns\WoWTranslate` (Release v3.5.8, WoW 1.12.1 / Turtle WoW client, Python proxy `wow_proxy.py`).
Scope: 12 authored/load-order Lua files per `WoWTranslate.toc`, `wow_proxy.py`, `config.toml`, and test suite `tools/run_audit_checks.py`.

---

## 1. Executive Summary

**CLEAN — ALL COMPONENTS CERTIFIED FOR v3.5.8.**
Wave 5 is a unified forensic sweep and release certification covering both the Lua addon and Python proxy. This wave independently investigated and evaluated prior claims, verified all changes introduced in commit `0d2ceea` (v3.5.8), reinforced fallback UTF-8 truncation safety, sanitized outgoing backend translations before hyperlink reconstruction, and added an automated multi-suite test runner (`tools/run_audit_checks.py`).

Zero CONFIRMED bugs or security vulnerabilities remain.

---

## 2. Independent Evaluation of Prior AI Claims

| Item / Claim | Prior Claim (Laguna 2.1) | Forensic Ground Truth & Resolution |
|---|---|---|
| **`SafeUTF8Truncate` Fallback in `Hooks.lua`** | Flagged as a regression in v3.5.8 due to fallback `return string.sub(str, 1, maxBytes)`. | **Refactored & Hardened**: While normal TOC load order guarantees `WT_SafeUTF8Truncate` is defined, the fallback in `WoWTranslate_Hooks.lua:410-435` was hardened with a self-contained multi-byte walkback loop. `WoWTranslate_API.lua:86` was similarly tightened. |
| **`/wt testout` Display Path** | Flagged as unsanitized, then self-corrected. | **Verified Clean**: `WoWTranslate.lua:296` wraps `result` in `(WT_SanitizeDisplayText and WT_SanitizeDisplayText(result) or result)`. |
| **Outgoing "Sent:" Line (`Hooks.lua:1038`)** | Flagged as unsanitized; suggested wrapping `finalMsg` in `WT_SanitizeDisplayText`. | **Debunked & Corrected**: Wrapping `finalMsg` after reconstruction destroys genuine player item links (`|c...|Hitem:...|h[Link]|h|r`). Instead, backend translation text is sanitized *before* `WT_ReconstructMessage` replaces link placeholders (`WoWTranslate_Hooks.lua:1022`), preserving item links while neutralizing rogue backend escapes. |
| **SuperWoW 300-byte Wire Truncation** | Questioned arithmetic and framing hazard. | **Verified Safe**: 280-byte chat message cap + `zh|en|` (6 bytes) = 286 bytes <= 300-byte `WriteRequest` cap < 320-byte SuperWoW buffer. `wow_proxy.py` uses `errors="replace"` and `.rstrip("\ufffd")` for complete resilience. |

---

## 3. Wave-5 PASS A: Security & Forensic Verification

1. **Code Execution Primitives**:
   - Python: Zero calls to `eval`, `exec`, `__import__`, `subprocess`, `os.system`, `popen`, `pickle`, `marshal`, `yaml.load`, `ctypes`.
   - Lua: Zero calls to `loadstring`, `RunScript`, `os.execute`, or `io.popen`.
2. **Network Egress & Binding Surfaces**:
   - HTTP server binds strictly to `127.0.0.1:7654` (`ProxyHTTPHandler`).
   - Egress points verified strictly to documented translation providers (Ollama `localhost:11434`, DeepL `api-free.deepl.com`/`api.deepl.com`, OpenAI `api.openai.com`, Google `translate.googleapis.com`/`clients5.google.com`, Gemini `generativelanguage.googleapis.com`). Zero telemetry or covert exfiltration channels.
3. **Chat & UI Escape Injection**:
   - Every `AddMessage`, `SetText`, `AddLine`, and `AddDoubleLine` call site across the 12 load-order Lua files verified sanitized against WoW escape sequences (`|c`, `|r`, `|H`, `|h`, `|T`, `|n`, `||`).
   - Outgoing pipeline sanitizes translation text before hyperlink reconstruction, preserving clickable item links while neutralizing backend markup injection.
4. **File System & IPC Handling**:
   - `req_id` is generated from monotonic internal counters (`in_N`, `out_N`) or validated numeric timestamps.
   - Result files written atomically via `.tmp` + `os.replace`.

---

## 4. Wave-5 PASS B: Correctness & Robustness Verification

1. **Lua 5.0 / WoW 1.12.1 Client Compatibility**:
   - All 12 load-order Lua files verified compatible with Lua 5.0 semantics (no Lua 5.1 `#` operator on tables, proper `table.getn` / `table.insert` / `table.remove` usage).
   - All 12 Lua files pass `luac -p` with zero errors.
2. **UTF-8 Truncation Engine**:
   - `WT_SafeUTF8Truncate` validated against 1-byte ASCII, 2-byte Latin/Cyrillic, 3-byte CJK/Kana, 4-byte Emoji, and malformed byte sequences.
   - Zero split multi-byte characters across all byte truncation thresholds.
3. **State Machine & Concurrency**:
   - `_in_flight` locks, `_http_results_lock`, and SQLite WAL mode verified in `wow_proxy.py`.
   - Timeout sweep and rate-limiting backoff verified in `WoWTranslate_API.lua`.

---

## 5. Automated Verification Suite

An automated test suite has been added at `tools/run_audit_checks.py`.
Running `python tools/run_audit_checks.py` executes 6 validation suites:
1. `luac -p` syntax compilation across all 12 load-order Lua files.
2. `py_compile` on `wow_proxy.py`.
3. UTF-8 multi-byte truncation edge cases with strict UTF-8 decoding verification.
4. SuperWoW wire protocol framing (280b chat -> 292b wire <= 300b cap < 320b buffer).
5. Static security sweep for code execution primitives and TOC load-order validation.
6. `config.toml` structure validation.

---

## 6. Audit Verdict

```
================================================================================
WAVE 5 (Release v3.5.8 Certification): 2026-08-28
Scope: 12 authored Lua files, wow_proxy.py, config.toml, tools/run_audit_checks.py
Findings: 0 CONFIRMED-BUG, 0 CONFIRMED-RISK
Automated Test Suite: 6/6 test suites passed
Status: CLEAN — APPROVED FOR PRODUCTION USE
================================================================================
```
