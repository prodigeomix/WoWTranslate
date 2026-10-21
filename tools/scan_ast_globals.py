#!/usr/bin/env python3
"""
tools/scan_ast_globals.py
=========================
AST Scope & Global Leak Detector for WoWTranslate v3.6.8.
Adapted from HolyPriest's scan_ast_globals.py architecture.
Uses luaparser to parse Lua 5.0 AST and identify true global variable/function leaks.
"""

import os
import sys

try:
    from luaparser import ast, astnodes
except ImportError:
    print("Notice: 'luaparser' not found. Installing...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "luaparser"])
    from luaparser import ast, astnodes

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

KNOWN_GLOBALS = {
    # Standard Lua 5.0 Environment
    "math", "string", "table", "pairs", "ipairs", "next", "type", "tonumber",
    "tostring", "pcall", "getfenv", "setfenv", "getglobal", "setglobal",
    "error", "assert", "loadstring", "unpack", "setmetatable", "getmetatable",
    "rawget", "rawset", "rawequal", "gcinfo", "io", "os",

    # Blizzard WoW 1.12 C-API & Frames
    "DEFAULT_CHAT_FRAME", "UIErrorsFrame", "UIParent", "WorldFrame",
    "GameTooltip", "Minimap", "SlashCmdList", "CreateFrame", "GetTime",
    "GetBuildInfo", "GetLocale", "GetChannelList", "GetChannelName",
    "SendChatMessage", "UnitName", "UnitIsAFK", "UnitIsPlayer",
    "UnitPlayerControlled", "UnitClass", "UnitLevel", "UnitExists",
    "GetNumPartyMembers", "GetNumRaidMembers", "GetPlayerInfoByGUID",
    "GetGuildInfo", "GetItemInfo", "PlaySound", "SetCVar", "GetCVar",
    "message", "this", "event", "arg1", "arg2", "arg3", "arg4", "arg5",
    "arg6", "arg7", "arg8", "arg9", "NUM_CHAT_WINDOWS", "ChatFrameEditBox",
    "ChatFrame_OnEvent", "ChatFrame_OnHyperlinkShow", "ChatEdit_SendText", "WIM_PostMessage",
    "LFT_UpdateGroupsList",
    "UIDropDownMenu_Initialize", "UIDropDownMenu_AddButton",
    "UIDropDownMenu_SetSelectedValue", "UIDropDownMenu_SetText",
    "UIDropDownMenu_SetWidth", "ToggleDropDownMenu", "CloseDropDownMenus",
    "UIDROPDOWNMENU_MENU_LEVEL", "UIDROPDOWNMENU_MENU_VALUE",
    "GameTooltipTemplate", "UIPanelCloseButton", "hooksecurefunc",

    # SuperWoW & UnitXP C Extensions
    "ExportFile", "ImportFile", "SuperWoW", "UnitXP",

    # WoWTranslate SavedVariables & Canonical Namespaces
    "WoWTranslateDB", "WoWTranslateCache", "WoWTranslateDebugLog",
    "WoWTranslateCacheOrder", "WoWTranslateCacheCounter",
    "WoWTranslate_API", "WoWTranslate_MinimapButton_Init",
    "WoWTranslate_MinimapButton_Toggle", "WoWTranslate_CheckGlossaryExact",
    "WoWTranslate_CheckOutGlossaryExact", "WoWTranslate_CacheGet",
    "WoWTranslate_CacheSave", "WoWTranslate_SetEnabled",
    "WoWTranslate_SetIncomingTargetLang", "WoWTranslate_SetOutgoingEnabled",
    "WoWTranslate_SetOutgoingTargetLang", "WoWTranslate_SetOutgoingFromLang",
    "WoWTranslate_SetTranslateTooltips", "WoWTranslate_SetPreferredTransport",
    "WoWTranslate_SaveCache", "WoWTranslate_ClearCache",
    "WoWTranslate_ResetStats", "WoWTranslate_ApplyProfile",
    "WoWTranslate_ResolveCurrentProfile", "WoWTranslate_SetProfileMode",
    "WoWTranslate_ExportConfigString", "WoWTranslate_ImportConfigString",
}

def is_blessed_global(name: str) -> bool:
    if name in KNOWN_GLOBALS:
        return True
    if name.startswith("WT_") or name.startswith("SLASH_WOWTRANSLATE") or name.startswith("WoWTranslate"):
        return True
    if name.endswith("_WTOriginal"):
        return True
    return False

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

def get_production_files():
    toc_path = os.path.join(ROOT_DIR, "WoWTranslate.toc")
    files = []
    with open(toc_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and line.endswith(".lua"):
                files.append(line.replace("\\", "/"))
    return files

_AST_CACHE = {}

def check_file_ast(filepath):
    full_path = os.path.join(ROOT_DIR, filepath)
    mtime = os.path.getmtime(full_path) if os.path.exists(full_path) else 0
    cache_key = (filepath, mtime)
    if cache_key in _AST_CACHE:
        return list(_AST_CACHE[cache_key])

    with open(full_path, "r", encoding="utf-8") as f:
        src = f.read()

    try:
        tree = ast.parse(src)
    except Exception as e:
        return [(1, f"Failed to parse AST in {filepath}: {e}")]

    leaks = []

    def visit(node, scope):
        if isinstance(node, astnodes.Block):
            new_scope = Scope(scope)
            for stmt in node.body:
                visit(stmt, new_scope)
        elif isinstance(node, astnodes.LocalAssign):
            for target in node.targets:
                if isinstance(target, astnodes.Name):
                    scope.add_local(target.id)
            if node.values:
                for val in node.values:
                    visit(val, scope)
        elif isinstance(node, astnodes.Function):
            if isinstance(node.name, astnodes.Name):
                name = node.name.id
                if not scope.is_local(name) and not is_blessed_global(name):
                    leaks.append((getattr(node, "line", "?"), f"Global Function '{name}'"))
            new_scope = Scope(scope)
            for arg in node.args:
                if isinstance(arg, astnodes.Name):
                    new_scope.add_local(arg.id)
                elif isinstance(arg, astnodes.Varargs):
                    new_scope.add_local("arg")
            visit(node.body, new_scope)
        elif isinstance(node, astnodes.AnonymousFunction):
            new_scope = Scope(scope)
            for arg in node.args:
                if isinstance(arg, astnodes.Name):
                    new_scope.add_local(arg.id)
                elif isinstance(arg, astnodes.Varargs):
                    new_scope.add_local("arg")
            visit(node.body, new_scope)
        elif isinstance(node, astnodes.LocalFunction):
            scope.add_local(node.name.id)
            new_scope = Scope(scope)
            for arg in node.args:
                if isinstance(arg, astnodes.Name):
                    new_scope.add_local(arg.id)
                elif isinstance(arg, astnodes.Varargs):
                    new_scope.add_local("arg")
            visit(node.body, new_scope)
        elif isinstance(node, astnodes.Assign):
            for target in node.targets:
                if isinstance(target, astnodes.Name):
                    name = target.id
                    if not scope.is_local(name) and not is_blessed_global(name):
                        leaks.append((getattr(node, "line", "?"), f"Global Variable '{name}'"))
                else:
                    visit(target, scope)
            if node.values:
                for val in node.values:
                    visit(val, scope)
        elif isinstance(node, astnodes.Forin):
            new_scope = Scope(scope)
            for name in node.targets:
                if isinstance(name, astnodes.Name):
                    new_scope.add_local(name.id)
            visit(node.body, new_scope)
        elif isinstance(node, astnodes.Fornum):
            new_scope = Scope(scope)
            if isinstance(node.target, astnodes.Name):
                new_scope.add_local(node.target.id)
            visit(node.body, new_scope)
        else:
            for key, val in vars(node).items():
                if isinstance(val, list):
                    for item in val:
                        if isinstance(item, astnodes.Node):
                            visit(item, scope)
                elif isinstance(val, astnodes.Node):
                    visit(val, scope)

    root_scope = Scope()
    visit(tree, root_scope)
    _AST_CACHE[cache_key] = leaks
    return leaks

def audit_all_globals():
    files = get_production_files()
    print("================================================================================")
    print("GLOBAL NAMESPACE & AST SCOPE LEAK AUDITOR")
    print("================================================================================")
    print(f"Auditing {len(files)} production Lua modules against known globals...")

    all_leaks = {}
    total_leaks = 0
    for f in files:
        leaks = check_file_ast(f)
        if leaks:
            all_leaks[f] = leaks
            total_leaks += len(leaks)

    if all_leaks:
        print(f"[FAIL] {total_leaks} Global Scope Leak(s) Detected:")
        for f, leaks in all_leaks.items():
            print(f"  {f}:")
            for line_no, desc in leaks:
                print(f"    Line {line_no}: {desc}")
        return False

    print(f"[PASS] All {len(files)} Lua modules strictly adhere to namespace isolation (0 global leaks)!")
    return True

if __name__ == "__main__":
    success = audit_all_globals()
    sys.exit(0 if success else 1)
