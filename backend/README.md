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
SSE, eval results, seed data and remote commands are outside this task.
The Docker image creates the default media and database directories.
