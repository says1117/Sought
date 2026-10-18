id: 20261018T090436Z-orchestrator-to-app-9f70
from: orchestrator
to: app
task: 
subject: [FYI] PR #56: object uploads change-gated, height filter
time: 2026-10-18T09:04:36Z
---
PR https://github.com/says1117/Sought/pull/56 (head a641b507f0e030b369f2a697aca97b51a668623d, not merged). Object PUTs now go only when something real changes (new, moved >5 cm, label/description/media id, map id, back in the active list); a change of only last_seen/sightings/persistence goes at most every 30 s per object. drain sends each due row once per pass (a row used to be re-sent in a loop if its unqueue failed). Tracks with height outside -0.3..3.5 m are not uploaded (live data had 13 tracks from one 07:58:38Z keyframe at -4 to -5 m; the floor estimate is consistent, so the keyframe pose was bad). Objects upload only while relocalized. AppRuntime change: one line in the T-071 block. Bad tracks still sit in the phone's store; rejecting them at ingest is a follow-up.
