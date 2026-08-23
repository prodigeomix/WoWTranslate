# 🌐 WoWTranslate v3.5 — Universal Real-Time Chat Translator
### World of Warcraft 1.12.1 (Vanilla / Turtle WoW)

**WoWTranslate** provides instant, two-way real-time translation between **Chinese, English, Russian, Japanese, and Korean** directly inside the World of Warcraft 1.12.1 game client.

Powered by **SuperWoW File IPC**, a local multi-threaded proxy, and an offline **SQLite cache**, WoWTranslate bypasses all Google rate limits, delivers **50ms response times**, and supports modern AI backends like **ChatGPT, DeepL, and local Ollama LLMs**.

---

## ⚡ Quick Start Guide (3 Simple Steps)

### Step 1: Install the Addon
1. Copy the `WoWTranslate` directory into your WoW AddOns folder:
   ```
   World of Warcraft\Interface\AddOns\WoWTranslate
   ```
2. Make sure you are using **SuperWoW** (`SuperWoWhook.dll` / standard on Turtle WoW client).

### Step 2: Start the Proxy (One-Click)
1. Open `Interface\AddOns\WoWTranslate\` in File Explorer.
2. Double-click **`start_proxy.bat`** (or run `python wow_proxy.py`).
3. Keep the small terminal window minimized while playing.

> **💡 Zero Setup Required!**
> The proxy has a built-in free Google Translate fallback with offline SQLite caching. It works immediately out of the box with zero API keys or external tools required!

### Step 3: Verify In-Game
Log in or type `/reload` in chat.
Type:
```
/wt diag
```
You will see:
```
[WoWTranslate] Diagnostics:
  Lua io.open: Sandboxed | SuperWoW IO: YES
  SuperWoW Probe: PASS | IO Test: PASS
  Active Transport: SuperWoW File IPC (Proxy)
```

---

## 💬 How It Works in Game

### 📥 1. Incoming Chat (Foreign → English)
- Chinese, Russian, Japanese, or Korean messages sent in **Guild, Party, Raid, Whisper, Say, Yell, or World Channels** are automatically translated to English.
- The translated line appears right below the original message, with **matching channel color** (e.g. `[WT-Guild]` in Guild green, `[WT-Party]` in Party blue).
- **Replace Mode**: If you want to hide the original foreign text completely and only display English, type `/wt show` and enable **"Replace Original Message"**.

### 📤 2. Outgoing Chat (English → Chinese)
- Enable outgoing translation:
  ```
  /wt out on
  ```
- Type normally in any chat channel (e.g. `/g Need 1 healer and 1 tank for Dire Maul then g2g`).
- WoWTranslate intercepts your message, translates it into Chinese in **50ms**, and broadcasts the translated message with the `[WoWTranslate]` tag.

---

## 🎮 In-Game Slash Commands (`/wt` or `/wowtranslate`)

| Command | Action |
| :--- | :--- |
| **`/wt show`** | Open the visual graphical settings & config panel |
| **`/wt hide`** | Close the configuration panel |
| **`/wt diag`** | Display live diagnostics and transport connection status |
| **`/wt status`** | Show addon status, active backends, cache hit rate, and settings |
| **`/wt out on`** / **`/wt out off`** | Turn automatic outgoing translation ON or OFF |
| **`/wt testout <text>`** | Preview/test outgoing translation locally without sending to chat |
| **`/wt test <text>`** | Test incoming translation locally (e.g. `/wt test 你好`) |
| **`/wt on`** / **`/wt off`** | Enable or disable incoming chat translation |
| **`/wt reset`** | Re-hook chat frames and clear any stale request queues |
| **`/wt clearcache`** | Clear local translation cache |
| **`/wt debug`** | Toggle developer debug logging in chat |

---

## 🤖 AI Backend Configuration (`config.toml`)

You can easily customize which translation engine is used by opening `config.toml` in Notepad:

```toml
# 1. Google AI Studio / Gemini (Free & High Quality Cloud AI)
# Get a free API key at: https://aistudio.google.com/app/apikey
[[backends]]
type = "gemini"
api_key = "YOUR_GEMINI_API_KEY_HERE"
model = "gemini-2.0-flash"
timeout = 10

# 2. OpenAI / ChatGPT (Cloud LLM - Highest Quality MMO Translations)
[[backends]]
type = "openai"
api_key = "sk-YOUR-API-KEY-HERE"   # Paste your OpenAI key here
model = "gpt-4o-mini"
base_url = "https://api.openai.com/v1"
timeout = 10

# 3. Ollama (100% Offline Local AI - Free)
# Install from https://ollama.com and run: ollama pull qwen2.5
[[backends]]
type = "ollama"
url = "http://localhost:11434/api/generate"
model = "qwen2.5"
timeout = 5

# 4. DeepL API (Cloud - 500,000 Free Chars/month)
# [[backends]]
# type = "deepl"
# api_key = "YOUR_DEEPL_AUTH_KEY:fx"
# timeout = 15

# 5. Built-in Google Web Translate (Free Fallback — Zero Setup)
[[backends]]
type = "google"
timeout = 8
```

---

## 🔧 Troubleshooting & FAQ

#### 1. Why do Chinese characters show as `??` on my screen?
- The standard English WoW client font (`FRIZQT__.TTF`) does not include Chinese font glyphs by default.
- **Other players with Chinese/Unicode clients receive and see the actual Chinese characters in chat!**
- To see Chinese characters on your own screen as well, place any CJK/Unicode font into `World of Warcraft\Fonts\FRIZQT__.TTF` (or use pfUI / ShaguTweaks with a Chinese font).

#### 2. `[WoWTranslate] Translation failing (no_backend)`
- Make sure `start_proxy.bat` is running in the background.
- Verify Python 3.8+ is installed on your Windows PC and in your PATH.

#### 3. It worked once and then stopped responding
- Type `/reload` or `/wt reset` in chat.
- Ensure you are running the latest v3.5 version with continuous background polling.
