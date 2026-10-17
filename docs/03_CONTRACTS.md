# Contracts v1 (source of truth for interfaces)

`schema_version: 1`. Any change to this file is made in a single commit that both leads sign off on. If you need a new field, add it as optional first.

## 0. Conventions

- **Units:** meters, seconds, degrees only where stated. Timestamps are ISO 8601 UTC strings (`2026-10-17T14:03:22Z`) in JSON, integer milliseconds in BLE.
- **IDs:** client-generated, prefixed, URL-safe: `obj_`, `wpt_`, `evt_`, `pat_`, `med_`, `cmd_`. Use `<prefix>_<10 random base32 chars>`. Backend writes are **idempotent upserts by id**.
- **World frame (ARKit):** meters, right-handed, **y up**. Robot forward is `-z` of the camera transform. For the dashboard top-down map: plot **x to the right and z downward on screen**, so forward-from-origin points up the screen. Origin is the phone pose when the Teach session started (the `home` waypoint).
- **Yaw:** degrees, counter-clockwise when viewed from above is positive. 0 deg points to -z.
- **Robot turn convention (BLE):** `angular > 0` turns left (counter-clockwise). `L = linear - angular`, `R = linear + angular`.

## 1. BLE link (phone to ESP32)

Peripheral name: `Navigator`.

| Item | UUID |
|---|---|
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| RX characteristic (phone writes, write and write-without-response) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| TX characteristic (ESP32 notifies) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |

### Commands (phone to ESP32), ASCII, newline terminated

| Command | Meaning |
|---|---|
| `L,R\n` | Wheel speeds, integers `-255..255`. Left side motors = channel A, right side = channel B. Must be resent at least every 100 ms |
| `STOP\n` | Immediate brake and zero |
| `PING\n` | Reply `PONG\n` on TX |

### Status (ESP32 to phone), 5 Hz, newline terminated

```
T,<uptime_ms>,<L>,<R>,<front_cm>,<rear_cm>,<flags>\n
```

- `L`, `R`: the speeds actually being applied after safety rules and ramping.
- `front_cm`, `rear_cm`: integer cm, `999` means no echo or out of range.
- `flags`: bit field. `1` = watchdog stopped, `2` = front blocked, `4` = rear blocked, `8` = BLE connected.

### Safety rules enforced on the ESP32 (never trust the phone)

- No valid command for **300 ms**: brake and zero, set watchdog flag. Resume on the next valid command.
- `linear = (L+R)/2`, `angular = (R-L)/2`. Front distance below **20 cm**: `linear = min(linear, 0)`. Rear below **15 cm**: `linear = max(linear, 0)`. Recompute L and R, clamp to +-255.
- BLE disconnect: brake and zero, restart advertising.
- Speed cap in firmware `MAX_PWM = 200` for the demo (adjustable constant).

## 2. Phone to backend (REST over HTTPS)

Base URL is a config value (`Secrets.xcconfig`, gitignored). Auth: header `Authorization: Bearer <RECALL_TOKEN>`. All bodies JSON except media. CORS open in dev.

The phone queues writes (SQLite `sync_queue`) and retries with backoff. The robot never blocks on the network.

| Method and path | Purpose |
|---|---|
| `GET /api/health` | `{ "ok": true, "schema_version": 1 }` |
| `POST /api/robot/heartbeat` | Robot status, every 2 s while online |
| `GET /api/robot/status` | Latest heartbeat plus `online` (seen within 10 s) |
| `PUT /api/waypoints/{id}` , `GET /api/waypoints` | Taught waypoints |
| `PUT /api/routes/{id}` , `GET /api/routes` | Named routes (ordered waypoint ids) |
| `PUT /api/objects/{id}` , `GET /api/objects?q=&limit=&since=` | Object tracks |
| `PUT /api/patrols/{id}` , `GET /api/patrols` | Patrol runs |
| `PUT /api/events/{id}` , `GET /api/events?since=&severity=&type=&patrol_id=` | Change events |
| `POST /api/media` (multipart `file`, field `id`) , `GET /media/{id}.jpg` | Thumbnails |
| `PUT /api/map` , `GET /api/map` | Latest occupancy snapshot |
| `GET /api/stream` | Server-sent events: `heartbeat`, `event`, `object`, `patrol`, `command` |
| `GET /api/evals` | Serves aggregated `evals/results.json` |
| (stretch) `POST /api/commands` , `GET /api/commands/next` , `POST /api/commands/{id}/ack` | Remote tasking. Phone polls `next` every 2 s |

Responses: `200` with the stored object for PUT/POST, `404` for missing, `422` for validation errors with `{ "detail": ... }`.

### 2.1 Heartbeat

```json
{
  "t": "2026-10-17T14:03:22Z",
  "state": "idle | teaching | finding | patrolling | checking_route | blocked | error",
  "task": "find: blue backpack",
  "tracking": "normal | limited | not_available",
  "mapping_status": "mapped | limited | extending | not_available",
  "pose": { "x": 1.20, "z": -3.40, "yaw_deg": 92.5 },
  "front_cm": 87,
  "rear_cm": 999,
  "phone_battery": 0.62,
  "firmware_link": true
}
```

### 2.2 Waypoint

```json
{
  "id": "wpt_k3m9q2x7ab",
  "name": "kitchen",
  "pose": { "x": 2.1, "z": -4.8, "yaw_deg": 180.0 },
  "created_at": "2026-10-17T13:01:00Z",
  "media_id": "med_f8d2c1z9ab"
}
```

### 2.3 Route

```json
{ "id": "rte_bathroom01", "name": "bathroom route", "waypoint_ids": ["wpt_home", "wpt_hall", "wpt_bath"], "kind": "patrol | user_path" }
```

### 2.4 Object track

Embeddings **stay on the phone** and are not part of this contract.

```json
{
  "id": "obj_5t8h2k9m1c",
  "label": "backpack",
  "label_source": "detector | user | none",
  "description": "blue backpack with a white zipper",
  "position": { "x": 0.8, "y": 0.0, "z": -2.9 },
  "height_above_floor_m": 0.0,
  "first_seen": "2026-10-17T13:05:00Z",
  "last_seen": "2026-10-17T14:02:10Z",
  "sightings": 7,
  "persistence": 0.86,
  "media_id": "med_1q2w3e4r5t",
  "history": [ { "t": "2026-10-17T13:05:00Z", "x": 0.8, "z": -2.9 } ]
}
```

### 2.5 Change event

```json
{
  "id": "evt_p0o9i8u7y6",
  "patrol_id": "pat_a1b2c3d4e5",
  "type": "appeared | disappeared | moved | new_obstacle | path_blocked | door_changed",
  "severity": "info | warning | hazard",
  "label": "cardboard box",
  "confidence": 0.82,
  "position": { "x": 1.2, "y": 0.0, "z": -3.4 },
  "previous_position": null,
  "near_waypoint": "hallway",
  "on_route": "rte_bathroom01",
  "distance_to_route_m": 0.3,
  "before_media_id": "med_aaaa111111",
  "after_media_id": "med_bbbb222222",
  "spoken": "A cardboard box is now in the hallway, 30 centimeters from your bathroom route.",
  "created_at": "2026-10-17T02:11:09Z"
}
```

Severity rules: `hazard` = new or moved object within 0.5 m of a taught route; `warning` = new or moved object elsewhere on the floor, or an object that disappeared; `info` = small moves under 0.5 m, door state, anything else.

### 2.6 Patrol

```json
{
  "id": "pat_a1b2c3d4e5",
  "started_at": "2026-10-17T02:00:00Z",
  "ended_at": "2026-10-17T02:12:30Z",
  "route_id": "rte_patrol01",
  "path": [ { "t": 0, "x": 0.0, "z": 0.0 } ],
  "event_ids": ["evt_p0o9i8u7y6"],
  "summary": "Two changes since the last patrol: ...",
  "stats": { "distance_m": 18.4, "keyframes": 41, "stops": 2 }
}
```

`path` is down-sampled to at most 1 point per second.

### 2.7 Map snapshot

```json
{
  "resolution_m": 0.05,
  "origin": { "x": -4.0, "z": -6.0 },
  "width": 160,
  "height": 240,
  "cells_b64": "<base64 of width*height uint8, row-major from origin; 0=free, 1=unknown, 2=occupied_low (floor-level object), 3=occupied_high (wall or furniture)>",
  "updated_at": "2026-10-17T02:12:30Z"
}
```

### 2.8 Media

JPEG, longest side 320 px, target under 60 KB. Filename is the id. Alt text on the dashboard is generated from the owning object or event label.

### 2.9 Remote command (stretch)

```json
{ "id": "cmd_x1y2z3", "text": "check the way to the bathroom", "created_at": "...", "status": "queued | running | done | failed", "result": "Path is clear." }
```

## 3. On-phone SQLite schema (owned by Robotics)

Mirrors the REST shapes plus private columns. Embeddings are float16 BLOBs.

```sql
CREATE TABLE waypoints (id TEXT PRIMARY KEY, name TEXT, x REAL, z REAL, yaw_deg REAL, media_id TEXT, created_at TEXT);
CREATE TABLE routes (id TEXT PRIMARY KEY, name TEXT, kind TEXT, waypoint_ids TEXT /* json */);
CREATE TABLE tracks (
  id TEXT PRIMARY KEY, label TEXT, label_source TEXT, description TEXT,
  x REAL, y REAL, z REAL, height_above_floor REAL,
  embedding BLOB, embedding_dim INTEGER,
  first_seen TEXT, last_seen TEXT, sightings INTEGER, persistence REAL,
  media_id TEXT, active INTEGER DEFAULT 1);
CREATE TABLE sightings (id INTEGER PRIMARY KEY, track_id TEXT, patrol_id TEXT, x REAL, y REAL, z REAL, sim REAL, t TEXT);
CREATE TABLE keyframes (id TEXT PRIMARY KEY, patrol_id TEXT, x REAL, z REAL, yaw_deg REAL, media_id TEXT, t TEXT, reason TEXT);
CREATE TABLE patrols (id TEXT PRIMARY KEY, kind TEXT /* teach|patrol|check */, started_at TEXT, ended_at TEXT, route_id TEXT, summary TEXT);
CREATE TABLE events (id TEXT PRIMARY KEY, patrol_id TEXT, type TEXT, severity TEXT, label TEXT, confidence REAL,
  x REAL, y REAL, z REAL, prev_x REAL, prev_z REAL, near_waypoint TEXT, on_route TEXT, dist_route REAL,
  before_media_id TEXT, after_media_id TEXT, spoken TEXT, created_at TEXT);
CREATE TABLE occupancy (patrol_id TEXT, cell_x INTEGER, cell_z INTEGER, hits INTEGER, PRIMARY KEY (patrol_id, cell_x, cell_z));
CREATE TABLE sync_queue (id INTEGER PRIMARY KEY, method TEXT, path TEXT, body TEXT, media_path TEXT, attempts INTEGER DEFAULT 0, next_try REAL);
```

## 4. Eval files (owned by Robotics, read by Web)

- `evals/queries.yaml`: list of `{ id, text, type: exact|attribute|descriptive|ambiguous, target_object_id }`.
- `evals/ground_truth.json`: `{ "objects": [ { "id", "label", "x", "z" } ], "changes": [ { "id", "type", "object_id", "from": {x,z}, "to": {x,z} } ] }`.
- `evals/results/run_<timestamp>.json`: raw per-trial logs (see `04_EVALS.md`).
- `evals/results.json` (aggregated, served by `GET /api/evals`):

```json
{
  "generated_at": "...",
  "retrieval": [
    { "variant": "yolo_labels_only", "n": 30, "top1": 0, "top3": 0, "pos_err_cm_median": 0 }
  ],
  "find_end_to_end": [ { "variant": "clip_plus_arrival_check", "n": 10, "success": 0, "median_time_s": 0, "near_misses": 0 } ],
  "change_detection": [ { "type": "moved", "tp": 0, "fp": 0, "fn": 0 } ],
  "memory": [ { "condition": "A_static | B_full_remap | C_selective", "patrols": 5, "db_mb": 0, "find_success": "0/0" } ],
  "notes": "Free text with the room, dates, and caveats."
}
```

The zeros are placeholders. **Never ship placeholder numbers.** The Evals page renders an empty state when a table is empty.

## 5. Security and privacy

- Shared bearer token from env `RECALL_TOKEN`. No keys in git. `Secrets.xcconfig`, `.env`, and `web/.env.local` are gitignored. Provide `*.example` files.
- No raw video or full-resolution frames leave the phone. Thumbnails only.
- The Gemini planner receives text only (transcript, waypoint names, the last patrol summary). Image reranking is an opt-in experiment, disabled by default, and documented.
- Dashboard shows a clear "last seen" and never claims the robot is online without a recent heartbeat.
