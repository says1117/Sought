id: T-058
title: PR27: pass saved ARWorldMap to PoseTracker.start and start RelocalizationMonitor
role: ios-drive
size: S
status: open
owner: 
depends: 
read: ios/Recall/Sources/App/RecallApp.swift, Teach/ARWorldMapAdapter.swift, Teach/RelocalizationMonitor.swift
created: 2026-10-17T12:01:12Z
---
Reviewer finding on PR27 verified: RecallApp calls pose.start() without initialWorldMap; monitor never started. Reviewer may already be fixing; check before claiming.
