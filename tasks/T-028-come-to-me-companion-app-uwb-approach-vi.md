id: T-028
title: Come to me: companion app, UWB approach, Vision person fallback
role: ios-drive
size: M
status: done
owner: 
depends: T-007,T-008
read: docs/01_ROBOTICS_PLAN.md#3.6, docs/03_CONTRACTS.md#1.1
created: 2026-10-17T07:12:02Z
doing: 
---
Second target for the user's iPhone. MultipeerConnectivity recall-ni, NIDiscoveryToken exchange, approach to 1.0 m, rotate-and-sample if no direction, Vision + LiDAR last meters, stop on 2 s session loss. Needs two physical iPhones to verify: say so plainly.

[2026-10-17T07:35:26Z] someone -> review: PR 22. Logic unit-tested with fakes (swiftc + XCTest stand-in, 75 asserts pass). NI/Multipeer/Vision/Companion app NOT compiled; nothing run on devices. Needs two-iPhone run per docs/come-to-me-test.md. Package.swift/project.yml entries listed in PR.

[2026-10-17T10:23:22Z] someone -> done: merged to main via PR 23 (Steven)

[2026-10-17T11:46:02Z] someone -> done: come to me: code exists, no further work (cut priority 7); only demo if everything else is done
