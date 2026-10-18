"""Authenticated, process-local latest camera frame. Nothing is archived."""
import time

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response
from backend.camera_frame import MAX_FRAME_BYTES, is_stale, validate_frame
router = APIRouter(prefix="/api/camera")


@router.put("/frame", status_code=204)
async def put_frame(request: Request):
    if request.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "image/jpeg":
        raise HTTPException(422, "Camera frame must be image/jpeg")
    data = bytearray()
    async for chunk in request.stream():
        if len(chunk) > MAX_FRAME_BYTES - len(data):
            raise HTTPException(413, "Camera frame exceeds 512 KiB")
        data.extend(chunk)
    received_at = time.monotonic()
    try:
        validate_frame(data)
    except ValueError as error:
        raise HTTPException(422, "Invalid camera JPEG or image exceeds 640 pixels") from error
    request.app.state.camera_frame.put(bytes(data), received_at)
    return Response(status_code=204, headers={"Cache-Control": "no-store"})


@router.get("/frame")
def get_frame(request: Request):
    frame = request.app.state.camera_frame.get(time.monotonic())
    headers = {"Cache-Control": "no-store"}
    if frame is None:
        raise HTTPException(404, "No camera frame received", headers=headers)
    data, age = frame
    headers["X-Frame-Age-Ms"] = str(int(age * 1000))
    if is_stale(age):
        raise HTTPException(410, "Camera frame is stale", headers=headers)
    return Response(content=data, media_type="image/jpeg", headers=headers)
