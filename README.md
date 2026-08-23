# 🌐 WoWTranslate v3.5 — Universal Real-Time Chat Translator
### World of Warcraft 1.12.1 (Vanilla / Turtle WoW)

Translate World of Warcraft chat in real-time between **Chinese, English, Russian, Japanese, and Korean** directly inside your game!

WoWTranslate runs **100% locally and offline on your computer** using **Ollama** (your own private AI model). It is completely free, private, has zero monthly limits, and translates chat in **under 50 milliseconds**.

---

## ⚡ Super Easy Setup (Ollama Local AI)

Follow these 3 simple steps to get it running. No programming knowledge required!

---

### 🟢 STEP 1: Download & Install Ollama

You can install Ollama either through your web browser OR with a single PowerShell command:

#### Option A: Using PowerShell (Fastest - Copy & Paste)
1. Right-click your Windows **Start menu** icon and click **Windows PowerShell** (or **Terminal**).
2. Paste this command and press **Enter**:
   ```powershell
   winget install Ollama.Ollama
   ```
   *(Or if you don't have winget, copy-paste this direct download & install line:)*
   ```powershell
   Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile "$env:TEMP\OllamaSetup.exe"; Start-Process "$env:TEMP\OllamaSetup.exe" -Wait
   ```

#### Option B: Using Web Browser
1. Go to **[https://ollama.com](https://ollama.com)** in your web browser.
2. Click the big **"Download for Windows"** button.
3. Open the downloaded file (`OllamaSetup.exe`) and click **Install**.

> Once installed, the Ollama llama icon will appear in your Windows system tray (bottom-right next to the clock).

---

### 🟢 STEP 2: Download the Free AI Translation Model
Now, tell Ollama to download the translation model (the AI brain):

1. Open **PowerShell** or Command Prompt (`cmd`).
2. Copy and paste **ONE** of the following lines, then press **Enter**:

   * **For most computers & gaming PCs (Recommended):**
     ```bash
     ollama pull qwen2.5
     ```

   * **For older laptops / slower PCs (Lighter & faster):**
     ```bash
     ollama pull qwen2.5:3b
     ```

   * **For powerful gaming PCs (8GB+ GPU VRAM - Highest Accuracy):**
     ```bash
     ollama pull qwen2.5:7b
     ```

4. You will see a download progress bar `[=======> 100%]`. Once it says **`success`**, close the black window!

---

### 🟢 STEP 3: Start the Translator & Play WoW!

1. Open your World of Warcraft folder:
   ```text
   World of Warcraft\Interface\AddOns\WoWTranslate\
   ```
2. Double-click **`start_proxy.bat`**.
3. A small black window will open and say:
   ```text
   ==========================================================
     WoWTranslate Universal Proxy v3.5
     Backends     : ['ollama', 'google']
   ==========================================================
   [proxy] Ready! Proxy is actively listening for translations.
   ```
4. **Leave this window open (minimized) while you play WoW.**
5. Launch World of Warcraft and enjoy instant translation!

---

## 🎮 How It Works In-Game

### 📥 1. Reading Foreign Chat (Chinese / Russian → English)
- Whenever someone speaks in Chinese, Russian, Japanese, or Korean in **Guild, Party, Raid, Whisper, Say, Yell, or World Channels**, WoWTranslate automatically translates it into English.
- The translation appears right below their message in the exact same channel color.

### 📤 2. Speaking to Foreign Players (English → Chinese)
- Want to speak in Chinese to Chinese players? Turn on outgoing translation in chat:
  ```text
  /wt out on
  ```
- Now type your message normally in English (e.g. `/g LF1M healer for Dire Maul then ready`).
- WoWTranslate automatically translates your message into Chinese and sends it to chat!
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
| **`/wt out on`** | Turns **ON** automatic English → Chinese outgoing translation. |
| **`/wt out off`** | Turns **OFF** outgoing translation. |
| **`/wt diag`** | Tests your connection to make sure the proxy and game are connected. |
| **`/wt status`** | Shows addon status, active translation backends, and cache stats. |
| **`/wt test <text>`** | Tests incoming translation (e.g. `/wt test 你好`). |
| **`/wt testout <text>`** | Previews an outgoing translation without sending it to public chat. |
| **`/wt reset`** | Refreshes chat frames and clears any stuck queues. |
| **`/wt clearcache`** | Clears the local translation memory cache. |

---

## ⚙️ Configuration (`config.toml`)

Your [`config.toml`](file:///c:/Games/Interface/AddOns/WoWTranslate/config.toml) is located in `Interface\AddOns\WoWTranslate\config.toml`. It is already pre-configured for Ollama:

```toml
# WoWTranslate Proxy Configuration
http_port = 7654
workers = 4
cache_db = "translations.db"
stale_ttl = 60
scan_interval = 0.05

# 1. Ollama (100% Local & Offline AI)
[[backends]]
type = "ollama"
url = "http://localhost:11434"
model = "qwen2.5"
timeout = 20
temperature = 0.0
num_predict = 128
keep_alive = "1h"

# 2. Built-in Google Web Translate (Automatic fallback if Ollama is closed)
[[backends]]
type = "google"
timeout = 8
```

> **Note:** If you downloaded `qwen2.5:3b` or `qwen2.5:7b` in Step 2, simply change `model = "qwen2.5"` to `model = "qwen2.5:3b"` or `model = "qwen2.5:7b"` in `config.toml`.

---

## ❓ Frequently Asked Questions & Troubleshooting

#### 1. Why do Chinese characters look like `????` on my screen?
- The default 2004 English WoW game font does not contain Chinese characters.
- **Other players with Chinese or Unicode game clients see your Chinese characters perfectly!**
- If you also want to see Chinese characters on your own screen, use an addon like **pfUI**, **ShaguTweaks**, or place a CJK-compatible font file named `FRIZQT__.TTF` inside your `World of Warcraft\Fonts\` folder.

#### 2. What happens if I forget to start Ollama?
- Don't worry! WoWTranslate has a built-in automatic fallback to Google Web Translate. You will never miss a translation.

#### 3. How do I know if the proxy is connected?
- In game, type `/wt diag` in chat. If it says `Active Transport: SuperWoW File IPC (Proxy)` with `IO Test: PASS`, you are 100% good to go!

#### 4. How fast is it?
- Translations for previously seen messages and player names load in **0.05 milliseconds** from your local SQLite cache (`translations.db`).
- Brand new messages translated by your local Ollama model take between **50ms to 200ms**.
