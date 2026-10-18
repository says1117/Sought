"""FastAPI entry point: python -m uvicorn backend.app:app."""
import os
import secrets
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.staticfiles import StaticFiles

from backend.stream import Broker
from backend.db import Store, connect
from backend.routes.api import router
from backend.models import HealthResponse
from backend.camera import router as camera_router
from backend.camera_frame import LatestFrame


def create_app() -> FastAPI:
    """Read configuration at construction so tests/deployments can isolate state."""
    token = os.environ.get("RECALL_TOKEN", "")
    environment = os.environ.get("RECALL_ENV", "development")
    if environment not in {"development", "production"}:
        raise ValueError("RECALL_ENV must be development or production")
    origins = [origin.strip() for origin in os.environ.get("RECALL_CORS_ORIGINS", "").split(",") if origin.strip()]
    if environment == "production" and (not origins or "*" in origins):
        raise ValueError("Production requires explicit RECALL_CORS_ORIGINS")
    media_dir = Path(os.environ.get("RECALL_MEDIA_DIR", "backend/media"))
    database_path = os.environ.get("RECALL_DB_PATH", "backend/data/recall.sqlite3")

    @asynccontextmanager
    async def lifespan(application: FastAPI):
        media_dir.mkdir(parents=True, exist_ok=True)
        application.state.db = connect(database_path)
        application.state.store = Store(application.state.db)
        application.state.media_dir = media_dir
        application.state.broker = Broker()
        application.state.camera_frame = LatestFrame()
        application.state.evals_path = Path(os.environ.get("RECALL_EVALS_PATH", "evals/results.json"))
        try:
            yield
        finally:
            application.state.db.close()

    application = FastAPI(title="Recall", version="1", lifespan=lifespan)

    @application.middleware("http")
    async def authenticate_api(request: Request, call_next):
        path = request.url.path
        protected = path == "/api" or path.startswith("/api/")
        public_health = path == "/api/health" and request.method == "GET"
        if protected and not public_health:
            authorization = request.headers.get("authorization", "")
            supplied = authorization[7:] if authorization[:7].lower() == "bearer " else ""
            if not token or not secrets.compare_digest(supplied.encode(), token.encode()):
                return JSONResponse({"detail": "Unauthorized"}, status_code=401, headers={"WWW-Authenticate": "Bearer"})
        return await call_next(request)

    # Added last so browser preflight requests are handled before authentication.
    application.add_middleware(
        CORSMiddleware,
        allow_origins=["*"] if environment == "development" else origins,
        allow_methods=["*"],
        allow_headers=["Authorization", "Content-Type"],
        expose_headers=["X-Frame-Age-Ms"],
    )

    @application.get("/api/health", response_model=HealthResponse)
    def health() -> HealthResponse:
        return HealthResponse()

    application.include_router(router)
    application.include_router(camera_router)

    # StaticFiles rejects traversal; missing files return 404 without API auth.
    application.mount("/media", StaticFiles(directory=media_dir, check_dir=False), name="media")
    return application


app = create_app()
