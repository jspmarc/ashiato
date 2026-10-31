"""Pure logic for the jp-reader tool.

No FastAPI imports: this module is testable without an HTTP server and can
be reused from a CLI or a scheduled job.
"""

import asyncio
from io import BytesIO

from PIL import Image, ImageOps, UnidentifiedImageError

from app.core import jr_store
from app.core.japanese import to_plain_reading, to_ruby_html, tokenize_with_reading
from app.core.translate import translate_text
from app.tools.jp_reader.transform import (
    Transform,
    apply_transform,
    normalize_box,
)

JPEG_QUALITY = 90

# The user is waiting for this one, so do not sit through the full retry ladder.
PREVIEW_RETRIES = 2

ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}

# Phrases being translated right now, so the same one is not sent twice.
_inflight: set[str] = set()

# A page photo is a couple of megapixels; 80 MP leaves room for a big scan
# while stopping a decompression bomb from eating the whole box.
MAX_PIXELS = 80_000_000


class InvalidImage(ValueError):
    """The upload is not an image we can use."""


class ImageTooLarge(ValueError):
    """The upload decodes to more pixels than we accept."""


def decode_image(raw: bytes) -> Image.Image:
    """Decode an upload and normalise its orientation.

    Raises InvalidImage for anything we cannot read, and ImageTooLarge when
    the image decodes to more pixels than we accept.
    """
    if not raw:
        raise InvalidImage("The file is empty.")
    try:
        image = Image.open(BytesIO(raw))
        if image.width * image.height > MAX_PIXELS:
            raise ImageTooLarge(
                "That image is too large to process "
                f"({image.width}x{image.height} pixels)."
            )
        image.load()
    except ImageTooLarge:
        raise
    except Image.DecompressionBombError as e:
        raise ImageTooLarge("That image is too large to process.") from e
    except (UnidentifiedImageError, OSError, ValueError) as e:
        raise InvalidImage("That file is not an image we can read.") from e

    if image.format not in ALLOWED_FORMATS:
        raise InvalidImage(
            f"{image.format or 'That file'} images are not supported — "
            "use JPEG, PNG or WebP."
        )
    return ImageOps.exif_transpose(image).convert("RGB")


def _encode(image: Image.Image) -> bytes:
    buf = BytesIO()
    image.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=True)
    return buf.getvalue()


def _fit(image: Image.Image, max_dim: int) -> Image.Image:
    if max(image.size) > max_dim:
        image.thumbnail((max_dim, max_dim), Image.Resampling.LANCZOS)
    return image


def normalize_image(raw: bytes, max_dim: int) -> tuple[bytes, int, int]:
    """Decode, straighten and downscale an uploaded photo.

    Returns ``(jpeg_bytes, width, height)``. The stored bytes are exactly what
    the worker OCRs, so the boxes it reports line up with the image the
    browser shows.
    """
    image = _fit(decode_image(raw), max_dim)
    return _encode(image), image.width, image.height


def transform_image(
    base_bytes: bytes, transform: Transform, max_dim: int
) -> tuple[bytes, int, int]:
    """Apply a transform to the base image and return the new image."""
    base = Image.open(BytesIO(base_bytes)).convert("RGB")
    result = _fit(apply_transform(base, transform), max_dim)
    return _encode(result), result.width, result.height


def make_thumb(image_bytes: bytes, width: int = 320) -> bytes:
    """A small preview of the page, for the list."""
    image = Image.open(BytesIO(image_bytes)).convert("RGB")
    if image.width > width:
        height = round(image.height * width / image.width)
        image = image.resize((width, height), Image.Resampling.LANCZOS)
    buf = BytesIO()
    image.save(buf, format="JPEG", quality=75, optimize=True)
    return buf.getvalue()


def crop_region(image_bytes: bytes, box) -> tuple[bytes, int, int, tuple[int, int]]:
    """Crop a region out of the current image.

    `box` is normalised to 0..1 of the image, so it does not depend on how
    the viewer is scaled. Returns the crop, its size and the pixel offset of
    its top-left corner, so boxes found in the crop can be mapped back.
    """
    image = Image.open(BytesIO(image_bytes)).convert("RGB")
    left, top, right, bottom = normalize_box(box, image.width, image.height)
    crop = image.crop((left, top, right, bottom))
    return _encode(crop), crop.width, crop.height, (left, top)


def build_reading(phrase: str) -> dict:
    """The reading of a phrase — computed locally, no network needed."""
    tokens = tokenize_with_reading(phrase)
    return {
        "phrase": phrase,
        "reading": to_plain_reading(tokens),
        "ruby_html": to_ruby_html(tokens),
    }


async def translate_phrase(phrase: str, lang: str) -> str:
    """Translate a phrase, reusing the cached translation when there is one.

    Returns an empty string if the same phrase is already being translated.
    """
    cached = await jr_store.get_cached_translation(lang, phrase)
    if cached is not None:
        return cached

    key = f"{lang}:{phrase}"
    if key in _inflight:
        return ""
    _inflight.add(key)
    try:
        translation, _, _ = await asyncio.to_thread(
            translate_text, phrase, lang, None, PREVIEW_RETRIES
        )
        await jr_store.cache_translation(lang, phrase, translation)
        return translation
    finally:
        _inflight.discard(key)
