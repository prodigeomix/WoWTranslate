#!/usr/bin/env python3
"""
tools/audit_bytecode.py
=======================
Native Lua 5.0.3 Bytecode, Upvalue Budget (<=32), and Compilation Auditor for WoWTranslate.
Uses tools/bin/lua50/luac50.exe -p -l to inspect bytecode chunks across all production Lua modules.
"""

import os
import re
import subprocess
import sys

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUAC_BIN = os.path.join(ROOT_DIR, "tools", "bin", "lua50", "luac50.exe")

MAX_LUA50_UPVALUES = 32

def get_production_files():
    toc_path = os.path.join(ROOT_DIR, "WoWTranslate.toc")
    files = []
    with open(toc_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and line.endswith(".lua"):
                files.append(line.replace("\\", "/"))
    return files

def audit_file(rel_path):
    full_path = os.path.join(ROOT_DIR, rel_path)
    if not os.path.exists(full_path):
        return [f"File not found: {rel_path}"]

    if not os.path.exists(LUAC_BIN):
        return [f"luac50 binary not found at: {LUAC_BIN}"]

    cmd = [LUAC_BIN, "-p", "-l", rel_path]
    res = subprocess.run(cmd, cwd=ROOT_DIR, capture_output=True, text=True, encoding="utf-8", errors="replace", check=False)
    if res.returncode != 0:
        return [f"Native luac50 compilation failed on {rel_path}: {res.stderr.strip()}"]

    errors = []
    # Parse function header lines:
    # function <WoWTranslate.lua:588> (36 instructions, 144 bytes at 00E0B740)
    # 0 params, 7 stacks, 1 upvalue, 5 locals, 10 constants, 0 functions
    header_pattern = re.compile(
        r"function\s+<([^:>]+):(\d+)>\s+\((\d+)\s+instructions[^\)]*\)\s*\n"
        r"(\d+)\s+params,\s+(\d+)\s+stacks,\s+(\d+)\s+upvalues?,\s+(\d+)\s+locals",
        re.MULTILINE,
    )

    for m in header_pattern.finditer(res.stdout):
        fname = m.group(1)
        line = m.group(2)
        instructions = int(m.group(3))
        params = int(m.group(4))
        stacks = int(m.group(5))
        upvalues = int(m.group(6))
        locals_cnt = int(m.group(7))

        if upvalues > MAX_LUA50_UPVALUES:
            errors.append(
                f"{rel_path}:{line} closure exceeds Lua 5.0 upvalue limit ({upvalues} > {MAX_LUA50_UPVALUES})"
            )

    return errors

def is_binary_runnable(binary_path: str) -> bool:
    if not os.path.exists(binary_path):
        return False
    try:
        res = subprocess.run([binary_path, "-v"], capture_output=True, timeout=2)
        return True
    except (OSError, subprocess.SubprocessError):
        return False

def audit_all():
    files = get_production_files()
    print("================================================================================")
    print("LUA 5.0.3 NATIVE BYTECODE & UPVALUE BUDGET AUDITOR")
    print("================================================================================")
    if not is_binary_runnable(LUAC_BIN):
        print(f"Disassembler: {LUAC_BIN} (not runnable in this environment)")
        print("[SKIP] Local luac50.exe binary not runnable; skipping native bytecode audit.")
        return True

    print(f"Disassembler: {LUAC_BIN}")
    print(f"Auditing {len(files)} production Lua modules...")

    all_errors = {}
    for f in files:
        errs = audit_file(f)
        if errs:
            all_errors[f] = errs

    if all_errors:
        print("[FAIL] Bytecode Audit Violations Detected:")
        for f, errs in all_errors.items():
            print(f"  {f}:")
            for e in errs:
                print(f"    - {e}")
        return False

    print(f"[PASS] All {len(files)} Lua modules compiled natively and satisfy Lua 5.0 upvalue budget (<=32)!")
    return True

if __name__ == "__main__":
    success = audit_all()
    sys.exit(0 if success else 1)
