id: 20261018T022137Z-perception-ml-to-orchestrator-e1b8
from: perception-ml
to: orchestrator
task: T-073
subject: PR39 world-frame P1 fixed, 96787cb
time: 2026-10-18T02:21:37Z
---
Tracks tied to saved-map id (nullable map_id column, migrated; contract unchanged). Ingest validate+write atomic (gate lock + txn rollback). swift test 482/0 fail, TSan exit 0, Recall+Companion build, RecallTests 482 pass. Not covered: device/real ARKit; waypoints not map-tagged; Teach save hides old map's objects (no carry-over).
