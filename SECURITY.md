# 🔒 Security Policy

## Supported Versions

| Version | Supported          | Status |
| ------- | ------------------ | ------ |
| 3.5.x   | :white_check_mark: | Active Support & Security Patches |
| < 3.5.0 | :x:                | Deprecated / End of Life |

---

## Reporting a Vulnerability

The WoWTranslate maintainers take security seriously. If you discover a potential vulnerability (such as a chat escape injection, memory exhaustion vector, or IPC path traversal issue):

1. **Do not create a public GitHub issue.**
2. Report the vulnerability privately to the project maintainers via GitHub Security Advisories or by contacting `belthazor` / `prodigeomix` directly on Discord / GitHub.
3. Please include:
   - Description of the vulnerability and its potential impact.
   - Exact steps or test vectors to reproduce.
   - Recommended fix or mitigation if known.

---

## Security Architecture & Design Principles

WoWTranslate enforces defense-in-depth security principles:
- **Zero Remote Code Execution**: No dynamic evaluation (`loadstring`, `RunScript`, `os.execute`, `io.popen`) is used on remote or backend-derived strings.
- **Display Sanitization**: All remote text is sanitized via `WT_SanitizeDisplayText` to strip malicious WoW escape sequences (`|c`, `|H...|h`, `|T`, `|n`) before rendering to chat frames, nameplates, or tooltips.
- **Local-First Privacy**: Translations default to local offline Ollama models to prevent sensitive chat messages from leaving your machine.
