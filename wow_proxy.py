"""
wow_proxy.py  v3.5  —  WoWTranslate Universal Proxy & Backend Engine
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
  - Google Translate (built-in free web client fallback — zero setup required!)

Persistent SQLite Cache (translations.db):
  Instant translation responses for previously translated text.
"""

import argparse
import hashlib
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
import urllib.parse
import urllib.request

# Ensure UTF-8 output on Windows consoles
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

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
        return dict(DEFAULT_CONFIG)
    if tomllib is None:
        print("[config] tomllib/tomli not installed — using defaults.")
        return dict(DEFAULT_CONFIG)
    try:
        with open(path, "rb") as f:
            cfg = tomllib.load(f)
        for k, v in DEFAULT_CONFIG.items():
            if k not in cfg:
                cfg[k] = v
        # Ensure google fallback is always present if no backends configured
        if "backends" not in cfg or not cfg["backends"]:
            cfg["backends"] = DEFAULT_CONFIG["backends"]
        print(f"[config] Loaded {path}")
        return cfg
    except Exception as e:
        print(f"[config] Error reading {path}: {e}, using defaults.")
        return dict(DEFAULT_CONFIG)

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

# ---------------------------------------------------------------------------
_ollama_online = None
_ollama_last_check = 0

def _is_ollama_online(url="http://localhost:11434/api/tags"):
    global _ollama_online, _ollama_last_check
    now = time.time()
    if _ollama_online is not None and (now - _ollama_last_check) < 15:
        return _ollama_online
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "WoWTranslateProxy/3.5"})
        with urllib.request.urlopen(req, timeout=0.8) as resp:
            _ollama_online = (resp.status == 200)
    except Exception:
        _ollama_online = False
    _ollama_last_check = now
    return _ollama_online

def _call_ollama(text, from_lang, to_lang, backend):
    tags_url = backend.get("url", "http://localhost:11434/api/generate").replace("/api/generate", "/api/tags")
    if not _is_ollama_online(tags_url):
        raise ConnectionRefusedError("Ollama is not running on localhost:11434")

    prompt = (
        f"Translate the following World of Warcraft chat message from {from_lang} to {to_lang}.\n"
        f"Output ONLY the translated text without explanations, quotes, or markdown.\n"
        f"Message: {text}\n"
        f"Translation:"
    )
    url = backend.get("url", "http://localhost:11434/api/generate")
    model = backend.get("model", "qwen2.5")
    timeout = backend.get("timeout", 5)
    payload = json.dumps({
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.1, "num_predict": 256},
    }).encode("utf-8")
    req = urllib.request.Request(
        url, data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "WoWTranslateProxy/3.5"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    result = data.get("response", "").strip()
    if not result:
        raise ValueError("Ollama returned empty response")
    return result

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
    
    endpoint = "https://api-free.deepl.com/v2/translate" if api_key.endswith(":fx") else "https://api.deepl.com/v2/translate"
    params = urllib.parse.urlencode({
        "auth_key": api_key,
        "text": text,
        "source_lang": src,
        "target_lang": tgt,
    }).encode("utf-8")
    
    req = urllib.request.Request(
        endpoint, data=params,
        headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": "WoWTranslateProxy/3.5"},
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
        "You are an expert translator for World of Warcraft Classic.\n"
        "Translate chat accurately, preserving MMO terms (LFG, DPS, MT, OT, CC, etc.) and placeholders (http://ph.wt/1).\n"
        "Output ONLY the translated text without quotes or preamble."
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
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}", "User-Agent": "WoWTranslateProxy/3.5"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    choices = data.get("choices", [])
    if not choices:
        raise ValueError("OpenAI returned no choices")
    return choices[0]["message"]["content"].strip()

def _call_google(text, from_lang, to_lang, backend):
    """Free Google Translate web API fallback (zero configuration required)."""
    timeout = backend.get("timeout", 8)
    sl = from_lang.lower()
    tl = to_lang.lower()
    encoded = urllib.parse.quote(text)
    url = f"https://translate.googleapis.com/translate_a/single?client=gtx&sl={sl}&tl={tl}&dt=t&q={encoded}"
    
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "*/*",
    }
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
        data = json.loads(raw)
        
    # Result format: [[[translated_seg1, src_seg1, ...], [translated_seg2, ...]], ...]
    if not data or not isinstance(data, list) or not data[0]:
        raise ValueError("Invalid Google Translate response format")
    
    parts = []
    for seg in data[0]:
        if seg and isinstance(seg, list) and seg[0]:
            parts.append(seg[0])
    
    result = "".join(parts).strip()
    if not result:
        raise ValueError("Google Translate returned empty text")
    return result

def _call_gemini(text, from_lang, to_lang, backend):
    """Google AI Studio (Gemini) API Backend."""
    api_key = backend.get("api_key", "").strip()
    if api_key.startswith("env:"):
        api_key = os.environ.get(api_key[4:], "").strip()
    if not api_key:
        api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key or api_key.startswith("YOUR_") or api_key == "AIzaSy...":
        raise ValueError("Gemini api_key not configured (please paste your Google AI Studio key in config.toml)")

    model = backend.get("model", "gemini-2.0-flash")
    timeout = backend.get("timeout", 10)
    
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
    system_prompt = (
        "You are an expert translator for World of Warcraft Classic.\n"
        "Translate chat accurately, preserving MMO terms (LFG, DPS, MT, OT, CC, etc.) and placeholders (http://ph.wt/1).\n"
        "Output ONLY the translated text without quotes, markdown formatting, or preamble."
    )
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
        }
    }).encode("utf-8")
    
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": "WoWTranslateProxy/3.5"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    
    candidates = data.get("candidates", [])
    if not candidates:
        raise ValueError("Gemini returned no candidates")
    parts = candidates[0].get("content", {}).get("parts", [])
    if not parts:
        raise ValueError("Gemini returned no content parts")
    return parts[0].get("text", "").strip()

BACKEND_FNS = {
    "gemini": _call_gemini,
    "google_ai": _call_gemini,
    "google_studio": _call_gemini,
    "ollama": _call_ollama,
    "deepl": _call_deepl,
    "openai": _call_openai,
    "google": _call_google,
}

def translate(text, from_lang, to_lang, backends):
    """Tries backends in order; returns (result_text, None) on success or (None, err_msg)."""
    if not text or not text.strip():
        return "", None
    
    last_err = "No backends configured"
    for backend in backends:
        btype = backend.get("type", "?").lower()
        fn = BACKEND_FNS.get(btype)
        if not fn:
            continue
        try:
            result = fn(text, from_lang, to_lang, backend)
            if result:
                # Clean up apostrophe space artifact e.g. "doesn' t" -> "doesn't"
                result = re.sub(r"'%s+(\w)", r"'\1", result)
                print(f"[translate] [{btype}] {from_lang}→{to_lang}: '{text[:40]}' → '{result[:40]}'")
                return result, None
        except Exception as e:
            last_err = f"{btype}: {e}"
            print(f"[translate] [{btype}] failed: {e}")
            continue
            
    # If all configured backends failed and google was not attempted, try google fallback
    has_google = any(b.get("type", "").lower() == "google" for b in backends)
    if not has_google:
        try:
            print("[translate] Attempting automatic Google fallback...")
            res = _call_google(text, from_lang, to_lang, {"timeout": 8})
            if res:
                print(f"[translate] [google-fallback] {from_lang}→{to_lang}: '{text[:40]}' → '{res[:40]}'")
                return res, None
        except Exception as e:
            last_err = f"google-fallback: {e}"
            print(f"[translate] [google-fallback] failed: {e}")
            
    return None, f"All translation backends failed ({last_err})"

# ---------------------------------------------------------------------------
# Memory & HTTP Queue Coordination
# ---------------------------------------------------------------------------
_http_results = {}  # req_id -> {"result": str, "error": str, "time": float}
_http_results_lock = threading.Lock()

def store_http_result(req_id, result, error):
    with _http_results_lock:
        _http_results[req_id] = {
            "result": result or "",
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
_job_queue = queue.Queue()

def _worker(db_path, backends, ipc_targets):
    while True:
        try:
            item = _job_queue.get(timeout=1)
        except queue.Empty:
            continue
        
        req_id, req_file_path, from_lang, to_lang, text, is_http = item
        
        # Check SQLite Cache first
        cached = cache_get(db_path, text, from_lang, to_lang)
        if cached:
            if is_http:
                store_http_result(req_id, cached, "")
            if req_file_path:
                _write_ipc_result(req_id, "ok", cached, ipc_targets)
                _safe_delete(req_file_path)
            _job_queue.task_done()
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
                
        if req_file_path:
            _safe_delete(req_file_path)
            
        _job_queue.task_done()

def _write_ipc_result(req_id, status, body, ipc_targets):
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
    
    class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", port), ProxyHTTPHandler)
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
    return parts[0], parts[1], parts[2]

def ipc_scanner(ipc_targets, db_path, backends, cfg):
    stale_ttl = cfg.get("stale_ttl", 60)
    scan_iv = cfg.get("scan_interval", 0.05)
    in_flight = set()

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

                if req_id in in_flight:
                    continue

                try:
                    age = now - os.path.getmtime(req_path)
                except Exception:
                    continue

                if age > stale_ttl:
                    _safe_delete(req_path)
                    in_flight.discard(req_id)
                    continue

                try:
                    with open(req_path, "r", encoding="utf-8") as f:
                        content = f.read().strip()
                    from_lang, to_lang, text = parse_request_file(content)
                except Exception as e:
                    print(f"[proxy] Error parsing {fname}: {e}")
                    _safe_delete(req_path)
                    continue

                # Cache check
                cached = cache_get(db_path, text, from_lang, to_lang)
                if cached:
                    _write_ipc_result(req_id, "ok", cached, ipc_targets)
                    _safe_delete(req_path)
                    print(f"[proxy] [cache-hit] {from_lang}→{to_lang}: '{text[:40]}'")
                    continue

                in_flight.add(req_id)
                _job_queue.put((req_id, req_path, from_lang, to_lang, text, False))

            # 3. Clean finished requests from in_flight set
            for rid in list(in_flight):
                check_fname = f"req_{rid}.txt" if is_imports else f"{rid}.req"
                if not os.path.exists(os.path.join(req_dir, check_fname)):
                    in_flight.discard(rid)

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
    parser = argparse.ArgumentParser(description="WoWTranslate Universal Proxy v3.5")
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

    backends = cfg.get("backends", [])
    workers = cfg.get("workers", 4)
    http_port = cfg.get("http_port", 7654)

    print("==========================================================")
    print("  WoWTranslate Universal Proxy v3.5")
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
