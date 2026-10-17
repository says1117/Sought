id: T-035
title: EvalMode: tap-to-annotate ground truth, run queries.yaml, export run_*.json
role: perception-ml
size: M
status: done
owner: perception-ml
depends: T-025
read: docs/04_EVALS.md, docs/03_CONTRACTS.md#4
created: 2026-10-17T10:26:38Z
doing: 
doing_at: 2026-10-17T22:00:15Z
---
Matches the raw run format in 04_EVALS.md section 7.

[2026-10-17T22:01:20Z] perception-ml -> review: PR 34: EvalMode (ground truth, YAML loader, retrieval runner -> raw run file, find logger, EvalView/Container). swift test 348 pass; xcodebuild build + RecallTests 348 pass. No device/real data; RecallApp hook in PR body.

[2026-10-17T23:05:40Z] perception-ml -> done: PR 34 merged by Steven (ceff393, gating fix included)
