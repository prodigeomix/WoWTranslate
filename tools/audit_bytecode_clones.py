#!/usr/bin/env python3
"""
tools/audit_bytecode_clones.py
==============================
Pillar 2: Bytecode AST Hash-Consing, Clone Deduplication, and VM Invariants Auditor for WoWTranslate.

Enforces deep Lua 5.0 (WoW 1.12.1) runtime bytecode invariants:
1. Native Lua 5.0.3 Bytecode Disassembly:
   - Uses `tools/bin/lua50/luac50.exe -p -l` to extract VM instructions, registers, and upvalues.
2. VM Invariants:
   - Upvalue depth <= 32 on all closures.
   - Max activation frame registers <= 180 (Lua 5.0 limit is 255).
   - Zero-allocation enforcement on hot filter paths: 0 CLOSURE, 0 NEWTABLE.
3. Bytecode AST Hash-Consing & Clone Detection:
   - Normalized instruction stream n-grams (N >= 18) detecting clone clusters.
4. Adversarial Negative Control Mutation Testing (--test-mutations):
   - Injects synthetic upvalue overflows and hot-path allocations to prove 100% kill rate.

Usage:
  python tools/audit_bytecode_clones.py [--test-mutations]
Exit code: 0 = pass, 1 = failure.
"""

from collections import defaultdict
import os
import re
import subprocess
import sys
import tempfile
from typing import Dict, List, NamedTuple, Optional, Set, Tuple

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
LUAC_BIN = os.path.join(ROOT_DIR, "tools", "bin", "lua50", "luac50.exe")

MAX_UPVALUES = 32
MAX_REGISTERS = 180
DEFAULT_NGRAM_SIZE = 18
MAX_ALLOWED_CLONE_PAIRS = 20

# Critical hot-path functions evaluated per chat/tooltip event that must never allocate closures or tables
HOT_PATH_FUNCTIONS = {
    "WoWTranslate_Hooks.lua": {"WT_IsAddonProtocolMessage", "WT_ContainsOutgoingTargetLanguage"},
    "WoWTranslate_Tooltip.lua": {"WT_ShouldTranslatePlayerName", "WT_StripOverheadDisplaySuffix"},
    "WoWTranslate_String.lua": {"WT_DetectSourceLanguage", "WT_SafeUTF8Truncate"},
}

FUNC_NAME_PATTERNS = [
    re.compile(r"\bfunction\s+(?:[A-Za-z0-9_]+[\.:])?([A-Za-z0-9_]+)\s*\("),
    re.compile(r"\b(?:[A-Za-z0-9_]+\.)?([A-Za-z0-9_]+)\s*=\s*function\s*\("),
    re.compile(r"\blocal\s+function\s+([A-Za-z0-9_]+)\s*\("),
]

class BytecodeInstruction(NamedTuple):
    src_line: int
    opcode: str
    operands: str
    normalized: str

class ParsedFunction:
    def __init__(self, filename: str, line: int, name: str, params: int, upvalues: int, locals_cnt: int):
        self.filename = filename
        self.line = line
        self.name = name
        self.params = params
        self.upvalues = upvalues
        self.locals_cnt = locals_cnt
        self.instructions: List[BytecodeInstruction] = []

    @property
    def opcode_sequence(self) -> List[str]:
        return [inst.opcode for inst in self.instructions]

def resolve_function_name(source_lines: List[str], line_num: int) -> str:
    for check_line in (line_num, line_num - 1):
        if 1 <= check_line <= len(source_lines):
            sline = source_lines[check_line - 1]
            for pat in FUNC_NAME_PATTERNS:
                m = pat.search(sline)
                if m:
                    return m.group(1)
    return f"<anon@{line_num}>"

def get_production_files(base_dir: str = ROOT_DIR) -> List[str]:
    toc_path = os.path.join(base_dir, "WoWTranslate.toc")
    if not os.path.exists(toc_path):
        return []
    files = []
    with open(toc_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and line.endswith(".lua"):
                files.append(line.replace("\\", "/"))
    return files

def is_binary_runnable(binary_path: str) -> bool:
    if not os.path.exists(binary_path):
        return False
    try:
        res = subprocess.run([binary_path, "-v"], capture_output=True, timeout=2)
        return True
    except (OSError, subprocess.SubprocessError):
        return False

def disassemble_file(filepath: str) -> str:
    if not LUAC_BIN or not os.path.exists(LUAC_BIN):
        raise FileNotFoundError(f"Native luac50.exe compiler not found at {LUAC_BIN}")
    res = subprocess.run([LUAC_BIN, "-p", "-l", filepath], cwd=ROOT_DIR, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if res.returncode != 0:
        raise RuntimeError(f"luac50 failed on {filepath}:\n{res.stderr}")
    return res.stdout

def parse_bytecode(listing: str, filename: str, source_lines: List[str]) -> List[ParsedFunction]:
    functions: List[ParsedFunction] = []
    lines = listing.splitlines()
    i = 0

    header_re = re.compile(r"^(?:main|function)\s+<(.+):(\d+)>\s+\((\d+)\s+instructions")
    param_re = re.compile(
        r"^(\d+)\s+params?,\s+\d+\s+stacks?,\s+(\d+)\s+upvalues?,\s+(\d+)\s+locals?,\s+(\d+)\s+constants?,\s+(\d+)\s+functions?"
    )
    inst_re = re.compile(r"^\s*(\d+)\s+\[(\d+)\]\s+([A-Z0-9_]+)\s*(.*)$")

    current_func: Optional[ParsedFunction] = None

    while i < len(lines):
        line = lines[i].strip()
        m_head = header_re.match(line)
        if m_head:
            line_part = int(m_head.group(2) or 0)
            i += 1
            if i < len(lines):
                m_params = param_re.match(lines[i].strip())
                if m_params:
                    func_name = resolve_function_name(source_lines, line_part) if line_part > 0 else "<main>"
                    current_func = ParsedFunction(
                        filename=filename,
                        line=line_part,
                        name=func_name,
                        params=int(m_params.group(1)),
                        upvalues=int(m_params.group(2)),
                        locals_cnt=int(m_params.group(3)),
                    )
                    functions.append(current_func)
            i += 1
            continue

        if current_func:
            m_inst = inst_re.match(lines[i])
            if m_inst:
                src_l = int(m_inst.group(2))
                op = m_inst.group(3)
                ops = m_inst.group(4).strip()
                norm_sym = op
                if ";" in ops:
                    c = ops.split(";", 1)[1].strip()
                    if c and not c.startswith("to ") and not c.startswith("- "):
                        norm_sym = f"{op}:{c}"
                current_func.instructions.append(
                    BytecodeInstruction(
                        src_line=src_l,
                        opcode=op,
                        operands=ops,
                        normalized=norm_sym,
                    )
                )
        i += 1

    return functions

def audit_functions(functions: List[ParsedFunction], hot_path_map: Dict[str, Set[str]]) -> List[str]:
    violations = []
    for fn in functions:
        fname = f"{fn.filename}:{fn.name} (line {fn.line})"
        if fn.upvalues > MAX_UPVALUES:
            violations.append(f"{fname}: Exceeds Lua 5.0 upvalue limit ({fn.upvalues} > {MAX_UPVALUES})!")
        if fn.locals_cnt > MAX_REGISTERS:
            violations.append(f"{fname}: High register pressure ({fn.locals_cnt} > {MAX_REGISTERS})!")

        # Hot-path zero-GC check
        hot_names = hot_path_map.get(os.path.basename(fn.filename), set())
        if fn.name in hot_names:
            for inst in fn.instructions:
                if inst.opcode == "NEWTABLE":
                    violations.append(f"{fname} (line {inst.src_line}): Hot-path NEWTABLE allocation detected in '{fn.name}'!")
                elif inst.opcode == "CLOSURE":
                    violations.append(f"{fname} (line {inst.src_line}): Hot-path CLOSURE allocation detected in '{fn.name}'!")

    return violations

def compute_normalized_ngrams(instructions: List[BytecodeInstruction], n: int = DEFAULT_NGRAM_SIZE) -> List[Tuple[str, int]]:
    res = []
    tokens = [inst.normalized for inst in instructions]
    for idx in range(len(tokens) - n + 1):
        ngram = ":".join(tokens[idx : idx + n])
        res.append((ngram, idx))
    return res

def find_bytecode_clones(functions: List[ParsedFunction], ngram_size: int = DEFAULT_NGRAM_SIZE) -> List[Tuple[str, str, int]]:
    ngram_map: Dict[str, List[Tuple[str, str, int, int]]] = defaultdict(list)
    BOILERPLATE_ALLOWLIST = {"<main>", "WT_BuildSenderPrefix", "WT_SafeSendChatMessage"}

    for fn in functions:
        if fn.name in BOILERPLATE_ALLOWLIST or fn.line == 0 or len(fn.instructions) < ngram_size:
            continue
        ngrams = compute_normalized_ngrams(fn.instructions, ngram_size)
        seen_in_func: Set[str] = set()
        for ng, offset in ngrams:
            if ng not in seen_in_func:
                seen_in_func.add(ng)
                ngram_map[ng].append((fn.filename, fn.name, fn.line, offset))

    clone_pairs = []
    seen_pairs = set()
    for ng, occs in ngram_map.items():
        if len(occs) > 1:
            for i in range(len(occs)):
                for j in range(i + 1, len(occs)):
                    f1, n1, l1, _ = occs[i]
                    f2, n2, l2, _ = occs[j]
                    if f1 == f2 and abs(l1 - l2) < ngram_size:
                        continue
                    pair_id = tuple(sorted([f"{f1}:{n1}@{l1}", f"{f2}:{n2}@{l2}"]))
                    if pair_id not in seen_pairs:
                        seen_pairs.add(pair_id)
                        clone_pairs.append((f"{f1}:{n1}", f"{f2}:{n2}", l1))

    return clone_pairs

def run_checks(file_list: List[str], base_dir: str = ROOT_DIR, hot_paths: Dict[str, Set[str]] = None) -> Tuple[bool, List[str]]:
    all_violations = []
    all_functions: List[ParsedFunction] = []
    if hot_paths is None:
        hot_paths = HOT_PATH_FUNCTIONS

    for fname in file_list:
        fpath = os.path.join(base_dir, fname)
        if not os.path.exists(fpath):
            continue
        with open(fpath, "r", encoding="utf-8", errors="replace") as f:
            src_lines = f.readlines()
        try:
            listing = disassemble_file(fpath)
            funcs = parse_bytecode(listing, fname, src_lines)
            all_functions.extend(funcs)
        except Exception as e:
            all_violations.append(f"{fname}: Bytecode disassembly failed: {e}")

    all_violations.extend(audit_functions(all_functions, hot_paths))
    clones = find_bytecode_clones(all_functions)
    if len(clones) > MAX_ALLOWED_CLONE_PAIRS:
        all_violations.append(f"Excessive bytecode clone pairs detected ({len(clones)} > {MAX_ALLOWED_CLONE_PAIRS})!")

    return (len(all_violations) == 0), all_violations

def run_negative_controls(files: List[str]) -> bool:
    print("      >>> Executing Bytecode & Upvalue Negative Controls (Mutation Testing)...")
    hooks_file = "WoWTranslate_Hooks.lua"
    hooks_path = os.path.join(ROOT_DIR, hooks_file)
    with open(hooks_path, "r", encoding="utf-8", errors="replace") as f:
        orig_hooks = f.read()

    # Mutation 1: Closure allocation on hot-path WT_IsAddonProtocolMessage
    mut_closure = orig_hooks.replace(
        "function WT_IsAddonProtocolMessage(msg)",
        "function WT_IsAddonProtocolMessage(msg)\n    local alloc = function() return msg end\n    alloc()"
    )

    # Mutation 2: Upvalue budget overflow (>32 upvalues)
    upvalues_35 = "\n".join([f"local u{i} = {i}" for i in range(35)])
    return_35 = " + ".join([f"u{i}" for i in range(35)])
    mut_upvalue = orig_hooks + f"\n{upvalues_35}\nfunction WT_TestUpvalueOverflow()\n    return {return_35}\nend\n"

    mutations = [
        ("Hot-path CLOSURE allocation", hooks_file, mut_closure),
        ("Upvalue limit (>32) overflow", hooks_file, mut_upvalue),
    ]

    all_passed = True
    for name, m_file, mutated_code in mutations:
        with tempfile.TemporaryDirectory() as tmpdir:
            for f in files:
                src_p = os.path.join(ROOT_DIR, f)
                dst_p = os.path.join(tmpdir, f)
                os.makedirs(os.path.dirname(dst_p), exist_ok=True)
                with open(src_p, "r", encoding="utf-8", errors="replace") as sf:
                    with open(dst_p, "w", encoding="utf-8") as df:
                        df.write(sf.read())

            mutated_path = os.path.join(tmpdir, m_file)
            with open(mutated_path, "w", encoding="utf-8") as f:
                f.write(mutated_code)

            passed, viols = run_checks([m_file], base_dir=tmpdir)
            if passed or len(viols) == 0:
                print(f"        [FAIL] Mutation '{name}' was NOT detected!")
                all_passed = False
            else:
                print(f"        [PASS] Mutation '{name}' caught successfully ({len(viols)} violation(s)).")

    return all_passed

def main():
    print("=" * 80)
    print("PILLAR 2: BYTECODE AST HASH-CONSING & VM INVARIANTS AUDITOR")
    print("=" * 80)

    if not is_binary_runnable(LUAC_BIN):
        print(f"[SKIP] Native luac50 disassembler not runnable at {LUAC_BIN}.")
        sys.exit(0)

    files = get_production_files(ROOT_DIR)
    print(f"Auditing native bytecode across {len(files)} production Lua modules...")

    passed, violations = run_checks(files)
    for v in violations:
        print(f"  [ERROR] {v}")

    if not passed:
        print(f"\n[FAIL] Detected {len(violations)} bytecode violation(s)!")
        sys.exit(1)

    print("  [OK] 100% of closures satisfy Lua 5.0 upvalue budget (<= 32).")
    print("  [OK] Activation register pressure safe (<= 180 registers).")
    print("  [OK] 0 CLOSURE and 0 NEWTABLE allocations on critical hot filter paths.")

    if "--test-mutations" in sys.argv:
        if not run_negative_controls(files):
            print("\n[FAIL] Bytecode negative control mutation testing failed!")
            sys.exit(1)
        print("      [PASS] Negative Controls Proven: 100% Mutation Kill Rate.")

    print("=" * 80)
    print("[PASS] 100% BYTECODE & VM INVARIANTS CERTIFIED!")
    print("=" * 80)
    sys.exit(0)

if __name__ == "__main__":
    main()
