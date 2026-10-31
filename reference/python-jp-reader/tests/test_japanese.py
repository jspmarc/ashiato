"""Tests for the furigana helpers."""

from app.core.japanese import (
    katakana_to_hiragana,
    to_plain_reading,
    to_ruby_html,
    tokenize_with_reading,
)


def test_katakana_to_hiragana():
    assert katakana_to_hiragana("ナゲ") == "なげ"
    assert katakana_to_hiragana("エネルギー") == "えねるぎー"
    # Prolonged sound marks and non-kana pass through untouched.
    assert katakana_to_hiragana("コーヒー") == "こーひー"
    assert katakana_to_hiragana("abc 123") == "abc 123"


def test_reading_of_a_kanji_word():
    tokens = tokenize_with_reading("力学")
    assert len(tokens) == 1
    assert tokens[0].surface == "力学"
    assert tokens[0].reading == "りきがく"
    assert tokens[0].ruby == "りきがく"


def test_okurigana_is_kept_outside_the_ruby():
    tokens = tokenize_with_reading("読む")
    assert len(tokens) == 1
    token = tokens[0]
    assert token.base == "読"
    assert token.okurigana == "む"
    assert token.ruby == "よ"
    assert to_ruby_html(tokens) == "<ruby>読<rp>(</rp><rt>よ</rt><rp>)</rp></ruby>む"


def test_words_without_kanji_get_no_annotation():
    tokens = tokenize_with_reading("エネルギー")
    assert tokens[0].ruby == ""
    assert to_ruby_html(tokens) == "エネルギー"

    particles = tokenize_with_reading("の")
    assert particles[0].ruby == ""


def test_unknown_word_keeps_its_text():
    # Not in IPADIC — the word still shows up, just without a reading.
    tokens = tokenize_with_reading("ザッリ")
    assert tokens[0].surface == "ザッリ"
    assert tokens[0].ruby == ""


def test_plain_reading_spells_the_whole_text_in_kana():
    assert to_plain_reading(tokenize_with_reading("力学")) == "りきがく"
    assert to_plain_reading(tokenize_with_reading("力学の法則")) == "りきがくのほうそく"
    assert to_plain_reading(tokenize_with_reading("読む")) == "よむ"


def test_to_plain_reading_accepts_tokens():
    tokens = tokenize_with_reading("運動の法則")
    assert to_plain_reading(tokens) == "うんどうのほうそく"
