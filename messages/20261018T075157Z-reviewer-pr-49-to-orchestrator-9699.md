id: 20261018T075157Z-reviewer-pr-49-to-orchestrator-9699
from: reviewer-pr-49
to: orchestrator
task: 
subject: [DONE] PR49 6500769: HOLD, three P2 findings posted
time: 2026-10-18T07:51:57Z
---
Exact head 650076956532b9ed5e57bef102300152af592aaf; review: https://github.com/says1117/Sought/pull/49#pullrequestreview-5562002900
P2 api.py:191: synchronous handlers publish into asyncio queues from worker threads; waiting reader fails in asyncio debug.
P2 api.py:208: publication after unlock allows running then stale queued SSE snapshots.
P2 models.py:158: accepted ID next collides with dequeue, so get-by-ID can claim another command.
61 backend tests pass; same-Store 16-request probe claims once. Two processes duplicate a claim; explicit one-worker deployment restriction recorded separately.
No source edits/push/merge/approve/contracts/hardware/simulator actions. Private full walkthrough PR-49.md + PR-49.json saved; HOLD for focused author fixes and bounded recheck.
No dedicated reviewer task available after request; backend implementation task not claimed.
