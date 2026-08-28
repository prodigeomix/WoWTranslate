## Description

Provide a brief summary of the changes introduced in this pull request and the problem they solve.

---

## Type of Change
- [ ] 🐛 Bug fix (non-breaking change which fixes an issue)
- [ ] ✨ New feature (non-breaking change which adds functionality)
- [ ] ⚡ Performance optimization / Memory leak prevention
- [ ] 📜 Documentation or glossary update
- [ ] 🛠️ CI / Tooling improvement

---

## Client Engine & Lua 5.0 QA Checklist

- [ ] **100% Strict Lua 5.0 Compliance**:
  - No `#` length operator (used `table.getn` / `string.len`).
  - No `string.match` or `string.gmatch` (used `string.find`, `string.gsub`, or `string.gfind`).
  - No `table.maxn` or Lua 5.1+ modules.
- [ ] **Buffer Limits & Framing Safety**:
  - Chat exports safely capped (`WT_SafeUTF8Truncate` <= 280b chat / 300b wire cap < 320b SuperWoW buffer).
- [ ] **SavedVariables Sanitization**:
  - Corrupted or missing DB entries fill defaults safely without throwing runtime Lua errors.
- [ ] **Sanitization of Display Surfaces**:
  - Remote/backend-derived strings sanitized before passing to `AddMessage` or FontStrings.
- [ ] **Testing & Verification**:
  - Ran `python tools/validate_lua50.py` (Passed).
  - Ran `python tools/check_lua.py` (Passed).
  - Ran `python tools/test_wowtranslate.py` (Passed).
  - Ran `python tools/run_audit_checks.py` (Passed).
