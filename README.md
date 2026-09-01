# 🌐 WoWTranslate v3.6.0 — Universal Real-Time Chat & Tooltip Translator
### World of Warcraft 1.12.1 (Vanilla / Turtle WoW Patch 1.18.1)

[![CI Build](https://github.com/prodigeomix/WoWTranslate/actions/workflows/ci.yml/badge.svg)](https://github.com/prodigeomix/WoWTranslate/actions/workflows/ci.yml)
[![Turtle WoW 1.18.1](https://img.shields.io/badge/Turtle_WoW-1.18.1-darkgreen?logo=worldofwarcraft)](https://turtle-wow.org)
[![Vanilla WoW 1.12.1](https://img.shields.io/badge/Vanilla_WoW-1.12.1-orange)](https://github.com/prodigeomix/WoWTranslate)
[![Lua 5.0 Strict](https://img.shields.io/badge/Lua_5.0-Strict_Compliant-blue?logo=lua)](tools/validate_lua50.py)
[![Tests Passing](https://img.shields.io/badge/Tests-8%2F8_Passed-brightgreen)](tools/run_audit_checks.py)
[![GitHub Sponsors](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/prodigeomix)
[![Latest Release](https://img.shields.io/github/v/release/prodigeomix/WoWTranslate?color=blue&label=Latest%20Release)](https://github.com/prodigeomix/WoWTranslate/releases/latest)
[![License](https://img.shields.io/github/license/prodigeomix/WoWTranslate?color=orange)](LICENSE)

Translate World of Warcraft chat, player names, group finder, and tooltips in real-time between **Chinese, English, Spanish, Russian, Japanese, and Korean** directly inside your game!

WoWTranslate is **local-first** using **Ollama** (your own private AI model) with optional automatic cloud fallback (Google Translate / DeepL / OpenAI). It is completely free, private, has zero monthly limits, and offers real-time translations (instant SQLite cache, ~50ms–200ms local AI inference).

---

## ⚡ Super Easy Setup (Ollama Local AI)

Follow these simple steps to get it running. No programming knowledge required!

---

### 🟢 STEP 1: Install Python (Required to run the proxy)
*(If you already have Python on your PC, you can skip to Step 2!)*

Choose **either** Method A (PowerShell) or Method B (Installer):

#### Method A: 1-Click Install via PowerShell (Automatically adds to PATH)
1. Right-click your Windows **Start menu button** and click **"Terminal"** or **"Windows PowerShell"**.
2. Copy and paste this command, then press **Enter**:
   ```powershell
   winget install Python.Python.3.12
   ```

#### Method B: Standard Python Installer (python.org)
1. Go to **[https://www.python.org/downloads/](https://www.python.org/downloads/)** and download Python for Windows.
2. Run the downloaded installer.
3. ⚠️ **CRITICAL STEP:** At the bottom of the installer window, **CHECK THE BOX**:
   > **`☑ Add python.exe to PATH`**  *(Do not forget this!)*
4. Click **Install Now**.

---

### 🟢 STEP 2: Download & Install Ollama

Choose **either** Method A (PowerShell) or Method B (Browser):

#### Method A: 1-Click Install via PowerShell (Fastest)
1. In your **PowerShell** window, paste this command and press **Enter**:
   ```powershell
   winget install Ollama.Ollama
   ```
   *(Or if winget is not installed on your Windows, copy-paste this direct download line:)*
   ```powershell
   Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile "$env:TEMP\OllamaSetup.exe"; Start-Process "$env:TEMP\OllamaSetup.exe" -Wait
   ```

#### Method B: Standard Browser Download
1. Go to **[https://ollama.com](https://ollama.com)** in your web browser.
2. Click the big **"Download for Windows"** button.
3. Run the downloaded `OllamaSetup.exe` file and click **Install**.

> **Verification:** Once installed, an Ollama llama icon will appear in your Windows bottom-right system tray (next to the clock).

---

### 🟢 STEP 3: Download the Free AI Translation Model (Using CMD / PowerShell)

To download the AI translation brain onto your computer, run a single command in **Command Prompt (CMD)** or **PowerShell**:

1. **Open Command Prompt (CMD):**
   - Press **`Windows Key + R`**, type **`cmd`**, and press **Enter**.

2. **Choose & Download ONE Model based on your PC:**

   | Model Command | Download Size | Best For | Speed | Required `config.toml` setting |
   | :--- | :--- | :--- | :--- | :--- |
   | `ollama pull qwen2.5` | ~4.7 GB | Standard / Gaming PCs (7B default) | ⚡ Fast | `model = "qwen2.5"` *(Default)* |
   | `ollama pull qwen2.5:1.5b` | ~1.0 GB | **Laptops & Older PCs** (Recommended for speed!) | 🚀 Instant | `model = "qwen2.5:1.5b"` |
   | `ollama pull qwen2.5:3b` | ~2.0 GB | Great balance of speed & quality | ⚡ Fast | `model = "qwen2.5:3b"` |
   | `ollama pull qwen2.5:0.5b` | ~400 MB | Ultra-low-end PCs / CPU only | 🚀 Instant | `model = "qwen2.5:0.5b"` |
   | `ollama pull qwen2.5:7b` | ~4.7 GB | High-end GPUs (alias for 7B default) | ⚡ Fast | `model = "qwen2.5:7b"` |

3. **Paste the command in CMD and press Enter:**
   - Example for ultra-fast performance on any PC:
     ```cmd
     ollama pull qwen2.5:1.5b
     ```
   - Wait for the download progress to reach `100%` and say **`success`**.

> ⚠️ **IMPORTANT RULE IF YOU CHOOSE A DIFFERENT MODEL:**
> If you pull a specific model tag (e.g. `qwen2.5:1.5b`, `qwen2.5:3b`, or `qwen2.5:7b`), you **must** open [`config.toml`](config.toml) and match the exact name:
> ```toml
> model = "qwen2.5:1.5b"
> ```
> *(If the name in `config.toml` doesn't match what is installed in Ollama, Ollama will return `404 Not Found` and the proxy will automatically fall back to Google Translate).*

---

### 🟢 STEP 4: Start the Translator & Play WoW!

1. Open your World of Warcraft folder:
   ```text
   World of Warcraft\Interface\AddOns\WoWTranslate\
   ```
2. Double-click **`start_proxy.bat`**.
3. A small black window will open and say:
   ```text
   ==========================================================
      WoWTranslate Universal Proxy v3.6.0
     Backends     : ['ollama', 'google']
   ==========================================================
   [proxy] Ready! Proxy is actively listening for translations.
   ```
4. **Leave this window open (minimized) while you play WoW.**
5. Launch World of Warcraft and enjoy instant translation!

---

## 🎮 How It Works In-Game

### 📥 1. Reading Foreign Chat (Chinese / Spanish / Russian → English)
- Whenever someone speaks in Chinese, Spanish, Russian, Japanese, or Korean in **Guild, Party, Raid, Whisper, Say, Yell, or World Channels**, WoWTranslate automatically translates it into English.
- The translation appears right below their message in the exact same channel color.

### 📤 2. Speaking to Foreign Players (English → Spanish / Chinese)
- Want to speak in Spanish or Chinese to other players? Turn on outgoing translation in chat or via `/wt`:
  ```text
  /wt out on
  ```
- Now type your message normally in English (e.g. `/g LF1M healer for Dire Maul then ready`).
- WoWTranslate automatically translates your message into the target language and sends it to chat!
- To turn it off later, type:
  ```text
  /wt out off
  ```

---

## 📋 In-Game Chat Commands (`/wt`)

| Command | What it does |
| :--- | :--- |
| **`/wt show`** | Opens the visual settings and options menu on your screen. |
| **`/wt hide`** | Closes the settings menu. |
| **`/wt out [on\|off]`** | Turns **ON** / **OFF** automatic English → Chinese outgoing translation. |
| **`/wt diag`** | Tests your connection to make sure the proxy and game are connected. |
| **`/wt status`** | Shows addon status, active translation backends, and cache stats. |
| **`/wt transport [proxy\|dll\|auto]`** | Selects active transport backend (SuperWoW IPC Proxy or UnitXP DLL). |
| **`/wt test <text>`** | Tests incoming translation (e.g. `/wt test 你好`). |
| **`/wt testout <text>`** | Previews an outgoing translation without sending it to public chat. |
| **`/wt reset`** | Refreshes chat frames, resets API backoff, and clears any stuck queues. |
| **`/wt clearcache`** | Clears the local translation memory cache. |
| **`/wt donate`** | Displays project support & GitHub Sponsors link. |
| **`/wt debug`** | Toggles verbose diagnostic logging. |

---

## ⚙️ Configuration (`config.toml`)

Your [`config.toml`](config.toml) is located in `Interface\AddOns\WoWTranslate\config.toml`. It is pre-configured with smart defaults:

```toml
# WoWTranslate Proxy Configuration
http_port = 7654
workers = 4
cache_db = "translations.db"
stale_ttl = 60
scan_interval = 0.05

# 1. Ollama (Local AI)
[[backends]]
type = "ollama"
url = "http://localhost:11434"
model = "qwen2.5"          # Change this to match your pulled model (e.g. "qwen2.5:1.5b" or "qwen2.5:3b")
timeout = 20
temperature = 0.0
num_predict = 256
keep_alive = "1h"

# 2. Built-in Google Web Translate (Automatic fallback if Ollama is closed or model missing)
[[backends]]
type = "google"
timeout = 8
```

> 💡 **Tip:** Whenever you edit `config.toml`, always close and re-open `start_proxy.bat` so it reloads your new settings!

---

## 🧪 Developer Verification & Quality Assurance

Maintainers and developers can verify repository compliance using our automated audit toolchain:

```bash
# Run Lua 5.0 strict syntax and opcode validator
python tools/validate_lua50.py

# Run static analysis and TOC order linter
python tools/check_lua.py

# Run core unit tests
python tools/test_wowtranslate.py

# Run full forensic audit suite
python tools/run_audit_checks.py
```

---

## ❓ Frequently Asked Questions & Troubleshooting

#### 1. Why does the proxy say `[translate] [ollama] failed: HTTP Error 404: Not Found`?
This error means Ollama is running, but the **model name in `config.toml` does not match the model installed on your PC**.
* **Fix in 2 steps:**
  1. Open Command Prompt and type:
     ```cmd
     ollama list
     ```
     Look at the exact name listed under **NAME** (e.g. `qwen2.5:1.5b`, `qwen2.5:latest`, `qwen2.5:7b`).
  2. Open `config.toml` and change `model = "..."` to match that exact name character-for-character.
  3. Close and re-open `start_proxy.bat`.
*(Note: If Ollama ever fails or 404s, WoWTranslate's built-in fallback will automatically use Google Translate so you never miss a chat message!)*

#### 2. Why do Chinese characters look like `????` on my screen?
- The default 2004 English WoW game font does not contain Chinese characters.
- **Other players with Chinese or Unicode game clients see your Chinese characters perfectly!**
- If you also want to see Chinese characters on your own screen, use an addon like **pfUI**, **ShaguTweaks**, or place a CJK-compatible font file named `FRIZQT__.TTF` inside your `World of Warcraft\Fonts\` folder.

#### 3. What happens if I forget to start Ollama or don't want to use it?
- You don't need to do anything! WoWTranslate has a built-in automatic fallback to Google Web Translate. You can also comment out the `[[backends]]` section for Ollama in `config.toml` to exclusively use Google.

#### 4. How do I know if the proxy is connected to the game?
- In game, type `/wt diag` in chat. If it says `Active Transport: SuperWoW File IPC (Proxy)` with `IO Test: PASS`, you are 100% connected!

#### 5. How fast is it?
- Translations for previously seen messages and player names load **instantly (< 1ms)** from your local SQLite cache (`translations.db`).
- Brand new messages translated by your local Ollama model take between **50ms to 200ms** depending on model size and GPU.

#### 6. How do I fix "Python is not found" or "Python not in PATH"?
If `start_proxy.bat` says Python was not found:
1. Re-run the Python installer from **[python.org/downloads](https://www.python.org/downloads/)**.
2. Click **Modify** (or uninstall and reinstall).
3. ⚠️ **Make sure to check the box:** **`☑ Add python.exe to PATH`** at the bottom of the installer!
4. *(Or simply open PowerShell and run: `winget install Python.Python.3.12` which sets up PATH automatically).*

---

## ❤️ Support & Sponsor

If you find WoWTranslate helpful in your adventures across Azeroth, consider supporting ongoing development:

[![Sponsor on GitHub](https://img.shields.io/badge/Sponsor-GitHub%20Sponsors-ea4aaa?style=for-the-badge&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/prodigeomix)

- **GitHub Sponsors**: [https://github.com/sponsors/prodigeomix](https://github.com/sponsors/prodigeomix)

Your support helps fund active maintenance, glossary expansions for custom private servers, and new language models!

---

## 📜 License
WoWTranslate is released under the [MIT License](LICENSE).
