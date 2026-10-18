"""Validated phone/backend contract models. Embeddings never enter storage."""
import base64
import binascii
from typing import Annotated, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator

Id = Annotated[str, Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")]
Probability = Annotated[float, Field(ge=0, le=1)]
Severity = Literal["info", "warning", "hazard"]
CommandStatus = Literal["queued", "running", "done", "failed"]
EventType = Literal["appeared", "disappeared", "moved", "new_obstacle", "path_blocked", "door_changed"]


class ContractModel(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)


class HealthResponse(ContractModel):
    ok: Literal[True] = True
    schema_version: Literal[1] = 1


class Pose(ContractModel):
    x: float
    z: float
    yaw_deg: float


class Position(ContractModel):
    x: float
    y: float
    z: float


class Heartbeat(ContractModel):
    t: AwareDatetime
    state: Literal["idle", "teaching", "finding", "patrolling", "checking_route", "blocked", "error", "exploring", "coming_to_user"]
    task: str
    tracking: Literal["normal", "limited", "not_available"]
    mapping_status: Literal["mapped", "limited", "extending", "not_available"]
    pose: Pose
    front_cm: Annotated[float, Field(ge=0)]
    rear_cm: Annotated[float, Field(ge=0)]
    phone_battery: Probability
    firmware_link: bool


class Waypoint(ContractModel):
    id: Id
    name: str
    pose: Pose
    created_at: AwareDatetime
    media_id: Id | None


class Route(ContractModel):
    id: Id
    name: str
    waypoint_ids: list[Id]
    kind: Literal["patrol", "user_path"]


class Sighting(ContractModel):
    t: AwareDatetime
    x: float
    z: float


class ObjectTrack(ContractModel):
    id: Id
    label: str
    label_source: Literal["detector", "user", "none"]
    description: str
    position: Position
    height_above_floor_m: float
    first_seen: AwareDatetime
    last_seen: AwareDatetime
    sightings: Annotated[int, Field(ge=0)]
    persistence: Probability
    media_id: Id | None
    history: list[Sighting]


class ChangeEvent(ContractModel):
    id: Id
    patrol_id: Id | None
    type: EventType
    severity: Severity
    label: str
    confidence: Probability
    position: Position
    previous_position: Position | None
    near_waypoint: str | None
    on_route: Id | None
    distance_to_route_m: Annotated[float, Field(ge=0)] | None
    before_media_id: Id | None
    after_media_id: Id | None
    spoken: str
    created_at: AwareDatetime


class PathPoint(ContractModel):
    t: Annotated[float, Field(ge=0)]
    x: float
    z: float


class PatrolStats(ContractModel):
    distance_m: Annotated[float, Field(ge=0)]
    keyframes: Annotated[int, Field(ge=0)]
    stops: Annotated[int, Field(ge=0)]


class Patrol(ContractModel):
    id: Id
    started_at: AwareDatetime
    ended_at: AwareDatetime | None
    route_id: Id
    path: list[PathPoint]
    event_ids: list[Id]
    summary: str
    stats: PatrolStats

    @model_validator(mode="after")
    def validate_path_sampling(self):
        if any(b.t - a.t < 1 for a, b in zip(self.path, self.path[1:])):
            raise ValueError("Patrol path must be ordered and sampled at most once per second")
        return self


class MapOrigin(ContractModel):
    x: float
    z: float


class MapSnapshot(ContractModel):
    resolution_m: Annotated[float, Field(gt=0)]
    origin: MapOrigin
    width: Annotated[int, Field(gt=0)]
    height: Annotated[int, Field(gt=0)]
    cells_b64: str
    updated_at: AwareDatetime

    @model_validator(mode="after")
    def validate_cells(self):
        try:
            cells = base64.b64decode(self.cells_b64, validate=True)
        except (ValueError, binascii.Error) as error:
            raise ValueError("cells_b64 must contain valid base64") from error
        if len(cells) != self.width * self.height or any(cell > 3 for cell in cells):
            raise ValueError("Map cells must match width*height and use values 0..3")
        return self


class CommandCreate(ContractModel):
    """Client may supply its own id (idempotent retries); the server fills the rest."""
    id: Id | None = None
    text: Annotated[str, Field(min_length=1, max_length=200)]


class Command(ContractModel):
    id: Id
    text: str
    created_at: AwareDatetime
    status: CommandStatus
    result: str | None


class CommandAck(ContractModel):
    status: Literal["running", "done", "failed"]
    result: Annotated[str, Field(max_length=500)] | None = None
