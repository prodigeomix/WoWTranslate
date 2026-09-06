# WoWTranslate — Project Status & Handoff Document

> **Last Updated:** 2026-09-06 09:05 (Antigravity Assistant)  
> **Status:** Production Ready (v3.5.4)  
> **Target Engine:** Turtle WoW 1.18.1 / Vanilla 1.12.1 Client + External Python IPC Proxy  
> **Active Verification:** `python tools/run_audit_checks.py` → **ALL 8 SUITES PASS**

---

## 1. Current Architecture
* **Hybrid Two-Tier Architecture**:
  1. **In-Game Lua Addon (`WoWTranslate.lua`, `WoWTranslate_*.lua`)**:
     - Hooks into standard chat frames (`ChatFrame_OnEvent`), monster speech (say, yell, whisper), and quest dialogues.
     - Interacts with local IPC files in the `IPC/` directory.
     - Handles in-game cache queries (`WoWTranslate_Cache.lua`) and glossary lookups (`WoWTranslate_Glossary.lua`).
  2. **External Daemon (`wow_proxy.py`)**:
     - Multi-threaded Python service connecting to cloud translation backends (Google Cloud Translation API, Hermes / custom endpoints).
     - Maintains persistent local SQLite cache (`translations.db`) with WAL mode for microsecond lookup times.
     - Exchanges messages with the game client via atomic temporary file replacement (`os.replace`) to prevent file lock contention.
* **Test Suite (`tools/run_audit_checks.py`)**:
  - Validates Lua 5.0 compliance, UTF-8 truncation boundaries, IPC protocol serialization, and SQLite indexing.

---

## 2. Invariant Rules (DO NOT TOUCH)
1. **Atomic IPC Guarantee**: In `wow_proxy.py`, never write directly to the active `.lua` or `.ipc` files. Always write to a `.tmp` file and invoke `os.replace` to guarantee atomic file system updates.
2. **Zero UI Stuttering**: In Lua, never poll IPC files on every frame. Use a throttled timer (minimum 0.5s intervals) and limit queue batch sizes to prevent client framerate drops.
3. **API Key & Cost Isolation**: Keep translation API keys in `config.toml` (which is git-ignored). Never hardcode keys in code. Local SQLite cache must intercept repetitive guild/world chat lines before hitting cloud APIs.

---

## 3. Active Backlog & Next Steps
- [x] All 8 test suites passing cleanly (`tools/run_audit_checks.py`).
- [x] Git working tree is clean on branch `main`.
- [ ] Ensure `start_proxy.bat` is running in background before launching the WoW client.
- [ ] Monitor SQLite cache hit ratio; do not alter translation logic while active.
