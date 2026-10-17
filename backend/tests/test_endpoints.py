"""Synthetic contract fixtures only; no rover measurements."""
import io
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from backend.app import create_app

T = "2026-10-17T13:00:00Z"
POSE = {"x": 0, "z": 0, "yaw_deg": 0}
POSITION = {"x": 0, "y": 0, "z": 0}
SAMPLES = {
    "waypoints": {"id": "wpt_sample", "name": "sample kitchen", "pose": POSE, "created_at": T, "media_id": None},
    "routes": {"id": "rte_sample", "name": "sample route", "waypoint_ids": ["wpt_sample"], "kind": "patrol"},
    "objects": {"id": "obj_sample", "label": "backpack", "label_source": "detector", "description": "sample blue bag", "position": POSITION, "height_above_floor_m": 0, "first_seen": T, "last_seen": T, "sightings": 1, "persistence": 0.5, "media_id": None, "history": [{"t": T, "x": 0, "z": 0}]},
    "patrols": {"id": "pat_sample", "started_at": T, "ended_at": None, "route_id": "rte_sample", "path": [{"t": 0, "x": 0, "z": 0}], "event_ids": [], "summary": "Sample patrol", "stats": {"distance_m": 0, "keyframes": 0, "stops": 0}},
    "events": {"id": "evt_sample", "patrol_id": "pat_sample", "type": "appeared", "severity": "warning", "label": "sample bag", "confidence": 0.5, "position": POSITION, "previous_position": None, "near_waypoint": None, "on_route": None, "distance_to_route_m": None, "before_media_id": None, "after_media_id": None, "spoken": "Sample bag appeared", "created_at": T},
}
MAP = {"resolution_m": 0.05, "origin": {"x": 0, "z": 0}, "width": 2, "height": 2, "cells_b64": "AAECAw==", "updated_at": T}
HEARTBEAT = {"t": T, "state": "idle", "task": "", "tracking": "normal", "mapping_status": "mapped", "pose": POSE, "front_cm": 999, "rear_cm": 999, "phone_battery": 0.5, "firmware_link": True}


@pytest.fixture
def app(monkeypatch, tmp_path):
    monkeypatch.setenv("RECALL_TOKEN", "synthetic-test-token")
    monkeypatch.setenv("RECALL_ENV", "development")
    monkeypatch.setenv("RECALL_DB_PATH", str(tmp_path / "recall.db"))
    monkeypatch.setenv("RECALL_MEDIA_DIR", str(tmp_path / "media"))
    return create_app()


@pytest.fixture
def client(app):
    with TestClient(app, headers={"Authorization": "Bearer synthetic-test-token"}) as client:
        yield client


@pytest.mark.parametrize("family", SAMPLES)
def test_family_upsert_and_validation(client, app, family):
    sample = SAMPLES[family]
    url = f'/api/{family}/{sample["id"]}'
    for _ in range(2):
        response = client.put(url, json=sample)
        assert response.status_code == 200, response.text
        assert response.json() == sample
    assert client.get(f"/api/{family}").json() == [sample]
    count = app.state.db.execute("SELECT count(*) FROM records WHERE family=?", (family,)).fetchone()[0]
    assert count == 1
    assert client.put(url, json={}).status_code == 422
    assert client.put(url + "_mismatch", json=sample).status_code == 422
    updated = dict(sample)
    key = "summary" if family == "patrols" else "name" if family in ("waypoints", "routes") else "label"
    updated[key] = "sample updated"
    assert client.put(url, json=updated).json() == updated
    assert client.get(f"/api/{family}").json() == [updated]


def test_no_embeddings_stored(client):
    sample = {**SAMPLES["objects"], "embedding": [0.1]}
    assert client.put("/api/objects/obj_sample", json=sample).status_code == 422
    assert client.get("/api/objects").json() == []


def test_object_filters(client):
    for id, last_seen in [("obj_a", T), ("obj_b", "2026-10-17T14:00:00Z")]:
        sample = {**SAMPLES["objects"], "id": id, "last_seen": last_seen}
        assert client.put(f"/api/objects/{id}", json=sample).status_code == 200
    assert len(client.get("/api/objects?q=BLUE").json()) == 2
    assert client.get("/api/objects?q=absent").json() == []
    assert [item["id"] for item in client.get("/api/objects?limit=1").json()] == ["obj_b"]
    assert [item["id"] for item in client.get("/api/objects", params={"since": T}).json()] == ["obj_b"]
    assert client.get("/api/objects?limit=0").status_code == 422
    assert client.get("/api/objects?since=invalid").status_code == 422


def test_event_filters(client):
    sample = SAMPLES["events"]
    client.put("/api/events/evt_sample", json=sample)
    for key, value in [("severity", "warning"), ("type", "appeared"), ("patrol_id", "pat_sample")]:
        assert client.get("/api/events", params={key: value}).json() == [sample]
    for params in [{"severity": "hazard"}, {"type": "moved"}, {"patrol_id": "absent"}, {"since": T}]:
        assert client.get("/api/events", params=params).json() == []
    assert client.get("/api/events?severity=invalid").status_code == 422
    assert client.get("/api/events?type=invalid").status_code == 422


def test_status_receipt_freshness_and_missing(client, monkeypatch):
    import backend.routes.api as api
    clock = [100.0]
    monkeypatch.setattr(api.time, "time", lambda: clock[0])
    assert client.get("/api/robot/status").status_code == 404
    assert client.post("/api/robot/heartbeat", json=HEARTBEAT).json() == HEARTBEAT
    assert client.get("/api/robot/status").json() == {**HEARTBEAT, "online": True}
    clock[0] = 110
    assert client.get("/api/robot/status").json()["online"] is True
    clock[0] = 110.01
    assert client.get("/api/robot/status").json()["online"] is False
    assert client.post("/api/robot/heartbeat", json={**HEARTBEAT, "state": "wrong"}).status_code == 422


def test_map_latest_and_validation(client, app):
    assert client.get("/api/map").status_code == 404
    for _ in range(2):
        assert client.put("/api/map", json=MAP).json() == MAP
    assert client.get("/api/map").json() == MAP
    assert len(app.state.store.all("map")) == 1
    for invalid in ["!", "AA==", "BAECAw=="]:
        assert client.put("/api/map", json={**MAP, "cells_b64": invalid}).status_code == 422


def jpeg(size=(2, 2), format="JPEG"):
    output = io.BytesIO()
    Image.new("RGB", size, "blue").save(output, format=format)
    return output.getvalue()


def test_jpeg_upload_and_public_download(client):
    data = jpeg()
    for _ in range(2):
        response = client.post("/api/media", data={"id": "med_sample_123"}, files={"file": ("ignored.jpg", data, "image/jpeg")})
        assert response.status_code == 200, response.text
        assert response.json() == {"id": "med_sample_123"}
    assert client.get("/media/med_sample_123.jpg", headers={"Authorization": ""}).content == data
    assert client.get("/media/missing.jpg").status_code == 404


@pytest.mark.parametrize("id,data,mime", [
    ("../escape_123", b"sample", "image/jpeg"),
    ("short", b"sample", "image/jpeg"),
    ("med_sample_123", b"x" * (500 * 1024 + 1), "image/jpeg"),
    ("med_sample_123", b"not jpeg", "image/jpeg"),
    ("med_sample_123", jpeg(), "image/png"),
    ("med_sample_123", jpeg(format="PNG"), "image/jpeg"),
    ("med_sample_123", jpeg()[:100], "image/jpeg"),
    ("med_sample_123", jpeg((321, 1)), "image/jpeg"),
])
def test_bad_media_rejected(client, id, data, mime):
    response = client.post("/api/media", data={"id": id}, files={"file": ("test.jpg", data, mime)})
    assert response.status_code == 422
    assert "detail" in response.json()


def test_persistence_across_lifecycles(app):
    headers = {"Authorization": "Bearer synthetic-test-token"}
    with TestClient(app, headers=headers) as client:
        client.put("/api/waypoints/wpt_sample", json=SAMPLES["waypoints"])
        client.put("/api/map", json=MAP)
        client.post("/api/robot/heartbeat", json=HEARTBEAT)
    with TestClient(app, headers=headers) as client:
        assert client.get("/api/waypoints").json() == [SAMPLES["waypoints"]]
        assert client.get("/api/map").json() == MAP
        assert client.get("/api/robot/status").json()["state"] == "idle"


def test_concurrent_upserts_remain_single_row(client, app):
    sample = SAMPLES["waypoints"]
    def put(_):
        return client.put("/api/waypoints/wpt_sample", json=sample).status_code
    with ThreadPoolExecutor(max_workers=4) as pool:
        assert list(pool.map(put, range(12))) == [200] * 12
    assert app.state.store.all("waypoints") == [sample]
