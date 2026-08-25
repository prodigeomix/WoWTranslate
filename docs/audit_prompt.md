# WoWTranslate Forensic Audit Prompt — v1

Date: 2026-08-25. Target: C:/Games/Interface/AddOns/WoWTranslate (v3.5.5, Turtle WoW 1.12.1 client, Python proxy wow_proxy.py).

## Mission
Full forensic audit of the addon (13 Lua files + wow_proxy.py + config.toml). Two passes minimum per wave: PASS A security/forensic, PASS B correctness/robustness. Iterate waves until a full wave produces zero confirmed findings.

## PASS A — Security / forensic checklist
1. Code execution primitives in Python: eval/exec/compile/__import__/subprocess/os.system/popen/pickle/marshal/yaml.load/ctypes. In Lua 5.0/1.12 API: RunScript, loadstring, and any use of insecure wrappers.
2. Network egress inventory: every URL/endpoint the proxy can contact; flag anything not localhost or a documented translation API (Google translate endpoint, DeepL, OpenAI, Gemini). Check for telemetry, DNS exfil via odd hostnames, encoded blobs.
3. Bind surfaces: confirm HTTP server binds loopback only; IPC dirs are local; no world-readable/writable handling.
4. File handling: path traversal in any filename built from request content (req_id from filenames, results files); symlink/toctou concerns; unbounded file growth.
5. Injection into game chat: does text from remote players / proxy results get sanitized before AddMessage / SendChatMessage? WoW 1.12 escape sequences |c...|r |H...|h...|h %s \124 — can a malicious translation inject links, formatting, fake system messages, or exploit chat-handling bugs?
6. Secrets handling: how are api keys stored/logged; do error prints leak keys?
7. Supply chain: verify git HEAD matches origin/main; list any files not tracked by git; check for obfuscated code (long base64 strings, hex blobs, minified sections).
8. Resource exhaustion: unbounded caches/dicts/logs, runaway threads, infinite retry loops.

## PASS B — Correctness / robustness checklist
1. Lua 5.0 compliance (1.12 client): no goto, no string methods beyond 5.0 set, careful with unpack/loadstring semantics.
2. Concurrency: SQLite WAL usage, thread locks around _http_results dict, IPC read/write races between scanner thread and workers.
3. Encoding: UTF-8 handling across CJK on Windows (mbcs vs utf-8 file writes), surrogate pairs, invalid bytes from network.
4. State machine: request lifecycle req->in_flight->result->cleanup; stale_ttl handling; double-processing; lost messages when proxy restarts mid-request.
5. Hooks: hook chain integrity (nextSendChatMessage pattern), unhook on logout, errors inside hooks breaking original chat flow, tainting.
6. String funcs: gsub replacement-string escaping (% in replacements), pattern injection from user/glossary data.
7. Cache correctness: hash collisions handled (PK is src_hash+langs), cache served for wrong direction, stale entries after language switch.
8. Error paths: every pcall guarded? exceptions in worker threads killing the worker silently?
9. Config parsing: malformed config.toml crash behavior, defaults.

## Method rules
- Every finding MUST cite exact file:line and quote the code. No speculation without a code citation.
- Classify each finding: CONFIRMED-BUG / CONFIRMED-RISK / SUSPECTED / INFO.
- Verify line numbers against current working tree before reporting.
- Known intentional behaviors (do not report as findings): dual-language mode appends original in parens; startup cache purge of embedded code-switched entries; preserve-list terms stay English; HTTP bound to 127.0.0.1.

## Deliverable
docs/audit_findings_v1.md with: executive summary, findings table (id, severity, classification, file:line, description, proposed fix), then fix plan ordered by severity. After fixes, run audit v2 on the new tree; repeat until a wave returns zero CONFIRMED findings. Record each wave's result at the bottom of this doc as: WAVE n: date, scope, findings count, clean Y/N.
