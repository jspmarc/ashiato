"""Redis-backed store for jp-reader pages, images and their translations.

Lives in its own Redis database (4) so it never collides with the task queue
(0), result backend (1), scheduler (2) or progress store (3).

Keys
----
``jr:{id}``       JSON page record — text, regions, translations
``jr:{id}:image`` the normalised JPEG bytes
``jr:index``      sorted set of ids scored by creation time

The store is capped: once ``settings.jp_reader.max_images`` pages exist, the
oldest finished ones are dropped.
"""

from __future__ import annotations

import json
import os
import time
from datetime import timedelta
from typing import TYPE_CHECKING

from app.config import settings

if TYPE_CHECKING:
    import redis.asyncio as _redis

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
_DB = 4
_INDEX_KEY = "jr:index"
EVENTS_CHANNEL = "jr:events"

# A page stuck in a non-terminal state is normally still in flight; only give
# up on it once it is clearly abandoned.
_INFLIGHT_GRACE = 3600  # seconds

_TERMINAL_STATUSES = ("done", "error")


def _ttl() -> int:
    return int(timedelta(days=settings.jp_reader.ttl_days).total_seconds())


def _record_key(record_id: str) -> str:
    return f"jr:{record_id}"


def _image_key(record_id: str) -> str:
    return f"jr:{record_id}:image"


def _base_key(record_id: str) -> str:
    return f"jr:{record_id}:base"


def _thumb_key(record_id: str) -> str:
    return f"jr:{record_id}:thumb"


def _translated_key(record_id: str) -> str:
    return f"jr:{record_id}:translated"


def _dump(doc: dict) -> str:
    """Serialise a record — Japanese must not be escaped to \\uXXXX."""
    return json.dumps(doc, ensure_ascii=False, default=str)


def _as_str(value) -> str:
    """Redis returns bytes; ids are text. Image bytes stay bytes."""
    return value.decode() if isinstance(value, bytes) else value


async def _get_redis() -> _redis.Redis:
    """Lazy-init Redis connection and import."""
    import redis.asyncio as _redis_mod

    if not hasattr(_get_redis, "_client"):
        _get_redis._client = _redis_mod.from_url(f"{REDIS_URL}/{_DB}")  # type: ignore[attr-defined]
    return _get_redis._client  # type: ignore[attr-defined]


def _summary(doc: dict) -> dict:
    """The listing view of a record — no region payloads."""
    return {
        "id": doc.get("id"),
        "created_at": doc.get("created_at"),
        "status": doc.get("status"),
        "width": doc.get("width"),
        "height": doc.get("height"),
        "n_bytes": doc.get("n_bytes"),
        "region_count": len(doc.get("regions") or []),
        "preview": (doc.get("text") or "")[:120],
    }


# ── records ──────────────────────────────────────────────────────


async def create_record(record_id: str, width: int, height: int, n_bytes: int) -> dict:
    """Write the pending record and register it in the index."""
    r = await _get_redis()
    now = time.time()
    doc = {
        "id": record_id,
        "created_at": now,
        "status": "pending",
        "width": width,
        "height": height,
        "base_width": width,
        "base_height": height,
        "revision": 1,
        "transform": {"rotation_deg": 0.0, "corners": None},
        "timings": None,
        "orientation": None,
        "n_bytes": n_bytes,
        "text": "",
        "translation": "",
        "regions": [],
        "error": None,
    }
    await r.setex(_record_key(record_id), _ttl(), _dump(doc))
    await r.zadd(_INDEX_KEY, {record_id: now})
    return doc


async def get_record(record_id: str) -> dict | None:
    """Read a record, or None if it is missing or expired."""
    r = await _get_redis()
    raw = await r.get(_record_key(record_id))
    return json.loads(raw) if raw else None


async def update_record(record_id: str, **fields) -> dict | None:
    """Merge `fields` into a record and refresh its TTL."""
    r = await _get_redis()
    raw = await r.get(_record_key(record_id))
    if raw is None:
        return None
    doc = json.loads(raw)
    doc.update(fields)
    await r.setex(_record_key(record_id), _ttl(), _dump(doc))
    await r.expire(_image_key(record_id), _ttl())
    await r.expire(_base_key(record_id), _ttl())
    await r.expire(_thumb_key(record_id), _ttl())
    await r.expire(_translated_key(record_id), _ttl())
    return doc


async def update_record_if_revision(
    record_id: str, revision: int, **fields
) -> dict | None:
    """Update a record only if it is still on `revision`.

    A job that was overtaken by a newer correction must not overwrite the
    newer result. Returns None when the revision no longer matches.
    """
    r = await _get_redis()
    raw = await r.get(_record_key(record_id))
    if raw is None:
        return None
    doc = json.loads(raw)
    if int(doc.get("revision") or 0) != int(revision):
        return None
    doc.update(fields)
    await r.setex(_record_key(record_id), _ttl(), _dump(doc))
    await r.expire(_image_key(record_id), _ttl())
    await r.expire(_base_key(record_id), _ttl())
    await r.expire(_thumb_key(record_id), _ttl())
    return doc


async def delete_record(record_id: str) -> None:
    """Drop a record, everything stored with it and its index entry."""
    r = await _get_redis()
    await r.delete(
        _record_key(record_id),
        _image_key(record_id),
        _base_key(record_id),
        _thumb_key(record_id),
        _translated_key(record_id),
    )
    await r.zrem(_INDEX_KEY, record_id)


async def list_records(limit: int = 100) -> list[dict]:
    """Summaries of the stored pages, newest first."""
    r = await _get_redis()
    ids = await r.zrange(_INDEX_KEY, 0, limit - 1, desc=True)
    out: list[dict] = []
    for raw_id in ids:
        record_id = _as_str(raw_id)
        doc = await get_record(record_id)
        if doc is None:
            # The record expired but the index entry outlived it.
            await r.zrem(_INDEX_KEY, record_id)
            continue
        out.append(_summary(doc))
    return out


async def evict_oldest(max_images: int) -> int:
    """Drop the oldest pages until the store is back within the cap.

    Pages still being processed are kept unless they look abandoned.
    Returns the number of pages evicted.
    """
    r = await _get_redis()
    evicted = 0
    while await r.zcard(_INDEX_KEY) > max_images:
        ids = await r.zrange(_INDEX_KEY, 0, 0)
        if not ids:
            break
        record_id = _as_str(ids[0])
        doc = await get_record(record_id)
        if doc is not None and doc.get("status") not in _TERMINAL_STATUSES:
            created_at = float(doc.get("created_at") or 0)
            if time.time() - created_at < _INFLIGHT_GRACE:
                # Still being worked on — leave it and stop evicting.
                break
        await r.delete(
            _record_key(record_id), _image_key(record_id), _base_key(record_id)
        )
        await r.zrem(_INDEX_KEY, record_id)
        evicted += 1
    return evicted


# ── image bytes ──────────────────────────────────────────────────


async def put_image(record_id: str, data: bytes) -> None:
    """Store the normalised JPEG bytes for a page."""
    r = await _get_redis()
    await r.setex(_image_key(record_id), _ttl(), data)


async def get_image(record_id: str) -> bytes | None:
    """Read the stored JPEG bytes for a page."""
    r = await _get_redis()
    return await r.get(_image_key(record_id))


async def put_thumb(record_id: str, data: bytes) -> None:
    """Store the small preview shown in the page list."""
    r = await _get_redis()
    await r.setex(_thumb_key(record_id), _ttl(), data)


async def get_thumb(record_id: str) -> bytes | None:
    """Read the small preview shown in the page list."""
    r = await _get_redis()
    return await r.get(_thumb_key(record_id))


async def put_translated(record_id: str, data: bytes) -> None:
    """Store the page with the translation painted over each line."""
    r = await _get_redis()
    await r.setex(_translated_key(record_id), _ttl(), data)


async def get_translated(record_id: str) -> bytes | None:
    """Read the page with the translation painted over each line."""
    r = await _get_redis()
    return await r.get(_translated_key(record_id))


async def put_base(record_id: str, data: bytes) -> None:
    """Store the uncorrected page — the source every correction is derived from."""
    r = await _get_redis()
    await r.setex(_base_key(record_id), _ttl(), data)


async def get_base(record_id: str) -> bytes | None:
    """Read the uncorrected page bytes."""
    r = await _get_redis()
    return await r.get(_base_key(record_id))


# ── events ───────────────────────────────────────────────────────


async def publish_event(event: dict) -> None:
    """Tell every open page that something changed."""
    r = await _get_redis()
    await r.publish(EVENTS_CHANNEL, _dump(event))


async def subscribe_events():
    """A pubsub object subscribed to the events channel."""
    r = await _get_redis()
    pubsub = r.pubsub()
    await pubsub.subscribe(EVENTS_CHANNEL)
    return pubsub


# ── translation cache ────────────────────────────────────────────
# The cache itself lives in app/core/translation_cache.py. Thin aliases keep
# jp-reader's call sites unchanged.


async def get_cached_translation(lang: str, text: str) -> str | None:
    """A previously translated phrase, if there is one."""
    from app.core import translation_cache

    return await translation_cache.get(lang, text)


async def cache_translation(lang: str, text: str, translation: str) -> None:
    """Remember a translation so the same phrase is not translated twice."""
    from app.core import translation_cache

    await translation_cache.put(lang, text, translation)
