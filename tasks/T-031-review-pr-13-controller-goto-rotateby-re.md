id: T-031
title: Review PR 13: Controller goTo/rotateBy (read-only)
role: reviewer
size: S
status: open
owner: 
depends: 
read: PR 13 diff (gh pr diff 13), ios/Recall/Sources/Controller, docs/01_ROBOTICS_PLAN.md#3.3, docs/03_CONTRACTS.md#0 (turn convention), PR 13 body
created: 2026-10-17T09:25:47Z
---
Read-only. Check: err sign and TURN_SIGN in exactly one place; L = linear - angular, R = linear + angular, angular > 0 turns left; turn-in-place above 20 degrees; slowdown inside 0.5 m; done after 3 consecutive ticks within stopDist + 0.05; 30 s timeout; stop if tracking != normal for 1 s; speeds clamped to -255..255 and below MAX_PWM. Post findings (severity first, file:line) as a PR comment with gh pr comment 13, and one board message to orchestrator. Do not push or edit. Fixes become a new task for ios-drive.
