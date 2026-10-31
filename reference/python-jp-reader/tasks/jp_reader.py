"""TaskIQ tasks: OCR a stored page, translate it and index its words.

Runs in the worker so the web process never has to load the OCR models. The
page image is read straight out of Redis, so no temporary files are involved.
"""

import asyncio
import logging
import time

from app.core import jr_store
from app.core.japanese import tokenize_with_reading
from app.core.ocr import detect_orientation
from app.core.ocr import run as run_ocr
from app.core.progress import write_progress
from app.core.render import render_translated_page
from app.core.translate import translate_lines, translate_text
from app.tools.jp_reader import service

logger = logging.getLogger(__name__)

# A page normally takes well under a minute. These bounds make sure a hung
# stage is marked failed instead of blocking the worker for good.
OCR_TIMEOUT = 300  # seconds
TRANSLATE_TIMEOUT = 240


def _token_payload(tokens) -> list[dict]:
    """Serialise furigana tokens for the API."""
    return [
        {
            "surface": t.surface,
            "reading": t.reading,
            "base": t.base,
            "okurigana": t.okurigana,
            "ruby": t.ruby,
        }
        for t in tokens
    ]


def _decode(image_bytes: bytes):
    """Decode the stored image into a BGR array."""
    import cv2
    import numpy as np

    buf = np.frombuffer(image_bytes, dtype=np.uint8)
    # cv2.imdecode gives BGR, which is what PaddleOCR's reader expects.
    image = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError("stored image could not be decoded")
    return image


def _build_regions(raw: list[dict]) -> list[dict]:
    """Turn raw OCR output into stored regions, splitting each into words."""
    regions: list[dict] = []
    for index, region in enumerate(raw):
        text = region["text"]
        regions.append(
            {
                "i": index,
                "bbox": list(region["bbox"]),
                "text": text,
                "score": region["score"],
                "tokens": _token_payload(tokenize_with_reading(text)),
            }
        )
    return regions


def _intersects(a, b) -> bool:
    """True when two [x1, y1, x2, y2] boxes overlap."""
    return not (a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1])


async def _progress(record_id: str, revision: int, data: dict) -> None:
    """Write progress, unless a newer revision has taken over."""
    doc = await jr_store.get_record(record_id)
    if doc and int(doc.get("revision") or 0) != int(revision):
        return
    await write_progress(record_id, data)


async def _fail(record_id: str, revision: int, message: str) -> None:
    """Mark a page as failed, so it shows the error and can be retried."""
    updated = await jr_store.update_record_if_revision(
        record_id, revision, status="error", error=message
    )
    if updated is None:
        return  # superseded by a newer correction
    await write_progress(record_id, {"status": "error", "message": message})
    await jr_store.publish_event(
        {"type": "updated", "id": record_id, "status": "error", "preview": message}
    )


async def ocr_page_task(record_id: str, revision: int, target_lang: str = "en") -> dict:
    """OCR the stored page image and fill in its record.

    `revision` is the revision of the image this job is for. If a newer
    correction lands while the job runs, the result is discarded rather than
    overwriting the newer one.
    """
    started_wall = time.time()
    doc = await jr_store.get_record(record_id)
    if doc is None:
        return {"error": "record not found"}

    enqueued_at = doc.get("enqueued_at")
    queue_ms = (
        int(max(0.0, started_wall - float(enqueued_at)) * 1000) if enqueued_at else None
    )

    await _progress(
        record_id, revision, {"status": "in_progress", "message": "Reading the page..."}
    )

    image_bytes = await jr_store.get_image(record_id)
    if image_bytes is None:
        await _fail(record_id, revision, "Image not found")
        return {"error": "image not found"}

    # ── decode ───────────────────────────────────────────────────
    t0 = time.monotonic()
    try:
        image = await asyncio.to_thread(_decode, image_bytes)
    except Exception as e:
        message = f"{type(e).__name__}: {e}"
        logger.exception("Could not decode %s", record_id)
        await _fail(record_id, revision, message)
        return {"error": message}
    decode_ms = int((time.monotonic() - t0) * 1000)

    # ── OCR ───────────────────────────────────────────────────────
    t1 = time.monotonic()
    try:
        raw = await asyncio.wait_for(
            asyncio.to_thread(run_ocr, image), timeout=OCR_TIMEOUT
        )
    except TimeoutError:
        message = f"Reading the page took longer than {OCR_TIMEOUT}s"
        logger.error("OCR timed out for %s", record_id)
        await _fail(record_id, revision, message)
        return {"error": message}
    except Exception as e:
        logger.exception("OCR failed for %s", record_id)
        message = f"{type(e).__name__}: {e}"
        await _fail(record_id, revision, message)
        return {"error": message}
    ocr_ms = int((time.monotonic() - t1) * 1000)

    # ── split into words ──────────────────────────────────────────
    t2 = time.monotonic()
    regions = await asyncio.to_thread(_build_regions, raw)
    tokenize_ms = int((time.monotonic() - t2) * 1000)
    full_text = "\n".join(region["text"] for region in regions)

    # ── which way up is it? ───────────────────────────────────────
    orientation = None
    try:
        orientation = await asyncio.to_thread(detect_orientation, image)
    except Exception as e:
        logger.warning("orientation detection failed: %s: %s", type(e).__name__, e)

    # A small preview for the page list, made once.
    try:
        thumb = await asyncio.to_thread(service.make_thumb, image_bytes)
        await jr_store.put_thumb(record_id, thumb)
    except Exception as e:
        logger.warning("could not make the preview: %s: %s", type(e).__name__, e)

    count = len(regions)
    timings = {
        "queue_ms": queue_ms,
        "preprocess_ms": decode_ms + tokenize_ms,
        "ocr_ms": ocr_ms,
    }

    updated = await jr_store.update_record_if_revision(
        record_id,
        revision,
        status="text_ready",
        regions=regions,
        text=full_text,
        timings=timings,
        orientation=orientation,
        error=None,
    )
    if updated is None:
        # A newer correction landed while we were working — drop this result.
        logger.info(
            "Discarding result for %s revision %s (superseded)", record_id, revision
        )
        return {"superseded": True}

    await write_progress(
        record_id,
        {
            "status": "in_progress",
            "message": f"{count} lines found — translating",
            "region_count": count,
        },
    )
    await jr_store.publish_event(
        {
            "type": "updated",
            "id": record_id,
            "status": "text_ready",
            "region_count": count,
            "preview": full_text[:120],
        }
    )

    # The translation is its own job, so the text is readable while it runs.
    from app.brokers.taskiq_broker import translate_page_task

    await translate_page_task.kiq(
        record_id=record_id, revision=revision, target_lang=target_lang
    )
    return {"regions": count, "timings": timings}


async def translate_page_task(
    record_id: str, revision: int, target_lang: str = "en"
) -> dict:
    """Translate the page that was just read, and finish it."""
    doc = await jr_store.get_record(record_id)
    if doc is None:
        return {"error": "record not found"}

    full_text = doc.get("text") or ""
    await _progress(
        record_id,
        revision,
        {"status": "in_progress", "message": "Translating..."},
    )

    started = time.monotonic()
    translation = ""
    if full_text.strip():
        try:
            # A short retry ladder: the fallback provider covers the rest.
            translation, _, _ = await asyncio.wait_for(
                asyncio.to_thread(translate_text, full_text, target_lang, None, 2),
                timeout=TRANSLATE_TIMEOUT,
            )
        except TimeoutError:
            logger.warning("translation timed out for %s", record_id)
        except Exception as e:
            # A failed page translation must not lose the OCR result.
            logger.warning("page translation failed: %s: %s", type(e).__name__, e)
    translate_ms = int((time.monotonic() - started) * 1000)

    timings = dict(doc.get("timings") or {})
    timings["translate_ms"] = translate_ms
    timings["total_ms"] = (
        (timings.get("queue_ms") or 0)
        + (timings.get("preprocess_ms") or 0)
        + (timings.get("ocr_ms") or 0)
        + translate_ms
    )

    # Each line is translated too, so the translation can be painted over it.
    regions = doc.get("regions") or []
    line_translations = await translate_lines(
        [region.get("text") or "" for region in regions],
        target_lang,
    )
    for region, line in zip(regions, line_translations):
        region["translation"] = line

    image_bytes = await jr_store.get_image(record_id)
    if image_bytes and regions:
        try:
            painted = await asyncio.to_thread(
                render_translated_page, image_bytes, regions
            )
            await jr_store.put_translated(record_id, painted)
        except Exception as e:
            logger.warning(
                "could not paint the translation: %s: %s", type(e).__name__, e
            )

    updated = await jr_store.update_record_if_revision(
        record_id,
        revision,
        status="done",
        translation=translation,
        regions=regions,
        timings=timings,
    )
    if updated is None:
        logger.info(
            "Discarding translation for %s revision %s (superseded)",
            record_id,
            revision,
        )
        return {"superseded": True}

    await write_progress(
        record_id,
        {
            "status": "done",
            "message": "Translated",
            "region_count": len(doc.get("regions") or []),
        },
    )
    await jr_store.publish_event(
        {
            "type": "updated",
            "id": record_id,
            "status": "done",
            "region_count": len(doc.get("regions") or []),
            "preview": (doc.get("text") or "")[:120],
        }
    )
    return {"translated": bool(translation), "timings": timings}


async def region_ocr_task(
    record_id: str,
    revision: int,
    box: list[float],
    replace_intersecting: bool = True,
) -> dict:
    """Read one region of the page and merge what it finds into the record.

    `box` is normalised to 0..1 of the current image, so it does not depend
    on how the viewer is scaled.
    """
    started = time.monotonic()
    doc = await jr_store.get_record(record_id)
    if doc is None:
        return {"error": "record not found"}

    image_bytes = await jr_store.get_image(record_id)
    if image_bytes is None:
        return {"error": "image not found"}

    try:
        crop_bytes, crop_w, crop_h, offset = await asyncio.to_thread(
            service.crop_region, image_bytes, box
        )
    except ValueError as e:
        logger.info("Bad region for %s: %s", record_id, e)
        return {"error": str(e)}

    image = await asyncio.to_thread(_decode, crop_bytes)
    raw = await asyncio.wait_for(asyncio.to_thread(run_ocr, image), timeout=OCR_TIMEOUT)
    found = await asyncio.to_thread(_build_regions, raw)

    left, top = offset
    for region in found:
        region["bbox"] = [
            region["bbox"][0] + left,
            region["bbox"][1] + top,
            region["bbox"][2] + left,
            region["bbox"][3] + top,
        ]

    existing = doc.get("regions") or []
    if replace_intersecting:
        pixel_box = [
            left,
            top,
            left + crop_w,
            top + crop_h,
        ]
        kept = [r for r in existing if not _intersects(r["bbox"], pixel_box)]
    else:
        kept = list(existing)

    merged = kept + found
    for index, region in enumerate(merged):
        region["i"] = index

    updated = await jr_store.update_record_if_revision(
        record_id, revision, regions=merged
    )
    if updated is None:
        logger.info("Region result for %s discarded (superseded)", record_id)
        return {"superseded": True}

    await jr_store.publish_event(
        {
            "type": "updated",
            "id": record_id,
            "status": doc.get("status"),
            "region_count": len(merged),
            "preview": doc.get("text", "")[:120],
        }
    )
    logger.info(
        "Region OCR for %s: %d new regions in %.1fs",
        record_id,
        len(found),
        time.monotonic() - started,
    )
    return {"regions": len(found)}
