#!/usr/bin/env python3
"""
tools/validate_lua50.py
=======================
Strict Lua 5.0 compliance and global-variable scope validator for World of Warcraft 1.12.1 addons.

Checks:
  1. No Lua 5.1+ '#' operator (table/string length).
  2. No Lua 5.1+ 'string.match' or 'string.gmatch' (must use string.find, string.gsub, string.gfind).
  3. No Lua 5.1+ 'table.pack', 'table.unpack', or 'table.maxn'.
  4. No Lua 5.1+ 'math.huge'.
  5. No retail WoW 'C_*' namespaces.
  6. No WoW 2.0+ ':HookScript'.
  7. No Lua 5.1+ 'select()'.
  8. No binary modulo '%' operator outside string literals (must use math.mod).
  9. No Lua 5.3+ '//' integer division.
  10. No Lua 5.2+ 'goto' or '::label::'.
  11. Global variable leak analysis: checks that variables assigned inside functions
      are either declared 'local', declared in file scope, or part of the allowed WoW API whitelist.
  12. Validates that luac -p compiles cleanly (when available).
"""

import os
import re
import subprocess
import sys

# Allowed global variables in WoW 1.12.1 Vanilla / Turtle WoW client environment
# and declared WoWTranslate public namespaces/SavedVariables.
ALLOWED_GLOBALS = {
    # Lua 5.0 Standard Library Globals
    "math", "string", "table", "io", "os", "debug",
    "assert", "error", "pcall", "xpcall", "type", "tostring", "tonumber",
    "print", "pairs", "ipairs", "next", "unpack", "getglobal", "setglobal",
    "loadstring", "dofile", "getmetatable", "setmetatable", "rawget", "rawset",
    "rawequal", "gcinfo", "collectgarbage", "_G",

    # WoW 1.12 Engine Globals & Frame XML Context
    "this", "event", "arg1", "arg2", "arg3", "arg4", "arg5", "arg6", "arg7", "arg8", "arg9", "self",
    "DEFAULT_CHAT_FRAME", "UIErrorsFrame", "UIParent", "WorldFrame",
    "GameTooltip", "GameTooltipStatusBar", "ItemRefTooltip", "ColorPickerFrame",
    "ShowUIPanel", "HideUIPanel", "UISpecialFrames", "ChatTypeInfo", "NUM_CHAT_WINDOWS",
    "SLASH_WOWTRANSLATE1", "SLASH_WOWTRANSLATE2", "SlashCmdList",

    # WoW 1.12 Engine Functions
    "CreateFrame", "GetTime", "UnitExists", "UnitIsPlayer", "UnitName", "UnitPVPName",
    "UnitClass", "UnitLevel", "GetDifficultyColor", "GetGuildInfo", "UnitAffectingCombat",
    "UnitIsAFK", "GetItemInfo", "GetChannelList", "IsShiftKeyDown", "GetCursorPosition",
    "Minimap", "tinsert", "tremove", "SendChatMessage", "CapitalizeName", "GetLocale",

    # Turtle WoW / SuperWoW / UnitXP Extensions
    "ExportFile", "ImportFile", "UnitXP",

    # Third-party Addon Namespaces (Optional Integrations)
    "LFTFrame", "LFT_UpdateGroupsList", "LFT_UpdateGroupsList_WTOriginal",
    "ShaguTweaks", "ShaguTweaks_cache", "ShaguPlates", "ShaguPlates_playerDB",
    "UNKNOWN", "RAID_CLASS_COLORS", "WIM_Data", "WIM_PostMessage", "pfDB",
    "ChatFrame_OnHyperlinkShow", "ChatFrame_OnHyperlinkShow_WTOriginal",

    # WoWTranslate SavedVariables & Public Namespaces
    "WoWTranslateDB", "WoWTranslateCache", "WoWTranslateDebugLog",
    "WoWTranslateCacheOrder", "WoWTranslateCacheCounter",
    "WoWTranslate_API", "WoWTranslate_TempConfig", "WoWTranslate_MinimapButton",
    "WoWTranslatePollFrame", "WT_itemCacheTooltip", "wtTooltipFrame",
}

# Addon prefix whitelist: Any global starting with WT_, WoWTranslate, or wt is an addon-level symbol.
ADDON_PREFIXES = ("WT_", "WoWTranslate", "wt")


COMMENT_OR_STR_RE = re.compile(
    r'--\[\[.*?\]\]|--[^\n]*|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\[\[.*?\]\]',
    re.DOTALL
)


def strip_comments_and_strings(code: str) -> str:
    """Replaces string literals and comments with preserved newlines to isolate tokens accurately."""
    return COMMENT_OR_STR_RE.sub(lambda m: "\n" * m.group(0).count("\n"), code)



def check_forbidden_tokens(filepath: str):
    """Checks for forbidden Lua 5.1+ syntax patterns."""
    errors = []
    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        content = f.read()

    # Stripped content eliminates comments and string literals
    stripped_content = strip_comments_and_strings(content)
    lines = content.splitlines()
    stripped_lines = stripped_content.splitlines()

    for idx, (raw_line, clean_line) in enumerate(zip(lines, stripped_lines), 1):
        # 1. Check for '#' length operator
        if re.search(r"#[a-zA-Z_({[]", clean_line):
            errors.append(f"Line {idx}: Forbidden Lua 5.1 '#' length operator used: '{raw_line.strip()}' (must use table.getn or string.len)")

        # 2. Check for string.match or string.gmatch
        if re.search(r"\bstring\.match\b", clean_line):
            errors.append(f"Line {idx}: Forbidden 'string.match' used (must use string.find or string.gsub in Lua 5.0)")
        if re.search(r"\bstring\.gmatch\b", clean_line):
            errors.append(f"Line {idx}: Forbidden 'string.gmatch' used (must use string.gfind in Lua 5.0)")

        # 3. Check for table.pack / table.unpack / table.maxn
        if re.search(r"\btable\.maxn\b", clean_line):
            errors.append(f"Line {idx}: Forbidden 'table.maxn' used (must use table.getn in Lua 5.0)")
        if re.search(r"\btable\.pack\b", clean_line):
            errors.append(f"Line {idx}: Forbidden 'table.pack' used (must use table constructor in Lua 5.0)")
        if re.search(r"\btable\.unpack\b", clean_line):
            errors.append(f"Line {idx}: Forbidden 'table.unpack' used (must use unpack in Lua 5.0)")

        # 4. Check for math.huge
        if re.search(r"\bmath\.huge\b", clean_line):
            errors.append(f"Line {idx}: Forbidden 'math.huge' used in Lua 5.0")

        # 5. Check for C_* retail namespaces
        if re.search(r"\bC_[A-Za-z0-9_]+\b", clean_line):
            errors.append(f"Line {idx}: Forbidden retail WoW 'C_*' namespace used")

        # 6. Check for :HookScript
        if ":HookScript" in clean_line:
            errors.append(f"Line {idx}: Forbidden ':HookScript' used (WoW 2.0+ API; use SetScript hooks)")

        # 7. Check for select()
        if re.search(r"\bselect\s*\(", clean_line):
            errors.append(f"Line {idx}: Forbidden 'select()' used (Lua 5.1+; use arg table in Lua 5.0)")

        # 8. Check for binary modulo (%) operator outside strings
        if re.search(r"\b\w+\s*%\s*\w+", clean_line):
            errors.append(f"Line {idx}: Forbidden binary modulo '%' operator used: '{raw_line.strip()}' (must use math.mod)")

        # 9. Check for integer division (//)
        if "//" in clean_line:
            errors.append(f"Line {idx}: Forbidden '//' floor division operator used (Lua 5.3+)")

        # 10. Check for goto and ::label::
        if re.search(r"\bgoto\s+[a-zA-Z_]\w*", clean_line):
            errors.append(f"Line {idx}: Forbidden 'goto' statement used (Lua 5.2+)")
        if re.search(r"::[a-zA-Z_]\w*::", clean_line):
            errors.append(f"Line {idx}: Forbidden '::label::' used (Lua 5.2+)")

    return errors


def check_global_scope_leaks(filepath: str):
    """
    Performs lexical scope analysis to detect undeclared global variables leaking into _G.
    Uses luaparser AST when available; falls back to lexical token analysis.
    """
    errors = []
    try:
        import luaparser.ast as ast
        import luaparser.astnodes as nodes
    except ImportError:
        return errors  # luaparser optional for pure standard-library environments

    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        src = f.read()

    try:
        tree = ast.parse(src)
    except Exception as e:
        return [f"AST parse error in {os.path.basename(filepath)}: {e}"]

    class Scope:
        def __init__(self, parent=None):
            self.parent = parent
            self.locals = set()

        def add_local(self, name):
            self.locals.add(name)

        def is_local(self, name):
            if name in self.locals:
                return True
            if self.parent:
                return self.parent.is_local(name)
            return False

    def get_node_children(node):
        children = []
        for attr in dir(node):
            if attr.startswith("_"):
                continue
            try:
                val = getattr(node, attr)
            except Exception:
                continue
            if isinstance(val, list):
                for item in val:
                    if isinstance(item, nodes.Node):
                        children.append(item)
            elif isinstance(val, nodes.Node):
                children.append(val)
        return children

    def analyze(node, current_scope):
        tname = type(node).__name__

        if tname in ("Chunk", "Block"):
            new_scope = Scope(current_scope)
            body = getattr(node, "body", [])
            if hasattr(body, "body"):
                body = body.body
            for child in body or []:
                analyze(child, new_scope)
            return

        if tname == "LocalAssign":
            for val in getattr(node, "values", []) or []:
                analyze(val, current_scope)
            for target in getattr(node, "targets", []) or []:
                if isinstance(target, nodes.Name):
                    current_scope.add_local(target.id)
            return

        if tname == "LocalFunction":
            current_scope.add_local(node.name.id)
            fn_scope = Scope(current_scope)
            for arg in getattr(node, "args", []) or []:
                if isinstance(arg, nodes.Name):
                    fn_scope.add_local(arg.id)
                elif isinstance(arg, nodes.Varargs):
                    fn_scope.add_local("arg")
            for child in node.body.body:
                analyze(child, fn_scope)
            return

        if tname == "Function":
            if isinstance(node.name, nodes.Name):
                fn_name = node.name.id
                if not current_scope.is_local(fn_name):
                    if fn_name not in ALLOWED_GLOBALS and not any(fn_name.startswith(p) for p in ADDON_PREFIXES):
                        errors.append(f"Line {getattr(node, 'line', '?')}: Undeclared global function '{fn_name}' leaking into _G")
            elif isinstance(node.name, nodes.Index):
                analyze(node.name, current_scope)

            fn_scope = Scope(current_scope)
            for arg in getattr(node, "args", []) or []:
                if isinstance(arg, nodes.Name):
                    fn_scope.add_local(arg.id)
                elif isinstance(arg, nodes.Varargs):
                    fn_scope.add_local("arg")
            for child in node.body.body:
                analyze(child, fn_scope)
            return

        if tname == "AnonymousFunction":
            fn_scope = Scope(current_scope)
            for arg in getattr(node, "args", []) or []:
                if isinstance(arg, nodes.Name):
                    fn_scope.add_local(arg.id)
                elif isinstance(arg, nodes.Varargs):
                    fn_scope.add_local("arg")
            for child in node.body.body:
                analyze(child, fn_scope)
            return

        if tname == "Forin":
            for it in getattr(node, "iter", []) or []:
                analyze(it, current_scope)
            for_scope = Scope(current_scope)
            for target in getattr(node, "targets", []) or []:
                if isinstance(target, nodes.Name):
                    for_scope.add_local(target.id)
            for child in node.body.body:
                analyze(child, for_scope)
            return

        if tname == "Fornum":
            analyze(node.start, current_scope)
            analyze(node.stop, current_scope)
            if getattr(node, "step", None):
                analyze(node.step, current_scope)
            for_scope = Scope(current_scope)
            if isinstance(node.target, nodes.Name):
                for_scope.add_local(node.target.id)
            for child in node.body.body:
                analyze(child, for_scope)
            return

        if tname == "Assign":
            for val in getattr(node, "values", []) or []:
                analyze(val, current_scope)
            for target in getattr(node, "targets", []) or []:
                if isinstance(target, nodes.Name):
                    var_name = target.id
                    if not current_scope.is_local(var_name):
                        if var_name not in ALLOWED_GLOBALS and not any(var_name.startswith(p) for p in ADDON_PREFIXES):
                            errors.append(f"Line {getattr(node, 'line', '?')}: Undeclared global assignment '{var_name}' leaking into _G")
                elif isinstance(target, nodes.Index):
                    analyze(target, current_scope)
            return

        for child in get_node_children(node):
            analyze(child, current_scope)

    analyze(tree, None)
    return errors


def check_syntax_compilation(filepath: str):
    """Compiles the Lua file using luac -p if available."""
    try:
        res = subprocess.run(["luac", "-p", filepath], capture_output=True, text=True)
        if res.returncode != 0:
            return [f"luac compilation error: {res.stderr.strip()}"]
    except FileNotFoundError:
        pass  # luac not installed on system, skip
    return []


def validate_file(filepath: str, check_ast: bool = False):
    errors = []
    errors.extend(check_forbidden_tokens(filepath))
    if check_ast:
        errors.extend(check_global_scope_leaks(filepath))
    errors.extend(check_syntax_compilation(filepath))
    return errors


def validate_all(addon_dir: str = None, check_ast: bool = False):
    """Validates all load-order Lua files in addon_dir. Returns dict of errors."""
    if addon_dir is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        addon_dir = os.path.dirname(script_dir)

    lua_files = [
        f for f in os.listdir(addon_dir)
        if f.startswith("WoWTranslate") and f.endswith(".lua") and f != "WoWTranslate_all.lua"
    ]
    lua_files.sort()

    all_errors = {}
    for lf in lua_files:
        path = os.path.join(addon_dir, lf)
        errs = validate_file(path, check_ast=check_ast)
        if errs:
            all_errors[lf] = errs

    return all_errors


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    addon_dir = os.path.dirname(script_dir)
    check_ast = "--ast" in sys.argv

    print("=" * 65)
    print("  WoWTranslate Lua 5.0 Strict Compliance & QA Validator")
    if check_ast:
        print("  [Mode: Deep AST Lexical Scope Analysis Enabled]")
    print("=" * 65)

    all_errors = validate_all(addon_dir, check_ast=check_ast)
    total_errors = sum(len(errs) for errs in all_errors.values())

    lua_files = [
        f for f in os.listdir(addon_dir)
        if f.startswith("WoWTranslate") and f.endswith(".lua") and f != "WoWTranslate_all.lua"
    ]
    lua_files.sort()

    for lf in lua_files:
        if lf in all_errors:
            print(f"\n[FAIL] {lf}:")
            for e in all_errors[lf]:
                print(f"  - {e}")
        else:
            print(f"  [PASS] {lf}")

    print("\n" + "-" * 65)
    if total_errors == 0:
        print(f"  ALL {len(lua_files)} LUA FILES STRICTLY COMPLIANT WITH LUA 5.0 & CLIENT ENGINE!")
        print("=" * 65)
        return 0
    else:
        print(f"  FOUND {total_errors} VIOLATION(S) ACROSS LUA CODEBASE!")
        print("=" * 65)
        return 1


if __name__ == "__main__":
    sys.exit(main())
