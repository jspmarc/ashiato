"""Request/response models for the jp-reader tool."""

from pydantic import BaseModel, Field


class PhraseRequest(BaseModel):
    """A phrase the user picked out of a page, to look up."""

    phrase: str = Field(min_length=1, max_length=500)


class TransformRequest(BaseModel):
    """Corrections to apply to a page before it is read again."""

    rotation_deg: float = 0.0
    # Four [x, y] points in the rotated image's space, or null for no
    # perspective correction.
    corners: list[list[float]] | None = None


class RegionRequest(BaseModel):
    """An area of the page to read on its own."""

    # Normalised to 0..1 of the image, so it does not depend on how the
    # viewer is scaled.
    box: list[float] = Field(min_length=4, max_length=4)
    replace_intersecting: bool = True
