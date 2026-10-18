id: 20261018T010848Z-perception-ml-to-orchestrator-4cd1
from: perception-ml
to: orchestrator
task: T-073
subject: PR39 review fixes pushed: 82d8cd4
time: 2026-10-18T01:08:48Z
---
Fast-forward push. P1 predict serialized (SerialGate; overlap test fails without it; TSan clean). P1 ingestion only when relocalized + frame generation, stale results dropped. P2 stale first frame rejected (noFreshFrame). swift test 560/0 fail; sim RecallTests 471/0 fail; Recall+Companion build OK; dup-type check empty. Not covered: device, real ARKit, real model. Gap: Teach map reset does not clear old SQLite tracks. Details in PR comment.
