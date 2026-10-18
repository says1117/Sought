"""Remote command queue: Sought posts text, the robot claims and acks it."""
import pytest
from fastapi.testclient import TestClient

from backend.tests.test_endpoints import HEARTBEAT, app, client  # noqa: F401 (fixtures)


def test_create_next_ack_flow(client, app):
    queue = app.state.broker.subscribe()
    created = client.post("/api/commands", json={"text": "find my keys"})
    assert created.status_code == 200, created.text
    command = created.json()
    assert command["id"].startswith("cmd_") and command["status"] == "queued" and command["result"] is None
    assert command["created_at"].endswith("Z")
    assert queue.get_nowait() == ("command", command)
    second = client.post("/api/commands", json={"id": "cmd_client2", "text": "come to me"}).json()
    assert second["id"] == "cmd_client2"
    queue.get_nowait()

    claimed = client.get("/api/commands/next")
    assert claimed.status_code == 200
    assert claimed.json() == {**command, "status": "running"}
    assert queue.get_nowait() == ("command", claimed.json())
    assert client.get("/api/commands/next").json()["id"] == "cmd_client2"
    queue.get_nowait()
    assert client.get("/api/commands/next").status_code == 204

    running = client.post(f"/api/commands/{command['id']}/ack", json={"status": "running", "result": None})
    assert running.status_code == 200
    queue.get_nowait()
    done = client.post(f"/api/commands/{command['id']}/ack", json={"status": "done", "result": "Your keys are on the desk."})
    assert done.json() == {**command, "status": "done", "result": "Your keys are on the desk."}
    assert queue.get_nowait() == ("command", done.json())
    # A retried identical final ack is fine; changing a finished command is not.
    assert client.post(f"/api/commands/{command['id']}/ack", json={"status": "done", "result": "Your keys are on the desk."}).status_code == 200
    assert client.post(f"/api/commands/{command['id']}/ack", json={"status": "failed", "result": "x"}).status_code == 409
    assert queue.empty()

    assert client.get(f"/api/commands/{command['id']}").json() == done.json()
    assert client.get("/api/commands/cmd_missing").status_code == 404
    listed = client.get("/api/commands").json()
    assert [item["id"] for item in listed] == ["cmd_client2", command["id"]]
    assert [item["id"] for item in client.get("/api/commands?limit=1").json()] == ["cmd_client2"]


def test_next_empty_is_204(client):
    response = client.get("/api/commands/next")
    assert response.status_code == 204 and response.content == b""
    assert client.get("/api/commands").json() == []


def test_next_is_oldest_first_and_claimed_once(client):
    ids = [client.post("/api/commands", json={"id": f"cmd_{n}", "text": f"find thing {n}"}).json()["id"] for n in range(3)]
    claimed = [client.get("/api/commands/next").json()["id"] for _ in ids]
    assert claimed == ids
    assert client.get("/api/commands/next").status_code == 204


def test_client_id_retry_is_idempotent(client):
    first = client.post("/api/commands", json={"id": "cmd_retry", "text": "find my keys"}).json()
    assert client.post("/api/commands", json={"id": "cmd_retry", "text": "find my keys"}).json() == first
    assert client.post("/api/commands", json={"id": "cmd_retry", "text": "other"}).status_code == 409
    assert len(client.get("/api/commands").json()) == 1


@pytest.mark.parametrize("method,path,body", [
    ("post", "/api/commands", {"text": "find my keys"}),
    ("get", "/api/commands/next", None),
    ("post", "/api/commands/cmd_x/ack", {"status": "done", "result": None}),
    ("get", "/api/commands/cmd_x", None),
    ("get", "/api/commands", None),
])
def test_auth_required(app, method, path, body):
    with TestClient(app) as anonymous:
        kwargs = {"json": body} if body is not None else {}
        assert getattr(anonymous, method)(path, **kwargs).status_code == 401
        assert getattr(anonymous, method)(path, headers={"Authorization": "Bearer wrong"}, **kwargs).status_code == 401


def test_validation(client):
    assert client.post("/api/commands", json={"text": ""}).status_code == 422
    assert client.post("/api/commands", json={"text": "x" * 201}).status_code == 422
    assert client.post("/api/commands", json={"text": "x" * 200}).status_code == 200
    assert client.post("/api/commands", json={"text": "ok", "status": "done"}).status_code == 422
    assert client.post("/api/commands", json={"id": "bad id!", "text": "ok"}).status_code == 422
    command = client.post("/api/commands", json={"text": "find my keys"}).json()
    ack = f"/api/commands/{command['id']}/ack"
    for status in ("queued", "finished", "", None):
        assert client.post(ack, json={"status": status, "result": None}).status_code == 422
    assert client.post(ack, json={"status": "done", "result": "x" * 501}).status_code == 422
    assert client.post("/api/commands/cmd_missing/ack", json={"status": "done", "result": None}).status_code == 404
    assert client.get("/api/commands?limit=0").status_code == 422


@pytest.mark.parametrize("state", ["exploring", "coming_to_user"])
def test_heartbeat_accepts_new_states(client, state):
    assert client.post("/api/robot/heartbeat", json={**HEARTBEAT, "state": state}).status_code == 200
    assert client.get("/api/robot/status").json()["state"] == state
