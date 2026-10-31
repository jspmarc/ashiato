"""Shared translation helper.

Google Translate is the primary provider. It rate-limits by IP and sometimes
refuses outright, so a second provider is tried when it does — with a short
circuit breaker so a blocked provider is not retried on every keystroke.
"""

import asyncio
import logging
import re
import time
from collections.abc import Callable

import httpx
from deep_translator import GoogleTranslator

from app.config import settings

logger = logging.getLogger(__name__)

MAX_RETRIES = 5
BACKOFF_BASE = 2.0
BACKOFF_CAP = 60.0

_MYMEMORY_URL = "https://api.mymemory.translated.net/get"
_MYMEMORY_MAX_CHARS = 500
_FALLBACK_BLOCK_SECONDS = 300  # skip Google for this long after it refuses

# MyMemory answers short words in a dictionary form: "[でんし] /electron/".
# The reading is shown separately, so keep only the meaning.
_DICTIONARY_FORM = re.compile(r"^\[[^\]]*\]\s*/(.+?)/?$")

# Set when Google starts refusing; compared against time.monotonic().
_google_blocked_until = 0.0


def translate_text(
    text: str,
    target_lang: str,
    on_retry: Callable[[int, int, int, str], None] | None = None,
    max_retries: int = MAX_RETRIES,
    source_lang: str = "auto",
) -> tuple[str, int, str | None]:
    """Translate text, with a fallback provider when Google refuses.

    Returns (translated_or_original, retries_used, last_error_msg_or_none).
    `on_retry(attempt, max_retries, wait_s, error_msg)` is called between
    attempts so the caller can surface retry notices to the UI.

    Pass a lower `max_retries` on interactive paths — the full retry ladder
    takes over a minute, which is fine for a background job but not for
    something a user is waiting on.

    `source_lang` defaults to auto-detection. The fallback cannot detect, so
    it assumes Japanese unless the caller names the source.

    Blocking — call from a thread when running inside an async request handler.
    """
    global _google_blocked_until

    google_error: Exception | None = None
    if time.monotonic() >= _google_blocked_until:
        try:
            result = _translate_with_google(
                text, target_lang, on_retry, max_retries, source_lang=source_lang
            )
            _google_blocked_until = 0.0
            return result
        except Exception as exc:
            google_error = exc
            logger.warning("Google Translate failed (%s); using fallback", exc)
            _google_blocked_until = time.monotonic() + _FALLBACK_BLOCK_SECONDS

    if settings.translation.fallback:
        try:
            return (
                _translate_with_fallback(text, target_lang, source_lang=source_lang),
                0,
                None,
            )
        except Exception as exc:
            logger.warning("fallback translation failed: %s", exc)
            if google_error is None:
                google_error = exc

    raise google_error or RuntimeError("no translation provider available")


def _translate_with_google(
    text: str,
    target_lang: str,
    on_retry: Callable[[int, int, int, str], None] | None,
    max_retries: int,
    source_lang: str = "auto",
) -> tuple[str, int, str | None]:
    """Translate with capped-exponential-backoff retry."""
    translator = GoogleTranslator(source=source_lang, target=target_lang)
    last_err: str | None = None
    for attempt in range(max_retries):
        try:
            result = translator.translate(text)
            return (result if result else text), attempt, last_err
        except Exception as e:
            last_err = f"{type(e).__name__}: {e}"
            if attempt == max_retries - 1:
                raise
            wait = min(BACKOFF_BASE * (2**attempt), BACKOFF_CAP)
            logger.warning(
                "translate retry %d/%d: %s (waiting %ds)",
                attempt + 1,
                max_retries,
                last_err,
                wait,
            )
            if on_retry:
                try:
                    on_retry(attempt + 1, max_retries, wait, last_err)
                except Exception:
                    logger.exception("on_retry callback raised")
            time.sleep(wait)
    return text, 0, last_err  # unreachable


def _translate_with_fallback(
    text: str, target_lang: str, source_lang: str = "auto"
) -> str:
    """Translate with MyMemory, which caps each query at 500 characters.

    MyMemory needs an explicit source; most text here is Japanese, so that is
    what "auto" means for it.
    """
    source = "ja" if source_lang == "auto" else source_lang
    chunks = _chunk(text, _MYMEMORY_MAX_CHARS)
    translated = [
        _fallback_chunk(chunk, target_lang, source) for chunk in chunks if chunk.strip()
    ]
    return "\n".join(translated)


def _fallback_chunk(chunk: str, target_lang: str, source_lang: str = "ja") -> str:
    response = httpx.get(
        _MYMEMORY_URL,
        params={"q": chunk, "langpair": f"{source_lang}|{target_lang}"},
        timeout=30.0,
    )
    response.raise_for_status()
    body = response.json()
    if body.get("responseStatus") != 200:
        raise RuntimeError(f"MyMemory: {body.get('responseDetails')}")
    return _clean_translation(str(body["responseData"]["translatedText"]))


def _clean_translation(text: str) -> str:
    """Turn MyMemory's dictionary form into a plain translation."""
    stripped = text.strip()
    match = _DICTIONARY_FORM.match(stripped)
    if match:
        return match.group(1).strip()
    return stripped


def _chunk(text: str, limit: int) -> list[str]:
    """Split text into chunks of at most `limit` characters.

    Lines are kept whole where possible so the translation stays readable.
    """
    chunks: list[str] = []
    current = ""
    for line in text.splitlines():
        while len(line) > limit:
            # A single line longer than the limit — cut it on character count.
            if current:
                chunks.append(current)
                current = ""
            chunks.append(line[:limit])
            line = line[limit:]
        if not current:
            current = line
        elif len(current) + 1 + len(line) <= limit:
            current = f"{current}\n{line}"
        else:
            chunks.append(current)
            current = line
    if current:
        chunks.append(current)
    return chunks


# The lines of a page are sent as a numbered list, so one request covers the
# whole page and the answers can be split back up.
_NUMBERED_LINE = re.compile(r"^\s*(\d+)[.)]\s*(.*)$")


async def translate_lines(lines: list[str], target_lang: str) -> list[str]:
    """Translate each line of a page.

    One request for the whole page where possible; if the numbering does not
    come back intact, the lines are asked for one by one.
    """
    if not lines:
        return []

    numbered = "\n".join(f"{index + 1}. {line}" for index, line in enumerate(lines))
    try:
        answer, _, _ = await asyncio.to_thread(
            translate_text, numbered, target_lang, None, 2
        )
    except Exception as e:
        logger.warning("the page translation failed: %s: %s", type(e).__name__, e)
        answer = ""

    parsed: dict[int, str] = {}
    for row in answer.splitlines():
        match = _NUMBERED_LINE.match(row)
        if match:
            parsed[int(match.group(1))] = match.group(2).strip()

    if len(parsed) == len(lines):
        return [parsed.get(index + 1, "") for index in range(len(lines))]

    # The numbering did not survive — ask again, line by line.
    out: list[str] = []
    for line in lines:
        try:
            translated, _, _ = await asyncio.to_thread(
                translate_text, line, target_lang, None, 2
            )
        except Exception:
            translated = ""
        out.append(translated)
    return out
