"""Authenticated phone sync endpoints; all persistence is independent of clients."""
import io
import json
import os
import re
import tempfile
import time
import warnings
from datetime import datetime
from typing import Annotated

from fastapi.responses import StreamingResponse
from fastapi import APIRouter, File, Form, HTTPException, Query, Request, UploadFile
from PIL import Image, UnidentifiedImageError
from pydantic import AwareDatetime

from backend.models import ChangeEvent, EventType, Heartbeat, MapSnapshot, ObjectTrack, Patrol, Route, Severity, Waypoint

router = APIRouter(prefix="/api")
MAX_MEDIA_BYTES = 500 * 1024


def store(request: Request):
    return request.app.state.store


async def save(request: Request, family: str, id: str, payload):
    if id != payload.id:
        raise HTTPException(422, "URL id must match body id")
    body = store(request).put(family, id, payload.model_dump(mode="json"))
    event = {"objects": "object", "events": "event", "patrols": "patrol"}.get(family)
    if event:
        request.app.state.broker.publish(event, body)
    return body


def newer(value: str, since: datetime | None):
    return since is None or datetime.fromisoformat(value.replace("Z", "+00:00")) > since


@router.post("/robot/heartbeat", response_model=Heartbeat)
async def heartbeat(payload: Heartbeat, request: Request):
    body = store(request).put("heartbeat", "latest", payload.model_dump(mode="json"), time.time())
    request.app.state.broker.publish("heartbeat", body)
    return body


@router.get("/robot/status")
def robot_status(request: Request):
    record = store(request).get("heartbeat", "latest")
    if record is None:
        raise HTTPException(404, "No heartbeat received")
    body, received_at = record
    return {**body, "online": 0 <= time.time() - received_at <= 10}


@router.put("/waypoints/{id}", response_model=Waypoint)
async def put_waypoint(id: str, payload: Waypoint, request: Request):
    return await save(request, "waypoints", id, payload)


@router.get("/waypoints", response_model=list[Waypoint])
def waypoints(request: Request):
    return store(request).all("waypoints")


@router.put("/routes/{id}", response_model=Route)
async def put_route(id: str, payload: Route, request: Request):
    return await save(request, "routes", id, payload)


@router.get("/routes", response_model=list[Route])
def routes(request: Request):
    return store(request).all("routes")


@router.put("/objects/{id}", response_model=ObjectTrack)
async def put_object(id: str, payload: ObjectTrack, request: Request):
    return await save(request, "objects", id, payload)


@router.get("/objects", response_model=list[ObjectTrack])
def objects(request: Request, q: str = "", limit: Annotated[int | None, Query(ge=1)] = None, since: AwareDatetime | None = None):
    matches = [item for item in store(request).all("objects") if newer(item["last_seen"], since) and q.casefold() in (item["label"] + " " + item["description"]).casefold()]
    matches.sort(key=lambda item: datetime.fromisoformat(item["last_seen"].replace("Z", "+00:00")), reverse=True)
    return matches[:limit]


@router.put("/patrols/{id}", response_model=Patrol)
async def put_patrol(id: str, payload: Patrol, request: Request):
    return await save(request, "patrols", id, payload)


@router.get("/patrols", response_model=list[Patrol])
def patrols(request: Request):
    return store(request).all("patrols")


@router.put("/events/{id}", response_model=ChangeEvent)
async def put_event(id: str, payload: ChangeEvent, request: Request):
    return await save(request, "events", id, payload)


@router.get("/events", response_model=list[ChangeEvent])
def events(request: Request, since: AwareDatetime | None = None, severity: Severity | None = None, type: EventType | None = None, patrol_id: str | None = None):
    return [item for item in store(request).all("events") if newer(item["created_at"], since) and (severity is None or item["severity"] == severity) and (type is None or item["type"] == type) and (patrol_id is None or item["patrol_id"] == patrol_id)]


@router.put("/map", response_model=MapSnapshot)
def put_map(payload: MapSnapshot, request: Request):
    return store(request).put("map", "latest", payload.model_dump(mode="json"))


@router.get("/map", response_model=MapSnapshot)
def get_map(request: Request):
    record = store(request).get("map", "latest")
    if record is None:
        raise HTTPException(404, "No map received")
    return record[0]


@router.post("/media")
async def upload_media(request: Request, id: Annotated[str, Form()], file: Annotated[UploadFile, File()]):
    # Callers must generate opaque random ids; length alone cannot prove entropy.
    if not re.fullmatch(r"[A-Za-z0-9_-]{10,128}", id):
        raise HTTPException(422, "Media id must be an opaque path-safe id of 10..128 characters")
    if file.content_type != "image/jpeg":
        raise HTTPException(422, "Media must be image/jpeg")
    data = await file.read(MAX_MEDIA_BYTES + 1)
    await file.close()
    if len(data) > MAX_MEDIA_BYTES:
        raise HTTPException(422, "JPEG exceeds 500 KiB")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as image:
                if image.format != "JPEG" or max(image.size) > 320:
                    raise ValueError("Media must be JPEG with longest side at most 320 px")
                image.verify()
            # verify() does not decode JPEG pixels; load() detects truncated scans.
            with Image.open(io.BytesIO(data)) as image:
                image.load()
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError, Image.DecompressionBombWarning) as error:
        raise HTTPException(422, "Invalid JPEG or image exceeds 320 px") from error
    directory = request.app.state.media_dir
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as output:
            temporary = output.name
            output.write(data)
        os.replace(temporary, directory / f"{id}.jpg")
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    return {"id": id}


@router.get("/stream")
async def stream(request: Request):
    broker = request.app.state.broker
    queue = broker.subscribe()
    return StreamingResponse(broker.messages(queue), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@router.get("/evals")
def evals(request: Request):
    try:
        return json.loads(request.app.state.evals_path.read_text())
    except FileNotFoundError:
        return {}
    except (ValueError, OSError):
        raise HTTPException(503, "Evaluation results unavailable")


@router.get("/metadata")
def metadata(request: Request):
    return {"mock": store(request).get("metadata", "mock") is not None}
