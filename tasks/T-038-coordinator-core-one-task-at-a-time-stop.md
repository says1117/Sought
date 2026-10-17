id: T-038
title: Coordinator core: one task at a time, stop always wins, state machine for planner tool calls
role: ios-drive
size: M
status: open
owner: 
depends: T-023,T-026
read: docs/01_ROBOTICS_PLAN.md#6.2, #3.5, #3.6
created: 2026-10-17T10:26:56Z
---
Pure logic over protocols: explore, find_object, come_to_me, go_to_waypoint, stop, say. Tracking-loss and blocked handling, one pending request. Heartbeat states exploring/finding/coming_to_user/blocked/idle.
