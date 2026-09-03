# Workspace Isolation & Project Boundary Rule

## 1. Strict Workspace Boundary
- **Active Workspace**: `c:\Games\Interface\AddOns\WoWTranslate` (prodigeomix/WoWTranslate).
- All file reads, code searches, file modifications, and command executions (`run_command`) MUST remain strictly within this repository.
- **FORBIDDEN**:
  - Traversal to parent directories (`c:\Games\Interface\AddOns\`) or inspection of sibling directories (`PriestBiS`, `HolyPriest`, `DiscPriest`, etc.).
  - Running commands with `Cwd` set to any path outside `WoWTranslate`.
  - Reading loose prompt files or scripts outside `WoWTranslate`.

## 2. Ignore Unrelated Conversation Memory & Summaries
- Context provided in `<conversation_summaries>` from prior conversations in other repositories (e.g. healing engines, gear rating addons, item classification) MUST be completely ignored.
- Treat `WoWTranslate` as a fully isolated, standalone codebase.

## 3. Domain Boundary
- `WoWTranslate` is strictly focused on:
  - In-game real-time chat translation across multiple languages (Spanish, Russian, Chinese, English, etc.).
  - Vanilla 1.12.1 / Turtle WoW chat event hooks and frame routing.
  - Asynchronous IPC / SQLite translation proxy (`wow_proxy.py`).
  - Strict Lua 5.0 compatibility and zero memory leak standards for chat processing.
