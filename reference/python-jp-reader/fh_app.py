"""Shared FastHTML app + rt decorator.

Per-tool views.py imports `rt` from here so all routes register on a
single FastHTML sub-app, which main.py mounts at `/`.
"""

from pathlib import Path

from fasthtml.common import fast_app

# FastHTML's static route defaults to the working directory, which would
# expose any .js/.css/.json file under it. Point it at our own assets.
STATIC_DIR = Path(__file__).parent / "static"

fh_app, rt = fast_app(static_path=str(STATIC_DIR))
