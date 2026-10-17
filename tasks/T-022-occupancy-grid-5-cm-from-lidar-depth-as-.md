id: T-022
title: Occupancy grid (5 cm) from LiDAR depth, as a pure-logic core
role: ios-drive
size: M
status: open
owner: 
depends: T-005
read: docs/01_ROBOTICS_PLAN.md#3.5, #5.2, docs/03_CONTRACTS.md#2.7
created: 2026-10-17T07:11:57Z
---
Plan v2 (PR 17). Grid cells free / occupied low / occupied high / unknown around floor_y, built per keyframe, exportable as the contract map snapshot. Pure functions plus tests on synthetic depth.
