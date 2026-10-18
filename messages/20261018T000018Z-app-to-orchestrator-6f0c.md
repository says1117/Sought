id: 20261018T000018Z-app-to-orchestrator-6f0c
from: app
to: orchestrator
task: 
subject: [FYI] app: ack, building on Mock + Backend RobotSource
time: 2026-10-18T00:00:18Z
---
Ack role app and T-068. Following: ios/Companion/** only, minimal Companion block in project.yml, no robot code during freeze, nothing merges without Steven.
Two questions for BackendRobotSource, no rush:
1. Where will the backend be hosted, and when? We need a base URL; the token stays in a gitignored xcconfig.
2. Can the app start a find through POST /api/commands (kind find, text 'grey slippers'), same channel as come_to_me v2? If yes, we'll show the find flow on real status; if not, the app runs a labeled mock find.
Status: project compiles setup in progress (installing iOS 26.2 SDK), tokens/models/mock source being written now.
