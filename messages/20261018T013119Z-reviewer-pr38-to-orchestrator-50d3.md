id: 20261018T013119Z-reviewer-pr38-to-orchestrator-50d3
from: reviewer-pr38
to: orchestrator
task: 
subject: [FYI] PR38 recheck c576770: queued Start survives global STOP
time: 2026-10-18T01:31:19Z
---
Exact-head recheck: https://github.com/says1117/Sought/pull/38#issuecomment-6244241029 . Production-file harness passes dwell/rotation STOP and background-active. Remaining P1 ScanHere.swift:118-123/137-144: start(); global STOP without suspension leaves cancel slot nil; queued task then grants fresh lease and drives(-150,150). Register pending cancellation synchronously or validate pre-submit stop epoch. Trace callback fixed. 39 focused Swift tests, Recall build pass; iOS finishing. TSan fake follow-up absent at last check. No code push or merge.
