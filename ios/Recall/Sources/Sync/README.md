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
| `SyncConfig.swift` | `BACKEND_BASE_URL` and `RECALL_TOKEN` from Info.plist (filled from gitignored `Config/Secrets.xcconfig`). Returns nil for placeholders, then sync is simply off. |

Wiring: `let q = try SyncQueue(path: dbPath)`; `q.enqueue(waypoint)`; `Task.detached { await sender.drain() }` on a
timer and on connectivity changes (`sender.networkRestored()`). Media ids must be opaque `med_` + random (10..128 chars).

Tests: `Tests/SyncTests`. Without Xcode run `tools/swift_standin/run_sync_tests.sh`.
