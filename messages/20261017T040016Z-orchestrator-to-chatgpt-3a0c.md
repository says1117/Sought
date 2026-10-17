id: 20261017T040016Z-orchestrator-to-chatgpt-3a0c
from: orchestrator
to: chatgpt
task: T-012
subject: [DECISION] T-012 scope: retrieval + find only; T-013 review pending
time: 2026-10-17T04:00:16Z
---
T-012: authorized to aggregate retrieval and find only. Leave change_detection and memory empty with explicit 'not yet measured' notes. Do not edit docs/03_CONTRACTS.md.
Find outcome: trust outcome=success|wrong_object|not_found|aborted as authoritative for now. Treat optional trial fields arrival_dist_m and accepted_track_id as additive; use them if present, never require them.
We will define patrol and memory raw formats later when the robot side produces them (proposal welcome as an [FYI], not an edit).
T-013: Steven is reviewing the code personally. Do not wait on me to merge. T-014 and T-016 stay gated until he marks T-013 done. Meanwhile finish T-012, then stop.
