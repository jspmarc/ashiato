"""HTTP layer for the jp-reader tool.

Reads are public; anything that writes requires the shared app password
(``APP_PASSWORD``).
"""

import asyncio
import json
import time
import uuid

from fastapi import (
    APIRouter,
    BackgroundTasks,
    File,
    Form,
    HTTPException,
    Request,
    UploadFile,
)
from starlette.responses import JSONResponse, Response, StreamingResponse

from app.config import settings
from app.core import jr_store
from app.core.auth import app_write
from app.core.progress import read_progress, write_progress
from app.tools.jp_reader import service
from app.tools.jp_reader.schemas import PhraseRequest, RegionRequest, TransformRequest
from app.tools.jp_reader.transform import Transform, validate_corners

router = APIRouter(prefix="/api/jp-reader", tags=["jp-reader"])


def _require_password(request: Request, supplied: str | None = None) -> None:
    """Reject the request unless it carries the configured password."""
    password = request.headers.get("X-App-Password") or supplied
    try:
        app_write.require(password)
    except PermissionError as e:
        # Unconfigured gets 503 (a server problem); a wrong password gets 401.
        if "not configured" in str(e):
            raise HTTPException(503, f"{e} on the server")
        raise HTTPException(401, str(e))


@router.post("/upload")
async def upload(
    request: Request,
    file: UploadFile = File(...),
    rotation_deg: float = Form(0.0),
    password: str = Form(""),
):
    """Accept a page photo, store it and queue the OCR job.

    The photo may already have been straightened on the upload page; the
    base stays unrotated so it can still be corrected later.
    """
    _require_password(request, password)

    raw = await file.read()
    limit = settings.app.max_upload_mb * 1024 * 1024
    if len(raw) > limit:
        raise HTTPException(
            413, f"Image is larger than {settings.app.max_upload_mb} MB"
        )

    try:
        base, base_width, base_height = await asyncio.to_thread(
            service.normalize_image, raw, settings.jp_reader.max_dim
        )
    except service.ImageTooLarge as e:
        raise HTTPException(413, str(e))
    except service.InvalidImage as e:
        raise HTTPException(400, str(e))

    transform = Transform(rotation_deg=rotation_deg)
    image, width, height = base, base_width, base_height
    if abs(rotation_deg) > 0.01:
        image, width, height = await asyncio.to_thread(
            service.transform_image, base, transform, settings.jp_reader.max_dim
        )

    record_id = uuid.uuid4().hex
    # The base is the uncorrected page; every correction is derived from it,
    # so repeated edits cannot degrade the image.
    await jr_store.put_base(record_id, base)
    await jr_store.put_image(record_id, image)
    record = await jr_store.create_record(record_id, width, height, len(image))
    await jr_store.update_record(
        record_id,
        transform=transform.to_dict(),
        base_width=base_width,
        base_height=base_height,
    )
    await jr_store.evict_oldest(settings.jp_reader.max_images)

    # Let every open page know a new scan started.
    await jr_store.publish_event(
        {
            "type": "created",
            "id": record_id,
            "created_at": record["created_at"],
            "status": "pending",
            "region_count": 0,
            "preview": "Reading the page…",
        }
    )

    # Written before the job is queued so the SSE stream finds it immediately.
    await jr_store.update_record(record_id, enqueued_at=time.time())
    await write_progress(
        record_id, {"status": "pending", "message": "Waiting for worker..."}
    )

    from app.brokers.taskiq_broker import ocr_page_task

    await ocr_page_task.kiq(
        record_id=record_id,
        revision=int(record.get("revision") or 1),
        target_lang=settings.jp_reader.target_lang,
    )

    return JSONResponse(content={"id": record_id})


@router.get("/events/{record_id}")
async def events(request: Request, record_id: str):
    """Stream OCR progress for one page."""

    async def stream():
        last: str | None = None
        attempts = 0
        while True:
            if await request.is_disconnected():
                break

            progress = await read_progress(record_id)

            if progress is None:
                attempts += 1
                if attempts > 10:
                    yield f"data: {json.dumps({'error': 'not_found'})}\n\n"
                    break
                await asyncio.sleep(1.0)
                continue

            current = json.dumps(progress, sort_keys=True, default=str)
            if current != last:
                yield f"data: {current}\n\n"
                last = current

            if progress.get("status") in ("done", "error"):
                break

            await asyncio.sleep(0.3)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


@router.get("/records")
async def list_records():
    """Stored pages, newest first."""
    return JSONResponse(content=await jr_store.list_records())


@router.get("/stream")
async def stream(request: Request):
    """Tell open pages when something changes elsewhere.

    New scans and saved phrases are published to a Redis channel; every open
    page follows it, so a page scanned on the phone appears on the laptop
    without a refresh.
    """

    async def generate():
        pubsub = await jr_store.subscribe_events()
        try:
            while not await request.is_disconnected():
                message = await pubsub.get_message(
                    ignore_subscribe_messages=True, timeout=1.0
                )
                if message and message.get("type") == "message":
                    data = message["data"]
                    if isinstance(data, bytes):
                        data = data.decode()
                    yield f"data: {data}\n\n"
        finally:
            await pubsub.unsubscribe(jr_store.EVENTS_CHANNEL)
            await pubsub.aclose()

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


@router.get("/records/{record_id}")
async def get_record(record_id: str):
    """One page with its regions and translations."""
    doc = await jr_store.get_record(record_id)
    if doc is None:
        raise HTTPException(404, "Not found")
    return JSONResponse(content=doc)


@router.post("/records/{record_id}/retry")
async def retry_record(request: Request, record_id: str):
    """Queue the OCR job for a page again.

    Useful when a job was lost — a worker restart mid-task, or a stage that
    hung — and the page is sitting at "Reading the page..." forever.
    """
    _require_password(request)

    doc = await jr_store.get_record(record_id)
    if doc is None:
        raise HTTPException(404, "Not found")
    if await jr_store.get_image(record_id) is None:
        raise HTTPException(404, "The image is gone — upload it again")

    # A job that is still working must not get a second one queued behind it:
    # the two would race, and the loser could overwrite the winner's result.
    progress = await read_progress(record_id)
    if progress and progress.get("status") == "in_progress":
        raise HTTPException(409, "That page is still being read — wait a moment")

    await jr_store.update_record(
        record_id, status="pending", error=None, enqueued_at=time.time()
    )
    await write_progress(
        record_id, {"status": "pending", "message": "Queued for a retry..."}
    )
    await jr_store.publish_event(
        {
            "type": "updated",
            "id": record_id,
            "status": "pending",
            "preview": "Reading the page…",
        }
    )

    from app.brokers.taskiq_broker import ocr_page_task

    await ocr_page_task.kiq(
        record_id=record_id,
        revision=int(doc.get("revision") or 1),
        target_lang=settings.jp_reader.target_lang,
    )
    return JSONResponse(content={"ok": True})


@router.post("/records/{record_id}/transform")
async def transform_record(request: Request, record_id: str, payload: TransformRequest):
    """Correct the page and queue it to be read again.

    The correction is applied to the base image, so repeated edits never
    degrade the picture. The previous result stays visible until the new one
    lands.
    """
    _require_password(request)

    doc = await jr_store.get_record(record_id)
    if doc is None:
        raise HTTPException(404, "Not found")
    base = await jr_store.get_base(record_id)
    if base is None:
        raise HTTPException(404, "The page is gone — upload it again")

    # A correction may land while the first read is still running: the epoch
    # guard drops the older job's result, so the two cannot fight over the
    # page. The older job is simply wasted work.

    max_dim = settings.jp_reader.max_dim
    # The corners are in the base image's space, so they are checked against
    # the base's dimensions — which never change.
    corners = None
    if payload.corners:
        base_width = int(doc.get("base_width") or doc.get("width") or 0)
        base_height = int(doc.get("base_height") or doc.get("height") or 0)
        try:
            corners = validate_corners(payload.corners, base_width, base_height)
        except ValueError as e:
            raise HTTPException(400, str(e))

    transform = Transform(rotation_deg=payload.rotation_deg, corners=corners)
    image, width, height = await asyncio.to_thread(
        service.transform_image, base, transform, max_dim
    )

    revision = int(doc.get("revision") or 0) + 1
    await jr_store.put_image(record_id, image)
    await jr_store.update_record(
        record_id,
        revision=revision,
        transform=transform.to_dict(),
        width=width,
        height=height,
        status="pending",
        error=None,
        timings=None,
        orientation=None,
        enqueued_at=time.time(),
    )
    await write_progress(
        record_id, {"status": "pending", "message": "Reading the page again..."}
    )
    await jr_store.publish_event(
        {
            "type": "updated",
            "id": record_id,
            "status": "pending",
            "preview": "Reading the page…",
        }
    )

    from app.brokers.taskiq_broker import ocr_page_task

    await ocr_page_task.kiq(
        record_id=record_id,
        revision=revision,
        target_lang=settings.jp_reader.target_lang,
    )
    return JSONResponse(
        content={
            "revision": revision,
            "width": width,
            "height": height,
            "transform": transform.to_dict(),
        }
    )


@router.get("/records/{record_id}/base")
async def get_base(record_id: str):
    """The uncorrected page — what the editor draws on.

    Every correction is derived from this image, so the editor always starts
    from the same picture the server will use.
    """
    doc = await jr_store.get_record(record_id)
    if doc is None:
        raise HTTPException(404, "Not found")
    base = await jr_store.get_base(record_id)
    if base is None:
        raise HTTPException(404, "The page is gone — upload it again")
    return Response(content=base, media_type="image/jpeg")


@router.post("/records/{record_id}/regions/ocr")
async def region_ocr(request: Request, record_id: str, payload: RegionRequest):
    """Read one region of the page and merge what it finds."""
    _require_password(request)

    doc = await jr_store.get_record(record_id)
    if doc is None:
        raise HTTPException(404, "Not found")

    from app.brokers.taskiq_broker import region_ocr_task

    await region_ocr_task.kiq(
        record_id=record_id,
        revision=int(doc.get("revision") or 1),
        box=payload.box,
        replace_intersecting=payload.replace_intersecting,
    )
    return JSONResponse(content={"ok": True})


@router.delete("/records/{record_id}")
async def delete_record(request: Request, record_id: str):
    """Delete a page and everything read from it."""
    _require_password(request)

    doc = await jr_store.get_record(record_id)
    if doc is None:
        raise HTTPException(404, "Not found")

    await jr_store.delete_record(record_id)
    await jr_store.publish_event({"type": "deleted", "id": record_id})
    return JSONResponse(content={"ok": True})


@router.get("/records/{record_id}/thumb")
async def get_thumb(record_id: str):
    """The small preview shown in the page list."""
    data = await jr_store.get_thumb(record_id)
    if data is None:
        raise HTTPException(404, "Not found")
    return Response(
        content=data,
        media_type="image/jpeg",
        headers={"Cache-Control": "private, max-age=3600"},
    )


@router.get("/records/{record_id}/translated")
async def get_translated(record_id: str):
    """The page with the translation painted over each line."""
    data = await jr_store.get_translated(record_id)
    if data is None:
        raise HTTPException(404, "Not found")
    return Response(
        content=data,
        media_type="image/jpeg",
        headers={"Cache-Control": "private, max-age=3600"},
    )


@router.get("/records/{record_id}/image")
async def get_image(record_id: str):
    """The stored (normalised) page image."""
    data = await jr_store.get_image(record_id)
    if data is None:
        raise HTTPException(404, "Not found")
    return Response(
        content=data,
        media_type="image/jpeg",
        headers={"Cache-Control": "private, max-age=3600"},
    )


@router.post("/records/{record_id}/preview")
async def preview_phrase(
    record_id: str, payload: PhraseRequest, background: BackgroundTasks
):
    """Reading and translation for a phrase, without saving it.

    The reading comes back straight away — it is computed locally. The
    translation follows when it is ready, over the event stream, unless it is
    already cached.
    """
    doc = await jr_store.get_record(record_id)
    if doc is None:
        raise HTTPException(404, "Not found")

    lang = settings.jp_reader.target_lang
    built = service.build_reading(payload.phrase)
    cached = await jr_store.get_cached_translation(lang, payload.phrase)

    if cached is not None:
        return JSONResponse(
            content={**built, "translation": cached, "translation_pending": False}
        )

    background.add_task(_translate_and_announce, payload.phrase)
    return JSONResponse(
        content={**built, "translation": "", "translation_pending": True}
    )


async def _translate_and_announce(phrase: str) -> None:
    """Translate in the background and tell open pages when it is ready."""
    lang = settings.jp_reader.target_lang
    translation = await service.translate_phrase(phrase, lang)
    if not translation:
        return
    await jr_store.publish_event(
        {"type": "translated", "phrase": phrase, "translation": translation}
    )
