"""Redis-backed progress store for cross-process SSE streaming.

Import is lazy — the module can be imported without redis installed,
but any call to read/write/delete will raise if redis is missing.
"""

from __future__ import annotations

import json
import os
from datetime import timedelta
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import redis.asyncio as _redis

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")

_TTL = int(timedelta(days=7).total_seconds())


async def _get_redis() -> _redis.Redis:
    """Lazy-init Redis connection and import."""
    import redis.asyncio as _redis_mod

    if not hasattr(_get_redis, "_client"):
        _get_redis._client = _redis_mod.from_url(f"{REDIS_URL}/3")  # type: ignore[attr-defined]
    return _get_redis._client  # type: ignore[attr-defined]


async def write_progress(task_id: str, data: dict) -> None:
    """Write task progress to Redis (called by worker)."""
    r = await _get_redis()
    await r.setex(f"task:{task_id}:progress", _TTL, json.dumps(data, default=str))


async def read_progress(task_id: str) -> dict | None:
    """Read task progress from Redis (called by web SSE endpoint)."""
    r = await _get_redis()
    raw = await r.get(f"task:{task_id}:progress")
    if raw is None:
        return None
    return json.loads(raw)


async def delete_progress(task_id: str) -> None:
    """Clean up progress data when task is done."""
    r = await _get_redis()
    await r.delete(f"task:{task_id}:progress")
