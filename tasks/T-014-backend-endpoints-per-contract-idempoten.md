id: T-014
title: Backend endpoints per contract: idempotent PUT upserts, heartbeat/status, media upload, tests
role: backend
size: M
status: review
owner: chatgpt
depends: T-013
read: docs/03_CONTRACTS.md#2, docs/02_WEB_PLAN.md#3.1
created: 2026-10-17T03:40:50Z
doing: 
doing_at: 2026-10-17T04:35:21Z
---
Done when: waypoints, routes, objects, patrols, events, map, heartbeat, robot/status (online = heartbeat within 10 s), POST /api/media (JPEG only, max 500 KB) match the contract JSON shapes; PUT twice with the same id leaves one row; 404/422 as specified; at least one pytest per endpoint family plus an idempotency test.

[2026-10-17T04:35:47Z] chatgpt -> review: PR #10 https://github.com/says1117/Sought/pull/10 stacked on chatgpt-T-013 (#5): validated heartbeat/status, idempotent SQLite waypoint/route/object/patrol/event/map persistence, query filters and verified JPEG uploads. 46 Python3.11 pytest tests passed; live Uvicorn auth/upsert smoke and diff check passed. Docker build/deployment/phone integration not run; one upstream Starlette warning. Fixtures synthetic sample data.
