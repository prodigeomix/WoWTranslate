# WoWTranslate Forensic Audit — v2, Python Proxy Scope (wow_proxy.py + config.toml)

Date: 2026-08-25. Scope: `wow_proxy.py` (~1158 lines) + `config.toml`, working tree clean at commit `98c79bf` ("Release v3.5.6: forensic audit wave-1 remediation").
Method: per docs/audit_prompt.md. Wave-2 = verification of every wave-1 fix + fresh PASS A + PASS B sweep. Every finding cites file:line with quoted code from the current tree (line numbers verified).

## Executive summary

All high/medium wave-1 issues are genuinely fixed in the current tree: IPC result bodies are control-character-flattened before the single-line wire write (P-01), the scanner no longer deletes requests a worker still holds (P-02), malformed/no-config fallback now prints explicit warnings that the external Google fallback is active (P-03), Google URL lang params are percent-encoded with `safe=""` and IPC language codes are regex-validated at intake (P-05/P-06), and the Ollama health globals are lock-guarded (P-10). No code-execution primitives, no undocumented egress, no obfuscation (re-checked this wave).

The residual surface is low-severity only. One new confirmed bug was found: `_write_ipc_result` sanitizes pipe characters out of **ok** bodies only, so an error message containing `|` can corrupt the `status|body` wire format on the error path.

## Wave-1 fix verification

| ID | Wave-1 classification | Verdict | Evidence (current tree) |
|----|----------------------|---------|--------------------------|
| P-01 newline corruption in IPC result | CONFIRMED-BUG High | **FIXED — verified** | wow_proxy.py:821-824: `# Wire format is single-line "status|body": flatten any newlines/control\n# chars...\nif body:\n    body = "".join(ch if ord(ch) >= 0x20 else " " for ch in body)` — strips \r/\n and all C0 controls before `f.write(f"{status}|{body}")` at :837. Result is also written atomically via `.tmp` + `os.replace` (:833-838). |
| P-02 scanner deletes in-flight requests | CONFIRMED-RISK Medium | **FIXED — verified** | wow_proxy.py:1044-1052: `if age > stale_ttl:` … `if req_path not in _in_flight:\n    _safe_delete(req_path)\n    unmark_in_flight(req_path)` with comment "Do not delete while a worker holds this request". Worker `finally` deletes + unmarks (:812-815). Nit: the `unmark_in_flight(req_path)` at :1051 sits on the not-in-flight branch where it is a no-op — harmless. |
| P-03 silent Google fallback on bad config | CONFIRMED-RISK Medium | **FIXED — verified** (warning approach; flag option not implemented) | Loud warnings at wow_proxy.py:93, :97, :108, :113, e.g. :113: `"[config] WARNING: your configured backends were NOT loaded because the config is malformed; the default backend list (including external Google) is active instead. FIX config.toml to restore local-only translation."` DEFAULT_CONFIG still contains the google backend (:83-86) — accepted per fix plan. |
| P-04 partial-write parse/deletion race | CONFIRMED-BUG Low | **PARTIALLY FIXED** | Writer side hardened (atomic tmp+replace above). Reader still parses optimistically and only logs after `age > 1.0` (wow_proxy.py:1064-1067: `except Exception as e:\n    if age > 1.0:\n        print(f"[proxy] Error parsing {fname}: {e}")`) — first-parse failures remain silent; retained as P2-02 below. |
| P-05 unencoded sl/tl in Google URLs | SUSPECTED Low | **FIXED — verified** | wow_proxy.py:499-500: `sl = urllib.parse.quote(str(from_lang).lower(), safe="")` / same for `tl`; used at :505, :522, :538. Additionally intake validation at :969-971: `lang_re = re.compile(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})?$")` rejects anything carrying `\|` or newlines on the IPC path. HTTP `/translate` from/to are still unvalidated (:910-911) but are quoted before URL construction, so injection is neutralized. |
| P-06 request-side wire-format field shifting | CONFIRMED-RISK Low | **FIXED for IPC — verified** | The new lang regex (:969-971) makes a `\|`/newline in from/to impossible on the IPC path. HTTP path has no positional wire format. |
| P-07 no client-socket timeout / unbounded q | SUSPECTED Low | **NOT FIXED** | No `timeout` attribute on `ProxyHTTPHandler` (checked class body, wow_proxy.py:863-935); `/translate` still accepts unbounded `q` (:909). Retained as P2-03. Loopback-only mitigates. |
| P-08 purge loads full table at startup | SUSPECTED Low | **NOT CHANGED** | wow_proxy.py:235-237: `"SELECT src_hash, from_lang, to_lang, result FROM translations"` fetchall. Purge itself is known-intentional; only the memory-spike aspect remains (P2-04, downgraded INFO). |
| P-09 over-aggressive asterisk/quote stripping | SUSPECTED Low | **PARTIALLY FIXED** | Ollama path narrowed: bold-only `re.sub(r"^\*{2,}(.+)\*{2,}$", r"\1", ...)` (:407) and length-guarded quote strip `if len(result) <= 120` (:408-411). Gemini path still has the old unguarded pair at wow_proxy.py:628-629: `result = re.sub(r"^\*+(.*?)\*+$", r"\1", result)` / `result = re.sub(r'^["\\'](.*)["\\']$', r"\1", result)` — retained as P2-05. |
| P-10 unsynchronized Ollama health globals | SUSPECTED Low | **FIXED — verified** | wow_proxy.py:279 `_ollama_lock = threading.Lock()`; whole check inside `with _ollama_lock:` (:284-294). 15 s negative caching remains, by design. |
| P-11 pipe-strip blocks chat escape injection | INFO | Unchanged/correct | Three redundant layers: :710, :747, :820 (+ control flatten :824). |
| P-12 client-supplied id as result key | INFO | Unchanged | wow_proxy.py:908, :914; loopback-only, acceptable. |
| P-13 dirs created under possibly-bogus wow_root | INFO | **NOT FIXED** | detect_wow_root still returns `three_up` unchecked (:139); main() creates IPC dirs regardless (:1123-1124). |
| P-14 repo hygiene | INFO | Improved | Tree now clean; remediation committed as `98c79bf`. |

## New wave-2 findings

| ID | Severity | Classification | File:Line | Description |
|----|----------|----------------|-----------|-------------|
| P2-01 | Low | CONFIRMED-BUG | wow_proxy.py:818-820 | Pipe sanitization is applied only to success bodies: `def _write_ipc_result(req_id, status, body, ipc_targets):\n    if status == "ok" and body:\n        body = body.replace("|", "/")`. An error body containing a literal `|` (backend exception text is interpolated into error strings, e.g. :396 `err_msg = f"Ollama /api/generate failed: {ge}"`, then :811 `_write_ipc_result(req_id, "err", error or ..., ipc_targets)`) is written raw into the `status|body` line, so any Lua reader that splits on more than the first pipe mis-parses the error. Fix: replace `|` in body unconditionally (and keep the control-char flatten at :823-824, which already covers both statuses). |
| P2-02 | Low | SUSPECTED | wow_proxy.py:1064-1067 | Residual P-04: first parse failure of a request file is silent (`if age > 1.0:` guards the log), so a producer bug producing consistently malformed files is invisible for the first second of each file's life and produces no aggregate signal. Suggest logging first failure per file at DEBUG-equivalent or counting. |
| P2-03 | Low | SUSPECTED | wow_proxy.py:909, 863-935 | Residual P-07: `ProxyHTTPHandler` sets no client-socket `timeout` and `/translate?q=` is unbounded (`text = query.get("q", [""])[0]`). A stuck local client pins a ThreadingHTTPServer thread; loopback-only mitigates. One-liner: `timeout = 30` class attribute (BaseHTTPRequestHandler honors it). |
| P2-05 | Low | SUSPECTED | wow_proxy.py:628-629 | Residual P-09 (Gemini path): `result = re.sub(r"^\*+(.*?)\*+$", r"\1", result)` strips a legitimate leading/trailing emphasis asterisk pair from genuine translations, and the quote strip `r'^["\\'](.*)["\\']$'` is unlength-guarded here, unlike the Ollama path (:407-411). Align Gemini cleanup with the narrowed Ollama rules. |
| P2-06 | Info | SUSPECTED | wow_proxy.py:1130-1131, 852-857 | Config value types are unvalidated: a TOML typo like `workers = "4"` passes tomllib and crashes at `for i in range(n)` with a raw traceback after the HTTP server thread has already started (daemon threads exit, but startup UX is a stack dump). Similarly `http_port` out of range fails only inside `start_http_server`'s try (handled, :954-956). |
| P2-04 | Info | INFO | wow_proxy.py:235-237 | Residual P-08: `cache_purge_code_switched` loads the entire translations table into memory each startup. Fine at expected scale (chat-sized rows); revisit if cache grows past ~100k entries. |
| P2-07 | Info | INFO | wow_proxy.py:284-293 | `_is_ollama_online` holds `_ollama_lock` across the network probe (up to 1.5 s timeout), serializing all workers during an offline-probe window. Worst case adds ~1.5 s latency to concurrent jobs when Ollama is down; acceptable, noted for completeness. |

## PASS A sweep (fresh) — confirmations

- No code-execution primitives: re-scanned for eval/exec/compile/__import__/subprocess/os.system/popen/pickle/marshal/yaml.load/ctypes — only hit is `re.compile` at wow_proxy.py:969 (benign).
- Egress inventory unchanged and clean: Ollama (localhost by default), DeepL api-free/api.deepl.com (:432), OpenAI base_url default api.openai.com (:462), Gemini generativelanguage.googleapis.com (:606), Google translate.googleapis.com/clients5.google.com/translate.google.com (:505/:522/:538). Nothing new; no blobs (long-base64 scan clean).
- Bind: `server_cls(("127.0.0.1", port), ProxyHTTPHandler)` at wow_proxy.py:949 — loopback only.
- Secrets: keys in headers/body only (:486 Authorization header, :613 x-goog-api-key, DeepL key in POST body :433-438); `env:` indirection intact (:455-458, :555-558); no key material in log prints.

## PASS B sweep (fresh) — confirmations

- SQLite WAL + busy_timeout + per-thread connections (:175-191) sound; PK (src_hash, from_lang, to_lang) prevents direction collisions (:185, :201-202).
- Request lifecycle: `_in_flight` guard correct (:769-778, :1049-1055); worker `finally` guarantees req deletion + unmark even on unexpected exceptions (:812-816); atomic result write via os.replace (:836-838).
- Encoding: UTF-8 everywhere on file I/O (:836, :984, :1013, :1058); stdout reconfigured utf-8/replace (:49-54).
- Stacked-timeout math: config.toml worst case ollama 20 s (×2 endpoints = 40 s) + google 8 s = 48 s < stale_ttl 60 s, and the in-flight guard now makes TTL overrun safe regardless (config.toml:7,27,35).
- Worker threads: all backend exceptions caught in translate() (:704-727); cache ops wrapped (:198-207, :210-219). No silent worker-death path.
- Known-intentional items excluded per spec: dual-language parens append, startup code-switch purge itself, preserve-list English terms, 127.0.0.1 bind.

## Wave log

WAVE 1: 2026-08-25, scope wow_proxy.py + config.toml (Python proxy), findings count: 14, clean: N
WAVE 2: 2026-08-25, scope wow_proxy.py + config.toml re-audit post-remediation (commit 98c79bf). Wave-1 fixes: 6 verified fixed (P-01, P-02, P-03, P-05, P-06, P-10), 2 partially fixed (P-04, P-09), 5 unchanged low/info (P-07, P-08, P-12, P-13, P-14-resolved). New findings: 7 (1 CONFIRMED-BUG low P2-01, 3 SUSPECTED low, 3 INFO). Confirmed-findings count: 1 (low). Clean: N (one low-severity confirmed bug; no medium/high remaining).
