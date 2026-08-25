# 📜 WoWTranslate Changelog

All notable changes, fixes, and improvements to **WoWTranslate** are documented in this file.

---

## [v3.5.5] - 2026-08-25

### 🔴 Critical Bug Fixes & Data-Corruption Prevention
- **Wire Format Pipe Sanitization**: Sanitized raw pipe (`|` $\rightarrow$ `/`) characters in translation results proxy-side (`translate`, `_write_ipc_result`, `store_http_result`), preventing wire protocol splitting errors and truncated translations during UnitXP and File IPC polling.
- **Progress Counter Masking**: Masked numeric counters (`(%d+)%s*/%s*(%d+)`) before slang/currency rewriting and unmasked them after in `WT_PreprocessIncoming`. Progress counters like `11/30`, `1/30`, `0/8`, and `999/1000` are now completely preserved instead of being rewritten to slang.
- **Incoming Language Preprocessing Gating**: Gated `WT_PreprocessIncoming` in `WT_ProcessSegmentsIncoming` to run only when `detectedLang == "zh"`, ensuring Russian, Japanese, and Korean messages are not modified by Chinese pinyin/slang rules.
- **`/wt out` Command Alias**: Added `/wt out [on|off]` alias in `WoWTranslate.lua` alongside `/wt outgoing`.
- **Apostrophe Regex Fix**: Fixed broken regex `r"'%s+(\w)"` $\rightarrow$ `r"'\s+(\w)"` in `wow_proxy.py` so apostrophe space artifacts (e.g. `doesn' t` $\rightarrow$ `doesn't`) are properly cleaned up.
- **Accurate Japanese Kana Detection**: Disambiguated UTF-8 lead byte `227` (0xE3) by checking the 2nd byte (`0x81..0x83` for Hiragana/Katakana vs `0x80` for CJK punctuation). Japanese messages mixing Kanji and Kana are now accurately detected as Japanese (`ja`) instead of Chinese (`zh`).

### 🟠 Medium & Stability Hardening
- **SQLite Concurrency & WAL Mode**: Enabled `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=5000` on database connections to prevent SQLite lockups under concurrent multi-threaded worker load.
- **Ollama Error Reporting**: Captured the initial `/api/chat` exception and preserved both chat and generate error messages if the fallback endpoint fails.
- **Gemini Backend Hardening**:
  - Removed non-existent `gemini-3.6-flash` model.
  - Switched authentication to use the `x-goog-api-key` header rather than URL query parameters.
  - Added `safetySettings` with `BLOCK_NONE` thresholds to prevent false moderation blocks on combat/game chat.
- **Tooltip Hook Safety**: Made `WT_HookGameTooltip` and `WT_HookItemRefTooltip` idempotent with early return guards (`if GameTooltip.WoWTranslateTooltipHooked then return end`), preventing third-party tooltip wrappers from being clobbered during `PLAYER_LOGIN`.
- **Glossary Collision Cleanup**: Removed ambiguous 2-3 letter Latin acronyms (`AH`/`ah` for Wailing Caverns, `HS`/`hs` for UBRS, `XD`/`xd` for Druid, `NTR`/`ntr` for Tauren) from the incoming glossary to avoid collisions with Auction House, Hearthstone, emoticons, and slang.
- **Punctuation Semantics Preservation**: Replaced flattening of `.`, `!`, `?` into commas with clean fullwidth normalization (`。` $\rightarrow$ `. `, `！` $\rightarrow$ `! `, `？` $\rightarrow$ `? `).
- **English Source Language Setting**: Updated `WT_DetectSourceLanguage` to respect `enabledSourceLangs.en` toggle in config.
- **Unified Versioning**: Synchronized all addon headers, chat greetings, and configuration titles to `v3.5.5`.

### 🟡 Improvements & Documentation
- **Anonymous Nameplate FontStrings**: Switched nameplate guild text creation to anonymous FontStrings to prevent global `_G["WoWTranslateNameplateGuild"]` collisions.
- **Setting Synchronization**: Fixed `translationColorFollow` default setting in `WT_InitializeSettings` to match `WT_defaults.translationColorFollow = true`.
- **Help Command Expansion**: Added `/wt out [on|off]`, `/wt diag`, `/wt transport`, and `/wt hooktest` to `/wt` command help output.
- **README Accuracy**: Corrected privacy phrasing to "local-first, with optional cloud fallback", fixed hardcoded local `file:///` links, clarified cache vs. inference latency, and noted model aliases.

---

## [v3.5.4] - 2026-08-25
- Upgraded LLM prompts for MMO slang and intent translation.
- Added support for game terms, coordinates, player name preservation, and URL placeholders.

## [v3.5.3] - 2026-08-25
- Fixed Lua `invalid key for 'next'` error during concurrent message processing.

## [v3.5.2] - 2026-08-25
- Enhanced Ollama model selection guide and config troubleshooting.

## [v3.5.1] - 2026-08-25
- Upgraded Ollama backend to native chat endpoint (`/api/chat`).
- Fixed empty responses and improved keep-alive session management.
