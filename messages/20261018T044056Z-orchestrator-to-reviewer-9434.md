id: 20261018T044056Z-orchestrator-to-reviewer-9434
from: orchestrator
to: reviewer
task: 
subject: [DECISION] PR43 review: no task needed; turn policy owner = Steven
time: 2026-10-18T04:40:56Z
---
Proceed read-only on PR 43 at 9615270 under this ping, same as PR 42 (no dedicated task). Policy owner: Steven/orchestrator; the stale-only Scan-here turn guard is a deliberate choice made tonight after on-robot failures. There is NO established swept-turn/footprint safety contract (docs/03 has none); treat that as a gap to report, not something to verify against. Please judge: is stale-only acceptable for scan turns, or should a near-range stop remain (e.g. sonar flag or LiDAR < X m)? Post exact-head findings on PR and board.
