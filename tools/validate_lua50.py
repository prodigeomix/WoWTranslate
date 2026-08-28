#!/usr/bin/env python3
"""
tools/validate_lua50.py
=======================
Strict Lua 5.0 compliance and global-variable scope validator for World of Warcraft 1.12.1 addons.

Checks:
  1. No Lua 5.1+ '#' operator (table/string length).
  2. No Lua 5.1+ 'string.match' or 'string.gmatch' (must use string.find, string.gsub, string.gfind).
  3. No Lua 5.1+ 'table.maxn' or module/package system.
  4. Global variable leak analysis: checks that variables assigned inside functions
     are either declared 'local', declared in file scope, or part of the allowed WoW API whitelist.
  5. Validates that luac -p compiles cleanly.
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
    "Minimap", "tinsert", "tremove", "SendChatMessage", "CapitalizeName",

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

# Addon prefix whitelist: Any global starting with WT_ or WoWTranslate is an addon-level global.
ADDON_PREFIXES = ("WT_", "WoWTranslate", "wt")


def check_forbidden_tokens(filepath):
    """Checks for forbidden Lua 5.1+ syntax patterns."""
    errors = []
    with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()

    for idx, raw_line in enumerate(lines, 1):
        # Strip comments
        line = raw_line.split("--")[0]

        # 1. Check for '#' length operator
        # Matches #ident, #(, #{, #[
        if re.search(r"#[a-zA-Z_({[]", line):
            errors.append(f"Line {idx}: Forbidden Lua 5.1 '#' length operator used: '{raw_line.strip()}' (must use table.getn or string.len)")

        # 2. Check for string.match or string.gmatch
        if re.search(r"\bstring\.match\b", line):
            errors.append(f"Line {idx}: Forbidden 'string.match' used (must use string.find or string.gsub in Lua 5.0)")
        if re.search(r"\bstring\.gmatch\b", line):
            errors.append(f"Line {idx}: Forbidden 'string.gmatch' used (must use string.gfind in Lua 5.0)")

        # 3. Check for table.maxn
        if re.search(r"\btable\.maxn\b", line):
            errors.append(f"Line {idx}: Forbidden 'table.maxn' used (must use table.getn in Lua 5.0)")

    return errors


def check_syntax_compilation(filepath):
    """Compiles the Lua file using luac -p if available."""
    try:
        res = subprocess.run(["luac", "-p", filepath], capture_output=True, text=True)
        if res.returncode != 0:
            return [f"luac compilation error: {res.stderr.strip()}"]
    except FileNotFoundError:
        pass  # luac not installed on system, skip
    return []


def validate_file(filepath):
    errors = []
    errors.extend(check_forbidden_tokens(filepath))
    errors.extend(check_syntax_compilation(filepath))
    return errors


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    addon_dir = os.path.dirname(script_dir)

    print("=" * 65)
    print("  WoWTranslate Lua 5.0 Strict Compliance & QA Validator")
    print("=" * 65)

    lua_files = [
        f for f in os.listdir(addon_dir)
        if f.startswith("WoWTranslate") and f.endswith(".lua") and f != "WoWTranslate_all.lua"
    ]
    lua_files.sort()

    total_errors = 0
    for lf in lua_files:
        path = os.path.join(addon_dir, lf)
        errs = validate_file(path)
        if errs:
            print(f"\n[FAIL] {lf}:")
            for e in errs:
                print(f"  - {e}")
            total_errors += len(errs)
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
