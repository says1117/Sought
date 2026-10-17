id: T-010
title: Memory SQLite schema + track association with tests
role: perception-ml
size: M
status: review
owner: perception-ml
depends: 
read: docs/03_CONTRACTS.md#3, docs/01_ROBOTICS_PLAN.md#4.5
created: 2026-10-17T03:26:02Z
---
Memory SQLite schema + track association with tests

[2026-10-17T03:32:58Z] perception-ml -> review: Branch claude/steven-t-010-33e4bf: ios/Recall/Package.swift (SwiftPM target Memory) + Sources/Memory (Schema, Thresholds, Association, MemoryUpdate) + Tests/MemoryTests. Verified: SQL schema executes in sqlite (python); logic tests (29 checks) pass via a standalone swiftc harness with an XCTest shim. NOT run: real 'swift test' (Mac CLT toolchain is broken: no XCTest, SDK/compiler mismatch, no Xcode installed), so SchemaTests (SQLite3) is unrun. Human: run 'swift test' in ios/Recall with full Xcode. All thresholds marked TO BE CALIBRATED; movedDistance 0.15, persistenceThreshold 0.5, alpha 0.3 are my guesses. Note: coord/ is not on main/this branch (only on steven-coordination).
