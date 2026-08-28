# 🤝 Contributing to WoWTranslate

Thank you for your interest in contributing to **WoWTranslate**! This project aims to maintain the highest quality standards for World of Warcraft 1.12.1 (Vanilla / Turtle WoW 1.18.1).

---

## 🏛️ Lua 5.0 Engine Constraints & Coding Standards

World of Warcraft 1.12.1 runs on a **Lua 5.0.2** runtime. Modern Lua 5.1+ syntax constructs will cause hard in-game syntax errors.

### 🚫 Forbidden Patterns
1. **NO Length Operator (`#`)**:
   - ❌ `local len = #myTable` or `local len = #str`
   - ✅ `local len = table.getn(myTable)` or `local len = string.len(str)`
2. **NO `string.match` or `string.gmatch`**:
   - ❌ `local val = string.match(str, "%d+")`
   - ✅ `local _, _, val = string.find(str, "(%d+)")`
   - ❌ `for w in string.gmatch(str, "%S+") do`
   - ✅ `for w in string.gfind(str, "%S+") do`
3. **NO `table.maxn`**:
   - Use `table.getn(tbl)` or custom counting logic.
4. **NO Global Leaks**:
   - Always declare local variables with `local`.
   - Never assign variables without `local` inside functions unless intentionally writing to public addon APIs (`WT_...` / `WoWTranslate...`).

---

## 📦 Buffer Safety & UTF-8 Multi-Byte Handling

- SuperWoW's internal buffer for `ExportFile` / `ImportFile` is capped at **320 bytes (`0x140`)**.
- Always truncate strings using `WT_SafeUTF8Truncate(str, maxBytes)`.
- Never truncate strings by raw byte slices (`string.sub(str, 1, 280)`) without multi-byte walkback, as cutting a 3-byte Chinese/Japanese character or 2-byte Cyrillic character mid-byte will cause UTF-8 decode errors in the Python proxy.

---

## 🧪 Local Testing & Verification

Before submitting any Pull Request, run the automated verification suite:

```bash
# 1. Validate strict Lua 5.0 compliance
python tools/validate_lua50.py

# 2. Run static analysis and TOC order linter
python tools/check_lua.py

# 3. Run core unit tests
python tools/test_wowtranslate.py

# 4. Run the full forensic audit suite
python tools/run_audit_checks.py
```

All 8 test suites must pass with zero errors.

---

## 🚀 Pull Request Workflow

1. Fork the repository and create your branch from `main`:
   ```bash
   git checkout -b feature/my-new-feature
   ```
2. Commit your changes with clear, semantic commit messages:
   ```bash
   git commit -m "feat(glossary): add 1.18.1 zone translations"
   ```
3. Push to your branch and open a Pull Request. Fill out all sections of the Pull Request template.
