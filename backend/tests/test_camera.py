"""Synthetic camera frames only; no device or network camera access."""
import asyncio
import io
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from PIL import Image

from backend import camera
from backend.app import create_app
from backend.tests.test_endpoints import app, client  # noqa: F401 (fixtures)

PATH = "/api/camera/frame"


def jpeg(size=(640, 480), color="red", format="JPEG"):
    output = io.BytesIO()
    Image.new("RGB", size, color).save(output, format=format)
    return output.getvalue()


def upload(client, data):
    return client.put(PATH, content=data, headers={"Content-Type": "image/jpeg"})


@pytest.mark.parametrize("method", ["get", "put"])
def test_camera_requires_auth(app, method):
    with TestClient(app) as anonymous:
        for headers in [{}, {"Authorization": "Bearer wrong"}]:
            assert getattr(anonymous, method)(PATH, headers=headers).status_code == 401


def test_latest_only_and_no_public_media(client, app):
    first, second = jpeg(), jpeg(color="blue")
    missing = client.get(PATH)
    assert missing.status_code == 404
    assert missing.headers["cache-control"] == "no-store"
    assert upload(client, first).status_code == 204
    response = client.get(PATH)
    assert response.content == first
    assert response.headers["content-type"] == "image/jpeg"
    assert response.headers["cache-control"] == "no-store"
    assert int(response.headers["x-frame-age-ms"]) >= 0
    assert upload(client, second).status_code == 204
    assert client.get(PATH).content == second
    assert list(app.state.media_dir.iterdir()) == []
    assert app.state.store.all("camera") == []


def test_frame_receipt_age_and_stale_boundary(client, monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(camera, "time", SimpleNamespace(monotonic=lambda: clock[0]))
    assert upload(client, jpeg()).status_code == 204
    clock[0] = 105.0
    fresh = client.get(PATH)
    assert fresh.status_code == 200
    assert fresh.headers["x-frame-age-ms"] == "5000"
    clock[0] = 105.001
    stale = client.get(PATH)
    assert stale.status_code == 410
    assert stale.headers["cache-control"] == "no-store"
    assert int(stale.headers["x-frame-age-ms"]) >= 5000
    assert upload(client, jpeg(color="blue")).status_code == 204
    assert client.get(PATH).headers["x-frame-age-ms"] == "0"


@pytest.mark.parametrize("data", [b"", b"not a jpeg", jpeg(format="PNG"), jpeg()[:-100],
                                  jpeg(size=(641, 10)), jpeg(size=(10, 641))])
def test_invalid_upload_preserves_latest(client, data):
    original = jpeg()
    assert upload(client, original).status_code == 204
    assert upload(client, data).status_code == 422
    assert client.get(PATH).content == original


def test_camera_rejects_wrong_content_type_and_oversize(client):
    assert client.put(PATH, content=jpeg(), headers={"Content-Type": "application/octet-stream"}).status_code == 422
    assert upload(client, b"x" * (camera.MAX_FRAME_BYTES + 1)).status_code == 413
    assert client.get(PATH).status_code == 404


def test_byte_limit_accepts_exact_limit(client):
    data = jpeg()
    # JPEG permits trailing bytes; size validation is independent of successful decode.
    padded = data + b"\0" * (camera.MAX_FRAME_BYTES - len(data))
    assert upload(client, padded).status_code == 204
    assert client.get(PATH).content == padded


def test_stream_stops_reading_as_soon_as_limit_is_crossed():
    consumed = []

    async def chunks():
        for index in range(4):
            consumed.append(index)
            yield b"x" * (256 * 1024)

    request = SimpleNamespace(headers={"content-type": "image/jpeg"}, stream=chunks)
    with pytest.raises(HTTPException) as failure:
        asyncio.run(camera.put_frame(request))
    assert failure.value.status_code == 413
    assert consumed == [0, 1, 2]


def test_camera_rejects_decompression_bomb_warning(client, monkeypatch):
    data = jpeg(size=(20, 20))
    monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", 300)
    assert upload(client, data).status_code == 422
    assert client.get(PATH).status_code == 404


def test_frame_state_is_per_app(client):
    assert upload(client, jpeg()).status_code == 204
    with TestClient(create_app(), headers={"Authorization": "Bearer synthetic-test-token"}) as other:
        assert other.get(PATH).status_code == 404
        assert upload(other, jpeg(color="blue")).status_code == 204
    assert client.get(PATH).content == jpeg()
