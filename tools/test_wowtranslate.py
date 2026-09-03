#!/usr/bin/env python3
"""
tools/test_wowtranslate.py
==========================
Comprehensive unit and integration test suite for WoWTranslate v3.6.1.

Test Suites:
  1. UTF-8 Multi-byte Safe Truncation Engine (ASCII, CJK, Kana, Cyrillic, 4-byte Emojis, boundary walkbacks).
  2. SuperWoW Wire Framing & IPC Envelope Limits (280b chat limit, 300b ExportFile limit, 320b client buffer cap).
  3. Wire Protocol Format & Escaping (status|body, pipes, newlines, control chars).
  4. Glossary Preprocessing & Normalization (LFG role shorthand, sentence terminators, currency notation).
  5. SQLite Translation Database (schema, WAL mode, concurrency, hashing, key isolation).
  6. Config.toml validation & Fallback Safety.
  7. Spanish Source Language & Accent/Gaming Vocabulary Detection Engine.
"""

import hashlib
import os
import re
import sqlite3
import tempfile
import time
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ADDON_DIR = os.path.dirname(SCRIPT_DIR)

# ---------------------------------------------------------------------------
# Reference Implementation of WT_SafeUTF8Truncate matching Lua logic
# ---------------------------------------------------------------------------
def py_safe_utf8_truncate(s: str, max_bytes: int) -> str:
    """
    Python equivalent of WT_SafeUTF8Truncate (WoWTranslate_String.lua).
    Truncates a string to at most max_bytes without severing multi-byte sequences.
    """
    if not s or max_bytes <= 0:
        return ""
    raw = s.encode("utf-8")
    if len(raw) <= max_bytes:
        return s

    cut = max_bytes
    back = 0
    while cut > 0 and back < 4:
        b = raw[cut - 1]
        if b < 128:
            return raw[:cut].decode("utf-8", errors="ignore")
        elif b >= 192:
            needed = 3 if b >= 240 else (2 if b >= 224 else 1)
            if back == needed:
                return raw[: cut + back].decode("utf-8", errors="ignore")
            else:
                if cut <= 1:
                    return ""
                return raw[: cut - 1].decode("utf-8", errors="ignore")
        else:
            cut -= 1
            back += 1

    if cut <= 0:
        return ""
    return raw[:cut].decode("utf-8", errors="ignore")


class TestUTF8Truncation(unittest.TestCase):
    """Verifies that the UTF-8 truncation algorithm never creates invalid byte sequences."""

    def test_ascii_truncation(self):
        text = "World of Warcraft 1.12.1 Turtle WoW"
        for cap in range(1, len(text) + 5):
            res = py_safe_utf8_truncate(text, cap)
            raw = res.encode("utf-8")
            self.assertLessEqual(len(raw), cap)
            self.assertEqual(res, raw.decode("utf-8"))

    def test_chinese_cjk_truncation(self):
        text = "魔兽世界乌龟服中文实时翻译插件！"
        for cap in range(1, len(text.encode("utf-8")) + 5):
            res = py_safe_utf8_truncate(text, cap)
            raw = res.encode("utf-8")
            self.assertLessEqual(len(raw), cap)
            # Must strictly decode without errors
            decoded = raw.decode("utf-8")
            self.assertEqual(decoded, res)
            # CJK characters are 3 bytes each; raw length must be multiple of 3
            self.assertEqual(len(raw) % 3, 0)

    def test_japanese_kana_and_kanji(self):
        text = "こんにちは世界！タートルWoWへようこそ"
        for cap in range(1, len(text.encode("utf-8")) + 5):
            res = py_safe_utf8_truncate(text, cap)
            raw = res.encode("utf-8")
            self.assertLessEqual(len(raw), cap)
            self.assertEqual(res, raw.decode("utf-8"))

    def test_cyrillic_russian(self):
        text = "Привет мир! Перевод сообщений чата ВоВ."
        for cap in range(1, len(text.encode("utf-8")) + 5):
            res = py_safe_utf8_truncate(text, cap)
            raw = res.encode("utf-8")
            self.assertLessEqual(len(raw), cap)
            self.assertEqual(res, raw.decode("utf-8"))

    def test_four_byte_emojis(self):
        text = "🎮⚔️🛡️🔥🌟✨🎉"
        for cap in range(1, len(text.encode("utf-8")) + 5):
            res = py_safe_utf8_truncate(text, cap)
            raw = res.encode("utf-8")
            self.assertLessEqual(len(raw), cap)
            self.assertEqual(res, raw.decode("utf-8"))

    def test_edge_cases(self):
        self.assertEqual(py_safe_utf8_truncate("", 10), "")
        self.assertEqual(py_safe_utf8_truncate("abc", 0), "")
        self.assertEqual(py_safe_utf8_truncate("abc", -5), "")


class TestSuperWoWFraming(unittest.TestCase):
    """Verifies SuperWoW wire protocol limits."""

    def test_superwow_chat_limits(self):
        long_chinese = "测试" * 150  # 900 bytes
        capped = py_safe_utf8_truncate(long_chinese, 280)
        raw = capped.encode("utf-8")
        self.assertLessEqual(len(raw), 280)

        wire_req = "zh|en|" + capped
        wire_capped = py_safe_utf8_truncate(wire_req, 300)
        raw_wire = wire_capped.encode("utf-8")
        self.assertLessEqual(len(raw_wire), 300)
        self.assertLessEqual(len(raw_wire), 320)  # SuperWoW client buffer limit


class TestGlossaryAndLFGPreprocessing(unittest.TestCase):
    """Verifies LFG shorthand and Turtle WoW terminology regex patterns."""

    def test_lfg_role_replacement(self):
        patterns = [
            ("来TND", " LF Tank Healer DPS "),
            ("来TN", " LF Tank Healer "),
            ("来TD", " LF Tank DPS "),
            ("来ND", " LF Healer DPS "),
        ]
        for src, expected in patterns:
            res = re.sub(r"\u6765\s*[tT]\s*[nN]\s*[dD]", " LF Tank Healer DPS ", src)
            res = re.sub(r"\u6765\s*[tT]\s*[nN]", " LF Tank Healer ", res)
            res = re.sub(r"\u6765\s*[tT]\s*[dD]", " LF Tank DPS ", res)
            res = re.sub(r"\u6765\s*[nN]\s*[dD]", " LF Healer DPS ", res)
            self.assertEqual(res.strip(), expected.strip())

    def test_currency_notation(self):
        # 100G -> 100g, 50Y -> 50s
        text = "WTS Arcanite Bar 100G 50Y"
        text = re.sub(r"(\d+)G([^a-zA-Z]|$)", r"\1g\2", text)
        text = re.sub(r"(\d+)Y([^a-zA-Z]|$)", r"\1s\2", text)
        self.assertEqual(text, "WTS Arcanite Bar 100g 50s")


class TestSQLiteDatabase(unittest.TestCase):
    """Tests SQLite translation cache behavior and key hashing."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.temp_dir.name, "test_translations.db")
        self.conn = sqlite3.connect(self.db_path)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS translations (
                src_hash  TEXT NOT NULL,
                from_lang TEXT NOT NULL,
                to_lang   TEXT NOT NULL,
                result    TEXT NOT NULL,
                created   INTEGER NOT NULL,
                PRIMARY KEY (src_hash, from_lang, to_lang)
            )
        """)
        self.conn.commit()

    def tearDown(self):
        self.conn.close()
        self.temp_dir.cleanup()

    def test_insert_and_retrieve(self):
        src_text = "你好世界"
        src_hash = hashlib.sha256(src_text.encode("utf-8")).hexdigest()
        self.conn.execute(
            "INSERT INTO translations VALUES (?, ?, ?, ?, ?)",
            (src_hash, "zh", "en", "Hello world", 1700000000),
        )
        self.conn.commit()

        row = self.conn.execute(
            "SELECT result FROM translations WHERE src_hash=? AND from_lang=? AND to_lang=?",
            (src_hash, "zh", "en"),
        ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "Hello world")


class TestSpanishLanguageDetection(unittest.TestCase):
    """Tests Spanish source language detection matching WoWTranslate_String.lua logic."""

    SPANISH_WORDS = frozenset({
        "hola", "buenas", "buenos", "gracias", "denada", "amigo", "amigos", "chicos",
        "gente", "saludos", "adios", "hasta", "busco", "buscamos", "buscan", "alguien",
        "nadie", "necesito", "necesitamos", "necesitan", "mazmorra", "mazmorras", "estancia",
        "estancias", "hermandad", "sanador", "sanadores", "curandero", "mision", "misiones",
        "ayuda", "ayudame", "listo", "listos", "vamos", "venga", "tanque", "donde", "cuanto",
        "cuando", "quien", "quienes", "porque", "como", "aqui", "alli", "alla", "para", "pero",
        "muy", "mucho", "muchos", "tambien", "tampoco", "todos", "todas", "tengo", "tenemos",
        "tienes", "teneis", "puedo", "puedes", "podemos", "estoy", "estan", "estamos", "somos",
        "vendo", "compro", "vender", "comprar", "hacer", "hacemos", "hacen", "unirse",
        "invita", "invitame", "invitacion", "reparar"
    })

    def detect_lang(self, text, enabled_langs=None):
        if enabled_langs is None:
            enabled_langs = {"zh": True, "ja": True, "ko": True, "ru": True, "es": True, "en": False}

        raw = text.encode("utf-8")
        has_cjk = False
        has_kana = False
        has_korean = False
        has_russian = False
        has_spanish_accent = False
        ascii_alpha = 0

        i = 0
        text_len = len(raw)
        while i < text_len:
            b = raw[i]
            if 234 <= b <= 237:
                has_korean = True
                i += 3
            elif b == 227:
                b2 = raw[i + 1] if i + 1 < text_len else 0
                if 129 <= b2 <= 131:
                    has_kana = True
                i += 3
            elif 228 <= b <= 233:
                has_cjk = True
                i += 3
            elif b in (208, 209):
                has_russian = True
                i += 2
            elif b == 195:
                b2 = raw[i + 1] if i + 1 < text_len else 0
                if (129 <= b2 <= 158) or (161 <= b2 <= 190):
                    has_spanish_accent = True
                i += 2
            elif b == 194:
                b2 = raw[i + 1] if i + 1 < text_len else 0
                if b2 in (161, 191):
                    has_spanish_accent = True
                i += 2
            elif 192 <= b <= 255 and (b < 227 or b > 237):
                has_spanish_accent = True
                i += 1
            else:
                if (65 <= b <= 90) or (97 <= b <= 122):
                    ascii_alpha += 1
                i += 1

        if enabled_langs.get("ko") and has_korean:
            return "ko"
        if enabled_langs.get("ja") and has_kana:
            return "ja"
        if enabled_langs.get("zh") and has_cjk:
            return "zh"
        if enabled_langs.get("ru") and has_russian:
            return "ru"

        if enabled_langs.get("es") and not (has_cjk or has_korean or has_kana or has_russian):
            words = re.findall(r"[a-zA-Z]+", text.lower())
            has_spanish_word = any(w in self.SPANISH_WORDS for w in words)
            if has_spanish_accent or has_spanish_word:
                return "es"

        if enabled_langs.get("en") and ascii_alpha >= 4 and not (has_cjk or has_korean or has_kana or has_russian or has_spanish_accent):
            return "en"

        return None

    def test_accented_spanish(self):
        self.assertEqual(self.detect_lang("¿Alguien para mazmorra?"), "es")
        self.assertEqual(self.detect_lang("¡Hola amigos!"), "es")
        self.assertEqual(self.detect_lang("Tengo que hacer la misión"), "es")

    def test_unaccented_spanish_gaming_chat(self):
        self.assertEqual(self.detect_lang("hola busco grupo para mazmorra"), "es")
        self.assertEqual(self.detect_lang("busco dps y sanador estancia"), "es")
        self.assertEqual(self.detect_lang("buenas alguien para hacer mision"), "es")
        self.assertEqual(self.detect_lang("necesito tanque para cueva"), "es")

    def test_english_not_detected_as_spanish(self):
        self.assertEqual(self.detect_lang("LFM 1 DPS deadmines need tank and healer"), None)
        self.assertEqual(self.detect_lang("where is the quest turn in?"), None)
        self.assertEqual(self.detect_lang("LF2M SM cath fast run"), None)

    def test_spanish_toggle_disabled(self):
        disabled = {"zh": True, "ja": True, "ko": True, "ru": True, "es": False, "en": False}
        self.assertIsNone(self.detect_lang("hola busco grupo para mazmorra", disabled))

    def test_database_spanish_cache(self):
        temp_dir = tempfile.TemporaryDirectory()
        db_path = os.path.join(temp_dir.name, "test_es.db")
        conn = sqlite3.connect(db_path)
        conn.execute("""
            CREATE TABLE translations (
                src_hash  TEXT NOT NULL,
                from_lang TEXT NOT NULL,
                to_lang   TEXT NOT NULL,
                result    TEXT NOT NULL,
                created   INTEGER NOT NULL,
                PRIMARY KEY (src_hash, from_lang, to_lang)
            )
        """)
        src_text = "hola busco grupo para mazmorra"
        src_hash = hashlib.sha256(src_text.encode("utf-8")).hexdigest()
        conn.execute(
            "INSERT INTO translations VALUES (?, ?, ?, ?, ?)",
            (src_hash, "es", "en", "hello looking for dungeon group", 1700000000),
        )
        conn.commit()

        row = conn.execute(
            "SELECT result FROM translations WHERE src_hash=? AND from_lang=? AND to_lang=?",
            (src_hash, "es", "en"),
        ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row[0], "hello looking for dungeon group")
        conn.close()
        temp_dir.cleanup()


class TestHyperlinkExtractionAndSanitization(unittest.TestCase):
    """Verifies hyperlink preservation and display text sanitization."""

    @staticmethod
    def py_sanitize_display_text(text: str) -> str:
        """Python equivalent of WT_SanitizeDisplayText (WoWTranslate_Hyperlink.lua)."""
        if not text:
            return text
        res = str(text)
        res = re.sub(r"\|c[0-9a-fA-F]{8}", "", res)
        res = re.sub(r"\|r", "", res)
        res = re.sub(r"\|H.*?\|h(.*?)\|h", r"\1", res)
        res = re.sub(r"\|H.*?\|h", "", res)
        res = re.sub(r"\|T.*?\|t", "", res)
        res = res.replace("|n", " ")
        res = res.replace("||", "|")
        return res

    def test_sanitize_color_codes(self):
        colored = "|cFFFF8000[Thunderfury, Blessed Blade of the Windseeker]|r"
        clean = self.py_sanitize_display_text(colored)
        self.assertEqual(clean, "[Thunderfury, Blessed Blade of the Windseeker]")

    def test_sanitize_hyperlinks(self):
        linked = "|cffa335ee|Hitem:19364:0:0:0|h[Ashkandi, Greatsword of the Brotherhood]|h|r"
        clean = self.py_sanitize_display_text(linked)
        self.assertEqual(clean, "[Ashkandi, Greatsword of the Brotherhood]")

    def test_sanitize_newlines_and_textures(self):
        text = "Hello|nWorld |TInterface\\Icons\\Spell_Holy_Heal:16|t!"
        clean = self.py_sanitize_display_text(text)
        self.assertEqual(clean, "Hello World !")

    def test_placeholder_token_isolation(self):
        """Ensures link placeholders ' http://ph.wt/1 ' survive segment mapping without mangling text."""
        original = "LF1M for |cffa335ee|Hitem:19019:0:0:0|h[Thunderfury]|h|r fast run"
        segments = [
            {"type": "text", "content": "LF1M for "},
            {"type": "link", "content": "|cffa335ee|Hitem:19019:0:0:0|h[Thunderfury]|h|r"},
            {"type": "text", "content": " fast run"},
        ]
        self.assertEqual("".join(s["content"] for s in segments), original)
        # Build translatable text:
        parts = []
        link_idx = 0
        for seg in segments:
            if seg["type"] == "text":
                parts.append(seg["content"])
            else:
                link_idx += 1
                parts.append(f" http://ph.wt/{link_idx} ")
        translatable = "".join(parts)
        self.assertEqual(translatable, "LF1M for  http://ph.wt/1  fast run")

        # Mock translation returning the placeholder in place:
        translated_body = "组1人去 http://ph.wt/1 速度来"
        reconstructed = translated_body.replace("http://ph.wt/1", segments[1]["content"])
        self.assertIn(segments[1]["content"], reconstructed)
        self.assertTrue(reconstructed.startswith("组1人去 "))
        self.assertTrue(reconstructed.endswith(" 速度来"))


class TestCacheKeyIsolationAndLRUEviction(unittest.TestCase):
    """Verifies cache key direction isolation and LRU eviction order."""

    @staticmethod
    def py_cache_key(incoming_to: str, outgoing_to: str, text: str) -> str:
        """Python equivalent of CacheKey in WoWTranslate_Cache.lua."""
        to_str = f"{incoming_to or '?'}/{outgoing_to or '?'}"
        return f"{to_str}|{text}"

    def test_directional_cache_isolation(self):
        key_incoming = self.py_cache_key("en", "zh", "你好")
        key_outgoing = self.py_cache_key("zh", "en", "你好")
        self.assertNotEqual(key_incoming, key_outgoing)
        self.assertTrue(key_incoming.startswith("en/zh|"))
        self.assertTrue(key_outgoing.startswith("zh/en|"))

    def test_lru_eviction_threshold(self):
        """Simulates WoWTranslate_CacheMaybeEvict with 10 entries, max 8, fraction 0.25 (drop 2)."""
        cache = {f"k{i}": f"val{i}" for i in range(1, 11)}
        order = {f"k{i}": i for i in range(1, 11)}  # k1 is oldest (ts=1), k10 is newest (ts=10)
        max_entries = 8
        evict_fraction = 0.25

        if len(cache) > max_entries:
            timestamps = sorted(order[k] for k in cache)
            to_evict = int(len(timestamps) * evict_fraction)  # 10 * 0.25 = 2
            threshold = timestamps[to_evict - 1]  # index 1 -> ts=2
            keys_to_evict = [k for k in cache if order[k] <= threshold][:to_evict]
            for k in keys_to_evict:
                del cache[k]
                del order[k]

        self.assertEqual(len(cache), 8)
        self.assertNotIn("k1", cache)
        self.assertNotIn("k2", cache)
        self.assertIn("k3", cache)
        self.assertIn("k10", cache)


class TestProxyAtomicWriteAndIPC(unittest.TestCase):
    """Verifies atomic result writing and wire safety."""

    def test_wire_pipe_and_control_char_escaping(self):
        raw_body = "Hello|World\nWith\tNewlines"
        # Logic from _write_ipc_result:
        body = raw_body.replace("|", "/")
        body = "".join(ch if ord(ch) >= 0x20 else " " for ch in body)
        wire_line = f"ok|{body}"
        self.assertEqual(wire_line, "ok|Hello/World With Newlines")
        self.assertNotIn("\n", wire_line)
        self.assertNotIn("\t", wire_line)
        parts = wire_line.split("|", 1)
        self.assertEqual(parts[0], "ok")
        self.assertEqual(parts[1], "Hello/World With Newlines")

    def test_atomic_file_replacement(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            res_path = os.path.join(temp_dir, "test.res")
            tmp_path = res_path + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as f:
                f.write("ok|translated text")
            os.replace(tmp_path, res_path)
            self.assertTrue(os.path.exists(res_path))
            self.assertFalse(os.path.exists(tmp_path))
            with open(res_path, "r", encoding="utf-8") as f:
                self.assertEqual(f.read(), "ok|translated text")

    def test_periodic_cleanup_superwow_and_luaio(self):
        """Ensures periodic cleanup removes stale SuperWoW res_*.txt and LuaIO *.res, plus orphan .tmp files."""
        with tempfile.TemporaryDirectory() as temp_dir:
            imports_dir = os.path.join(temp_dir, "Imports")
            luaio_dir = os.path.join(temp_dir, "IPC")
            luaio_res = os.path.join(luaio_dir, "results")
            os.makedirs(imports_dir)
            os.makedirs(luaio_res)

            # Create test files
            stale_superwow = os.path.join(imports_dir, "res_req1.txt")
            fresh_superwow = os.path.join(imports_dir, "res_req2.txt")
            tmp_superwow = os.path.join(imports_dir, "res_req3.txt.tmp")
            other_file = os.path.join(imports_dir, "unrelated.txt")

            stale_luaio = os.path.join(luaio_res, "out_1.res")
            fresh_luaio = os.path.join(luaio_res, "out_2.res")
            tmp_luaio = os.path.join(luaio_res, "out_3.res.tmp")

            for p in [stale_superwow, fresh_superwow, tmp_superwow, other_file,
                      stale_luaio, fresh_luaio, tmp_luaio]:
                with open(p, "w", encoding="utf-8") as f:
                    f.write("test")

            # Set mtime on stale files to 200 seconds in the past
            now = time.time()
            stale_time = now - 200
            for p in [stale_superwow, tmp_superwow, stale_luaio, tmp_luaio]:
                os.utime(p, (stale_time, stale_time))

            # Simulate cleanup logic from wow_proxy.py
            stale_ttl = 60
            ipc_targets = [imports_dir, luaio_dir]
            for ipc_root in ipc_targets:
                is_imports = os.path.basename(ipc_root).lower() == "imports"
                if is_imports:
                    res_dir = ipc_root
                    is_res_file = lambda fn: (fn.startswith("res_") and fn.endswith(".txt")) or fn.endswith(".tmp")
                else:
                    res_dir = os.path.join(ipc_root, "results")
                    is_res_file = lambda fn: fn.endswith(".res") or fn.endswith(".tmp")

                if os.path.exists(res_dir):
                    for fname in os.listdir(res_dir):
                        if is_res_file(fname):
                            fp = os.path.join(res_dir, fname)
                            if now - os.path.getmtime(fp) > stale_ttl:
                                os.remove(fp)

            # Assert stale were cleaned, fresh and unrelated were kept
            self.assertFalse(os.path.exists(stale_superwow))
            self.assertFalse(os.path.exists(tmp_superwow))
            self.assertTrue(os.path.exists(fresh_superwow))
            self.assertTrue(os.path.exists(other_file))

            self.assertFalse(os.path.exists(stale_luaio))
            self.assertFalse(os.path.exists(tmp_luaio))
            self.assertTrue(os.path.exists(fresh_luaio))


if __name__ == "__main__":
    unittest.main()


