import sqlite3

import pytest
from fastapi.testclient import TestClient

from backend.app import create_app


@pytest.fixture
def configured(monkeypatch, tmp_path):
    monkeypatch.setenv("RECALL_TOKEN", "test-only-token")
    monkeypatch.setenv("RECALL_ENV", "development")
    monkeypatch.setenv("RECALL_DB_PATH", str(tmp_path / "data" / "recall.db"))
    monkeypatch.setenv("RECALL_MEDIA_DIR", str(tmp_path / "media"))
    return tmp_path


def test_health_and_sqlite_lifecycle(configured):
    app = create_app()
    with TestClient(app) as client:
        response = client.get("/api/health")
        assert response.status_code == 200
        assert response.json() == {"ok": True, "schema_version": 1}
        connection = app.state.db
        assert connection.execute("PRAGMA foreign_keys").fetchone()[0] == 1
    with pytest.raises(sqlite3.ProgrammingError):
        connection.execute("SELECT 1")


@pytest.mark.parametrize("path", ["/api", "/api/objects", "/api/not-yet-implemented", "/api/health/"])
@pytest.mark.parametrize("authorization", [None, "Bearer wrong", "Basic test-only-token", "Bearer "])
def test_api_requires_valid_token(configured, path, authorization):
    with TestClient(create_app()) as client:
        response = client.get(path, headers={"Authorization": authorization} if authorization is not None else {})
        assert response.status_code == 401
        assert response.headers["www-authenticate"] == "Bearer"


def test_valid_token_passes_auth_and_health_post_is_protected(configured):
    with TestClient(create_app()) as client:
        assert client.get("/api/objects", headers={"Authorization": "Bearer test-only-token"}).status_code == 200
        assert client.post("/api/health").status_code == 401


@pytest.mark.parametrize("token", [None, ""])
def test_unconfigured_token_fails_closed(configured, monkeypatch, token):
    if token is None:
        monkeypatch.delenv("RECALL_TOKEN")
    else:
        monkeypatch.setenv("RECALL_TOKEN", token)
    with TestClient(create_app()) as client:
        assert client.get("/api/objects", headers={"Authorization": "Bearer "}).status_code == 401
        assert client.get("/api/health").status_code == 200


def test_public_media(configured):
    with TestClient(create_app()) as client:
        (configured / "media" / "sample-id.jpg").write_bytes(b"sample fixture")
        assert client.get("/media/sample-id.jpg").content == b"sample fixture"
        assert client.get("/media/missing.jpg").status_code == 404


def test_development_preflight(configured):
    with TestClient(create_app()) as client:
        response = client.options("/api/objects", headers={"Origin": "https://example.test", "Access-Control-Request-Method": "PUT", "Access-Control-Request-Headers": "authorization,content-type"})
        assert response.status_code == 200
        assert response.headers["access-control-allow-origin"] == "*"


def test_production_cors(configured, monkeypatch):
    monkeypatch.setenv("RECALL_ENV", "production")
    monkeypatch.setenv("RECALL_CORS_ORIGINS", "https://dashboard.example.test")
    with TestClient(create_app()) as client:
        allowed = client.get("/api/health", headers={"Origin": "https://dashboard.example.test"})
        denied = client.get("/api/health", headers={"Origin": "https://other.example.test"})
        assert allowed.headers["access-control-allow-origin"] == "https://dashboard.example.test"
        assert "access-control-allow-origin" not in denied.headers


@pytest.mark.parametrize("origins", ["", "*"])
def test_production_requires_explicit_origins(configured, monkeypatch, origins):
    monkeypatch.setenv("RECALL_ENV", "production")
    monkeypatch.setenv("RECALL_CORS_ORIGINS", origins)
    with pytest.raises(ValueError, match="explicit RECALL_CORS_ORIGINS"):
        create_app()
