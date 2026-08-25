# WoWTranslate Forensic Audit — v3, Python Proxy Scope (wow_proxy.py + config.toml)

Date: 2026-08-25. Scope: `wow_proxy.py` (1160 lines) + `config.toml`.
Method: per docs/audit_prompt.md. Wave-3 = verification of the wave-2 P2-01 fix + fresh PASS A + PASS B sweep. Every claim cites file:line from the current tree.

## Executive summary

**CLEAN — zero CONFIRMED findings.** The single wave-2 confirmed bug (P2-01, pipe sanitization applied only to `ok` bodies) is fixed correctly. The residual surface is unchanged from wave 2: 3 SUSPECTED-low items and 3 INFO items, none materially worse than documented. This wave closes the loop per the audit spec.

## P2-01 fix verification

**FIXED — verified correct.**

- wow_proxy.py:818-822:
  ```python
  def _write_ipc_result(req_id, status, body, ipc_targets):
      # Pipe sanitization must apply on BOTH ok and err bodies: the wire format
      # is "status|body", so an error message containing "|" would corrupt it.
      if body:
          body = body.replace("|", "/")
  ```
  The `status == "ok"` guard from wave 2 is gone; replacement is unconditional. Error bodies carrying literal `|` (e.g. backend exception text interpolated at :396-399, written via :811 `_write_ipc_result(req_id, "err", error or ...)`) are now neutralized before the wire write.
- The control-char flatten (:825-826 `body = "".join(ch if ord(ch) >= 0x20 else " " for ch in body)`) likewise applies to both statuses, so `\r`/`\n` cannot break the single-line write at :839 `f.write(f"{status}|{body}")`.
- Atomicity intact: `.tmp` + `os.replace` (:838-840); tmp cleanup on failure (:841-845).
- Edge check: `status` is always a literal `"ok"`/`"err"` at all six call sites (:797, :806, :811, :1076 plus HTTP-only paths), so the status field itself can never contain `|`. Wire format is now fully producer-safe.

No regressions introduced by the fix.

## Fresh PASS A sweep — confirmations

- Code-execution primitives: re-scanned for eval/exec/compile/__import__/subprocess/os.system/popen/pickle/marshal/yaml.load/ctypes — only benign hit remains `re.compile` (:971).
- Egress inventory unchanged: Ollama (localhost default, :297-304), DeepL api-free/api.deepl.com (:432), OpenAI base_url default api.openai.com (:462), Gemini generativelanguage.googleapis.com (:606), Google translate.googleapis.com / clients5.google.com / translate.google.com (:505/:522/:538). No telemetry, no encoded blobs, no odd hostnames.
- Bind surface: `server_cls(("127.0.0.1", port), ProxyHTTPHandler)` (:951) — loopback only. IPC dirs are local paths under wow_root/script_dir.
- File handling: result filenames built only from `req_id` derived from `os.listdir` entries (:1033/:1037), never from raw request content — no traversal vector on the writer side. `/poll?id=` and client-supplied HTTP ids touch only an in-memory dict key (:898, :910), not the filesystem.
- Injection into chat: three redundant pipe-strip layers remain (:710, :747, :821-822) plus control flatten (:825-826); Lua-side escaping out of scope this wave.
- Secrets: keys in headers/body only (Authorization :486, x-goog-api-key :613, DeepL body :433-438); `env:` indirection intact (:455-458, :555-558); no key material printed in any log path (checked every print/f-string).

## Fresh PASS B sweep — confirmations

- SQLite: WAL + busy_timeout + per-thread connections (:175-191); PK (src_hash, from_lang, to_lang) prevents direction collisions; parameterized queries throughout.
- Lifecycle: `_in_flight` guard correct (:769-778, :1046-1057); worker `finally` guarantees deletion + unmark (:812-816); stale-skip honors in-flight (:1051). The no-op `unmark_in_flight` at :1053 (not-in-flight branch) remains harmless, as documented in wave 2.
- Encoding: UTF-8 on all file I/O (:838, :986, :1015, :1060); stdout reconfigured utf-8/replace (:49-54).
- Stacked timeouts: config.toml worst case ollama 20 s ×2 endpoints + google 8 s = 48 s < stale_ttl 60 s; in-flight guard makes overrun safe regardless.
- Workers: all backend exceptions caught in translate() (:704-727); cache ops wrapped (:198-207, :210-219); purge wrapped (:233-240, per-row try :246-265). No silent worker-death path found.
- Config parsing: malformed config → loud warnings + defaults (:111-114); missing-file/tomli-absent paths warned (:91-98). Type-validation gap remains P2-06 (SUSPECTED, below).
- Quote-strip edge at :408-411 verified safe for 0- and 1-char results (`len(result) >= 2` guards the slice).
- Known-intentional items excluded per spec: dual-language parens append, startup code-switch purge itself, preserve-list terms, 127.0.0.1 bind.

## Residual items (unchanged classification, not materially worse than v2)

| ID | Severity | Classification | File:Line | Status |
|----|----------|----------------|-----------|--------|
| P2-03 | Low | SUSPECTED | :909-913, :865 | No client-socket timeout; unbounded `q`. Loopback mitigates; unchanged. |
| P2-05 | Low | SUSPECTED | :628-629 | Gemini cleanup still uses unguarded asterisk/quote strips (Ollama path narrowed at :407-411). Cosmetic over-stripping risk only. |
| P2-06 | Low | SUSPECTED | :1130-1134, :852-857 | Config value types unvalidated (`workers = "4"` → raw traceback post-server-start). Startup UX only. |
| P2-02 | Low | SUSPECTED | :1066-1070 | First parse failure silent when age ≤ 1.0 s (by design for partial-write tolerance); no aggregate signal. |
| P2-04 | Info | INFO | :235-237 | Startup purge loads full table. Fine at expected scale. |
| P2-07 | Info | INFO | :284-294 | Ollama probe holds lock ≤1.5 s. Accepted. |
| P-13 | Info | INFO | :126-139, :1125-1126 | detect_wow_root fallback unchecked; dirs created regardless. Unchanged. |

None of these were found materially worse than documented in wave 2; per task rules they stand as previously classified and are not re-raised as CONFIRMED.

## Wave log

WAVE 3: 2026-08-25, scope wow_proxy.py + config.toml re-audit post-P2-01-fix. P2-01 fix verified correct (unconditional pipe + control-char sanitization on both statuses, atomic write intact). Fresh PASS A + PASS B: no new findings. Residual: 4 SUSPECTED-low, 3 INFO, 0 CONFIRMED. Confirmed-findings count: 0. **Clean: Y — loop closed.**
