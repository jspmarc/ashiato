"""Tests for the jp-reader Redis store."""

import pytest
from fakeredis.aioredis import FakeRedis

from app.core import jr_store


@pytest.fixture
def store(monkeypatch):
    """A store backed by an in-memory Redis."""
    client = FakeRedis()

    async def _get_redis():
        return client

    monkeypatch.setattr(jr_store, "_get_redis", _get_redis)
    return client


async def test_record_round_trip(store):
    doc = await jr_store.create_record("abc", 100, 200, 1234)
    assert doc["status"] == "pending"

    fetched = await jr_store.get_record("abc")
    assert fetched is not None
    assert fetched["width"] == 100
    assert fetched["height"] == 200

    updated = await jr_store.update_record("abc", status="done", text="力学")
    assert updated is not None
    assert updated["status"] == "done"
    assert updated["text"] == "力学"


async def test_japanese_text_is_not_escaped(store):
    await jr_store.create_record("abc", 1, 1, 1)
    await jr_store.update_record("abc", text="力学の法則")
    raw = await store.get("jr:abc")
    assert "力学の法則" in raw.decode()


async def test_missing_record_is_none(store):
    assert await jr_store.get_record("nope") is None


async def test_image_bytes_are_stored(store):
    await jr_store.put_image("abc", b"\xff\xd8jpegbytes")
    assert await jr_store.get_image("abc") == b"\xff\xd8jpegbytes"
    assert await jr_store.get_image("nope") is None


async def test_list_is_newest_first(store):
    await jr_store.create_record("old", 1, 1, 1)
    await jr_store.create_record("new", 1, 1, 1)
    listed = await jr_store.list_records()
    assert [r["id"] for r in listed] == ["new", "old"]


async def test_eviction_drops_the_oldest(store):
    for name in ("a", "b", "c"):
        await jr_store.create_record(name, 1, 1, 1)
        await jr_store.update_record(name, status="done")

    assert await jr_store.evict_oldest(2) == 1
    remaining = [r["id"] for r in await jr_store.list_records()]
    assert remaining == ["c", "b"]
    assert await jr_store.get_record("a") is None


async def test_eviction_keeps_pages_still_in_flight(store):
    await jr_store.create_record("busy", 1, 1, 1)  # still pending
    await jr_store.create_record("done", 1, 1, 1)
    await jr_store.update_record("done", status="done")

    # "busy" is the oldest but is not finished, so it is kept.
    assert await jr_store.evict_oldest(1) == 0
    remaining = [r["id"] for r in await jr_store.list_records()]
    assert remaining == ["done", "busy"]
