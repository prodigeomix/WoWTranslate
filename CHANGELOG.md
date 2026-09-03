# 📜 WoWTranslate Changelog

All notable changes, fixes, and improvements to **WoWTranslate** are documented in this file.

## [v3.6.1] - 2026-09-03

### ⚡ Performance & Default Model Optimization (Qwen 2.5 3B)
- **Qwen 2.5 3B Default Engine**: Preconfigured `model = "qwen2.5:3b"` across [config.toml](file:///c:/Games/Interface/AddOns/WoWTranslate/config.toml), [wow_proxy.py](file:///c:/Games/Interface/AddOns/WoWTranslate/wow_proxy.py), and [README.md](file:///c:/Games/Interface/AddOns/WoWTranslate/README.md).
  - Drops VRAM allocation from ~5.5 GB (7B) down to ~2.2 GB (3B), completely preventing GPU memory paging when World of Warcraft is running.
  - Slashes inference latency to **200ms – 400ms** on consumer gaming GPUs.
  - Aligned quickstart documentation so the 1-click command pulls `qwen2.5:3b`, eliminating previous `404 Not Found` model tag mismatches.

### 🔴 Core Engine Hardening
- **SuperWoW & IPC Disk Hygiene**: Enhanced periodic cleanup in [wow_proxy.py](file:///c:/Games/Interface/AddOns/WoWTranslate/wow_proxy.py) to remove abandoned SuperWoW `res_*.txt` files in `Imports/` and orphaned `.tmp` files older than `stale_ttl`, preventing disk buildup across long gaming sessions.
- **ReplaceMode Message Recovery on Queue Rejection**: Fixed an edge-case in [WoWTranslate_Hooks.lua](file:///c:/Games/Interface/AddOns/WoWTranslate/WoWTranslate_Hooks.lua) where incoming chat suppressed in `replaceMode` was lost if `WoWTranslate_API.Translate()` rejected the request (e.g., during queue saturation or rate limits). Added immediate fallback rendering from `replacePendingData`.
- **SavedVariables Cache Order Sanitation**: In [WoWTranslate_Cache.lua](file:///c:/Games/Interface/AddOns/WoWTranslate/WoWTranslate_Cache.lua), added automatic purging of orphaned keys in `WoWTranslateCacheOrder` during LRU eviction to prevent disk inflation of `SavedVariables.lua`.
- **Cloud Backend Configuration Templates**: Added ready-to-use commented configurations for Google Gemini (`gemini-2.5-flash`), DeepL, and OpenAI (`gpt-4o-mini`) in [config.toml](file:///c:/Games/Interface/AddOns/WoWTranslate/config.toml).

### 🧪 Test Suite & Audit Expansion
- **Comprehensive Test Expansion**: Added test suites to [tools/test_wowtranslate.py](file:///c:/Games/Interface/AddOns/WoWTranslate/tools/test_wowtranslate.py) (now 24/24 tests passing) covering hyperlink sanitization, directional cache key isolation, atomic Windows `.tmp` replacement, and dual SuperWoW/LuaIO periodic IPC cleanup.
- **Forensic Audit Certified**: Documented full 5-subsystem forensic audit findings in [docs/forensic_code_audit_v3.6.0.md](file:///c:/Games/Interface/AddOns/WoWTranslate/docs/forensic_code_audit_v3.6.0.md).

---

## [v3.6.0] - 2026-09-01

### 🟢 New Feature — Spanish Source Language & Incoming Translation Support
- **Spanish Source Language Checkbox**: Added **Spanish** (`es`) to the *"Translate incoming from:"* source language selection row in [WoWTranslate_Config.lua](file:///c:/Games/Interface/AddOns/WoWTranslate/WoWTranslate_Config.lua).
- **Accented & Extended Latin Detection**: Implemented robust UTF-8 and extended ASCII byte recognition in `WT_DetectSourceLanguage()` and `WT_ContainsLanguageChars()` in [WoWTranslate_String.lua](file:///c:/Games/Interface/AddOns/WoWTranslate/WoWTranslate_String.lua) for Spanish vowels and punctuation (`á, é, í, ó, ú, ü, ñ, Á, É, Í, Ó, Ú, Ü, Ñ, ¿, ¡`).
- **Spanish MMO Gaming Vocabulary Engine**: Built `WT_SPANISH_WORDS` and `WT_ContainsSpanishWords()` recognizing unaccented Spanish gaming chat, LFG keywords, greetings, question terms, group finding phrases, and role requests (e.g. `hola`, `buenas`, `busco grupo`, `mazmorra`, `estancia`, `necesito tanque`, `sanador`, `mision`, `hermandad`, `ayuda`, `listos`).
- **SavedVariables & Settings Persistence**: Initialized `enabledSourceLangs.es = false` in `WT_defaults` ([WoWTranslate_Globals.lua](file:///c:/Games/Interface/AddOns/WoWTranslate/WoWTranslate_Globals.lua)) and `WT_InitializeSettings` ([WoWTranslate.lua](file:///c:/Games/Interface/AddOns/WoWTranslate/WoWTranslate.lua)).
- **Unit Test Suite & Audit Expansion**: Added `TestSpanishLanguageDetection` to [tools/test_wowtranslate.py](file:///c:/Games/Interface/AddOns/WoWTranslate/tools/test_wowtranslate.py) covering accented Spanish, unaccented gaming chat, English isolation, toggle disable states, and SQLite database storage.

### 🟡 Forensic Audit & Repository Modernization
- **Strict Lua 5.0 & TOC Verification**: All 12 Lua files verified strictly compliant with Lua 5.0 and WoW 1.12.1 client engine constraints.
- **Synchronized Versioning**: Bumped all addon headers, proxy constants, test runners, and configuration banners to `v3.6.0`.

### 💬 Community & Acknowledgments
- **Special Thanks**: Huge shoutout to **ninja_tabby** for requesting and inspiring full Spanish ➔ English translation support!

---

## [v3.5.10] - 2026-08-30

### 🔴 Critical Fixes — Chat Tab Routing & Channel Isolation
- **Separate Chat Tab Channel Isolation**: Fixed a race-condition bug where incoming translated messages from channels configured exclusively on separate chat tabs (such as `/world` or `/trade` on `ChatFrame3`) were leaking and spilling over into `DEFAULT_CHAT_FRAME` (`ChatFrame1`).
- **Direct Frame Closure Dispatching**: Replaced the global `WT_frameTranslationTargets` lookup table with direct dispatching to `capturedThis` (the `ChatFrame` instance captured in the frame's `OnEvent` closure). Removed the legacy fallback `else DEFAULT_CHAT_FRAME:AddMessage(wtMsg)` that was erroneously triggered when deduplicated async callbacks completed.
- **Multi-Tab Channel Subscription**: Maintained request deduplication in `WoWTranslate_API.Translate()` so when multiple tabs subscribe to the same channel, each frame receives the translated message exactly once with zero cross-frame leakage.

---

## [v3.5.9] - 2026-08-29

### 🔴 Critical Fixes — Clickable Hyperlinks in Translated Chat
- **Hyperlink Sanitization Ordering Fix**: Restructured incoming message pipeline in `WoWTranslate_Hooks.lua` and item cache queue in `WoWTranslate_Hyperlink.lua`. The display sanitizer (`WT_SanitizeDisplayText`) now sanitizes raw backend translation text *before* hyperlink reconstruction replaces placeholders with genuine `|Hitem:...|h[Name]|h|r` sequences, rather than running across the reconstructed message. This prevents `|H` link metadata from being stripped and ensures item, quest, and player links in translated chat remain **100% clickable** in-game.

### 🟢 Out-of-the-Box Configuration & Defaults
- **Optimal Default Settings**: Preconfigured `WT_defaults` in `WoWTranslate_Globals.lua` and `WT_InitializeSettings` in `WoWTranslate.lua` to enable Player Name Translation (`translatePlayerNames = true`), Guild Name Translation (`translateGuildNames = true`), Nameplate Overlays (`translateNameplates = true`), LFT Group Finder (`translateGroupFinder = true`), and the Hardcore chat channel (`incomingChannels.HARDCORE = true`) by default. New installations immediately enjoy the full feature set without manual menu configuration.

### 🟡 Proxy Reliability & Startup Hardening
- **Batch Script Error-Handling & Pause**: Hardened `start_proxy.bat` with exit code verification (`if %ERRORLEVEL% NEQ 0 pause`). Prevents the terminal window from silently and immediately closing if Python encounters a runtime startup error, permission issue, or port conflict.

---

## [v3.5.8] - 2026-08-28

### 🔴 Critical Fixes — SuperWoW UTF-8 Truncation & Proxy Decode Crash
- **SuperWoW Export Buffer Truncation Prevention**: Added `WT_SafeUTF8Truncate()` in `WoWTranslate_String.lua` which walks backward over multi-byte sequences (2-, 3-, and 4-byte UTF-8 sequences). Incoming chat messages are now safely capped at 280 bytes (`zh|en|` wire prefix + 280 bytes = ~286 bytes max), and `WriteRequest` in `WoWTranslate_API.lua` enforces a 300-byte cap before `ExportFile`. This prevents SuperWoW's internal 320-byte (`0x140`) buffer from ever severing multi-byte Chinese/Japanese/Korean characters mid-byte at offset 319.
- **Proxy Resilient Binary Intake**: Switched `wow_proxy.py` request file reading from strict text mode to binary reading (`open(req_path, "rb")`) with `decode("utf-8", errors="replace").rstrip("\ufffd")`. Eliminates `UnicodeDecodeError: 'utf-8' codec can't decode byte 0xe7 in position 319` crashes, ensuring requests are always gracefully decoded and translated even if trailing bytes were clipped.

### 🟡 Wave-5 Forensic Audit & Test Suite
- **Turtle WoW 1.18.1 & Vanilla 1.12.1 Glossary Enrichment**: Expanded incoming (`WoWTranslate_Glossary.lua`, 1,594 entries) and outgoing (`WoWTranslate_OutGlossary.lua`, 572 entries) glossaries with full coverage for custom Turtle 1.18.1 content:
  - **Survival Tents & Rested XP**: `帐篷` $\to$ `Tent`, `搭帐篷`/`扎帐篷` $\to$ `Pitch Tent`, `蹭帐篷` $\to$ `Rest in Tent`, `双倍经验` $\to$ `Rested XP`, tent location calls.
  - **Custom 1.18.x Geography & Instances**: `泰拉比姆`/`香蕉岛` $\to$ `Tel'Abim`, `卡拉赞地穴` $\to$ `Karazhan Crypts`, `拉皮迪斯岛` $\to$ `Lapidis Isle`, `吉利吉姆岛` $\to$ `Gillijim's Isle`, `血月岛` $\to$ `Bloodmoon Isle`, `黑石桥` $\to$ `Blackstone Span`, `便携集合石` $\to$ `Portable Meeting Stone`, `幻化` $\to$ `Transmog`.
  - **Dungeon & Gameplay Slang**: `自强`/`自强队` $\to$ `Self-reliant leveling`, `AA`/`AA队` $\to$ `AoE spellcleave`, `带刷`/`带小号` $\to$ `Dungeon boost`, `老板` $\to$ `Buyer`, `摸奖` $\to$ `Rare drop run`, `贡品` $\to$ `DM Tribute run`, `刷马` $\to$ `Baron mount run`, `救元帅` $\to$ `Rescue Windsor`, `包正义` $\to$ `Hand of Justice reserved`, `发糖` $\to$ `Healthstone`, `拉人` $\to$ `Summon`, `战复` $\to$ `Combat res`, `干涉` $\to$ `Divine Intervention`, `分金` $\to$ `Gold split`.
- **LFG Role & Recruitment Translation**: Added pattern preprocessing and glossary mappings for Chinese group recruitment shorthand (`来TND` $\to$ `LF Tank Healer DPS`, `来TN` $\to$ `LF Tank & Healer`, `来TD` $\to$ `LF Tank & DPS`, `来ND` $\to$ `LF Healer & DPS`, `来T` $\to$ `LF Tank`, `来N` $\to$ `LF Healer`, `TND` $\to$ `Tank/Healer/DPS`, `奶妈`/`治疗` $\to$ `Healer`, `坦克` $\to$ `Tank`). Added explicit role translation rules to LLM system prompts in `wow_proxy.py`.
- **Hardened Multi-byte Truncation Fallbacks**: Reinforced local fallback in `WoWTranslate_Hooks.lua` and `WoWTranslate_API.lua` with a self-contained multi-byte walkback loop ensuring UTF-8 characters can never be split regardless of load order.
- **Outgoing Backend Translation Sanitization**: Sanitized backend translation output before hyperlink reconstruction in `WoWTranslate_Hooks.lua`, eliminating escape injection vectors while preserving clickable player item links.
- **`/wt test` and `/wt testout` Flow Fix**: Fixed test commands in `WoWTranslate.lua` to only short-circuit on full exact glossary matches, ensuring test sentences with isolated terms (e.g. `MC`) properly flow through to the translation API backend.
- **Automated Audit Test Suite & Toolchain**: Added `tools/run_audit_checks.py`, `tools/validate_lua50.py`, `tools/check_lua.py`, and `tools/test_wowtranslate.py` containing 8 comprehensive verification suites (Lua 5.0 opcode checks, TOC order validation, Python compilation, UTF-8 truncation vectors, SuperWoW wire framing, static security sweep, config validation, and unit tests).
- **Top 0.1% GitHub Automation & Community Governance**: Added `.github/workflows/ci.yml` (Python 3.10/3.11/3.12 test matrix), interactive GitHub Issue Forms (`bug_report.yml`, `feature_request.yml`, `config.yml`), Pull Request template (`pull_request_template.md`), `CONTRIBUTING.md`, `SECURITY.md`, and updated `.gitignore`.
- **Audit Documentation**: Formal Wave 5 Unified Forensic Audit Report documented in `docs/audit_findings_v5.md` (0 CONFIRMED findings, all components certified clean).

---

## [v3.5.7] - 2026-08-25

### 🔴 Security — Chat Injection Closure (audit waves 2–3)
- **6th AddMessage Path Sanitized (LUA-12, HIGH)**: `WT_ProcessItemCacheMessage` now runs `WT_SanitizeDisplayText` on every display path (no-translatable-content, cache hit, API success, API-error fallback) — item-link messages can no longer carry backend-injected WoW escape sequences (`|c`, `|H...|h`, `|T`).
- **Non-Chat Surfaces Sanitized (LUA-13, MED)**: Backend-derived text is stripped of escape sequences on tooltip guild/rank lines, chat sender-prefix name/guild, nameplate overlay names, right-click player name lookup, and `/wt testout` output.
- **Error-Path Wire Sanitization (P2-01, LOW)**: Proxy IPC result pipe-replacement (`|` → `/`) now applies to error bodies too, not just successful translations, so an error message containing `|` cannot corrupt the single-line `status|body` wire format.

### 🟠 Correctness
- **Incoming Target Language Fixed (LUA-14, MED)**: Incoming requests read `incomingToLang` (the field the config UI actually writes) instead of the never-written `targetLang` — incoming target language was silently pinned to English regardless of settings.

### 🟡 Audit Documentation
- Full forensic audit reports for waves 1–4 added under `docs/`: security + correctness findings with file:line citations, fix verification, and wave logs. Both Python proxy and Lua loops closed CLEAN (proxy wave 3, Lua wave 4).
- **LUA-18 Closure**: Sanitized the three remaining backend-derived display surfaces found in wave 3 — LFT widget text, tooltip/chat display names (`WT_MarkTranslatedDisplayName`), and nameplate guild lines (`WT_FormatNameplateGuildLine`).

---

## [v3.5.6] - 2026-08-25

### 🔴 Security & Correctness Remediation (audit wave 1)

**Lua addon side:**
- **Chat Escape Injection Fix (LUA-01)**: New `WT_SanitizeDisplayText()` strips all WoW escape sequences from backend-derived text; applied at the 5 main `AddMessage` paths.
- **Direction-Aware Cache (LUA-03)**: Translation cache keys now include language direction — no stale wrong-direction hits after switching languages.
- **Pending-Key Collision Fix (LUA-04)**: Monotonic counter appended to replacement pending-keys.
- **`/wt reset` Flush (LUA-10)**: ClearPending fires dropped callbacks with a "reset" error instead of leaving suppressed originals hidden.
- Guild-name map capped at 500 entries (LUA-07); color channel rounding fixed (LUA-09); auto language mapping for LLM/DeepL backends (LUA-05).

**Python proxy:**
- **IPC Wire Sanitization (P-01)**: Newlines/control chars flattened before result writes; results written atomically (tmp + replace).
- **In-Flight Protection (P-02)**: Scanner no longer deletes requests being processed by workers.
- **Language-Code Validation (P-05/P-06)**: Intake regex validation plus URL parameter quoting on Google endpoints.
- **Config-Fallback Warning (P-03)**: Loud warning when malformed config activates the external Google fallback.
- Ollama health-probe lock (P-10); wow-root existence check before IPC directory creation (P-13).

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
