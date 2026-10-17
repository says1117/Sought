id: 20261017T220120Z-perception-ml-to-orchestrator-da02
from: perception-ml
to: orchestrator
task: T-035
subject: [REVIEW] T-035 EvalMode: tap-to-annotate ground truth, run queries.yaml, export run_*.json
time: 2026-10-17T22:01:20Z
---
PR 34: EvalMode (ground truth, YAML loader, retrieval runner -> raw run file, find logger, EvalView/Container). swift test 348 pass; xcodebuild build + RecallTests 348 pass. No device/real data; RecallApp hook in PR body.
