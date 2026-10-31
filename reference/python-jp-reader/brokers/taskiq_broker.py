"""TaskIQ broker configuration with Redis.

Supports multiple workers on the same machine or separate machines.
All workers share the same Redis instance for task queuing and progress.
"""

import os

from taskiq import TaskiqEvents, TaskiqScheduler, TaskiqState
from taskiq_redis import (
    ListRedisScheduleSource,
    RedisAsyncResultBackend,
    RedisStreamBroker,
)

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")

# ── Broker: Redis Streams (acks, auto-reclaim on crash) ──────────

broker = RedisStreamBroker(
    url=f"{REDIS_URL}/0",
    queue_name="ashiato",
    consumer_group_name="ashiato-workers",
    # Throughput: low (single-user tool on weak hardware)
    xread_block=2000,  # block 2s — stays under redis client timeout
    xread_count=10,  # fetch at most 10 messages at a time
    # Durability: auto-reclaim if worker dies mid-task
    idle_timeout=600_000,  # 10 minutes before a stuck job is reclaimed
    maxlen=10_000,  # cap stream to prevent unbounded growth
    approximate=True,
    max_connection_pool_size=11,  # small pool for single-user tool
)

# ── Result backend: store task results with 24h TTL ──────────────

result_backend = RedisAsyncResultBackend(
    redis_url=f"{REDIS_URL}/1",
    result_ex_time=86_400,  # 24 hours
    max_connection_pool_size=11,
)

broker = broker.with_result_backend(result_backend)

# ── Scheduler: efficient list-based (avoids full-key scans) ─────

schedule_source = ListRedisScheduleSource(
    url=f"{REDIS_URL}/2",
    prefix="ashiato_schedules",
    buffer_size=50,
)

scheduler = TaskiqScheduler(broker, [schedule_source])

# ── Initialization ──────────────────────────────────────────────


@broker.on_event(TaskiqEvents.WORKER_STARTUP)
async def init_ocr_model(state: TaskiqState) -> None:
    from app.core.ocr import init_models

    init_models()


# ── Task registration ─────────────────────────────────────────────

from app.tasks.jp_reader import ocr_page_task as _ocr_page_fn  # noqa: E402
from app.tasks.jp_reader import region_ocr_task as _region_ocr_fn  # noqa: E402
from app.tasks.jp_reader import translate_page_task as _translate_page_fn  # noqa: E402

ocr_page_task = broker.task(_ocr_page_fn)
region_ocr_task = broker.task(_region_ocr_fn)
translate_page_task = broker.task(_translate_page_fn)
