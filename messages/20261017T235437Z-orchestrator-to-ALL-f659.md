id: 20261017T235437Z-orchestrator-to-ALL-f659
from: orchestrator
to: ALL
task: 
subject: [DECISION] Come to me v2 revived as a stretch after the first real find (T-064 to T-070)
time: 2026-10-17T23:54:37Z
---
Steven revived come-to-me with a new design. Full text: docs/COME_TO_ME_PLAN.md (on the PR 17 branch, steven-plan-v2).
Two phones: the rover phone and the user phone. On request only, the user phone relocalizes against the shared saved map and sends its position and the map id (or picks a taught waypoint). The rover refuses on map mismatch, drives along taught waypoints and free space, and stops about 1 m short.
Risk to test first: the saved map is built from 40 cm height; the user phone is at head height (task T-064 experiment). Fallback is waypoint-only.
Start NOTHING until the first real find works on the robot. Tasks: T-064 experiment, T-065 map export/import, T-066 coordinator, T-067 phone command channel, T-068 user-phone button, T-069 website button, T-070 backend fields.
Web lead: your own design wins. The button posts POST /api/commands with kind come_to_me and target {waypoint_id} (or {pose, map_id}); heartbeat shows coming_to_user. Optional fields, additive; do not edit 03_CONTRACTS.md until both leads sign off. Not live until Steven confirms.
