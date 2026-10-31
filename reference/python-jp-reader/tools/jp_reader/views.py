"""FastHTML pages for jp-reader.

Two pages: one to pick and upload a photo, one per scanned page. The detail
page is rendered on the server, like the index page — the JavaScript only does
what JavaScript has to do: the live preview, the corner dragging, the region
drawing and the clicks.
"""

from fastapi.responses import HTMLResponse
from fasthtml.common import (
    H1,
    H2,
    H3,
    A,
    Button,
    Details,
    Dialog,
    Div,
    Form,
    Img,
    Input,
    Label,
    NotStr,
    P,
    Pre,
    Progress,
    Script,
    Span,
    Style,
    Summary,
    Table,
    Td,
    Template,
    Tr,
)
from fastlucide.icons import Arrow_left, Copy, Crop, Scan, Trash_2

from app.core import jr_store
from app.fh_app import rt
from app.ui import asset_url, page

# The overlay boxes and the quad sit above the picture.
_QUAD_SVG = (
    "<svg id='jr-quad' class='absolute inset-0 w-full h-full' "
    "viewBox='0 0 100 100' preserveAspectRatio='none'></svg>"
)

# The reader's own look. DaisyUI 5 calls the primary colour
# `--color-primary`; the old `--p` shorthand is not defined, which left the
# boxes without a border and the tapped line unmarked.
_BOX_STYLES = """
.jr-box { border-color: color-mix(in oklab, var(--color-primary) 45%, transparent); }
.jr-box:hover {
  background: color-mix(in oklab, var(--color-primary) 12%, transparent);
  box-shadow: 0 0 0 2px color-mix(in oklab, var(--color-primary) 55%, transparent);
}
.jr-box.is-active {
  background: color-mix(in oklab, var(--color-primary) 22%, transparent);
  border-color: var(--color-primary);
  box-shadow: 0 0 0 3px color-mix(in oklab, var(--color-primary) 60%, transparent);
}
"""


@rt("/jp-reader/")
def index():
    """Upload a new page."""
    return page(
        "jp-reader",
        H1("JP Reader", cls="text-3xl font-bold mb-2"),
        P(
            "Photograph a Japanese page — read the text, its translation, "
            "and how each word is pronounced.",
            cls="opacity-70 mb-6",
        ),
        Div(
            Div(
                H2("New page"),
                Form(
                    Label(
                        Div(Span("Page photo", cls="label-text"), cls="label"),
                        Input(
                            type="file",
                            name="file",
                            accept="image/*",
                            capture="environment",
                            cls="file-input file-input-bordered w-full",
                        ),
                        Div(
                            Span(
                                "Take a photo of a page, or choose a file",
                                cls="label-text-alt",
                            ),
                            cls="label",
                        ),
                        cls="form-control",
                    ),
                    Div(
                        Img(
                            id="jr-preview",
                            cls="hidden rounded-lg max-h-96 w-auto "
                            "border border-base-300",
                        ),
                        id="jr-preview-wrap",
                        cls="mt-4",
                    ),
                    # The straighten controls only mean something once there
                    # is a photo to straighten.
                    Div(
                        _angle_controls(0.0, show_apply=False),
                        id="jr-straighten",
                        cls="mt-4 hidden",
                    ),
                    Input(
                        type="hidden",
                        name="rotation_deg",
                        id="jr-rotation",
                        value="0",
                    ),
                    Label(
                        Div(Span("Password", cls="label-text"), cls="label"),
                        Input(
                            type="password",
                            name="password",
                            id="jr-password",
                            placeholder="required to upload",
                            cls="input input-bordered w-full max-w-xs",
                        ),
                        Div(
                            Span(
                                "Needed for uploads and corrections",
                                cls="label-text-alt",
                            ),
                            cls="label",
                        ),
                        cls="form-control mt-4",
                    ),
                    Div(
                        Progress(
                            id="jr-bar",
                            cls="progress progress-primary w-full",
                            value="0",
                            max="100",
                        ),
                        Div(
                            Span(id="jr-status", cls="text-sm opacity-70"),
                            Button(
                                "Cancel",
                                type="button",
                                id="jr-cancel",
                                cls="btn btn-ghost btn-sm",
                            ),
                            cls="flex items-center justify-between gap-3 mt-2",
                        ),
                        id="jr-progress-box",
                        cls="hidden mt-4",
                    ),
                    Div(
                        Button(
                            "Upload",
                            type="submit",
                            id="jr-upload-btn",
                            cls="btn btn-primary",
                        ),
                        cls="card-actions justify-end mt-4",
                    ),
                    id="jr-upload-form",
                ),
                cls="card-body",
            ),
            cls="card bg-base-200 shadow-xl",
        ),
        Div(
            H2("Recent pages", cls="text-xl font-bold mb-3"),
            Div(
                id="jr-list",
                cls="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4",
            ),
            cls="mt-8",
        ),
        _delete_dialog(),
        # The page list is drawn in JavaScript; it copies its icon from here
        # so the icon still comes from the one sprite sheet.
        Template(Trash_2(sz=16), id="jr-icon-trash"),
        Script(src=asset_url("/jp-reader/editor.js")),
        Script(src=asset_url("/jp-reader/delete.js")),
        Script(src=asset_url("/jp-reader/upload.js")),
        NotStr("<div id='jr-toast' class='toast toast-end toast-bottom z-50'></div>"),
    )


def _delete_dialog():
    """The confirmation shown before a page is deleted."""
    return Dialog(
        Div(
            Div(
                H3("Delete this page?", cls="font-bold text-lg"),
                P(
                    "The picture and everything read from it are removed. "
                    "This cannot be undone.",
                    cls="text-sm opacity-70 mt-1",
                ),
                cls="p-6",
            ),
            Div(
                Button(
                    "Cancel",
                    type="button",
                    id="jr-delete-cancel",
                    cls="btn btn-ghost",
                ),
                Button(
                    "Delete",
                    type="button",
                    id="jr-delete-confirm",
                    cls="btn btn-error",
                ),
                cls="flex justify-end gap-2 px-6 pb-6",
            ),
            cls="modal-box",
        ),
        NotStr(
            "<form method='dialog' class='modal-backdrop'>"
            "<button aria-label='close'>close</button></form>"
        ),
        id="jr-delete-modal",
        cls="modal",
    )


@rt("/jp-reader/{record_id}")
async def detail(record_id: str):
    """One scanned page. The link is shareable and shows the work as it goes."""
    record = await jr_store.get_record(record_id)
    if record is None:
        return page(
            "jp-reader",
            H1("JP Reader", cls="text-3xl font-bold mb-4"),
            Div("That page is no longer here.", cls="alert alert-error"),
            A(
                Arrow_left(sz=16),
                "Back",
                href="/jp-reader/",
                cls="btn btn-ghost btn-sm mt-4 gap-2",
            ),
        )

    return page(
        "jp-reader",
        Div(
            A(
                Arrow_left(sz=18),
                href="/jp-reader/",
                cls="btn btn-ghost btn-sm btn-square",
                title="Back to the pages",
                aria_label="Back to the pages",
            ),
            H1("JP Reader", cls="text-2xl font-bold flex-1"),
            Button(
                Copy(sz=18),
                type="button",
                id="jr-copy",
                cls="btn btn-ghost btn-sm btn-square",
                title="Copy the link to this page",
                aria_label="Copy link",
            ),
            Button(
                Trash_2(sz=18),
                type="button",
                id="jr-delete",
                cls="btn btn-ghost btn-sm btn-square text-error",
                title="Delete this page (shift-click skips the question)",
                aria_label="Delete page",
            ),
            cls="flex items-center gap-2 mb-6",
        ),
        Div(
            Div(id="jr-status-box", cls="py-4"),
            Div(id="jr-orientation", cls="hidden alert alert-info mb-4"),
            Div(_detail_body(record), id="jr-detail"),
            cls="card-body",
        ),
        Div(id="jr-root", data_record_id=record_id, cls="hidden"),
        _delete_dialog(),
        Style(_BOX_STYLES),
        Script(src=asset_url("/jp-reader/editor.js")),
        Script(src=asset_url("/jp-reader/delete.js")),
        Script(src=asset_url("/jp-reader/detail.js")),
        NotStr("<div id='jr-toast' class='toast toast-end toast-bottom z-50'></div>"),
    )


@rt("/jp-reader/{record_id}/fragment")
async def fragment(record_id: str):
    """The detail page's body, on its own.

    The page swaps this in when the read finishes, so the picture and the
    text can arrive at different times.
    """
    record = await jr_store.get_record(record_id)
    if record is None:
        return HTMLResponse(
            "<div class='alert alert-error'>That page is no longer here.</div>"
        )
    return HTMLResponse(_detail_body(record).__html__())


def _detail_body(record: dict):
    """The detail page's body — the page and the fragment share it."""
    regions = record.get("regions") or []
    width = record.get("width") or 1
    height = record.get("height") or 1

    boxes = [
        Div(
            cls="absolute jr-box rounded-sm border-2",
            style=(
                f"left:{region['bbox'][0] / width * 100:.4f}%;"
                f"top:{region['bbox'][1] / height * 100:.4f}%;"
                f"width:{(region['bbox'][2] - region['bbox'][0]) / width * 100:.4f}%;"
                f"height:{(region['bbox'][3] - region['bbox'][1]) / height * 100:.4f}%;"
            ),
            data_region=str(region["i"]),
            title=region.get("text", ""),
        )
        for region in regions
    ]

    # Both frames are locked to the page's shape, so the original and the
    # translation stay level and the same size even before the translation
    # exists.
    frame = f"aspect-ratio:{width}/{height};"
    # The images are cached, so each revision gets its own address.
    rev = f"?r={record.get('revision') or 0}"

    return Div(
        # The learning view: the page as it is, and the page translated, side
        # by side and level with each other.
        Div(
            Div(
                P("Original — tap a line", cls="text-xs opacity-60 mb-1"),
                Div(
                    Img(
                        id="jr-image",
                        src=f"/api/jp-reader/records/{record['id']}/image{rev}",
                        cls="w-full h-full block",
                        alt="scanned page",
                    ),
                    Div(*boxes, id="jr-boxes", cls="absolute inset-0"),
                    id="jr-canvas",
                    cls="relative rounded overflow-hidden border border-base-300 "
                    "bg-base-200",
                    style=frame,
                ),
                cls="min-w-0",
            ),
            Div(
                P("Translated", cls="text-xs opacity-60 mb-1"),
                Div(
                    Span(
                        "The translation is not ready yet.",
                        cls="absolute inset-0 flex items-center justify-center "
                        "p-4 text-center text-xs opacity-60",
                    ),
                    Img(
                        id="jr-translated",
                        src=f"/api/jp-reader/records/{record['id']}/translated{rev}",
                        cls="relative w-full h-full block bg-base-200",
                        alt="the page, translated",
                        onerror="this.style.visibility='hidden'",
                    ),
                    cls="relative rounded overflow-hidden border border-base-300 "
                    "bg-base-200",
                    style=frame,
                ),
                cls="min-w-0",
            ),
            cls="grid grid-cols-2 gap-2 sm:gap-4 items-start",
        ),
        # Improving the scan comes straight after the pictures it changes.
        _tools(record),
        # The words of the line that was tapped.
        Div(_words(), cls="mt-4"),
        # The reading, in full.
        Div(
            Div(
                H3("The page", cls="font-bold"),
                Pre(
                    record.get("text") or "(no text yet)",
                    cls="text-xs whitespace-pre-wrap bg-base-100 p-3 rounded-box",
                ),
            ),
            Div(
                H3("The translation", cls="font-bold"),
                Pre(
                    record.get("translation") or "(not translated yet)",
                    cls="text-xs whitespace-pre-wrap bg-base-100 p-3 rounded-box",
                ),
            ),
            cls="grid grid-cols-1 lg:grid-cols-2 gap-4 mt-4",
        ),
        # The inspection, under everything else.
        Details(
            Summary("Details", cls="font-bold cursor-pointer"),
            _timings_table(record),
            cls="bg-base-100 rounded-box p-3 mt-4",
        ),
        id="jr-detail-body",
    )


def _tools(record: dict):
    """Improving the scan, with a preview of its own.

    The pictures above stay as they are; the panel shows the uncorrected page
    with the pending change on it. Whatever falls outside the corners is
    shaded, not hidden, so it is still clear what is being cut away.
    """
    transform = record.get("transform") or {}
    angle = transform.get("rotation_deg") or 0
    base_width = record.get("base_width") or record.get("width") or 1
    base_height = record.get("base_height") or record.get("height") or 1
    return Details(
        Summary(
            Span(
                Crop(sz=18),
                "Improve the scan",
                cls="inline-flex items-center gap-2 font-bold",
            ),
            Span(
                "straighten, crop the corners, re-read a region",
                cls="text-xs opacity-60 ml-2",
            ),
            cls="cursor-pointer",
        ),
        Div(
            Div(
                Div(
                    Img(
                        id="jr-edit-image",
                        src=f"/api/jp-reader/records/{record['id']}/base",
                        cls="w-full h-full block",
                        alt="the page, before the change",
                        loading="lazy",
                    ),
                    NotStr(_QUAD_SVG),
                    id="jr-edit-pivot",
                    cls="relative w-full h-full",
                ),
                # A dark frame: when the page is turned, the corners it leaves
                # behind read as shadow rather than as a white cut-out.
                id="jr-edit-preview",
                cls="relative rounded overflow-hidden bg-neutral max-w-xl mx-auto",
                style=f"aspect-ratio:{base_width}/{base_height};",
            ),
            _angle_controls(angle),
            Div(
                Button(
                    Scan(sz=14),
                    Span("Select region", data_label="1"),
                    type="button",
                    id="jr-region",
                    cls="btn btn-xs btn-outline gap-1",
                ),
                Span(id="jr-region-status", cls="text-xs opacity-70"),
                cls="flex items-center gap-2",
            ),
            P(
                "Straighten the page, or drag the corners to square off a "
                "photo taken at an angle. Applying reads the page again. "
                "Select region draws on the original above.",
                cls="text-xs opacity-60",
            ),
            cls="pt-3 space-y-3",
        ),
        cls="bg-base-100 rounded-box p-3 mt-4",
        id="jr-edit",
    )


def _words():
    """The words of the line that was tapped."""
    return Div(
        Div(
            H3("Words", cls="font-bold text-sm"),
            P(
                "Tap a line on the page to see its words.",
                cls="text-xs opacity-60",
            ),
            cls="flex items-baseline gap-2 flex-wrap",
        ),
        Div(id="jr-chips", cls="flex flex-wrap gap-1 mt-2"),
        Input(
            id="jr-phrase",
            cls="input input-bordered w-full mt-3",
            placeholder="Tap words above, or type a phrase",
        ),
        Div(id="jr-preview-box", cls="mt-2 text-sm"),
        cls="card bg-base-100 p-4 rounded-box",
    )


def _angle_controls(angle: float = 0.0, show_apply: bool = True):
    """The rotation controls, shared by the upload page and the editor.

    The upload page has no Apply button: the angle travels with the upload.
    """
    return Div(
        Div(
            Button("−90°", type="button", data_rot="-90", cls="btn btn-xs btn-outline"),
            Button("+90°", type="button", data_rot="90", cls="btn btn-xs btn-outline"),
            Button("180°", type="button", data_rot="180", cls="btn btn-xs btn-outline"),
            Input(
                id="jr-angle",
                type="range",
                min="-180",
                max="180",
                step="0.1",
                value=f"{angle}",
                cls="range range-primary range-xs w-36",
            ),
            Input(
                id="jr-angle-num",
                type="number",
                step="0.1",
                value=f"{angle}",
                cls="input input-xs w-20",
            ),
            Span("°", cls="text-xs opacity-60"),
            Button(
                "−0.1°", type="button", id="jr-rot-down", cls="btn btn-xs btn-outline"
            ),
            Button(
                "+0.1°", type="button", id="jr-rot-up", cls="btn btn-xs btn-outline"
            ),
            Button(
                "Corners", type="button", id="jr-corners", cls="btn btn-xs btn-outline"
            ),
            Button("Reset", type="button", id="jr-reset", cls="btn btn-xs btn-ghost"),
            *(
                [
                    Button(
                        "Apply",
                        type="button",
                        id="jr-apply",
                        cls="btn btn-xs btn-primary",
                    )
                ]
                if show_apply
                else []
            ),
            cls="flex flex-wrap items-center gap-2",
        ),
        cls="text-sm",
    )


def _timings_table(record: dict):
    """What each stage of the read cost."""
    timings = record.get("timings") or {}
    rows = [
        ("Status", record.get("status") or "—"),
        ("Queue", _ms(timings.get("queue_ms"))),
        ("Preprocess", _ms(timings.get("preprocess_ms"))),
        ("OCR", _ms(timings.get("ocr_ms"))),
        ("Translation", _ms(timings.get("translate_ms"))),
        ("Total", _ms(timings.get("total_ms"))),
        ("Revision", str(record.get("revision", "—"))),
        ("Job", record.get("id", "—")),
    ]
    return Table(
        *[Tr(Td(name, cls="opacity-70"), Td(value)) for name, value in rows],
        cls="table table-xs",
    )


def _ms(value) -> str:
    if value is None:
        return "—"
    if value < 1000:
        return f"{value} ms"
    return f"{value / 1000:.1f} s"
