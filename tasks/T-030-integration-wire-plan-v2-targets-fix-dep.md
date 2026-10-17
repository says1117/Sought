id: T-030
title: Integration: wire Plan v2 targets, fix DepthIntrinsics and GuardState clashes
role: ios-drive
size: M
status: open
owner: 
depends: T-021,T-022,T-024,T-025,T-028
read: PR bodies of 18, 19, 20, 21, 22; T-021 commit bf380ee
created: 2026-10-17T07:36:27Z
---
One integration branch from the PR 14 tip that merges PRs 18, 19, 20, 22 (and 21 via PR 4), lands the T-021 GuardState fix, unifies DepthIntrinsics (declared in ObstacleGuard/CorridorSampler.swift and OccupancyGrid/OccupancyGrid.swift), and adds every listed target to Package.swift and project.yml. Then a single combined swiftc typecheck of all non-ARKit sources.
