#!/usr/bin/env python3
"""
tools/package_addon.py
======================
Automated release packager and packaging hygiene validator for WoWTranslate.
Ensures zero developer tooling, zero tests, zero dev databases, and zero dotfiles
contaminate end-user release ZIPs, strictly conforming to the
'Release Packaging Hygiene & Developer Tool Exclusion' discipline.
"""

import os
import sys
import zipfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON_NAME = "WoWTranslate"
OUTPUT_ZIP = os.path.join(ROOT_DIR, f"{ADDON_NAME}.zip")

# Allowed root auxiliary runtime files for WoWTranslate distribution
WHITELIST_EXTRA = {
    "wow_proxy.py",
    "start_proxy.bat",
    "start_proxy.sh",
    "config.toml",
    "README.md",
    "LICENSE",
}

# Forbidden substrings anywhere in archive paths
FORBIDDEN_SUBSTRINGS = [
    "tools/",
    "tests/",
    "docs/",
    "__pycache__",
    ".git",
    ".agents",
    ".github",
    "translations.db",
    "agents.md",
    "handoff.md",
    ".editorconfig",
]

# Forbidden file extensions in release package (except wow_proxy.py)
FORBIDDEN_EXTENSIONS = {".exe", ".dll", ".tmp", ".pyc", ".db", ".log", ".patch"}


def get_whitelisted_files():
    """Returns list of relative files that belong in the distribution."""
    toc_path = os.path.join(ROOT_DIR, f"{ADDON_NAME}.toc")
    if not os.path.exists(toc_path):
        raise FileNotFoundError(f"Missing {toc_path}")

    files = [f"{ADDON_NAME}.toc"]
    with open(toc_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                mod_file = line.replace("\\", "/")
                if os.path.exists(os.path.join(ROOT_DIR, mod_file)):
                    if mod_file not in files:
                        files.append(mod_file)

    for extra in WHITELIST_EXTRA:
        if os.path.exists(os.path.join(ROOT_DIR, extra)) and extra not in files:
            files.append(extra)

    return sorted(files)


def build_package():
    files_to_pack = get_whitelisted_files()
    print("================================================================================")
    print(f"PACKAGING RELEASE ARTIFACT: {ADDON_NAME}.zip")
    print("================================================================================")
    print(f"Target Addon Root:  {ROOT_DIR}")
    print(f"Output Archive:     {OUTPUT_ZIP}")
    print(f"Whitelisted files ({len(files_to_pack)}):")
    for f in files_to_pack:
        print(f"  + {ADDON_NAME}/{f}")

    if os.path.exists(OUTPUT_ZIP):
        os.remove(OUTPUT_ZIP)

    with zipfile.ZipFile(OUTPUT_ZIP, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in files_to_pack:
            disk_path = os.path.join(ROOT_DIR, f)
            archive_path = f"{ADDON_NAME}/{f}"
            zf.write(disk_path, archive_path)

    print(f"\nCreated {OUTPUT_ZIP} ({os.path.getsize(OUTPUT_ZIP):,} bytes)")
    return OUTPUT_ZIP


def audit_package(zip_path):
    print("\n================================================================================")
    print("RELEASE PACKAGING HYGIENE AUDIT")
    print("================================================================================")

    with zipfile.ZipFile(zip_path, "r") as zf:
        entries = zf.namelist()
        total_entries = len(entries)
        print(f"Inspecting {total_entries} entries in archive...")

        violations = []
        for entry in entries:
            # Check 1: Root directory invariant
            if not entry.startswith(f"{ADDON_NAME}/"):
                violations.append(f"Root path violation (must start with {ADDON_NAME}/): {entry}")

            # Check 2: Forbidden substrings
            entry_lower = entry.lower()
            for forbidden in FORBIDDEN_SUBSTRINGS:
                if forbidden in entry_lower:
                    violations.append(f"Forbidden directory/component '{forbidden}' in: {entry}")

            # Check 3: Forbidden extensions
            _, ext = os.path.splitext(entry)
            if ext.lower() in FORBIDDEN_EXTENSIONS:
                violations.append(f"Forbidden file extension '{ext}' in: {entry}")

            # Check 4: Python scripts - strictly only wow_proxy.py allowed
            if ext.lower() == ".py" and os.path.basename(entry) != "wow_proxy.py":
                violations.append(f"Non-runtime python script in archive: {entry}")

        if violations:
            print("[FAIL] Packaging Hygiene Violations Found:")
            for v in violations:
                print(f"  - {v}")
            sys.exit(1)

        print("[PASS] 100% Release Packaging Hygiene Verified!")
        print(f"  • Zero developer tools/ or tests/ directories")
        print(f"  • Zero developer databases (translations.db)")
        print(f"  • Zero dotfiles (.git, .agents, .github, .editorconfig)")
        print(f"  • Zero developer documentation (AGENTS.md, HANDOFF.md)")
        print(f"  • Client root folder strictly '{ADDON_NAME}/'")
        print("--------------------------------------------------------------------------------")
        print("Final Release Archive Manifest:")
        for info in zf.infolist():
            print(f"  {info.filename:<40} | {info.file_size:>8,} B | {info.compress_size:>8,} B (deflated)")
        print("================================================================================")
        return True


if __name__ == "__main__":
    archive = build_package()
    audit_package(archive)
