"""
wow_proxy.py  v3.5.7  --  WoWTranslate Universal Proxy & Backend Engine
===================================================================
Works with or without UnitXP DLL. Works with or without external API keys.

Dual Interface:
  1. File IPC Transport:
     Lua writes   <wow_root>/WoWTranslate/IPC/requests/{id}.req
     Proxy reads  request, translates, writes:
                  <wow_root>/WoWTranslate/IPC/results/{id}.res
     Lua reads    result and deletes .res / .req files.
     Health:      Ping/pong via <wow_root>/WoWTranslate/IPC/ping and pong

  2. Local HTTP Server Transport (127.0.0.1:7654):
     Endpoints:   GET /ping
                  GET /translate?id=ID&q=TEXT&from=zh&to=en
                  GET /poll?id=ID
                  GET /stats

Translation Backends (ordered priority with automatic fallback):
  - Ollama (local offline LLM, e.g. qwen2.5)
  - DeepL (Free or Pro API key)
  - OpenAI (gpt-4o-mini / compatible endpoints)
  - Google Translate (built-in free web client fallback -- zero setup required!)

Persistent SQLite Cache (translations.db):
  Instant translation responses for previously translated text.
"""

import argparse
import copy
import hashlib
import html
import http.server
import json
import os
import queue
import re
import socketserver
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

# Ensure UTF-8 output on Windows consoles
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

VERSION = "3.5.7"
USER_AGENT = f"WoWTranslateProxy/{VERSION}"

# ---------------------------------------------------------------------------
# Configuration Loader
# ---------------------------------------------------------------------------
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        tomllib = None

DEFAULT_CONFIG = {
    "http_port": 7654,
    "workers": 4,
    "cache_db": "translations.db",
    "stale_ttl": 60,
    "scan_interval": 0.05,
    "backends": [
        {
            "type": "ollama",
            "url": "http://localhost:11434/api/generate",
            "model": "qwen2.5",
            "timeout": 20,
        },
        {
            "type": "google",
            "timeout": 8,
        }
    ],
}

def load_config(path):
    if path is None or not os.path.exists(path):
        print(f"[config] No config file found at '{path}', using defaults.")
        print("[config] WARNING: default config includes an external Google web-translate fallback; chat text will be sent to Google unless Ollama is running. Edit config.toml to change this.")
        return copy.deepcopy(DEFAULT_CONFIG)
    if tomllib is None:
        print("[config] tomllib/tomli not installed -- using defaults.")
        print("[config] WARNING: default config includes an external Google web-translate fallback; chat text will be sent to Google unless Ollama is running. Edit config.toml to change this.")
        return copy.deepcopy(DEFAULT_CONFIG)
    try:
        with open(path, "rb") as f:
            cfg = tomllib.load(f)
        for k, v in DEFAULT_CONFIG.items():
            if k not in cfg:
                cfg[k] = copy.deepcopy(v)
        # Ensure google fallback is always present if no backends configured
        if "backends" not in cfg or not cfg["backends"]:
            cfg["backends"] = copy.deepcopy(DEFAULT_CONFIG["backends"])
            print("[config] WARNING: no backends configured; enabling Google external fallback (chat text goes to Google).")
        print(f"[config] Loaded {path}")
        return cfg
    except Exception as e:
        print(f"[config] Error reading {path}: {e}, using defaults.")
        print("[config] WARNING: your configured backends were NOT loaded because the config is malformed; the default backend list (including external Google) is active instead. FIX config.toml to restore local-only translation.")
        return copy.deepcopy(DEFAULT_CONFIG)

# ---------------------------------------------------------------------------
# Path Auto-Detection
# ---------------------------------------------------------------------------
def detect_wow_root(script_path):
    """
    Finds the WoW root folder.
    Case 1: script is at <wow_root>/Interface/AddOns/WoWTranslate/wow_proxy.py -> 3 levels up
    Case 2: script is run in a custom folder or WoW root
    """
    d = os.path.dirname(os.path.abspath(script_path))
    three_up = os.path.normpath(os.path.join(d, "..", "..", ".."))
    
    # Check if WoW.exe or WTF directory exists 3 levels up
    if os.path.exists(os.path.join(three_up, "WoW.exe")) or os.path.exists(os.path.join(three_up, "WTF")):
        return three_up
    
    # Check if WoW.exe exists in current directory or parent
    if os.path.exists(os.path.join(d, "WoW.exe")):
        return d
    parent = os.path.normpath(os.path.join(d, ".."))
    if os.path.exists(os.path.join(parent, "WoW.exe")):
        return parent
        
    return three_up

def get_all_ipc_targets(script_dir, wow_root):
    """Returns all potential directories where Lua might write/read IPC files."""
    targets = []
    # SuperWoW target: <wow_root>/Imports
    t0 = os.path.join(wow_root, "Imports")
    targets.append(t0)
    # Primary File IPC: <wow_root>/WoWTranslate/IPC
    t1 = os.path.join(wow_root, "WoWTranslate", "IPC")
    targets.append(t1)
    # Secondary: <wow_root>/Interface/AddOns/WoWTranslate/IPC
    t2 = os.path.join(wow_root, "Interface", "AddOns", "WoWTranslate", "IPC")
    if os.path.normpath(t2) != os.path.normpath(t1):
        targets.append(t2)
    # Tertiary: <script_dir>/IPC
    t3 = os.path.join(script_dir, "IPC")
    if os.path.normpath(t3) != os.path.normpath(t1) and os.path.normpath(t3) != os.path.normpath(t2):
        targets.append(t3)
    return targets

def ensure_ipc_dirs(ipc_root):
    requests = os.path.join(ipc_root, "requests")
    results = os.path.join(ipc_root, "results")
    os.makedirs(ipc_root, exist_ok=True)
    os.makedirs(requests, exist_ok=True)
    os.makedirs(results, exist_ok=True)
    return requests, results

# ---------------------------------------------------------------------------
# SQLite Translation Cache
# ---------------------------------------------------------------------------
_db_local = threading.local()

def _db(db_path):
    if not hasattr(_db_local, "conn") or _db_local.conn is None:
        _db_local.conn = sqlite3.connect(db_path, check_same_thread=False)
        _db_local.conn.execute("PRAGMA journal_mode=WAL")
        _db_local.conn.execute("PRAGMA busy_timeout=5000")
        _db_local.conn.execute("""
            CREATE TABLE IF NOT EXISTS translations (
                src_hash  TEXT NOT NULL,
                from_lang TEXT NOT NULL,
                to_lang   TEXT NOT NULL,
                result    TEXT NOT NULL,
                created   INTEGER NOT NULL,
                PRIMARY KEY (src_hash, from_lang, to_lang)
            )
        """)
        _db_local.conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_hash ON translations(src_hash)"
        )
        _db_local.conn.commit()
    return _db_local.conn

def _src_hash(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()

def cache_get(db_path, text, from_lang, to_lang):
    try:
        h = _src_hash(text)
        row = _db(db_path).execute(
            "SELECT result FROM translations WHERE src_hash=? AND from_lang=? AND to_lang=?",
            (h, from_lang.lower(), to_lang.lower()),
        ).fetchone()
        return row[0] if row else None
    except Exception as e:
        print(f"[cache] GET error: {e}")
        return None

def cache_set(db_path, text, from_lang, to_lang, result):
    try:
        h = _src_hash(text)
        _db(db_path).execute(
            "INSERT OR REPLACE INTO translations "
            "(src_hash, from_lang, to_lang, result, created) VALUES (?,?,?,?,?)",
            (h, from_lang.lower(), to_lang.lower(), result, int(time.time())),
        )
        _db(db_path).commit()
    except Exception as e:
        print(f"[cache] SET error: {e}")

def cache_count(db_path):
    try:
        row = _db(db_path).execute("SELECT COUNT(*) FROM translations").fetchone()
        return row[0] if row else 0
    except Exception:
        return 0

def cache_purge_code_switched(db_path):
    """One-time-per-startup cleanup: drop cached translations that contain
    untranslated English words mixed into non-Latin output (small-LLM
    code-switching artifacts, e.g. '是的，现在everything都很贵。'). Runs at
    startup so users who received bad cached entries get them fixed silently."""
    try:
        conn = _db(db_path)
        rows = conn.execute(
            "SELECT src_hash, from_lang, to_lang, result FROM translations"
        ).fetchall()
    except Exception as e:
        print(f"[cache] purge error: {e}")
        return 0
    bad = []
    for h, fl, tl, result in rows:
        # Only inspect pairs whose target is a non-Latin script; skip pure-EN targets.
        if not re.search(r"[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af\u0400-\u04ff]", result or ""):
            continue
        try:
            # We only stored the hash, not the source text — so detect the
            # artifact directly in the output. Require the English word to be
            # EMBEDDED in non-Latin script: a non-ASCII, non-Latin char
            # immediately before AND after it. This spares legit mixed chat
            # like '我喜欢Star Wars' or trailing brand/item names.
            for m in re.finditer(r"[A-Za-z']+", result):
                wl = m.group(0).lower()
                if len(wl) < 4 or wl in _PRESERVE_TERMS:
                    continue
                s, e = m.start(), m.end()
                if s == 0 or e >= len(result):
                    continue  # at string edge -> not embedded
                before, after = result[s - 1], result[e]
                if (ord(before) > 0x2FFF and not before.isascii()
                        and ord(after) > 0x2FFF and not after.isascii()):
                    bad.append((h, fl, tl))
                    break
        except Exception:
            continue
    if bad:
        conn.executemany(
            "DELETE FROM translations WHERE src_hash=? AND from_lang=? AND to_lang=?",
            bad,
        )
        conn.commit()
    print(f"[cache] startup purge: removed {len(bad)} code-switched entr{'y' if len(bad)==1 else 'ies'} "
          f"of {len(rows)} cached")
    return len(bad)

# ---------------------------------------------------------------------------
_ollama_online = None
_ollama_last_check = 0
_ollama_lock = threading.Lock()

def _is_ollama_online(url="http://localhost:11434/api/tags"):
    global _ollama_online, _ollama_last_check
    now = time.time()
    with _ollama_lock:
        if _ollama_online is not None and (now - _ollama_last_check) < 15:
            return _ollama_online
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=1.5) as resp:
                _ollama_online = (resp.status == 200)
        except Exception:
            _ollama_online = False
        _ollama_last_check = now
        return _ollama_online

def _call_ollama(text, from_lang, to_lang, backend):
    raw_url = backend.get("url", "http://localhost:11434").rstrip("/")
    if raw_url.endswith("/api/generate") or raw_url.endswith("/api/chat"):
        base_url = re.sub(r"/api/(?:generate|chat)$", "", raw_url).rstrip("/")
    else:
        base_url = raw_url
    tags_url = f"{base_url}/api/tags"
    chat_url = f"{base_url}/api/chat"
    gen_url = f"{base_url}/api/generate"

    if not _is_ollama_online(tags_url):
        raise ConnectionRefusedError(f"Ollama is not responding at {base_url} (ensure 'ollama serve' or Ollama desktop app is running)")

    lang_map = {
        "zh": "Chinese",
        "en": "English",
        "ru": "Russian",
        "ja": "Japanese",
        "ko": "Korean",
        "de": "German",
        "fr": "French",
        "es": "Spanish",
        "pt": "Portuguese",
    }
    src_lang = lang_map.get(from_lang.lower(), from_lang)
    tgt_lang = lang_map.get(to_lang.lower(), to_lang)
    if src_lang.lower() == "auto":
        # LLM backends have no native auto-detect; instruct the model instead.
        src_lang = "the source language (auto-detect it)"

    system_prompt = (
        f"You are a specialized real-time translator for World of Warcraft Classic.\n"
        f"Translate accurately from {src_lang} to {tgt_lang} using natural MMORPG terminology.\n\n"
        f"Rules:\n"
        f"1. Context & Slang: Accurately translate gamer slang and intent (e.g., 'plsease' -> please, '邮箱' -> mailbox, '有坑' -> has spot, '+' or '1' -> invite/inv, '重登' -> relog, '打信' -> turn in texts).\n"
        f"2. Full Translation: Translate EVERY ordinary word into the target language. Common vocabulary (e.g., everything, need, want, gold, run) must NEVER be left untranslated in the output.\n"
        f"3. Preservation (ONLY these stay intact): player/character names, coordinates, links, numbers/progress counters (e.g., 11/30), URL placeholders (http://ph.wt/1), and standard MMO abbreviations (LFG, LFM, DPS, MT, OT, CC, SR, HR, GDKP).\n"
        f"4. Output Format: Return ONLY the raw translated text. No explanations, quotes, markdown, conversational commentary, or channel prefixes."
    )

    model = backend.get("model", "qwen2.5")
    timeout = backend.get("timeout", 20)
    keep_alive = backend.get("keep_alive", "1h")
    temperature = backend.get("temperature", 0.0)
    num_predict = backend.get("num_predict", 256)

    result = ""
    chat_exc = None
    # 1. Primary: Native Ollama /api/chat endpoint (Structured system & user roles)
    try:
        chat_payload = json.dumps({
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": text},
            ],
            "stream": False,
            "keep_alive": keep_alive,
            "options": {
                "temperature": temperature,
                "num_predict": num_predict,
            },
        }).encode("utf-8")

        req = urllib.request.Request(
            chat_url, data=chat_payload,
            headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        result = data.get("message", {}).get("content", "").strip()
    except Exception as ce:
        chat_exc = ce
        result = ""

    # 2. Fallback: /api/generate if /api/chat returned empty or was unavailable
    if not result:
        try:
            prompt = f"{system_prompt}\n\nChat: {text}\nTranslation:"
            gen_payload = json.dumps({
                "model": model,
                "prompt": prompt,
                "stream": False,
                "keep_alive": keep_alive,
                "options": {
                    "temperature": temperature,
                    "num_predict": num_predict,
                },
            }).encode("utf-8")

            req = urllib.request.Request(
                gen_url, data=gen_payload,
                headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            result = data.get("response", "").strip()
        except Exception as ge:
            err_msg = f"Ollama /api/generate failed: {ge}"
            if chat_exc:
                err_msg += f" (chat error: {chat_exc})"
            raise ValueError(err_msg)

    # Post-process: strip <think>...</think> tags if model is reasoning-based (e.g. DeepSeek-R1)
    result = re.sub(r"<think>.*?</think>", "", result, flags=re.DOTALL).strip()
    # Strip leading "Translation:" prefix if model outputs it
    result = re.sub(r"^(?:Translation|Translated text|Output):\s*", "", result, flags=re.IGNORECASE).strip()
    # Strip markdown quotes or bolding (only when BOTH ends use the same wrapper
# and the content is short enough that it's clearly model chatter, not speech)
    result = re.sub(r"^\*{2,}(.+)\*{2,}$", r"\1", result)  # **bold** only, not *emphasis*
    if len(result) <= 120:
        q = result[0]
        if len(result) >= 2 and q in "\"'" and result[-1] == q:
            result = result[1:-1]

    if not result:
        raise ValueError("Ollama returned empty response")
    return result.strip()

def _call_deepl(text, from_lang, to_lang, backend):
    api_key = backend.get("api_key", "").strip()
    if not api_key:
        raise ValueError("DeepL api_key not configured")
    
    deepl_map = {
        "zh": "ZH", "en": "EN-US", "ja": "JA",
        "ko": "KO", "ru": "RU", "de": "DE",
        "fr": "FR", "es": "ES", "pt": "PT-BR",
    }
    src = deepl_map.get(from_lang.lower(), from_lang.upper())
    tgt = deepl_map.get(to_lang.lower(), to_lang.upper())
    if from_lang.lower() == "auto":
        src = "auto"  # DeepL native auto-detect
    
    endpoint = "https://api-free.deepl.com/v2/translate" if api_key.endswith(":fx") else "https://api.deepl.com/v2/translate"
    params = urllib.parse.urlencode({
        "auth_key": api_key,
        "text": text,
        "source_lang": src,
        "target_lang": tgt,
    }).encode("utf-8")
    
    req = urllib.request.Request(
        endpoint, data=params,
        headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT},
        method="POST",
    )
    timeout = backend.get("timeout", 15)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    translations = data.get("translations", [])
    if not translations:
        raise ValueError("DeepL returned no translations")
    return translations[0]["text"].strip()

def _call_openai(text, from_lang, to_lang, backend):
    api_key = backend.get("api_key", "").strip()
    if api_key.startswith("env:"):
        api_key = os.environ.get(api_key[4:], "").strip()
    if not api_key:
        api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key or api_key.startswith("sk-YOUR") or api_key == "sk-...":
        raise ValueError("OpenAI api_key not configured (please paste your key in config.toml)")

    base_url = backend.get("base_url", "https://api.openai.com/v1").rstrip("/")
    model = backend.get("model", "gpt-4o-mini")
    timeout = backend.get("timeout", 10)
    system = (
        f"You are a specialized real-time translator for World of Warcraft Classic.\n"
        f"Translate accurately from {from_lang} to {to_lang} using natural MMORPG terminology.\n\n"
        f"Rules:\n"
        f"1. Context & Slang: Accurately translate gamer slang and intent (e.g., 'plsease' -> please, '邮箱' -> mailbox, '有坑' -> has spot, '+' or '1' -> invite/inv, '重登' -> relog, '打信' -> turn in texts).\n"
        f"2. Full Translation: Translate EVERY ordinary word into the target language. Common vocabulary (e.g., everything, need, want, gold, run) must NEVER be left untranslated in the output.\n"
        f"3. Preservation (ONLY these stay intact): player/character names, coordinates, links, numbers/progress counters (e.g., 11/30), URL placeholders (http://ph.wt/1), and standard MMO abbreviations (LFG, LFM, DPS, MT, OT, CC, SR, HR, GDKP).\n"
        f"4. Output Format: Return ONLY the raw translated text without quotes, markdown, explanations, or channel prefixes."
    )
    payload = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": f"Translate from {from_lang} to {to_lang}: {text}"},
        ],
        "max_tokens": 256,
        "temperature": 0.1,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{base_url}/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}", "User-Agent": USER_AGENT},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    choices = data.get("choices", [])
    if not choices:
        raise ValueError("OpenAI returned no choices")
    return choices[0]["message"]["content"].strip()

def _call_google(text, from_lang, to_lang, backend):
    """Free Google Translate web API fallback with multi-endpoint rotation against 429 rate limits."""
    timeout = backend.get("timeout", 8)
    sl = urllib.parse.quote(str(from_lang).lower(), safe="")
    tl = urllib.parse.quote(str(to_lang).lower(), safe="")
    encoded = urllib.parse.quote(text)
    
    # 1. Primary: translate.googleapis.com
    try:
        url = f"https://translate.googleapis.com/translate_a/single?client=gtx&sl={sl}&tl={tl}&dt=t&q={encoded}"
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "*/*",
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        if data and isinstance(data, list) and data[0]:
            parts = [seg[0] for seg in data[0] if seg and isinstance(seg, list) and seg[0]]
            res = "".join(parts).strip()
            if res:
                return res
    except Exception:
        pass

    # 2. Secondary: clients5.google.com
    try:
        url2 = f"https://clients5.google.com/translate_a/t?client=dict-chrome-ex&sl={sl}&tl={tl}&q={encoded}"
        req2 = urllib.request.Request(url2, headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        })
        with urllib.request.urlopen(req2, timeout=timeout) as resp:
            data2 = json.loads(resp.read().decode("utf-8"))
        if isinstance(data2, list) and len(data2) > 0:
            if isinstance(data2[0], str) and data2[0].strip():
                return data2[0].strip()
            elif isinstance(data2[0], list) and len(data2[0]) > 0 and isinstance(data2[0][0], str):
                return data2[0][0].strip()
    except Exception:
        pass

    # 3. Tertiary: translate.google.com/m mobile endpoint
    try:
        url3 = f"https://translate.google.com/m?sl={sl}&tl={tl}&q={encoded}"
        req3 = urllib.request.Request(url3, headers={
            "User-Agent": "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
        })
        with urllib.request.urlopen(req3, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
        match = re.search(r'class="result-container">([^<]+)', raw)
        if match:
            return html.unescape(match.group(1)).strip()
    except Exception as e3:
        raise ValueError(f"Google Translate rate limit / connection error ({e3})")

    raise ValueError("Google Translate returned empty response across all endpoints")

def _call_gemini(text, from_lang, to_lang, backend):
    """Google AI Studio (Gemini) API Backend."""
    api_key = backend.get("api_key", "").strip()
    if api_key.startswith("env:"):
        api_key = os.environ.get(api_key[4:], "").strip()
    if not api_key:
        api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key or api_key.startswith("YOUR_") or api_key == "AIzaSy...":
        raise ValueError("Gemini api_key not configured (please paste your Google AI Studio key in config.toml)")

    model = backend.get("model", "gemini-2.5-flash")
    timeout = backend.get("timeout", 10)
    
    system_prompt = (
        f"You are a specialized real-time translator for World of Warcraft Classic.\n"
        f"Translate accurately from {from_lang} to {to_lang} using natural MMORPG terminology.\n\n"
        f"Rules:\n"
        f"1. Context & Slang: Accurately translate gamer slang and intent (e.g., 'plsease' -> please, '邮箱' -> mailbox, '有坑' -> has spot, '+' or '1' -> invite/inv, '重登' -> relog, '打信' -> turn in texts).\n"
        f"2. Full Translation: Translate EVERY ordinary word into the target language. Common vocabulary (e.g., everything, need, want, gold, run) must NEVER be left untranslated in the output.\n"
        f"3. Preservation (ONLY these stay intact): player/character names, coordinates, links, numbers/progress counters (e.g., 11/30), URL placeholders (http://ph.wt/1), and standard MMO abbreviations (LFG, LFM, DPS, MT, OT, CC, SR, HR, GDKP).\n"
        f"4. Output Format: Return ONLY the raw translated plain text without quotes, markdown bolding, explanations, commentary, or channel prefixes."
    )

    safety_settings = [
        {"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"},
        {"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"},
        {"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"},
        {"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"},
    ]

    payload = json.dumps({
        "contents": [
            {
                "parts": [
                    {"text": f"{system_prompt}\n\nTranslate from {from_lang} to {to_lang}: {text}"}
                ]
            }
        ],
        "generationConfig": {
            "temperature": 0.1,
            "maxOutputTokens": 256,
        },
        "safetySettings": safety_settings,
    }).encode("utf-8")
    
    # Try configured model, fallback to gemini-2.5-flash on 404
    models_to_try = [model]
    if model != "gemini-2.5-flash":
        models_to_try.append("gemini-2.5-flash")
    if "gemini-2.0-flash" not in models_to_try:
        models_to_try.append("gemini-2.0-flash")

    last_exc = None
    for m in models_to_try:
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{m}:generateContent"
        req = urllib.request.Request(
            url,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "User-Agent": USER_AGENT,
                "x-goog-api-key": api_key,
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            candidates = data.get("candidates", [])
            if not candidates:
                raise ValueError("Gemini returned no candidates")
            parts = candidates[0].get("content", {}).get("parts", [])
            if not parts:
                raise ValueError("Gemini returned no content parts")
            result = parts[0].get("text", "").strip()
            # Clean up markdown bolding or quotes if any
            result = re.sub(r"^\*+(.*?)\*+$", r"\1", result)
            result = re.sub(r'^["\'](.*)["\']$', r"\1", result)
            return result.strip()
        except urllib.error.HTTPError as he:
            last_exc = he
            if he.code == 404:
                continue
            raise he
        except Exception as e:
            last_exc = e
            raise e

    raise last_exc or ValueError("Gemini request failed")

BACKEND_FNS = {
    "gemini": _call_gemini,
    "google_ai": _call_gemini,
    "google_studio": _call_gemini,
    "ollama": _call_ollama,
    "deepl": _call_deepl,
    "openai": _call_openai,
    "google": _call_google,
}

# Abbreviations/terms the system prompt tells LLMs to keep intact.
# An English word in the output is only "suspicious" (code-switching) if it is
# NOT in this list.
_PRESERVE_TERMS = {
    "lfg", "lfm", "dps", "mt", "ot", "cc", "sr", "hr", "gdkp",
    "afk", "brb", "wts", "wtb", "wtt", "pst", "bio", "brd", "mc", "bwl",
    "zf", "sm", "mara", "dm", "ubrs", "lbrs", "strat", "scholo", "ony",
    "zg", "aq", "silithus", "epic", "boe", "bop", "aoe", "mob", "npc",
    "buff", "debuff", "rez", "res", "loot", "tank", "heal", "heals",
    "pull", "aggro", "wipe", "trash", "boss", "adds", "dot", "hot",
    "cd", "cds", "mana", "hp", "xp", "lvl", "level", "gold", "gank",
    "alt", "main", "twink", "guild", "raid", "party", "duel", "trade",
}

def _looks_code_switched(source_text, translated_text, min_len=4):
    """True if translated_text contains an English word EMBEDDED in non-Latin
    script (non-Latin char immediately before AND after, no spaces) that was
    present in source_text and is not on the preserve list. Catches small-LLM
    code-switching like '是的，现在everything都很贵。' while sparing legit
    mixed chat such as '我喜欢Star Wars。'."""
    if not source_text or not translated_text:
        return False
    # Only meaningful when the translation is mostly non-Latin (zh/ja/ko/ru).
    if not re.search(r"[\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af\u0400-\u04ff]", translated_text):
        return False
    src_words = set(w.lower() for w in re.findall(r"[A-Za-z']+", source_text))
    for m in re.finditer(r"[A-Za-z']+", translated_text):
        wl = m.group(0).lower()
        if len(wl) < min_len or wl in _PRESERVE_TERMS or wl not in src_words:
            continue
        s, e = m.start(), m.end()
        if s == 0 or e >= len(translated_text):
            continue  # at string edge -> not embedded
        before, after = translated_text[s - 1], translated_text[e]
        if (ord(before) > 0x2FFF and not before.isascii()
                and ord(after) > 0x2FFF and not after.isascii()):
            return True
    return False


def translate(text, from_lang, to_lang, backends):
    """Tries backends in order; returns (result_text, None) on success or (None, err_msg)."""
    if not text or not text.strip():
        return "", None

    last_err = "No backends configured"
    fallback_result = None  # best suspect result, used only if nothing better
    for backend in backends:
        btype = backend.get("type", "?").lower()
        fn = BACKEND_FNS.get(btype)
        if not fn:
            continue
        try:
            result = fn(text, from_lang, to_lang, backend)
            if result:
                # Clean up apostrophe space artifact e.g. "doesn' t" -> "doesn't"
                result = re.sub(r"'\s+(\w)", r"'\1", result)
                # Sanitize wire format separator | to /
                result = result.replace("|", "/")
                # Code-switching sanity pass (LLM backends only): if the output
                # left ordinary source words untranslated, prefer another backend.
                if btype in ("ollama", "openai", "gemini", "deepl") and _looks_code_switched(text, result):
                    print(f"[translate] [{btype}] suspected code-switching (untranslated English word), trying next backend")
                    if fallback_result is None:
                        fallback_result = result
                    last_err = f"{btype}: suspected code-switching"
                    continue
                # Formatted log with clean length limit
                t_disp = (text[:50] + "...") if len(text) > 50 else text
                r_disp = (result[:50] + "...") if len(result) > 50 else result
                print(f"[translate] [{btype}] {from_lang} -> {to_lang}: '{t_disp}' -> '{r_disp}'")
                return result, None
        except Exception as e:
            last_err = f"{btype}: {e}"
            print(f"[translate] [{btype}] failed: {e}")
            continue

    # Nothing clean came back; use the least-bad suspect translation rather than failing.
    if fallback_result is not None:
        t_disp = (text[:50] + "...") if len(text) > 50 else text
        r_disp = (fallback_result[:50] + "...") if len(fallback_result) > 50 else fallback_result
        print(f"[translate] all backends suspected code-switching; using best attempt: '{r_disp}' (src: '{t_disp}')")
        return fallback_result, None

    return None, f"All translation backends failed ({last_err})"

# ---------------------------------------------------------------------------
# Memory & HTTP Queue Coordination
# ---------------------------------------------------------------------------
_http_results = {}  # req_id -> {"result": str, "error": str, "time": float}
_http_results_lock = threading.Lock()

def store_http_result(req_id, result, error):
    with _http_results_lock:
        _http_results[req_id] = {
            "result": (result or "").replace("|", "/"),
            "error": error or "",
            "time": time.time(),
        }

def get_http_result(req_id):
    with _http_results_lock:
        return _http_results.get(req_id)

def clean_http_results(max_age=120):
    now = time.time()
    with _http_results_lock:
        stale = [k for k, v in _http_results.items() if now - v["time"] > max_age]
        for k in stale:
            del _http_results[k]

# ---------------------------------------------------------------------------
# Worker Pool
# ---------------------------------------------------------------------------
_in_flight = set()
_in_flight_lock = threading.Lock()

def mark_in_flight(req_path):
    with _in_flight_lock:
        if req_path in _in_flight:
            return False
        _in_flight.add(req_path)
        return True

def unmark_in_flight(req_path):
    with _in_flight_lock:
        _in_flight.discard(req_path)

_job_queue = queue.Queue()

def _worker(db_path, backends, ipc_targets):
    while True:
        try:
            item = _job_queue.get(timeout=1)
        except queue.Empty:
            continue
        
        req_id, req_file_path, from_lang, to_lang, text, is_http = item
        try:
            # Check SQLite Cache first
            cached = cache_get(db_path, text, from_lang, to_lang)
            if cached:
                if is_http:
                    store_http_result(req_id, cached, "")
                if req_file_path:
                    _write_ipc_result(req_id, "ok", cached, ipc_targets)
                continue
                
            result, error = translate(text, from_lang, to_lang, backends)
            if result:
                cache_set(db_path, text, from_lang, to_lang, result)
                if is_http:
                    store_http_result(req_id, result, "")
                if req_file_path:
                    _write_ipc_result(req_id, "ok", result, ipc_targets)
            else:
                if is_http:
                    store_http_result(req_id, "", error or "Translation failed")
                if req_file_path:
                    _write_ipc_result(req_id, "err", error or "Translation failed", ipc_targets)
        finally:
            if req_file_path:
                _safe_delete(req_file_path)
                unmark_in_flight(req_file_path)
            _job_queue.task_done()

def _write_ipc_result(req_id, status, body, ipc_targets):
    # Pipe sanitization must apply on BOTH ok and err bodies: the wire format
    # is "status|body", so an error message containing "|" would corrupt it.
    if body:
        body = body.replace("|", "/")
    # Wire format is single-line "status|body": flatten any newlines/control
    # chars that a backend could return inside the translation.
    if body:
        body = "".join(ch if ord(ch) >= 0x20 else " " for ch in body)
    for ipc_root in ipc_targets:
        is_imports = os.path.basename(ipc_root).lower() == "imports"
        if is_imports:
            res_dir = ipc_root
            res_path = os.path.join(res_dir, f"res_{req_id}.txt")
        else:
            res_dir = os.path.join(ipc_root, "results")
            res_path = os.path.join(res_dir, req_id + ".res")
        tmp_path = res_path + ".tmp"
        try:
            os.makedirs(res_dir, exist_ok=True)
            with open(tmp_path, "w", encoding="utf-8") as f:
                f.write(f"{status}|{body}")
            os.replace(tmp_path, res_path)
        except Exception as e:
            try:
                os.remove(tmp_path)
            except Exception:
                pass

def _safe_delete(path):
    try:
        if os.path.exists(path):
            os.remove(path)
    except Exception:
        pass

def start_workers(n, db_path, backends, ipc_targets):
    for i in range(n):
        t = threading.Thread(
            target=_worker, args=(db_path, backends, ipc_targets), daemon=True, name=f"Worker-{i+1}"
        )
        t.start()
    print(f"[proxy] Started {n} worker thread(s)")

# ---------------------------------------------------------------------------
# HTTP Server (Port 7654 for UnitXP DLL / HTTP compatibility)
# ---------------------------------------------------------------------------
class ProxyHTTPHandler(http.server.BaseHTTPRequestHandler):
    db_path = ""
    backends = []
    ipc_targets = []

    def log_message(self, format, *args):
        pass  # Suppress default noisy access logs

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/ping":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"pong": true}\n')
            return

        elif path == "/stats":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            stats = {
                "cache_entries": cache_count(self.db_path),
                "pending_jobs": _job_queue.qsize(),
                "backends": [b.get("type", "?") for b in self.backends],
            }
            self.wfile.write(json.dumps(stats).encode("utf-8") + b"\n")
            return

        elif path == "/poll":
            req_id = query.get("id", [""])[0]
            res = get_http_result(req_id)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            if res:
                self.wfile.write(json.dumps({"id": req_id, "result": res["result"], "error": res["error"]}).encode("utf-8") + b"\n")
            else:
                self.wfile.write(b"{}\n")
            return

        elif path == "/translate":
            req_id = query.get("id", [""])[0]
            text = query.get("q", [""])[0]
            from_lang = query.get("from", ["zh"])[0]
            to_lang = query.get("to", ["en"])[0]

            if not req_id:
                req_id = str(int(time.time() * 1000))

            # Fast cache check
            cached = cache_get(self.db_path, text, from_lang, to_lang)
            if cached:
                store_http_result(req_id, cached, "")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"queued": True, "cached": True, "result": cached}).encode("utf-8") + b"\n")
                return

            _job_queue.put((req_id, None, from_lang, to_lang, text, True))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"queued": true, "cached": false}\n')
            return

        else:
            self.send_response(404)
            self.end_headers()

def start_http_server(port, db_path, backends, ipc_targets):
    ProxyHTTPHandler.db_path = db_path
    ProxyHTTPHandler.backends = backends
    ProxyHTTPHandler.ipc_targets = ipc_targets
    
    server_cls = getattr(http.server, "ThreadingHTTPServer", None)
    if server_cls is None:
        class FallbackThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
        server_cls = FallbackThreadingHTTPServer

    try:
        httpd = server_cls(("127.0.0.1", port), ProxyHTTPHandler)
        t = threading.Thread(target=httpd.serve_forever, daemon=True, name="HTTPServer")
        t.start()
        print(f"[http] HTTP server listening on http://127.0.0.1:{port}")
        return httpd
    except Exception as e:
        print(f"[http] Warning: Could not start HTTP server on port {port}: {e}")
        return None

# ---------------------------------------------------------------------------
# File IPC Scanner Loop
# ---------------------------------------------------------------------------
def parse_request_file(content):
    """Wire format: 'fromLang|toLang|text'"""
    parts = content.split("|", 2)
    if len(parts) < 3:
        raise ValueError(f"Malformed request line: '{content}'")
    from_lang, to_lang, text = parts[0], parts[1], parts[2]
    # Language codes must be simple codes (en, zh, pt-br...): anything else
    # could carry '|' or newlines that shift wire-format parsing downstream.
    lang_re = re.compile(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$")
    if not lang_re.match(from_lang.strip()) or not lang_re.match(to_lang.strip()):
        raise ValueError(f"Invalid language code(s): '{from_lang}|{to_lang}'")
    return from_lang.strip(), to_lang.strip(), text

def ipc_scanner(ipc_targets, db_path, backends, cfg):
    stale_ttl = cfg.get("stale_ttl", 60)
    scan_iv = cfg.get("scan_interval", 0.05)

    # Write proxy_ready signal in all IPC locations
    for target in ipc_targets:
        is_imports = os.path.basename(target).lower() == "imports"
        ready_path = os.path.join(target, "proxy_ready.txt" if is_imports else "proxy_ready")
        try:
            os.makedirs(target, exist_ok=True)
            with open(ready_path, "w", encoding="utf-8") as f:
                f.write("ok|proxy_ready")
            print(f"[proxy] Wrote proxy_ready to {ready_path}")
        except Exception:
            pass

    last_cleanup = time.time()

    while True:
        now = time.time()

        for ipc_root in ipc_targets:
            is_imports = os.path.basename(ipc_root).lower() == "imports"
            if is_imports:
                ping_file = os.path.join(ipc_root, "ping.txt")
                pong_file = os.path.join(ipc_root, "pong.txt")
                req_dir = ipc_root
            else:
                ping_file = os.path.join(ipc_root, "ping")
                pong_file = os.path.join(ipc_root, "pong")
                req_dir = os.path.join(ipc_root, "requests")

            # 1. Ping / Pong
            if os.path.exists(ping_file):
                try:
                    os.remove(ping_file)
                except Exception:
                    pass
                try:
                    with open(pong_file, "w", encoding="utf-8") as f:
                        f.write(f"ok|{int(now)}")
                except Exception:
                    pass

            # 2. Scan requests
            if not os.path.exists(req_dir):
                continue
                
            try:
                entries = os.listdir(req_dir)
            except Exception:
                continue

            for fname in entries:
                if is_imports:
                    if not (fname.startswith("req_") and fname.endswith(".txt")):
                        continue
                    req_id = fname[4:-4]
                else:
                    if not fname.endswith(".req"):
                        continue
                    req_id = fname[:-4]

                req_path = os.path.join(req_dir, fname)

                try:
                    age = now - os.path.getmtime(req_path)
                except Exception:
                    continue

                if age > stale_ttl:
                    # Do not delete while a worker holds this request: stacked
                    # backend timeouts can exceed stale_ttl, and deleting here
                    # loses/duplicates the request. The worker's finally block
                    # cleans it up instead.
                    if req_path not in _in_flight:
                        _safe_delete(req_path)
                        unmark_in_flight(req_path)
                    continue

                if not mark_in_flight(req_path):
                    continue

                try:
                    with open(req_path, "r", encoding="utf-8") as f:
                        content = f.read().strip()
                    if not content:
                        unmark_in_flight(req_path)
                        continue
                    from_lang, to_lang, text = parse_request_file(content)
                except Exception as e:
                    if age > 1.0:
                        print(f"[proxy] Error parsing {fname}: {e}")
                        _safe_delete(req_path)
                    unmark_in_flight(req_path)
                    continue

                # Cache check
                cached = cache_get(db_path, text, from_lang, to_lang)
                if cached:
                    _write_ipc_result(req_id, "ok", cached, ipc_targets)
                    _safe_delete(req_path)
                    unmark_in_flight(req_path)
                    print(f"[proxy] [cache-hit] {from_lang}→{to_lang}: '{text[:40]}'")
                    continue

                _job_queue.put((req_id, req_path, from_lang, to_lang, text, False))

        # Periodic cleanup of old result files and HTTP map
        if now - last_cleanup > 30:
            last_cleanup = now
            clean_http_results()
            for ipc_root in ipc_targets:
                res_dir = os.path.join(ipc_root, "results")
                if os.path.exists(res_dir):
                    try:
                        for fname in os.listdir(res_dir):
                            if fname.endswith(".res"):
                                fp = os.path.join(res_dir, fname)
                                try:
                                    if now - os.path.getmtime(fp) > stale_ttl:
                                        os.remove(fp)
                                except Exception:
                                    pass
                    except Exception:
                        pass

        time.sleep(scan_iv)

# ---------------------------------------------------------------------------
# Startup & Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description=f"WoWTranslate Universal Proxy v{VERSION}")
    parser.add_argument("--config", default="config.toml", help="Path to config.toml")
    parser.add_argument("--wow-root", default=None, help="Override WoW root directory")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    cfg_path = args.config if os.path.isabs(args.config) else os.path.join(script_dir, args.config)
    cfg = load_config(cfg_path)

    wow_root = os.path.abspath(args.wow_root) if args.wow_root else detect_wow_root(__file__)
    ipc_targets = get_all_ipc_targets(script_dir, wow_root)

    db_path = cfg.get("cache_db", "translations.db")
    if not os.path.isabs(db_path):
        db_path = os.path.join(script_dir, db_path)

    for target in ipc_targets:
        ensure_ipc_dirs(target)

    # Startup hygiene: silently drop cached translations with code-switching
    # artifacts so users who received bad entries get clean re-translations.
    cache_purge_code_switched(db_path)

    backends = cfg.get("backends", [])
    workers = cfg.get("workers", 4)
    http_port = cfg.get("http_port", 7654)

    print("==========================================================")
    print(f"  WoWTranslate Universal Proxy v{VERSION}")
    print(f"  WoW Root     : {wow_root}")
    print(f"  IPC Targets  : {ipc_targets}")
    print(f"  HTTP Port    : {http_port}")
    print(f"  Cache DB     : {db_path} ({cache_count(db_path)} entries)")
    print(f"  Backends     : {[b.get('type','?') for b in backends]}")
    print("==========================================================")

    # Start HTTP server
    start_http_server(http_port, db_path, backends, ipc_targets)

    # Start worker pool
    start_workers(workers, db_path, backends, ipc_targets)

    print("[proxy] Ready! Proxy is actively listening for translations.")
    print("[proxy] Press Ctrl+C to stop.\n")

    try:
        ipc_scanner(ipc_targets, db_path, backends, cfg)
    except KeyboardInterrupt:
        print("\n[proxy] Stopping proxy...")

if __name__ == "__main__":
    main()
