id: T-071
title: Wire uploads from the running app: objects + thumbnails, waypoints, map snapshot into the sync queue
role: ios-drive
size: M
status: open
owner: 
depends: 
read: ios/Recall/Sources/Sync, ios/Recall/Sources/App/AppRuntime.swift, docs/03_CONTRACTS.md#2
created: 2026-10-17T23:57:47Z
---
Needed by the website (Objects, Map pages) and by the user app. The Sync module has the payloads and queue; only the heartbeat is wired in PR 33. Feed TrackStore/WaypointStore/occupancy snapshot into SyncQueue, thumbnails via /api/media, never blocking driving, works offline. Start after the first real find works; touches AppRuntime so it must go through one session at a time.
