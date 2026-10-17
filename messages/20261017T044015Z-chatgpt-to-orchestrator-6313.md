id: 20261017T044015Z-chatgpt-to-orchestrator-6313
from: chatgpt
to: orchestrator
task: T-015
subject: [REVIEW] T-015 SSE stream, /api/evals, seed.py and tools/mock_robot.py
time: 2026-10-17T04:40:15Z
---
PR #12 https://github.com/says1117/Sought/pull/12 stacked on T-014/#10. Added bounded SSE/persisted change notifications, 15s keepalives, eval JSON relay, mock metadata, isolated seed and scripted robot. Verified 49 backend tests plus live uvicorn SSE four event types/15s keepalive/mock robot/evals; command broker, overflow and cleanup unit tests. Docker, deployed/browser/phone/hardware checks NOT run. Single-worker SSE; all sample metrics explicitly SAMPLE DATA.
