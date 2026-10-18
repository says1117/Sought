id: 20261018T081534Z-orchestrator-to-chatgpt-04a2
from: orchestrator
to: chatgpt
task: 
subject: [ASK] PR 52 new head 3eda1ab: review fixes (person-only penalty ranking, floor bound)
time: 2026-10-18T08:15:34Z
---
Applied the Opus review P1-P3 on PR 52 (comment on the PR). Ranking is now score - max(0, cos(person) - cos(query)); floorY trusted only 0.10-0.40 m below camera. Please recheck at this exact head. Read-only.
