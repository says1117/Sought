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
SQLite opens at startup and closes on shutdown. No domain tables, sync routes,
seed data, or upload endpoint are implemented in this skeleton. `/media` serves
existing files publicly. Startup creates the configured media directory.
The Docker image creates the default media and database directories.
