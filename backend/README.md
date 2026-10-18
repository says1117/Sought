# Backend skeleton

Requires Python 3.11. From the repository root:

```sh
python3.11 -m venv backend/.venv
backend/.venv/bin/pip install -r backend/requirements-dev.txt
# Set RECALL_TOKEN to a private random value in your shell.
backend/.venv/bin/python -m uvicorn backend.app:app
backend/.venv/bin/python -m pytest backend/tests
```

`GET /api/health` is public. Every other `/api` request requires the
configured bearer token, including requests for routes not yet implemented.
An unset or empty token rejects every protected request.

Configuration is read when the app is created. Development allows all CORS
origins. Production (`RECALL_ENV=production`) requires explicit comma-separated
`RECALL_CORS_ORIGINS` and rejects wildcard configuration. See `.env.example`;
variables must be exported by the process environment (dotenv is not loaded).
SQLite opens at startup and closes on shutdown. Contract payloads persist as
validated JSON in a table keyed by family and id. Repeated PUTs replace the same
row, and URL/body id disagreement returns 422. Sync endpoints cover heartbeat,
robot status, waypoints, routes, objects, patrols, events, and the latest map.
Missing heartbeat/map returns 404; empty collections return []. Status freshness
uses server receipt time (online through 10 seconds), independent of phone time.

Object `q` matches label/description without case sensitivity, `since` filters
last_seen strictly after the timestamp, and `limit` is a positive integer.
Objects return newest last_seen first. Event filters combine with AND; `since`
uses created_at strictly after the timestamp. Timestamps require time zones.
Payloads reject unknown fields, including embeddings, and non-finite numbers.

Multipart uploads use fields `id` and `file`. JPEG content must decode correctly,
fit within 500 KiB and have a longest side at most 320 pixels. The response is
`{"id": "<submitted id>"}`. Media ids must be path-safe and 10..128 characters;
the phone must generate unguessable random ids because uploads are served
publicly. Filename input is ignored, and writes replace the id atomically.
`/media` serves existing files publicly. Startup creates the media directory.
The Docker image creates the default media and database directories.

### Isolated MOCK demo

From the repository root, run `python -m backend.seed`. It writes only
`backend/mock/` (never the real DB, media, or eval results). All generated images,
labels, summaries, and evaluation values say MOCK or SAMPLE DATA. Do not use these
values or screenshots as measured project results.

Start a separate development server with your local token and:

```sh
export RECALL_DB_PATH=backend/mock/recall.sqlite3
export RECALL_MEDIA_DIR=backend/mock/media
export RECALL_EVALS_PATH=backend/mock/results.json
python -m uvicorn backend.app:app
```

`GET /api/metadata` reports `{"mock":true}` for a seeded database so clients can
show “Using mock data”. `python tools/mock_robot.py --steps 10` sends heartbeats
at two-second intervals and a scripted sample patrol. Set `RECALL_TOKEN` locally.
Only point this tool at the isolated mock server.

Authenticated `GET /api/stream` emits heartbeat, event, object and patrol writes
only after persistence. Command creates and status changes emit `command`. Idle connections receive comments every 15 seconds. Queues are
bounded: slow clients disconnect and should reconnect and refresh GET snapshots.
Use fetch streaming with an Authorization header. `/api/evals` reads the configured
JSON path (default `evals/results.json`), returns `{}` when missing, and 503 for an
unreadable or malformed file. This is process-local live fan-out; run one worker.

### Remote commands

Shape is docs/03_CONTRACTS.md section 2.9:
`{"id","text","created_at","status":"queued|running|done|failed","result"}` (`result` is null until acked).

- `POST /api/commands` body `{"text": "...", "id"?: "cmd_..."}`; text is 1..200 characters.
  Returns the stored command (`status` queued). The server makes an id when none is sent.
  Re-posting the same id and text returns the original; the same id with other text is 409.
- `GET /api/commands/next` (robot) claims the oldest queued command, marks it `running`
  and returns it. **204 No Content when nothing is queued.**
- `POST /api/commands/{id}/ack` body `{"status": "running|done|failed", "result": "..."|null}`
  (result up to 500 characters). 404 for an unknown id; 409 to change a done/failed command
  (an ack that changes nothing returns 200 and emits no event).
- `GET /api/commands/{id}` returns one command (404 if unknown).
- `GET /api/commands?limit=20` returns the newest commands first (limit 1..200).

Every create and status change emits an SSE `command` event with the full command.
All endpoints need the bearer token.
