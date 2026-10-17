id: T-015
title: SSE stream, /api/evals, seed.py and tools/mock_robot.py
role: backend
size: M
status: claimed
owner: chatgpt
depends: T-014
read: docs/02_WEB_PLAN.md#3.1, #5
created: 2026-10-17T03:40:50Z
doing: Implemented bounded SSE broker and results endpoint; building isolated mock fixtures
doing_at: 2026-10-17T04:37:42Z
---
Done when: GET /api/stream emits heartbeat/event/object/patrol/command events with 15 s keep-alives; /api/evals serves evals/results.json or {}; seed.py loads mock data clearly marked as mock; mock_robot.py posts a heartbeat every 2 s and plays a scripted patrol. Sample eval values must be labeled SAMPLE DATA.
