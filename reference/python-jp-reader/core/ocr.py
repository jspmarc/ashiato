"""PaddleOCR engine — plain text detection + recognition.

The plain pipeline is used rather than PPStructureV3 because it reports
bounding boxes in original image coordinates. PPStructureV3 recognises text
per layout-region crop, so its boxes are local to each crop and cannot be
drawn over the page as-is.
"""

from __future__ import annotations

import logging
import os
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import numpy as np

logger = logging.getLogger(__name__)

_ENGINE = None
_ORIENTATION_MODEL = None

# PaddleOCR's default is every core, which oversubscribes badly: one page
# cost 85 CPU-seconds on 16 threads but only 22 on one. A small cap is
# faster in practice and much cheaper on a small VPS.
_MAX_THREADS = 4


def _thread_count() -> int:
    return max(1, min(_MAX_THREADS, os.cpu_count() or 1))


def _build_engine():
    from paddleocr import PaddleOCR
    from paddlex.utils.deps import is_dep_available

    # paddlex gates its result types on this package — without it the OCR
    # result class raises on instantiation instead of failing on import.
    if not is_dep_available("opencv-contrib-python"):
        raise RuntimeError(
            "opencv-contrib-python is required for PaddleOCR "
            "(it ships with the paddleocr[all] extra)"
        )

    # Every preprocessor is disabled: each one would pull an extra model
    # (~10 MB each) that this tool has no use for.
    return PaddleOCR(
        lang="japan",
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        cpu_threads=_thread_count(),
    )


def init_models() -> None:
    """Load the OCR engine. Idempotent — safe to call on every startup."""
    global _ENGINE
    if _ENGINE is None:
        _ENGINE = _build_engine()
        logger.info("PaddleOCR engine ready")
    init_orientation_model()


def init_orientation_model() -> None:
    """Load the page-orientation classifier. Idempotent."""
    global _ORIENTATION_MODEL
    if _ORIENTATION_MODEL is None:
        from paddlex import create_model

        _ORIENTATION_MODEL = create_model("PP-LCNet_x1_0_doc_ori")
        logger.info("Page orientation model ready")


def detect_orientation(image: np.ndarray) -> dict | None:
    """Guess which way up a page is.

    Returns ``{"angle": 0|90|180|270, "confidence": float}`` or None.

    Run standalone rather than through the OCR pipeline: the pipeline only
    exposes the angle and throws the confidence away, and it rotates the
    image under us, which would break the coordinate space our overlays
    depend on.
    """
    init_orientation_model()
    assert _ORIENTATION_MODEL is not None
    for result in _ORIENTATION_MODEL.predict(image):
        angle = int(result["label_names"][0])
        confidence = float(result["scores"][0])
        return {"angle": angle, "confidence": round(confidence, 4)}
    return None


def run(image: np.ndarray) -> list[dict]:
    """Run OCR over a BGR numpy array.

    Returns one region per detected text line:
    ``{"bbox": (x1, y1, x2, y2), "text": str, "score": float}``

    Coordinates are in the original image space. `image` must be a numpy
    array — PaddleOCR's reader rejects PIL images, and an RGB array would
    swap the colour channels.
    """
    init_models()
    engine = _ENGINE
    assert engine is not None
    regions: list[dict] = []
    for res in engine.predict(image):
        boxes, texts, scores = res["rec_boxes"], res["rec_texts"], res["rec_scores"]
        for box, text, score in zip(boxes, texts, scores):
            x1, y1, x2, y2 = (int(v) for v in box)
            regions.append(
                {
                    "bbox": (x1, y1, x2, y2),
                    "text": str(text),
                    "score": float(score),
                }
            )
    return regions
