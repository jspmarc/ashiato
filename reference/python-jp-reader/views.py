"""Top-level FastHTML views (home page).

Per-tool pages live in app/tools/<tool>/views.py.
"""

from fasthtml.common import H1, H2, A, Div, P

from app.fh_app import rt
from app.ui import page


@rt("/")
def index():
    return page(
        "home",
        H1("Ashiato", cls="text-3xl font-bold mb-6"),
        Div(
            Div(
                Div(
                    H2("JP Reader"),
                    P(
                        "Photograph a Japanese page — read the text, its "
                        "translation and how each word is pronounced."
                    ),
                    Div(
                        A("Open", href="/jp-reader/", cls="btn btn-primary"),
                        cls="card-actions justify-end",
                    ),
                    cls="card-body",
                ),
                cls="card bg-base-200 shadow-xl",
            ),
            cls="grid grid-cols-1 md:grid-cols-2 gap-6",
        ),
    )
