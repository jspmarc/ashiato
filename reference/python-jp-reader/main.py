import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

from app import views as _home_views  # noqa: F401 — registers routes
from app.config import settings
from app.fh_app import fh_app
from app.tools.jp_reader import (
    views as _jp_reader_views,  # noqa: F401 — registers routes
)
from app.tools.jp_reader.router import router as jp_reader_router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    (settings.app.temp_dir / "uploads").mkdir(parents=True, exist_ok=True)
    yield


app = FastAPI(title="Ashiato", lifespan=lifespan)


@app.get("/robots.txt", include_in_schema=False)
async def robots() -> PlainTextResponse:
    return PlainTextResponse(
        "# Ashiato is a public personal study tool.\n"
        "User-agent: *\nAllow: /\n",
        media_type="text/plain",
    )


# API routes registered FIRST — Starlette checks mounted subapps before
# include_router, so this order lets /api/* win over FastHTML's catch-all.
app.include_router(jp_reader_router)

# FastHTML pages mounted at root — handles / and /jp-reader/
app.mount("/", fh_app)
