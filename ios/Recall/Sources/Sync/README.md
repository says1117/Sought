# Sync (T-027)

Phone to backend client. The robot never waits on the network: writes go into SQLite `sync_queue`
first, a sender drains it in the background, heartbeats are fire and forget.

| File | Role |
|---|---|
| `Models.swift` | `Wire*` Codable types for contract section 2. Nullable fields encode as explicit `null` (the backend requires the key). Prefixed `Wire` to avoid clashing with ARKit/Pose/Memory types in the single app target. |
| `SyncQueue.swift` | Durable outbox on the contract `sync_queue` table. One pending row per (method, path[, media file]); re-enqueueing an id replaces the unsent body (latest wins), so replays are idempotent. |
| `SyncSender.swift` | Drain loop. 2xx remove; network error, 5xx, 408, 429 back off and retry; 401 pauses and keeps everything (`state == .authRequired`, call `resume()`); other 4xx dropped with a logged `ERROR`. |
| `Backoff.swift` | 1, 2, 4 ... capped at 60 s, +-25 % jitter. |
| `Transport.swift` | `SyncTransport` protocol, `URLSessionTransport` (Bearer auth, 5 s request timeout, multipart JPEG upload). |
| `HeartbeatPublisher.swift` | `POST /api/robot/heartbeat` every 2 s, not queued, at most one in flight, failures swallowed. |
| `LocalStoreReader.swift` | Read-only connection to the shared `recall.sqlite`: `waypoints` and the `tracks` rows of one `map_id` as contract bodies. Skips rows the backend would 422 (bad timestamps, non-finite numbers). |
| `BackendUploader.swift` | T-071. Every 5 s in a background task: snapshot, queue only resources whose body changed (media first), drain. Adds a short in-memory `history` (a point per move over 25 cm). Built only when `SyncConfig` exists. |
| `SyncConfig.swift` | `BACKEND_BASE_URL` and `RECALL_TOKEN` from Info.plist (filled from gitignored `Config/Secrets.xcconfig`). Returns nil for placeholders, then sync is simply off. |

Wiring: `let q = try SyncQueue(path: dbPath)`; `q.enqueue(waypoint)`; `Task.detached { await sender.drain() }` on a
timer and on connectivity changes (`sender.networkRestored()`). Media ids must be opaque `med_` + random (10..128 chars).

App wiring (T-071 block in `AppRuntime.init`): `BackendUploader.make(config:databasePath:queuePath:mapId:)` with the
gate's `activeMapId`, so only tracks of the map in use upload. No thumbnails or map yet: tracks keep no crop and the app
builds no occupancy grid; `UploadSnapshot.media` / `.map` are ready for both.

Tests: `Tests/SyncTests`. `LiveBackendSmokeTests` runs against a real backend when `RECALL_SMOKE_URL` and
`RECALL_SMOKE_TOKEN` are set (local backend, fake token only). Without Xcode run `tools/swift_standin/run_sync_tests.sh`.

## Remote commands (CommandPoller)

Only when a backend is configured, and only between `AppRuntime.start()` and `pause()`, `CommandPoller` GETs
`/api/commands/next` every 2 s (204 = nothing queued). A claimed command is acked `running`, its text runs through
`RemoteCommandRunner` (Sources/Coordinator: keyword STOP first, then the find bar's planner, then the coordinator),
and it is acked `done` with the result or `failed` with the reason. A busy robot (task running or pending, manual
tool open, another remote command in progress) answers `failed` / `busy` and never queues motion; a "stop" always
runs `stopAll()`. Network errors back off 2, 4, 8 ... 30 s.
