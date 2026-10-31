"""Image geometry for jp_reader.

Pure Pillow on purpose: the web process applies these transformations, and
opencv/paddle live in the worker's `ocr` dependency group, which the web
process does not install.

Corners are given in the coordinate space of the base image and stored in
the order top-left, top-right, bottom-right, bottom-left.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from PIL import Image

# A corner quad smaller than this (in pixels) is not worth warping.
MIN_QUAD_AREA = 10_000

# Right angles that map exactly onto a transpose, so no resampling is needed.
_EXACT_ANGLES = {
    90: Image.Transpose.ROTATE_270,  # PIL rotates counter-clockwise
    180: Image.Transpose.ROTATE_180,
    270: Image.Transpose.ROTATE_90,
}


@dataclass(frozen=True)
class Transform:
    """The corrections applied to a page's base image."""

    rotation_deg: float = 0.0
    corners: tuple[tuple[int, int], ...] | None = None

    @property
    def is_identity(self) -> bool:
        return abs(self.rotation_deg) < 0.01 and not self.corners

    def to_dict(self) -> dict:
        return {
            "rotation_deg": round(self.rotation_deg, 3),
            "corners": [list(c) for c in self.corners] if self.corners else None,
        }

    @classmethod
    def from_dict(cls, data: dict | None) -> Transform:
        data = data or {}
        corners = data.get("corners")
        parsed = None
        if corners:
            parsed = tuple((int(x), int(y)) for x, y in corners)
        return cls(
            rotation_deg=float(data.get("rotation_deg") or 0.0),
            corners=parsed,
        )


def rotate_image(image: Image.Image, degrees: float) -> Image.Image:
    """Rotate clockwise by `degrees`, expanding so nothing is clipped."""
    if abs(degrees) < 0.01:
        return image
    normalized = degrees % 360
    for angle, transpose in _EXACT_ANGLES.items():
        if abs(normalized - angle) < 0.01:
            return image.transpose(transpose)
    return image.rotate(
        -degrees,
        expand=True,
        resample=Image.Resampling.BICUBIC,
        fillcolor=(255, 255, 255),
    )


def warp_perspective(
    image: Image.Image, corners: tuple[tuple[int, int], ...]
) -> Image.Image:
    """Map the source quadrilateral onto a rectangle."""
    top_left, top_right, bottom_right, bottom_left = corners
    width = int(
        round(max(_distance(top_left, top_right), _distance(bottom_left, bottom_right)))
    )
    height = int(
        round(max(_distance(top_left, bottom_left), _distance(top_right, bottom_right)))
    )
    if width < 2 or height < 2:
        raise ValueError("The selected corners are too small to warp.")
    # Pillow's QUAD wants upper-left, lower-left, lower-right, upper-right.
    data = (
        top_left[0],
        top_left[1],
        bottom_left[0],
        bottom_left[1],
        bottom_right[0],
        bottom_right[1],
        top_right[0],
        top_right[1],
    )
    return image.transform(
        (width, height),
        Image.Transform.QUAD,
        data,
        resample=Image.Resampling.BICUBIC,
    )


def apply_transform(image: Image.Image, transform: Transform) -> Image.Image:
    """Square the page first, then straighten it.

    The corners are in the base image's space, so they stay valid no matter
    how the page is later rotated. The order matches what the editor
    previews: crop to the quad, then turn the result.
    """
    result = image
    if transform.corners:
        result = warp_perspective(result, transform.corners)
    return rotate_image(result, transform.rotation_deg)


def validate_corners(corners, width: int, height: int) -> tuple[tuple[int, int], ...]:
    """Check four corner points and return them as integers.

    Raises ValueError with a message meant for the user.
    """
    if not corners or len(corners) != 4:
        raise ValueError("Four corners are needed to correct the perspective.")
    points = []
    for point in corners:
        x, y = point
        xi, yi = int(round(x)), int(round(y))
        if not (0 <= xi < width and 0 <= yi < height):
            raise ValueError("The corners must stay inside the page.")
        points.append((xi, yi))

    area = abs(_polygon_area(points))
    if area < MIN_QUAD_AREA:
        raise ValueError("The selected area is too small to correct.")
    if _crosses_itself(points):
        raise ValueError("The corners cross each other — try again.")
    return tuple(points)


def _distance(a: tuple[int, int], b: tuple[int, int]) -> float:
    return math.hypot(b[0] - a[0], b[1] - a[1])


def _polygon_area(points: list[tuple[int, int]]) -> float:
    """Shoelace formula."""
    total = 0.0
    for index, (x1, y1) in enumerate(points):
        x2, y2 = points[(index + 1) % len(points)]
        total += x1 * y2 - x2 * y1
    return total / 2


def _orientation(a, b, c) -> int:
    value = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    if value > 0:
        return 1
    if value < 0:
        return -1
    return 0


def _crosses_itself(points: list[tuple[int, int]]) -> bool:
    """True when the quad is a bow tie rather than a simple polygon."""
    for i in range(4):
        a1, a2 = points[i], points[(i + 1) % 4]
        for j in range(i + 1, 4):
            if j == i or (j + 1) % 4 == i or j == (i + 1) % 4:
                continue
            b1, b2 = points[j], points[(j + 1) % 4]
            if _segments_cross(a1, a2, b1, b2):
                return True
    return False


def _segments_cross(p1, p2, p3, p4) -> bool:
    d1 = _orientation(p3, p4, p1)
    d2 = _orientation(p3, p4, p2)
    d3 = _orientation(p1, p2, p3)
    d4 = _orientation(p1, p2, p4)
    if d1 != d2 and d3 != d4:
        return True
    return False


def normalize_box(box, width: int, height: int) -> tuple[int, int, int, int]:
    """Turn a normalised (0..1) box into image pixels, clipped to the image."""
    if not box or len(box) != 4:
        raise ValueError("A region needs four coordinates.")
    x1, y1, x2, y2 = (float(v) for v in box)
    left = max(0, min(width - 1, int(round(min(x1, x2) * width))))
    top = max(0, min(height - 1, int(round(min(y1, y2) * height))))
    right = max(left + 1, min(width, int(round(max(x1, x2) * width))))
    bottom = max(top + 1, min(height, int(round(max(y1, y2) * height))))
    if right - left < 8 or bottom - top < 8:
        raise ValueError("That region is too small to read.")
    return left, top, right, bottom
