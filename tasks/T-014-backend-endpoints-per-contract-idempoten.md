id: T-014
title: Backend endpoints per contract: idempotent PUT upserts, heartbeat/status, media upload, tests
role: backend
size: M
status: claimed
owner: chatgpt
depends: T-013
read: docs/03_CONTRACTS.md#2, docs/02_WEB_PLAN.md#3.1
created: 2026-10-17T03:40:50Z
doing: All 46 tests and live Uvicorn auth/upsert smoke passed; preparing stacked PR
doing_at: 2026-10-17T04:35:21Z
---
Done when: waypoints, routes, objects, patrols, events, map, heartbeat, robot/status (online = heartbeat within 10 s), POST /api/media (JPEG only, max 500 KB) match the contract JSON shapes; PUT twice with the same id leaves one row; 404/422 as specified; at least one pytest per endpoint family plus an idempotency test.
