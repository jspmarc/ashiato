"""Tests for the translation helper and its fallback."""

import pytest

from app.core import translate as translate_module
from app.core.translate import _chunk, _clean_translation, translate_text


def test_dictionary_form_is_cleaned():
    # MyMemory answers short words as "[でんし] /electron/" — the reading is
    # shown separately, so only the meaning is kept.
    assert _clean_translation("[でんし] /electron/electronic/") == "electron/electronic"
    assert _clean_translation("[はどうほうていしき] /wave equation/") == "wave equation"
    assert _clean_translation("Law of Motion") == "Law of Motion"


def test_chunk_keeps_lines_whole():
    text = "first line\nsecond line\nthird line"
    chunks = _chunk(text, 30)
    assert chunks == ["first line\nsecond line", "third line"]


def test_chunk_splits_a_line_that_is_too_long():
    chunks = _chunk("x" * 25, 10)
    assert all(len(c) <= 10 for c in chunks)
    assert "".join(chunks) == "x" * 25


def test_chunk_preserves_all_text():
    text = "資本効率と社会的価値を両立させるガバナンス\n自分自身の突破"
    chunks = _chunk(text, 30)
    # Chunks are rejoined with newlines, so nothing is lost.
    assert "\n".join(chunks) == text


def test_google_is_used_when_it_works(monkeypatch):
    monkeypatch.setattr(translate_module, "_google_blocked_until", 0.0)
    monkeypatch.setattr(
        translate_module,
        "_translate_with_google",
        lambda *args, **kwargs: ("from google", 0, None),
    )
    assert translate_text("力学", "en")[0] == "from google"


def test_fallback_is_used_when_google_refuses(monkeypatch):
    monkeypatch.setattr(translate_module, "_google_blocked_until", 0.0)

    def boom(*args, **kwargs):
        raise RuntimeError("TooManyRequests")

    monkeypatch.setattr(translate_module, "_translate_with_google", boom)
    monkeypatch.setattr(
        translate_module,
        "_translate_with_fallback",
        lambda text, lang, source_lang="auto": "from fallback",
    )

    assert translate_text("力学", "en")[0] == "from fallback"


def test_google_is_skipped_while_it_is_blocked(monkeypatch):
    monkeypatch.setattr(translate_module, "_google_blocked_until", 1e12)
    monkeypatch.setattr(
        translate_module,
        "_translate_with_google",
        lambda *args, **kwargs: pytest.fail("Google should not be called"),
    )
    monkeypatch.setattr(
        translate_module,
        "_translate_with_fallback",
        lambda text, lang, source_lang="auto": "from fallback",
    )

    assert translate_text("力学", "en")[0] == "from fallback"


class _FakeResponse:
    def __init__(self, body):
        self._body = body

    def raise_for_status(self):
        pass

    def json(self):
        return self._body


def _record_langpairs(monkeypatch):
    seen = []

    def fake_get(url, params, timeout):
        seen.append(params["langpair"])
        return _FakeResponse(
            {"responseStatus": 200, "responseData": {"translatedText": "ok"}}
        )

    monkeypatch.setattr(translate_module.httpx, "get", fake_get)
    return seen


def test_the_fallback_assumes_japanese_when_the_source_is_auto(monkeypatch):
    seen = _record_langpairs(monkeypatch)
    translate_module._translate_with_fallback("力学", "en")
    assert seen == ["ja|en"]


def test_the_fallback_uses_the_named_source(monkeypatch):
    seen = _record_langpairs(monkeypatch)
    translate_module._translate_with_fallback("I study", "ja", source_lang="en")
    assert seen == ["en|ja"]


def test_the_source_reaches_google(monkeypatch):
    monkeypatch.setattr(translate_module, "_google_blocked_until", 0.0)
    calls = []

    def fake_google(text, target, on_retry, max_retries, source_lang="auto"):
        calls.append((source_lang, target))
        return ("ok", 0, None)

    monkeypatch.setattr(translate_module, "_translate_with_google", fake_google)
    translate_text("I study", "ja", source_lang="en")
    assert calls == [("en", "ja")]
