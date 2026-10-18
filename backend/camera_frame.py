"""Framework-independent validation and bounded latest-frame storage."""
import io
import warnings
from threading import Lock

from PIL import Image, UnidentifiedImageError

MAX_FRAME_BYTES = 512 * 1024
MAX_FRAME_SIDE = 640
MAX_FRAME_AGE_SECONDS = 5.0


def validate_frame(data: bytes):
    if len(data) > MAX_FRAME_BYTES:
        raise ValueError("Camera frame exceeds 512 KiB")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as image:
                if image.format != "JPEG" or max(image.size) > MAX_FRAME_SIDE:
                    raise ValueError("Camera frame must be JPEG with longest side at most 640 pixels")
                image.verify()
            with Image.open(io.BytesIO(data)) as image:
                image.load()
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError,
            Image.DecompressionBombWarning) as error:
        raise ValueError("Invalid camera JPEG or image exceeds 640 pixels") from error


class LatestFrame:
    def __init__(self):
        self._lock = Lock()
        self._frame = None

    def put(self, data: bytes, received_at: float):
        with self._lock:
            self._frame = (data, received_at)

    def get(self, now: float):
        with self._lock:
            if self._frame is None:
                return None
            data, received_at = self._frame
            return data, max(0.0, now - received_at)


def is_stale(age_seconds: float) -> bool:
    return age_seconds > MAX_FRAME_AGE_SECONDS
