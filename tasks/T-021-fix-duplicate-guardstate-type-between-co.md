id: T-021
title: Fix duplicate GuardState type between Controller (PR13) and ObstacleGuard (PR14)
role: ios-drive
size: S
status: done
owner: ios-drive
depends: T-007,T-008
read: ios/Recall/Sources/Controller/ControllerMath.swift, ios/Recall/Sources/ObstacleGuard/ObstacleGuardLogic.swift, project.yml
created: 2026-10-17T06:41:17Z
doing: 
doing_at: 2026-10-17T06:41:44Z
---
Both declare GuardState; one Xcode app target compiles both. Make one shared definition and update tests. Push to the PR 14 branch as a fast-forward.

[2026-10-17T10:05:26Z] ios-drive -> done: obsolete: main's ObstacleGuard now uses ObstacleLevel/ObstacleGuardState, no GuardState clash remains; local commit bf380ee is stale and not to be pushed
