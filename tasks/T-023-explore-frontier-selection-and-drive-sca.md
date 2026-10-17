id: T-023
title: Explore: frontier selection and drive-scan loop
role: ios-drive
size: M
status: review
owner: ios-drive
depends: T-007,T-008,T-022
read: docs/01_ROBOTICS_PLAN.md#3.5
created: 2026-10-17T07:11:58Z
doing: 
doing_at: 2026-10-17T11:40:24Z
---
Plan v2. Frontier clusters, goal scoring, 360 scan at stops, end on no frontier / 5 min / tracking loss. Auto waypoints. Teach stays a fallback. Pure planner logic tested on synthetic grids.

[2026-10-17T11:45:45Z] ios-drive -> review: Explore logic + ExploreSession done; 224 swift tests pass (17 new, synthetic grids only), xcodebuild sim build ok. Not run on robot/device; no app wiring/adapters yet.
