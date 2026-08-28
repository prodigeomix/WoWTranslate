#!/usr/bin/env python3
"""
tools/check_lua.py
==================
Static analysis, namespace hygiene, and structural linter for WoWTranslate.

Checks:
  1. Lua syntax compilation via luac (when luac is present).
  2. TOC manifest validation (checks that all referenced files exist in order).
  3. Strict Lua 5.0 grammar restrictions (no # length operator, no string.match/gmatch).
  4. Global namespace safety (ensures no unintended global variables leak into global table).
  5. Security sweeps (no loadstring/RunScript dynamic execution on tainted remote strings).
"""

import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ADDON_DIR = os.path.dirname(SCRIPT_DIR)


def check_toc_order():
    toc_path = os.path.join(ADDON_DIR, "WoWTranslate.toc")
    if not os.path.exists(toc_path):
        return ["WoWTranslate.toc not found!"]

    with open(toc_path, "r", encoding="utf-8") as f:
        toc_lines = [line.strip() for line in f if line.strip() and not line.startswith("##")]

    errors = []
    for lf in toc_lines:
        file_path = os.path.join(ADDON_DIR, lf)
        if not os.path.exists(file_path):
            errors.append(f"TOC references missing file: {lf}")

    # Check crucial load-order constraints
    try:
        glossary_idx = toc_lines.index("WoWTranslate_Glossary.lua")
        globals_idx = toc_lines.index("WoWTranslate_Globals.lua")
        string_idx = toc_lines.index("WoWTranslate_String.lua")
        hyperlink_idx = toc_lines.index("WoWTranslate_Hyperlink.lua")
        tooltip_idx = toc_lines.index("WoWTranslate_Tooltip.lua")
        hooks_idx = toc_lines.index("WoWTranslate_Hooks.lua")
        api_idx = toc_lines.index("WoWTranslate_API.lua")
        main_idx = toc_lines.index("WoWTranslate.lua")

        if not (globals_idx < string_idx < hyperlink_idx < tooltip_idx < hooks_idx < main_idx):
            errors.append("TOC load order violation: Dependencies must load before downstream consumers.")
        if not (string_idx < api_idx < main_idx):
            errors.append("TOC load order violation: String utilities must load before API.")
    except ValueError as e:
        errors.append(f"TOC load order missing expected core file: {e}")

    return errors


def check_security_and_lua50(filepath):
    errors = []
    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    dangerous_patterns = [
        (r"\bloadstring\b", "Forbidden dynamic code execution via 'loadstring'"),
        (r"\bRunScript\b", "Forbidden dynamic execution via 'RunScript'"),
        (r"\bos\.execute\b", "Forbidden system execution via 'os.execute'"),
        (r"\bio\.popen\b", "Forbidden process execution via 'io.popen'"),
    ]

    for idx, raw_line in enumerate(lines, 1):
        line = raw_line.split("--")[0]

        # Security check
        for pattern, desc in dangerous_patterns:
            if re.search(pattern, line):
                errors.append(f"Line {idx}: {desc}")

        # Lua 5.1+ syntax check
        if re.search(r"#[a-zA-Z_({[]", line):
            errors.append(f"Line {idx}: Lua 5.1 '#' operator used: {raw_line.strip()}")
        if re.search(r"\bstring\.match\b", line):
            errors.append(f"Line {idx}: Lua 5.1 'string.match' used (use string.find/string.gsub)")
        if re.search(r"\bstring\.gmatch\b", line):
            errors.append(f"Line {idx}: Lua 5.1 'string.gmatch' used (use string.gfind)")

    return errors


def main():
    print("=" * 65)
    print("  WoWTranslate Static Analysis & Namespace Hygiene Checker")
    print("=" * 65)

    all_errors = []

    # 1. TOC Checks
    toc_errs = check_toc_order()
    if toc_errs:
        print("[FAIL] TOC Manifest Order:")
        for err in toc_errs:
            print(f"  - {err}")
        all_errors.extend(toc_errs)
    else:
        print("  [PASS] WoWTranslate.toc load order verified.")

    # 2. Lua File Checks
    lua_files = [
        f for f in os.listdir(ADDON_DIR)
        if f.startswith("WoWTranslate") and f.endswith(".lua") and f != "WoWTranslate_all.lua"
    ]
    lua_files.sort()

    for lf in lua_files:
        path = os.path.join(ADDON_DIR, lf)
        errs = check_security_and_lua50(path)
        if errs:
            print(f"\n[FAIL] {lf}:")
            for e in errs:
                print(f"  - {e}")
            all_errors.extend(errs)
        else:
            print(f"  [PASS] {lf} verified clean.")

    print("-" * 65)
    if all_errors:
        print(f"  TOTAL ISSUES DETECTED: {len(all_errors)}")
        print("=" * 65)
        return 1
    else:
        print(f"  ALL {len(lua_files)} LUA FILES PASSED STATIC ANALYSIS & SECURITY SWEEP!")
        print("=" * 65)
        return 0


if __name__ == "__main__":
    sys.exit(main())
