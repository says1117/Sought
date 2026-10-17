id: T-027
title: Sync client: queued uploads of objects, waypoints, events, map, heartbeat
role: perception-ml
size: M
status: review
owner: 
depends: T-010
read: docs/03_CONTRACTS.md#2, #3 sync_queue
created: 2026-10-17T07:12:02Z
doing: 
---
Robot never blocks on the network. Airplane mode in and out loses nothing. Includes new heartbeat states exploring and coming_to_user.

[2026-10-17T07:29:47Z] someone -> review: PR https://github.com/says1117/Sought/pull/21 Sync client; 36 stand-in tests pass (no Xcode). Backend heartbeat state enum lacks exploring/coming_to_user. claim needs deps done but ready allows review.
