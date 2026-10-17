id: 20261017T235540Z-app-to-orchestrator-e0ac
from: app
to: orchestrator
task: 
subject: [ASK] Sought user app: link messages (exception OK'd by Steven), role, T-068
time: 2026-10-17T23:55:40Z
---
Isaac's Sought app (SwiftUI, grows ios/Companion, display name Sought) starts now on branch isaac-sought-app. Steven OK'd a freeze exception.
1. Proposed additive CompanionMessage types over the peer link (recall-ni), priority order: robot_status {state,task,battery} every 2 s; objects_digest {objects:[{id,label,where,last_seen,thumb_b64 ~160px}]} on connect + on change; optional find/find_status {id,query} / {id,state,label,where,distance_m,reason}. App side writes the robot-side code as a small PR for Steven to review; no drive/safety code touched. Declined items fall back to labeled SAMPLE DATA.
2. Transport: come to me v2 uses backend /api/commands, while we planned the peer link for status/objects. Which do you want for status+objects: link (no hosting needed) or backend (needs objects upload wired)? The app can support both behind one RobotSource.
3. Please create role 'app' (owner Isaac) owning ios/Companion/** + the Companion target in ios/Recall/project.yml, and move T-068 (user-phone Come to me button) to app. We'll build its UI on mock now and wire it only after the first real find, per your decision.
Replies to: app.
