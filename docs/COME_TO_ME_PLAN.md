# Come to me (version 2): design and plan

Decided 2026-10-17 with Steven. This replaces the UWB-only idea. It is a **stretch that starts only after the first real find works** on the robot. The older UWB code (T-028) stays and is reused for the last meters.

## The idea

There are two phones. The **rover phone** is mounted on the rover. The **user phone** is the one the person carries. The user presses **Come to me**, and the rover drives to where the user is, using the places and routes it already knows from Teach.

The user phone learns its own position only at the moment the user asks. It is not tracked all the time (privacy and battery).

## How it works

1. The user presses **Come to me** (in the user-phone app, and later on the website).
2. The user phone loads the **same saved room map** the rover phone built during Teach, and relocalizes against it. That puts both phones in the same coordinate system.
3. The user phone sends the rover a one-shot request: its position in the map `(x, z)` and the **map id** it used.
4. The rover checks that the map id matches the map it has loaded and relocalized against. If not, it refuses and says so aloud.
5. The rover drives to that point along the taught waypoints and known free space, with obstacle slowdown, and stops about 1 m short. If the second phone is in range, UWB can guide the last meters (existing T-028 code).
6. If the user moves, they ask again. The rover goes to where the user was at the time of the request.

## Fallback if relocalization fails

The button offers a list of taught waypoints ("I'm in the kitchen"). The request carries a waypoint id instead of a pose. This is the safer path and the likely demo version if the experiment below fails.

## The risk to test first

The rover phone sees the room from about 40 cm up, and the user phone is held at head height. ARKit relocalizes best from a similar viewpoint, so a map built low may not be recognized from standing height. Test this before building anything else (task list below). The outcome decides between the pose version and the waypoint-only version.

## Proposed contract addition (needs sign-off by both leads before use)

Remote command shape, extending `03_CONTRACTS.md` section 2.9. All new fields are optional so the current shape stays valid:

```json
{
  "id": "cmd_x1y2z3",
  "text": "come to me",
  "kind": "come_to_me",
  "target": { "waypoint_id": "wpt_k3m9q2x7ab" },
  "created_at": "2026-10-17T22:00:00Z",
  "status": "queued | running | done | failed",
  "result": "Path is clear."
}
```

or, for the pose version:

```json
{ "kind": "come_to_me", "target": { "pose": { "x": 1.2, "z": -3.4 }, "map_id": "map_ab12cd34" } }
```

Heartbeat `state` is `coming_to_user` while the rover is on its way. The rover reports `failed` with a plain reason such as "map does not match", "not relocalized", "no known route", or "blocked".

## Safety rules

- The rover only drives to a point inside space it has actually mapped. Anything else is refused.
- It stops about 1 m short of the target.
- Hardware safety stays on the ESP32. Obstacle slowdown and stop-always-wins still apply.
- One task at a time. A new request while one is running is refused with a spoken reason.
- If tracking is lost for more than 1 s, it stops and says it needs to rescan.

## Tasks (all on the board; do not start until the first real find works)

| Id | Owner | What |
|---|---|---|
| T-064 | human + ios-drive | Experiment: save the world map on the rover phone, load it on the second phone at standing height, record whether it relocalizes and how fast |
| T-065 | ios-drive | World map export and import between phones (share sheet, AirDrop, or backend) with a map id |
| T-066 | ios-drive | Coordinator `come_to_me` to a pose or waypoint along taught routes, with the safety rules above |
| T-067 | ios-drive | Remote command channel on the phone: poll the backend for the next command, acknowledge, report status |
| T-068 | ios-drive | User-phone app: Come to me button, relocalize, send pose and map id, or pick a waypoint |
| T-069 | web | Website: Come to me button with a room picker that posts the command |
| T-070 | backend | Confirm command endpoints accept the optional `kind` and `target` fields |

## Not claimed

Nothing in this document has been run on two phones. Do not state that come to me works until it has been run and logged.
