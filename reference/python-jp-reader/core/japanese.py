"""Japanese text helpers: word readings (furigana) and ruby HTML.

Janome (pure Python, IPADIC bundled) splits Japanese text into words and
looks up their readings. Readings come back in katakana; unknown words carry
the reading "*" and simply get no annotation.

The tokenizer is loaded lazily — reading IPADIC takes about a second and
roughly 100 MB of RAM.
"""

from __future__ import annotations

import html
import re
import threading
import unicodedata
from dataclasses import dataclass

from janome.tokenizer import Tokenizer

# Katakana U+30A1 (ァ) .. U+30F6 (ヶ) map to hiragana by subtracting 0x60.
_KATAKANA_START = 0x30A1
_KATAKANA_END = 0x30F6
_KANA_OFFSET = 0x60

# Trailing kana of a word — the okurigana, e.g. the む in 読む.
_TRAILING_KANA = re.compile(r"[ぁ-ゖァ-ヺー]+$")

# CJK unified ideographs: the only characters worth annotating with a reading.
_HAS_KANJI = re.compile(r"[一-鿿]")

_TOKENIZER: Tokenizer | None = None
_TOKENIZER_LOCK = threading.Lock()


def get_tokenizer() -> Tokenizer:
    """Lazily build the tokenizer — loading IPADIC is slow."""
    global _TOKENIZER
    if _TOKENIZER is None:
        with _TOKENIZER_LOCK:
            if _TOKENIZER is None:
                _TOKENIZER = Tokenizer()
    return _TOKENIZER


def katakana_to_hiragana(text: str) -> str:
    """Convert katakana to hiragana. Other characters pass through."""
    return "".join(
        chr(ord(ch) - _KANA_OFFSET)
        if _KATAKANA_START <= ord(ch) <= _KATAKANA_END
        else ch
        for ch in text
    )


def normalize(text: str) -> str:
    """NFKC-normalise so OCR output lines up with dictionary lookups."""
    return unicodedata.normalize("NFKC", text)


@dataclass(frozen=True)
class FuriganaToken:
    """A word and how it should be annotated.

    `base` + `okurigana` always reconstructs `surface`. `ruby` holds the
    reading for `base` alone and is empty when the word needs no annotation.
    """

    surface: str
    reading: str  # full hiragana reading of the word
    base: str  # kanji stem carrying the annotation
    okurigana: str  # trailing kana, rendered outside the <ruby> element
    ruby: str  # reading of `base`; empty means no annotation


def tokenize_with_reading(text: str) -> list[FuriganaToken]:
    """Split `text` into words with their kana readings.

    Words with no kanji (kana, latin, digits) and words missing from the
    dictionary get an empty `ruby` — they still appear, just unannotated.
    """
    tokens: list[FuriganaToken] = []
    for tok in get_tokenizer().tokenize(normalize(text)):
        if isinstance(tok, str):
            continue
        surface = tok.surface
        raw_reading = tok.reading
        if not raw_reading or raw_reading == "*" or not _HAS_KANJI.search(surface):
            tokens.append(FuriganaToken(surface, "", surface, "", ""))
            continue

        reading = katakana_to_hiragana(raw_reading)
        match = _TRAILING_KANA.search(surface)
        if match and match.start() > 0:
            base = surface[: match.start()]
            okurigana = match.group()
            # The okurigana is read as itself, so drop it from the annotation.
            ruby = ""
            if len(reading) > len(okurigana):
                ruby = reading[: len(reading) - len(okurigana)]
        else:
            base, okurigana = surface, ""
            ruby = reading

        if not ruby:
            tokens.append(FuriganaToken(surface, reading, surface, "", ""))
            continue
        tokens.append(FuriganaToken(surface, reading, base, okurigana, ruby))
    return tokens


def to_ruby_html(tokens: list[FuriganaToken]) -> str:
    """Render tokens as HTML with <ruby> furigana annotations."""
    parts: list[str] = []
    for tok in tokens:
        if not tok.ruby:
            parts.append(html.escape(tok.surface, quote=False))
            continue
        parts.append(
            f"<ruby>{html.escape(tok.base, quote=False)}<rp>(</rp>"
            f"<rt>{html.escape(tok.ruby, quote=False)}</rt><rp>)</rp></ruby>"
            f"{html.escape(tok.okurigana, quote=False)}"
        )
    return "".join(parts)


def to_plain_reading(tokens: list[FuriganaToken]) -> str:
    """Render tokens as plain kana — the whole text as it would be read."""
    parts: list[str] = []
    for tok in tokens:
        parts.append(tok.ruby + tok.okurigana if tok.ruby else tok.surface)
    return "".join(parts)


def furigana_html(text: str) -> str:
    """Tokenize `text` and return it as ruby-annotated HTML."""
    return to_ruby_html(tokenize_with_reading(text))
