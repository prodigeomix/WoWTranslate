# AGENTS.md — WoWTranslate Engineering Guidelines & Rules

## 1. Absolute Workspace Isolation (Strict Invariant)
- **Active Workspace**: `c:\Games\Interface\AddOns\WoWTranslate`.
- **Zero Cross-Contamination**:
  - Never inspect, search, view, or modify files in parent (`c:\Games\Interface\AddOns\`) or sibling directories (`PriestBiS`, `HolyPriest`, `DiscPriest`, etc.).
  - Disregard any context from `<conversation_summaries>` related to other addons or projects.
  - All commands (`run_command`) MUST have `Cwd` set to this repository or a subfolder.

---

## 2. Client Engine & Lua 5.0 Strict Compatibility
- **Engine**: World of Warcraft 1.12.1 (Vanilla / Turtle WoW 1.18.1).
- **Strict Lua 5.0 Compliance**:
  - **NO `#` length operator**: Use `table.getn(tbl)` or `string.len(str)`.
  - **NO `string.match` / `string.gmatch`**: Use `string.find` or `string.gsub`.
  - **NO Modulo `%` operator**: Use `math.mod(a, b)`.
  - **NO post-5.0 features**: No `select()`, `table.pack/unpack`, `//`, `goto`, `::label::`.
- **Zero-GC & Memory Safety**:
  - Hot chat event hooks (`CHAT_MSG_*`) must minimize temporary table churn.
  - Avoid creating anonymous closures inside repetitive chat filters.

---

## 3. Chat System & UI Invariants
- **Tab Routing & Spillover Prevention**:
  - Translated output must route directly to the originating chat tab frame (`capturedThis` closure in `OnEvent`), NOT broadcast globally to `DEFAULT_CHAT_FRAME` if the user routed the channel to a dedicated tab.
- **Hyperlink Preservation**:
  - Item, spell, quest, and player hyperlinks (`|c...|Hitem:...|h[...] |h|r`) must remain clickable and uncorrupted after translation formatting.
- **Wire Protocol & Buffer Limits**:
  - SuperWoW buffer framing: Respect the maximum wire cap (280b text -> 292b wire <= 300b cap < 320b client buffer).
  - Truncation must be multi-byte UTF-8 safe (never split a multi-byte sequence).

---

## 4. Asynchronous Proxy & IPC Architecture
- **Proxy**: `wow_proxy.py` operates asynchronously using SQLite (`translations.db`) with WAL mode.
- **IPC Protocol**:
  - Lua writes requests to `IPC/requests/` or polls `IPC/results/`.
  - Non-blocking file I/O and graceful fallback when proxy is offline.

---

## 5. Verification Gate (Non-Negotiable)
Before committing or completing any task, execute:
```bash
python tools/run_audit_checks.py
```
All 18 verification suites must pass with zero errors:
1. Lua 5.0 strict validator (`validate_lua50.py`)
2. TOC load order & static analysis (`check_lua.py`)
3. Python proxy & tools compilation (`py_compile`)
4. Comprehensive unit test suite (`test_wowtranslate.py`)
5. UTF-8 truncation algorithm test vectors
6. SuperWoW buffer framing & wire truncation
7. Static security & display sanitization sweep
8. config.toml structure validation
9. Version concordance assertion across TOC, Lua, Proxy, and Changelog (`assert_version_concordance.py`)
10. Lua 5.0.3 native bytecode & upvalue budget audit (`audit_bytecode.py`)
11. AST global namespace & scope leak audit (`scan_ast_globals.py`)
12. Release packaging hygiene & whitelist exclusion discipline (`package_addon.py`)
13. **Pillar 1A: Typestate Safety & Threat Model Audit** (`audit_typestate_threat.py`) with adversarial mutations proving 100% kill rate.
14. **Pillar 1B: Formal String Typestate & Information Flow Control** (`verify_typestate_formal.py`) with abstract interpretation lattice and adversarial mutations proving 100% kill rate.
15. **Pillar 2A: Bytecode AST Hash-Consing & Upvalue Budget Audit** (`audit_bytecode_clones.py`) with adversarial mutations proving 100% kill rate.
16. **Pillar 2B: Generative Property-Based Fuzzing & RFC 3629 Boundary Proof** (`fuzz_utf8_properties.py` & `.lua`) with 25,000+ permutations and native Lua 5.0 verification.
17. **Pillar 3A: Low-Level IPC Chaos Engineering & Concurrency Resilience** (`test_ipc_chaos.py`) verifying malformed write resilience, concurrent lock safety, and SQLite WAL integrity.
18. **Pillar 3B: Headless VM Zero-GC Gauntlet & SuperWoW Wire Simulation** (`test_headless_branch_coverage.py`) with 10,000-tick steady-state Delta GC == 0 KiB and adversarial mutations.
