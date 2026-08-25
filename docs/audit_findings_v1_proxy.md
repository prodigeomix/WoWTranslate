# WoWTranslate Forensic Audit — v1, Python Proxy Scope (wow_proxy.py + config.toml)

Date: 2026-08-25. Auditor scope: `wow_proxy.py` (~1128 lines) + `config.toml`, working tree as-is.
Method: per docs/audit_prompt.md. Every finding cites file:line with quoted code from the current working tree (verified).
Lua-side findings are excluded except IPC contract issues visible from the Python side.

## Executive summary

The proxy is generally well-built for its threat model: HTTP binds loopback only (wow_proxy.py:930), no eval/exec/subprocess/pickle anywhere, no telemetry or undocumented egress (all endpoints are localhost Ollama or documented translation APIs), API keys are sent in headers/bodies rather than URLs and are not printed in logs, SQLite uses WAL with per-thread connections, and the in-flight set prevents double-processing of IPC requests. The literal `|` wire-format character is stripped from all translation results, which incidentally neutralizes most WoW 1.12 chat escape-sequence injection (`|c...|r`, `|H...|h`).

The confirmed issues are concentrated in the file-IPC contract: newline characters in translations are never sanitized before being written into a line-oriented `status|body` result file, and the scanner's stale-TTL deletion can destroy a request that is still being processed by a worker when backend timeouts stack past 60s. Remaining findings are low-severity robustness items.

## Findings table

| ID | Severity | Classification | File:Line | Description |
|----|----------|----------------|-----------|-------------|
| P-01 | High | CONFIRMED-BUG | wow_proxy.py:817-818 | Newlines in translation results are written unsanitized into the single-line IPC result file, corrupting the `status\|body` wire format |
| P-02 | Medium | CONFIRMED-RISK | wow_proxy.py:1019-1021 | Scanner deletes `.req` files purely on mtime age (`stale_ttl=60`) even while a worker is still processing them; stacked backend timeouts can exceed 60s, producing lost/duplicate requests |
| P-03 | Medium | CONFIRMED-RISK | wow_proxy.py:104-105 (+70-88) | If config.toml is malformed/corrupt or tomllib is unavailable, load_config silently falls back to DEFAULT_CONFIG which includes a Google web-translate backend — chat content is silently shipped to Google even though the user may have configured only local Ollama |
| P-04 | Low | CONFIRMED-BUG | wow_proxy.py:1035-1038 | A request file still being written by Lua (partial content, or write taking >1s) is parsed, fails, then deleted after age>1.0s; no atomic-rename expectation is enforced or tolerated on the reader side |
| P-05 | Low | SUSPECTED | wow_proxy.py:490, 507, 523 | `sl`/`tl` language codes are interpolated into Google endpoints unquoted (`f"...sl={sl}&tl={tl}..."`); a crafted lang value from an IPC request or HTTP query injects extra query parameters into the outbound request |
| P-06 | Low | CONFIRMED-RISK | wow_proxy.py:944-947 / 694-695 | Wire format reserves `\|` but the *request* text keeps embedded newlines (only edge-trimmed at :1029 via `.strip()`); multi-line request text flows into cache keys and backends, and any `\|` inside the text portion survives split(…,2) only to be re-emitted in the body position where it was already replaced — but a `\|` inside the from/to fields would shift field parsing |
| P-07 | Low | SUSPECTED | wow_proxy.py:852-916 | HTTP handler has no client-socket timeout and `/translate?q=` accepts unbounded text; a runaway local process can pin ThreadingHTTPServer threads and queue unbounded jobs (loopback-only mitigates) |
| P-08 | Low | SUSPECTED | wow_proxy.py:224-270 | `cache_purge_code_switched` loads the entire translations table into memory (`SELECT ... FROM translations` with no LIMIT) at every startup; a large cache causes slow starts and memory spike |
| P-09 | Low | SUSPECTED | wow_proxy.py:397-398, 613-614 | Post-processing regexes `^\*+(.*?)\*+$` and `^["\'](.*)["\']$` strip legitimate leading/trailing asterisk pairs or quotes from genuine translations (e.g., emphasis or quoted speech) — silent output mutation |
| P-10 | Low | SUSPECTED | wow_proxy.py:273-288 | `_is_ollama_online` reads/writes `_ollama_online`/`_ollama_last_check` globals without a lock from multiple workers — benign race (worst case duplicate probe), but also caches a False result for 15s during which all Ollama attempts are skipped even if Ollama just came up |
| P-11 | Info | INFO | wow_proxy.py:694-695, 732, 805 | All translation results have literal `\|` replaced by `/` on three redundant layers, which incidentally blocks WoW escape-sequence injection (`|c...|r`, `|Hitem...|h`) since those require a literal pipe; numeric `\124` forms exist only in Lua source literals, not runtime strings. No further chat sanitization is done Python-side — final safety depends on the Lua AddMessage path |
| P-12 | Info | INFO | wow_proxy.py:894-895 | Client-supplied `id` on `/translate` is used unchecked as the result-dict key; any local process can overwrite or read another requester's pending result (loopback only, acceptable) |
| P-13 | Info | INFO | wow_proxy.py:135, 1093-1094 | When WoW root detection fails, `detect_wow_root` returns a possibly nonexistent path three levels up and `main()` creates `IPC/requests/results` directories there anyway — silent directory litter outside the real install |
| P-14 | Info | INFO | repo root | Untracked runtime artifacts present: `translations.db-shm`, `translations.db-wal` (normal WAL sidecars; recommend .gitignore), plus modified `wow_proxy.py` (known-intentional working-tree fixes, not reported). Git HEAD f77288f matches v3.5.5 release commit. No base64/hex blobs or obfuscated code found in wow_proxy.py |

### Security checklist sweep (PASS A) — no-finding confirmations
- No code-execution primitives: no eval/exec/compile/__import__/subprocess/os.system/popen/pickle/marshal/yaml.load/ctypes anywhere in wow_proxy.py.
- Egress inventory: Ollama (localhost:11434 by default, configurable URL), DeepL api-free/api.deepl.com, OpenAI api.openai.com or configured base_url, Gemini generativelanguage.googleapis.com, Google translate.googleapis.com / clients5.google.com / translate.google.com. Nothing else. No DNS-exfil-shaped hostnames, no encoded blobs.
- Bind surface: `server_cls(("127.0.0.1", port), ...)` at wow_proxy.py:930 — loopback only (known-intentional, not counted as finding).
- Secrets: DeepL key goes in POST body (:418-423), OpenAI/Gemini keys in headers (:471, :598); error prints interpolate exception strings only, which do not include bodies/headers. `env:` indirection supported for OpenAI/Gemini (:440-441, :540-541). DeepL key has no env fallback and must sit plaintext in config.toml (acceptable for this threat model; noted).
- Resource exhaustion: `_http_results` bounded by clean_http_results(max_age=120) every 30s (:741-746, :1053-1055); worker pool fixed size; job queue bounded only by scan rate of on-disk requests.

### Correctness checklist sweep (PASS B) — no-finding confirmations
- SQLite: WAL + busy_timeout=5000, per-thread connections (:167-188) — sound.
- Request lifecycle: `_in_flight` set guards double-processing (:754-763, :1024); cache PK is (src_hash, from_lang, to_lang) so direction collisions are impossible (:181, :197-199); hash is sha256 (no practical collision concern).
- Encoding: all file I/O explicitly UTF-8 (:817, :959, :988, :1028); stdout reconfigured to utf-8 with errors="replace" (:49-54).
- Config parsing: malformed TOML caught and defaults used (:108-110) — see P-03 for the privacy caveat.
- Worker threads: translate() catches all backend exceptions (:689-712); cache get/set wrapped (:193-215); _write_ipc_result/_safe_delete swallow OS errors (:803-831). No silent worker-death path found.

## Fix plan (ordered by severity)

1. **P-01**: In `_write_ipc_result`, sanitize body for the wire: `body = body.replace("\r", " ").replace("\n", " ")` (alongside the existing pipe replace at :805). Optionally also strip control chars < 0x20.
2. **P-02**: In the scanner's stale branch (:1019), skip deletion when `req_path in _in_flight`; instead let the worker's `finally` block handle cleanup, or raise stale_ttl to exceed worst-case sum of configured backend timeouts (documented in config comments).
3. **P-03**: On config load failure, print a loud warning that the Google external fallback is active, and/or add a config flag `allow_external_fallback = true/false` consulted when assembling the effective backend list.
4. **P-04**: Document/enforce atomic-write expectation for Lua producers; on parse failure keep the retry window but log at first failure too (currently silent until age>1.0s).
5. **P-05**: `urllib.parse.quote(sl)` / `quote(tl)` in the three Google URL constructions; validate langs against `^[a-z]{2}(-[A-Z]{2})?$` at request intake.
6. **P-09/P-10/P-13**: Minor hardening — make quote-stripping optional/narrower, add a lock around Ollama health globals, and verify detected wow_root exists before creating IPC dirs.

## Wave log

WAVE 1: 2026-08-25, scope wow_proxy.py + config.toml (Python proxy), findings count: 14 (0 high-severity security RCE/egress; 1 confirmed correctness bug P-01), clean: N
