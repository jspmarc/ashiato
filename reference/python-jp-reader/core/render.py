"""Paint text onto a page.

Used by the reader to draw a translation over the region it came from, so
the page reads the way a translation overlay does.
"""

from __future__ import annotations

import logging
import os
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

logger = logging.getLogger(__name__)

# Start the text at this fraction of the region's height, so a translation
# longer than the source still has room.
INITIAL_FONT_FRAC = 0.70
MIN_FONT_SIZE = 8

_FONT_CANDIDATES = [
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/TTF/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
]


def find_font(
    font_path: str | None, size: int
) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    """A font that can draw the characters we need."""
    if font_path and Path(font_path).exists():
        return ImageFont.truetype(font_path, size)
    env_path = os.environ.get("TRANSLATION_FONT_PATH", "")
    if env_path and Path(env_path).exists():
        return ImageFont.truetype(env_path, size)
    for candidate in _FONT_CANDIDATES:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size)
    logger.warning("No CJK font found — translated text may render as tofu (boxes)")
    return ImageFont.load_default()


def fit_text(
    draw: ImageDraw.ImageDraw,
    translated: str,
    region_w: int,
    region_h: int,
    font_path: str | None = None,
) -> tuple[ImageFont.FreeTypeFont | ImageFont.ImageFont, int, float, float]:
    """Find a font size that fits the text in the box.

    Returns (font, size, text_w, text_h). The size starts at
    INITIAL_FONT_FRAC of the region's height, which leaves headroom for a
    translation longer than the source, and shrinks until the text fits both
    ways.
    """
    initial_size = max(int(region_h * INITIAL_FONT_FRAC), MIN_FONT_SIZE)
    try:
        font = find_font(font_path, initial_size)
    except Exception:
        font = find_font(font_path, MIN_FONT_SIZE)
    size = initial_size
    while size >= MIN_FONT_SIZE:
        bbox = draw.textbbox((0, 0), translated, font=font)
        text_w = bbox[2] - bbox[0]
        text_h = bbox[3] - bbox[1]
        if text_w <= region_w and text_h <= region_h:
            return font, size, text_w, text_h
        size -= 1
        try:
            font = find_font(font_path, size)
        except Exception:
            break
    bbox = draw.textbbox((0, 0), translated, font=font)
    return font, size, bbox[2] - bbox[0], bbox[3] - bbox[1]


def render_translated_page(
    image_bytes: bytes, regions: list[dict], font_path: str | None = None
) -> bytes:
    """Draw each region's translation over the region it came from.

    `regions` need a "bbox" and a "translation"; a region without a
    translation is left as it is.
    """
    image = Image.open(BytesIO(image_bytes)).convert("RGB")
    draw = ImageDraw.Draw(image)

    for region in regions:
        translated = (region.get("translation") or "").strip()
        if not translated:
            continue
        x1, y1, x2, y2 = region["bbox"]
        region_w = max(1, x2 - x1)
        region_h = max(1, y2 - y1)
        # A little padding, so the edges of the original text do not show.
        pad = 2
        draw.rectangle([x1 - pad, y1 - pad, x2 + pad, y2 + pad], fill="white")
        font, _, _, _ = fit_text(draw, translated, region_w, region_h, font_path)
        draw.text((x1 + 2, y1 + 2), translated, fill="black", font=font)

    buf = BytesIO()
    image.save(buf, format="JPEG", quality=90, optimize=True)
    return buf.getvalue()
