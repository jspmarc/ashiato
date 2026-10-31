"""Tests for the worker task: failures, timeouts, retries and revisions."""

import time

import pytest

from app.core import jr_store
from app.tasks import jp_reader


@pytest.fixture(autouse=True)
def no_orientation_model(monkeypatch):
    """Keep the orientation model out of the tests."""
    monkeypatch.setattr(jp_reader, "detect_orientation", lambda image: None)


@pytest.fixture(autouse=True)
def no_queue(monkeypatch):
    """The read hands over to the translation job — do not queue it here."""
    from app.brokers import taskiq_broker

    async def no_kiq(**kwargs):
        return None

    monkeypatch.setattr(taskiq_broker.translate_page_task, "kiq", no_kiq)


async def _store_page(record_id: str = "rec1") -> None:
    await jr_store.put_image(record_id, b"jpeg-bytes")
    await jr_store.create_record(record_id, 10, 10, 10)


def _decode_ok(_image_bytes: bytes):
    return "image"


def _decode_boom(_image_bytes: bytes):
    raise RuntimeError("boom")


def _ocr_ok(_image):
    return [{"bbox": (0, 0, 10, 10), "text": "hello", "score": 1.0}]


def _ocr_boom(_image):
    raise RuntimeError("boom")


def _ocr_hang(_image):
    # A thread cannot be killed, so this keeps running after the timeout
    # fires — that is exactly the behaviour the timeout has to cope with.
    time.sleep(1)
    return []


def _ocr_slow_text(_image):
    return [{"bbox": (0, 0, 10, 10), "text": "hello", "score": 1.0}]


async def test_a_failed_page_is_marked_as_failed(fake_redis, monkeypatch):
    monkeypatch.setattr(jp_reader, "_decode", _decode_ok)
    monkeypatch.setattr(jp_reader, "run_ocr", _ocr_boom)
    await _store_page()

    result = await jp_reader.ocr_page_task("rec1", 1, "en")
    assert "error" in result

    doc = await jr_store.get_record("rec1")
    assert doc is not None
    assert doc["status"] == "error"
    assert "boom" in doc["error"]


async def test_an_undecodable_page_is_marked_as_failed(fake_redis, monkeypatch):
    monkeypatch.setattr(jp_reader, "_decode", _decode_boom)
    await _store_page()

    result = await jp_reader.ocr_page_task("rec1", 1, "en")
    assert "error" in result

    doc = await jr_store.get_record("rec1")
    assert doc is not None
    assert doc["status"] == "error"


async def test_a_hung_page_is_marked_as_failed(fake_redis, monkeypatch):
    monkeypatch.setattr(jp_reader, "_decode", _decode_ok)
    monkeypatch.setattr(jp_reader, "run_ocr", _ocr_hang)
    monkeypatch.setattr(jp_reader, "OCR_TIMEOUT", 0.2)
    await _store_page()

    result = await jp_reader.ocr_page_task("rec1", 1, "en")
    assert "error" in result

    doc = await jr_store.get_record("rec1")
    assert doc is not None
    assert doc["status"] == "error"
    assert "longer than" in doc["error"]


async def test_a_missing_image_is_marked_as_failed(fake_redis):
    await jr_store.create_record("rec1", 10, 10, 10)

    result = await jp_reader.ocr_page_task("rec1", 1, "en")
    assert "error" in result

    doc = await jr_store.get_record("rec1")
    assert doc is not None
    assert doc["status"] == "error"
    assert doc["error"] == "Image not found"


async def test_a_failed_page_can_be_retried(fake_redis, monkeypatch):
    """The record goes back to pending, so the worker can pick it up again."""
    monkeypatch.setattr(jp_reader, "_decode", _decode_ok)
    monkeypatch.setattr(jp_reader, "run_ocr", _ocr_boom)
    await _store_page()

    await jp_reader.ocr_page_task("rec1", 1, "en")

    await jr_store.update_record("rec1", status="pending", error=None)

    doc = await jr_store.get_record("rec1")
    assert doc is not None
    assert doc["status"] == "pending"
    assert doc["error"] is None


async def test_a_hung_translation_still_keeps_the_ocr_result(fake_redis, monkeypatch):
    """A slow translation must not throw the page away."""
    import time as _time

    def _slow_translate(*args, **kwargs):
        _time.sleep(1)
        return ("late", 0, None)

    monkeypatch.setattr(jp_reader, "_decode", _decode_ok)
    monkeypatch.setattr(jp_reader, "run_ocr", _ocr_slow_text)
    monkeypatch.setattr(jp_reader, "translate_text", _slow_translate)
    monkeypatch.setattr(jp_reader, "TRANSLATE_TIMEOUT", 0.2)
    await _store_page()

    await jp_reader.ocr_page_task("rec1", 1, "en")
    await jp_reader.translate_page_task("rec1", 1, "en")

    doc = await jr_store.get_record("rec1")
    assert doc is not None
    assert doc["status"] == "done"
    assert doc["text"] == "hello"
    assert doc["translation"] == ""


async def test_the_timings_are_recorded(fake_redis, monkeypatch):
    monkeypatch.setattr(jp_reader, "_decode", _decode_ok)
    monkeypatch.setattr(jp_reader, "run_ocr", _ocr_ok)
    await _store_page()

    await jr_store.update_record("rec1", enqueued_at=time.time())
    await jp_reader.ocr_page_task("rec1", 1, "en")
    await jp_reader.translate_page_task("rec1", 1, "en")

    doc = await jr_store.get_record("rec1")
    assert doc is not None
    timings = doc["timings"]
    assert timings is not None
    assert timings["ocr_ms"] >= 0
    assert timings["total_ms"] >= 0
    assert timings["queue_ms"] is not None


async def test_the_text_is_readable_before_the_translation(fake_redis, monkeypatch):
    """The read and the translation are separate jobs."""
    monkeypatch.setattr(jp_reader, "_decode", _decode_ok)
    monkeypatch.setattr(jp_reader, "run_ocr", _ocr_ok)
    await _store_page()

    await jp_reader.ocr_page_task("rec1", 1, "en")

    doc = await jr_store.get_record("rec1")
    assert doc is not None
    assert doc["status"] == "text_ready"
    assert doc["text"] == "hello"
    assert doc["translation"] == ""


async def test_a_result_for_a_superseded_revision_is_discarded(fake_redis, monkeypatch):
    """A slow job must not overwrite the result of a newer correction."""
    monkeypatch.setattr(jp_reader, "_decode", _decode_ok)
    monkeypatch.setattr(jp_reader, "run_ocr", _ocr_ok)
    await _store_page()

    # While the job runs, a newer correction lands.
    await jr_store.update_record("rec1", revision=2, text="newer", regions=[])

    result = await jp_reader.ocr_page_task("rec1", 1, "en")
    assert result.get("superseded") is True

    doc = await jr_store.get_record("rec1")
    assert doc is not None
    assert doc["revision"] == 2
    assert doc["text"] == "newer"
    assert doc["status"] == "pending"
