#!/usr/bin/env python3
"""
tools/assert_version_concordance.py
===================================
Asserts 100% version concordance across:
  - WoWTranslate.toc (## Version: X.Y.Z)
  - WoWTranslate_Globals.lua (WT_VERSION = "X.Y.Z")
  - wow_proxy.py (VERSION = "X.Y.Z")
  - CHANGELOG.md (## [v?X.Y.Z])
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def main():
    toc_path = os.path.join(ROOT, "WoWTranslate.toc")
    globals_path = os.path.join(ROOT, "WoWTranslate_Globals.lua")
    proxy_path = os.path.join(ROOT, "wow_proxy.py")
    cl_path = os.path.join(ROOT, "CHANGELOG.md")

    # 1. TOC Version
    with open(toc_path, "r", encoding="utf-8") as f:
        toc_match = re.search(r"^## Version:\s*(.+)$", f.read(), re.M)
        assert toc_match, "WoWTranslate.toc missing ## Version:"
        toc_v = toc_match.group(1).strip()

    # 2. Lua Globals Version
    with open(globals_path, "r", encoding="utf-8") as f:
        lua_match = re.search(r'WT_VERSION\s*=\s*["\']([^"\']+)["\']', f.read())
        assert lua_match, "WoWTranslate_Globals.lua missing WT_VERSION"
        lua_v = lua_match.group(1).strip()

    # 3. Python Proxy Version
    with open(proxy_path, "r", encoding="utf-8") as f:
        proxy_match = re.search(r'VERSION\s*=\s*["\']([^"\']+)["\']', f.read())
        assert proxy_match, "wow_proxy.py missing VERSION"
        proxy_v = proxy_match.group(1).strip()

    # 4. CHANGELOG Latest Version
    with open(cl_path, "r", encoding="utf-8") as f:
        cl_match = re.search(r"^##\s*\[v?([^\]]+)\]", f.read(), re.M)
        assert cl_match, "CHANGELOG.md missing ## [version]"
        cl_v = cl_match.group(1).strip()

    proposed_tag = "v" + toc_v

    print("================================================================================")
    print("VERSION CONCORDANCE ASSERTION AUDIT")
    print("================================================================================")
    print(f"  WoWTranslate.toc:          {toc_v}")
    print(f"  WoWTranslate_Globals.lua:  {lua_v}")
    print(f"  wow_proxy.py:              {proxy_v}")
    print(f"  CHANGELOG.md:              {cl_v}")
    print(f"  Proposed Git Tag:          {proposed_tag}")
    print("--------------------------------------------------------------------------------")

    if not (toc_v == lua_v == proxy_v == cl_v):
        print(f"[FAIL] Version mismatch detected: TOC={toc_v}, LUA={lua_v}, PROXY={proxy_v}, CHANGELOG={cl_v}")
        sys.exit(1)

    print("[PASS] 100% Version Concordance Validated Across All Repositories!")
    return proposed_tag

if __name__ == "__main__":
    main()
