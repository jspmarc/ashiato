"""Tests for the image transformations and the upload guards."""

import io

import pytest
from PIL import Image

from app.tools.jp_reader import service
from app.tools.jp_reader.transform import (
    Transform,
    apply_transform,
    normalize_box,
    rotate_image,
    validate_corners,
    warp_perspective,
)


def _image(width: int = 400, height: int = 200, colour=(10, 20, 30)) -> Image.Image:
    return Image.new("RGB", (width, height), colour)


def _jpeg(image: Image.Image) -> bytes:
    buf = io.BytesIO()
    image.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


# ── rotation ─────────────────────────────────────────────────────


def test_a_right_angle_rotates_without_resampling():
    image = _image(400, 200)
    rotated = rotate_image(image, 90)
    assert rotated.size == (200, 400)
    # The top-left pixel ends up at the top-right after a clockwise turn.
    assert rotated.getpixel((199, 0)) == image.getpixel((0, 0))


def test_a_quarter_turn_the_other_way():
    image = _image(400, 200)
    assert rotate_image(image, 270).size == (200, 400)
    assert rotate_image(image, 180).size == (400, 200)


def test_a_fine_rotation_expands_so_nothing_is_clipped():
    image = _image(400, 200)
    rotated = rotate_image(image, 3.7)
    assert rotated.width >= 400
    assert rotated.height >= 200
    # The corner that was at the centre is still in the picture.
    assert rotated.getpixel((rotated.width // 2, rotated.height // 2)) != (0, 0, 0)


def test_no_rotation_returns_the_same_size():
    image = _image(400, 200)
    assert rotate_image(image, 0).size == (400, 200)


# ── perspective ──────────────────────────────────────────────────


def test_a_quad_warps_onto_a_rectangle():
    image = _image(400, 200)
    corners = ((10, 5), (390, 5), (390, 195), (10, 195))
    warped = warp_perspective(image, corners)
    assert warped.size == (380, 190)


def test_corners_outside_the_image_are_rejected():
    with pytest.raises(ValueError):
        validate_corners([(0, 0), (500, 0), (500, 200), (0, 200)], 400, 200)


def test_crossing_corners_are_rejected():
    with pytest.raises(ValueError):
        validate_corners([(10, 10), (390, 190), (390, 10), (10, 190)], 400, 200)


def test_a_tiny_quad_is_rejected():
    with pytest.raises(ValueError):
        validate_corners([(0, 0), (10, 0), (10, 10), (0, 10)], 400, 200)


def test_the_wrong_number_of_corners_is_rejected():
    with pytest.raises(ValueError):
        validate_corners([(0, 0), (10, 0), (10, 10)], 400, 200)


# ── the transform as a whole ─────────────────────────────────────


def test_the_transform_applies_rotation_then_perspective():
    image = _image(400, 200)
    transform = Transform(
        rotation_deg=90, corners=((0, 0), (199, 0), (199, 199), (0, 199))
    )
    result = apply_transform(image, transform)
    # Rotated first: 200x400, then warped to the quad's size.
    assert result.width == 199
    assert result.height == 199


def test_an_identity_transform_changes_nothing():
    image = _image(400, 200)
    assert Transform().is_identity
    assert apply_transform(image, Transform()).size == (400, 200)


def test_the_corners_are_measured_in_the_base_image():
    """The quad is cut out of the base, then the result is turned."""
    image = _image(400, 200)
    corners = ((50, 25), (350, 25), (350, 175), (50, 175))
    result = apply_transform(image, Transform(corners=corners))
    # The quad is 300x150, and there is no rotation on top of it.
    assert result.size == (300, 150)


def test_rotating_keeps_the_quad_where_it_was():
    """The corners are in the base's space, so a turn does not move them."""
    image = _image(400, 200)
    corners = ((50, 25), (350, 25), (350, 175), (50, 175))
    result = apply_transform(image, Transform(rotation_deg=90, corners=corners))
    # The quad is cut out first (300x150), then turned on its side.
    assert result.size == (150, 300)


def test_a_transform_round_trips_through_its_dict():
    transform = Transform(rotation_deg=-12.5, corners=((1, 2), (3, 4), (5, 6), (7, 8)))
    parsed = Transform.from_dict(transform.to_dict())
    assert parsed.rotation_deg == -12.5
    assert parsed.corners == transform.corners


# ── region boxes ─────────────────────────────────────────────────


def test_a_normalised_box_becomes_pixels():
    assert normalize_box([0.0, 0.0, 0.5, 0.5], 400, 200) == (0, 0, 200, 100)


def test_a_normalised_box_is_clipped_to_the_image():
    left, top, right, bottom = normalize_box([-1, -1, 2, 2], 400, 200)
    assert (left, top, right, bottom) == (0, 0, 400, 200)


def test_a_tiny_region_is_rejected():
    with pytest.raises(ValueError):
        normalize_box([0.5, 0.5, 0.505, 0.505], 400, 200)


# ── the service ──────────────────────────────────────────────────


def test_a_non_image_is_rejected():
    with pytest.raises(service.InvalidImage):
        service.decode_image(b"this is not an image")


def test_an_empty_upload_is_rejected():
    with pytest.raises(service.InvalidImage):
        service.decode_image(b"")


def test_a_truncated_image_is_rejected():
    data = _jpeg(_image(400, 200))
    with pytest.raises(service.InvalidImage):
        service.decode_image(data[: len(data) // 3])


def test_an_unsupported_format_is_rejected():
    buf = io.BytesIO()
    _image(20, 20).save(buf, format="BMP")
    with pytest.raises(service.InvalidImage):
        service.decode_image(buf.getvalue())


def test_an_oversized_image_is_rejected(monkeypatch):
    monkeypatch.setattr(service, "MAX_PIXELS", 100)
    with pytest.raises(service.ImageTooLarge):
        service.decode_image(_jpeg(_image(400, 200)))


def test_the_exif_orientation_is_applied():
    """A photo tagged as rotated 90° comes out upright."""
    image = _image(400, 200)
    exif = image.getexif()
    exif[274] = 6  # "rotate 90° clockwise" as cameras record it
    buf = io.BytesIO()
    image.save(buf, format="JPEG", exif=exif)

    decoded = service.decode_image(buf.getvalue())
    assert decoded.size == (200, 400)


def test_the_base_image_is_never_re_encoded_by_a_correction():
    base = _jpeg(_image(400, 200))
    before = service.transform_image(base, Transform(rotation_deg=90), 2000)[0]
    # A second correction starts from the same base, so the picture cannot
    # degrade step by step.
    after = service.transform_image(base, Transform(rotation_deg=90), 2000)[0]
    assert before == after


def test_cropping_a_region_reports_where_it_came_from():
    image = _image(400, 200)
    data = _jpeg(image)
    crop, width, height, offset = service.crop_region(data, [0.25, 0.5, 0.75, 1.0])
    assert (width, height) == (200, 100)
    assert offset == (100, 100)
    assert crop[:2] == b"\xff\xd8"
