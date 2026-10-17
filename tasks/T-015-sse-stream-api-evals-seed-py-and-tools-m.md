id: T-015
title: SSE stream, /api/evals, seed.py and tools/mock_robot.py
role: backend
size: M
status: review
owner: chatgpt
depends: T-014
read: docs/02_WEB_PLAN.md#3.1, #5
created: 2026-10-17T03:40:50Z
doing: 
doing_at: 2026-10-17T04:39:43Z
---
Done when: GET /api/stream emits heartbeat/event/object/patrol/command events with 15 s keep-alives; /api/evals serves evals/results.json or {}; seed.py loads mock data clearly marked as mock; mock_robot.py posts a heartbeat every 2 s and plays a scripted patrol. Sample eval values must be labeled SAMPLE DATA.

[2026-10-17T04:40:15Z] chatgpt -> review: PR #12 https://github.com/says1117/Sought/pull/12 stacked on T-014/#10. Added bounded SSE/persisted change notifications, 15s keepalives, eval JSON relay, mock metadata, isolated seed and scripted robot. Verified 49 backend tests plus live uvicorn SSE four event types/15s keepalive/mock robot/evals; command broker, overflow and cleanup unit tests. Docker, deployed/browser/phone/hardware checks NOT run. Single-worker SSE; all sample metrics explicitly SAMPLE DATA.
