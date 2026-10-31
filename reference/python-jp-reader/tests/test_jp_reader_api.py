"""Tests for the jp-reader HTTP API."""

import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.main import app


@pytest.fixture
def queued():
    """Jobs that the API tried to hand to the worker."""
    return []


@pytest.fixture
def client(fake_redis, password, monkeypatch, queued):
    """A test client whose uploads do not reach the task queue."""
    from app.brokers import taskiq_broker

    async def fake_kiq(**kwargs):
        queued.append(kwargs)

    monkeypatch.setattr(taskiq_broker.ocr_page_task, "kiq", fake_kiq)
    monkeypatch.setattr(taskiq_broker.region_ocr_task, "kiq", fake_kiq)

    # No network in tests — the reading is computed locally, the meaning is not.
    def fake_translate(text, target_lang, on_retry=None, max_retries=5):
        return (f"[{target_lang}] {text}", 0, None)

    monkeypatch.setattr("app.tools.jp_reader.service.translate_text", fake_translate)

    with TestClient(app) as test_client:
        yield test_client


def _jpeg() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (60, 40), "white").save(buf, format="JPEG")
    return buf.getvalue()


def test_upload_needs_the_password(client):
    response = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
    )
    assert response.status_code == 401


def test_upload_rejects_a_wrong_password(client):
    response = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "wrong"},
    )
    assert response.status_code == 401


def test_upload_stores_the_page_and_queues_the_job(client, queued):
    response = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 200
    record_id = response.json()["id"]

    assert queued and queued[0]["record_id"] == record_id

    record = client.get(f"/api/jp-reader/records/{record_id}").json()
    assert record["status"] == "pending"
    assert record["width"] == 60
    assert record["height"] == 40

    image = client.get(f"/api/jp-reader/records/{record_id}/image")
    assert image.status_code == 200
    assert image.headers["content-type"] == "image/jpeg"
    assert image.content[:2] == b"\xff\xd8"


def test_an_upload_can_be_straightened(client):
    """The photo may be turned on the upload page before it is sent."""
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        data={"rotation_deg": "90"},
        headers={"X-App-Password": "secret"},
    ).json()["id"]

    record = client.get(f"/api/jp-reader/records/{record_id}").json()
    assert record["transform"]["rotation_deg"] == 90
    # The page is turned; the base it was derived from is not.
    assert (record["width"], record["height"]) == (40, 60)
    assert (record["base_width"], record["base_height"]) == (60, 40)


def test_password_may_also_be_sent_as_a_form_field(client):
    response = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        data={"password": "secret"},
    )
    assert response.status_code == 200


def test_listing_shows_the_stored_pages(client):
    client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    )
    listed = client.get("/api/jp-reader/records").json()
    assert len(listed) == 1
    assert listed[0]["status"] == "pending"


def test_unknown_record_is_404(client):
    assert client.get("/api/jp-reader/records/nope").status_code == 404
    assert client.get("/api/jp-reader/records/nope/image").status_code == 404


def test_preview_returns_a_reading_without_saving_it(client):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]

    response = client.post(
        f"/api/jp-reader/records/{record_id}/preview",
        json={"phrase": "運動"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["reading"] == "うんどう"
    assert "<ruby>運動" in body["ruby_html"]
    # The translation is still being fetched.
    assert body["translation_pending"] is True


def test_a_cached_phrase_comes_back_translated_at_once(client):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]

    # The first call fills the cache in the background.
    client.post(f"/api/jp-reader/records/{record_id}/preview", json={"phrase": "力学"})

    second = client.post(
        f"/api/jp-reader/records/{record_id}/preview", json={"phrase": "力学"}
    ).json()
    assert second["translation"] == "[en] 力学"
    assert second["translation_pending"] is False


def test_a_page_can_be_retried(client, queued):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]
    queued.clear()

    response = client.post(
        f"/api/jp-reader/records/{record_id}/retry",
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 200
    assert queued and queued[0]["record_id"] == record_id

    record = client.get(f"/api/jp-reader/records/{record_id}").json()
    assert record["status"] == "pending"
    assert record["error"] is None


def test_retrying_needs_the_password(client):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]

    response = client.post(f"/api/jp-reader/records/{record_id}/retry")
    assert response.status_code == 401


def test_retrying_an_unknown_page_is_404(client):
    response = client.post(
        "/api/jp-reader/records/nope/retry",
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 404


async def test_retrying_a_page_that_is_still_being_read_is_refused(client, queued):
    """A second job must not race the one that is still running."""
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]
    queued.clear()

    from app.core.progress import write_progress

    await write_progress(record_id, {"status": "in_progress", "message": "Reading..."})

    response = client.post(
        f"/api/jp-reader/records/{record_id}/retry",
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 409
    assert not queued


async def test_retrying_a_page_whose_image_expired_is_404(client, queued):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]
    queued.clear()

    from app.core import jr_store

    await jr_store.delete_record(record_id)

    response = client.post(
        f"/api/jp-reader/records/{record_id}/retry",
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 404
    assert not queued


def test_a_non_image_upload_is_rejected(client):
    response = client.post(
        "/api/jp-reader/upload",
        files={"file": ("notes.txt", b"this is not an image", "text/plain")},
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 400


def test_the_transform_needs_the_password(client):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]

    response = client.post(
        f"/api/jp-reader/records/{record_id}/transform",
        json={"rotation_deg": 90},
    )
    assert response.status_code == 401


def test_a_transform_rotates_the_page_and_queues_it_again(client, queued):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]
    queued.clear()

    response = client.post(
        f"/api/jp-reader/records/{record_id}/transform",
        json={"rotation_deg": 90},
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["revision"] == 2
    assert body["width"] == 40 and body["height"] == 60  # the 60x40 test image
    assert queued and queued[0]["revision"] == 2

    record = client.get(f"/api/jp-reader/records/{record_id}").json()
    assert record["status"] == "pending"
    assert record["transform"]["rotation_deg"] == 90


def test_a_transform_rejects_corners_outside_the_page(client):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]

    response = client.post(
        f"/api/jp-reader/records/{record_id}/transform",
        json={
            "rotation_deg": 0,
            "corners": [[0, 0], [5000, 0], [5000, 5000], [0, 5000]],
        },
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 400


def test_the_region_ocr_queues_a_job(client, queued):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]
    queued.clear()

    response = client.post(
        f"/api/jp-reader/records/{record_id}/regions/ocr",
        json={"box": [0.1, 0.1, 0.6, 0.6]},
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 200
    assert queued and queued[0]["box"] == [0.1, 0.1, 0.6, 0.6]


def test_the_region_ocr_needs_the_password(client):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]

    response = client.post(
        f"/api/jp-reader/records/{record_id}/regions/ocr",
        json={"box": [0.1, 0.1, 0.6, 0.6]},
    )
    assert response.status_code == 401


def test_the_upload_page_and_its_script_are_served(client):
    page = client.get("/jp-reader/")
    assert page.status_code == 200
    assert "JP Reader" in page.text
    assert "/jp-reader/upload.js" in page.text

    script = client.get("/jp-reader/upload.js")
    assert script.status_code == 200
    assert "jp-reader" in script.text


def test_the_detail_page_is_rendered_on_the_server(client):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]

    page = client.get(f"/jp-reader/{record_id}")
    assert page.status_code == 200
    assert "JP Reader" in page.text
    assert "/jp-reader/detail.js" in page.text
    # The record id travels in the page so the script knows what to load.
    assert f'data-record-id="{record_id}"' in page.text
    # The page's structure is on the server, not built in the browser.
    assert "Straighten the page" in page.text
    assert "Select region" in page.text
    assert "jr-canvas" in page.text


def test_a_missing_page_says_so(client):
    page = client.get("/jp-reader/nosuchpage")
    assert page.status_code == 200
    assert "no longer here" in page.text


def test_the_fragment_is_the_page_body(client):
    record_id = client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]

    fragment = client.get(f"/jp-reader/{record_id}/fragment")
    assert fragment.status_code == 200
    assert "Straighten the page" in fragment.text
    assert "jr-canvas" in fragment.text


def test_the_detail_script_is_served(client):
    script = client.get("/jp-reader/detail.js")
    assert script.status_code == 200
    assert "jp-reader" in script.text


def _upload(client) -> str:
    return client.post(
        "/api/jp-reader/upload",
        files={"file": ("page.jpg", _jpeg(), "image/jpeg")},
        headers={"X-App-Password": "secret"},
    ).json()["id"]


def test_a_page_can_be_deleted(client):
    record_id = _upload(client)

    response = client.delete(
        f"/api/jp-reader/records/{record_id}",
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 200

    assert client.get(f"/api/jp-reader/records/{record_id}").status_code == 404
    assert client.get(f"/api/jp-reader/records/{record_id}/image").status_code == 404
    listed = [r["id"] for r in client.get("/api/jp-reader/records").json()]
    assert record_id not in listed


def test_deleting_needs_the_password(client):
    record_id = _upload(client)
    response = client.delete(f"/api/jp-reader/records/{record_id}")
    assert response.status_code == 401
    assert client.get(f"/api/jp-reader/records/{record_id}").status_code == 200


def test_deleting_an_unknown_page_is_404(client):
    response = client.delete(
        "/api/jp-reader/records/nosuchpage",
        headers={"X-App-Password": "secret"},
    )
    assert response.status_code == 404


def test_both_pages_can_ask_before_deleting(client):
    record_id = _upload(client)
    for url in ("/jp-reader/", f"/jp-reader/{record_id}"):
        page = client.get(url)
        assert "jr-delete-modal" in page.text
        assert "/jp-reader/delete.js" in page.text


def test_every_icon_on_a_page_is_in_its_sprite_sheet(client):
    import re

    record_id = _upload(client)
    for url in ("/jp-reader/", f"/jp-reader/{record_id}"):
        page = client.get(url).text
        uses = set(re.findall(r'<use href="#([^"]+)"', page))
        symbols = set(re.findall(r'<symbol id="([^"]+)"', page))
        assert uses, url
        assert uses <= symbols, (url, uses - symbols)
