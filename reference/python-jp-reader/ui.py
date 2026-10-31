"""Shared FastHTML UI components and layout."""

from hashlib import sha256
from pathlib import Path

from fasthtml.common import (
    A,
    Body,
    Div,
    Footer,
    Head,
    Html,
    Link,
    Main,
    Meta,
    NotStr,
    Script,
    Small,
    Style,
    Title,
)
from fasthtml.components import FT
from fastlucide.icons import spritesheet

_APP_DIR = Path(__file__).parent

# Build stamp: the newest mtime of any file the app serves or renders. It
# changes whenever the code changes, so a page refresh both shows which
# build you are on and cache-busts every asset — no manual version bumps.
_BUILD_STAMP: str | None = None


def build_stamp() -> str:
    """A short hash of the current build, stable across requests."""
    global _BUILD_STAMP
    if _BUILD_STAMP is None:
        mtimes = [
            path.stat().st_mtime
            for path in _APP_DIR.rglob("*")
            if path.suffix in (".py", ".js") and "__pycache__" not in path.parts
        ]
        digest = sha256(str(max(mtimes)).encode()).hexdigest()
        _BUILD_STAMP = digest[:7]
    return _BUILD_STAMP


def asset_url(path: str) -> str:
    """A static asset URL with the build stamp as its cache-buster."""
    return f"{path}?v={build_stamp()}"


def page(active: str, *content) -> FT:
    """Full HTML page with DaisyUI + htmx."""

    def nav_link_class(target: str) -> str:
        return "font-bold" if active == target else ""

    nav = NotStr(
        "<ul class='menu menu-horizontal px-1'>"
        f"<li><a href='/jp-reader/' class='{nav_link_class('jp-reader')}'>"
        "JP Reader</a></li>"
        "<li class='menu-horizontal border-l border-base-300 pl-2 ml-2'>"
        "<a href='https://jeremiaaxel.dev'>Portfolio</a></li>"
        "<li><a href='https://blog.jeremiaaxel.dev'>Blog</a></li>"
        "<li><a href='https://moneybackward.jeremiaaxel.dev'>Money Backward</a></li>"
        "</ul>"
    )
    return Html(
        Head(
            Meta(charset="UTF-8"),
            Meta(name="viewport", content="width=device-width, initial-scale=1.0"),
            Title("Ashiato"),
            Link(rel="stylesheet", href="https://cdn.jsdelivr.net/npm/daisyui@5"),
            Script(src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"),
            Script(src="https://unpkg.com/htmx.org@1.9.12"),
            Style("rt { font-size: 0.5em; }"),
        ),
        Body(
            Div(
                Div(
                    A("Ashiato", href="/", cls="btn btn-ghost text-xl"),
                    cls="flex-1",
                ),
                Div(nav, cls="flex-none"),
                cls="navbar bg-base-100 shadow-sm",
            ),
            Main(*content, cls="container mx-auto px-4 py-8 max-w-4xl"),
            Footer(
                Small(
                    f"build {build_stamp()}",
                    title="Changes with every deploy — use it to check "
                    "you are on the latest version",
                    cls="opacity-40",
                ),
                cls="footer footer-center pb-4 text-base-content",
            ),
            # Every icon on the site is a fastlucide `<use>` pointing into this
            # sheet, so it has to be on every page — including the icons that
            # arrive later in a swapped-in fragment or are drawn by JavaScript.
            spritesheet,
            cls="min-h-screen",
        ),
        lang="en",
        data_theme="light",
    )
