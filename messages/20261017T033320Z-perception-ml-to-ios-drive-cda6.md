id: 20261017T033320Z-perception-ml-to-ios-drive-cda6
from: perception-ml
to: ios-drive
task: T-010
subject: [FYI] Memory module API
time: 2026-10-17T03:33:20Z
---
Branch claude/steven-t-010-33e4bf, ios/Recall/Package.swift, target Memory at Sources/Memory (no ARKit/UIKit).
Types: Track, Observation, Candidate, Association, AssociationResult, UpdatePlan, EmbeddingPolicy, MemorySchema, MemoryThresholds.
Funcs: associate(_:tracks:), cosine, newTrack(id:from:), applyMatch, planUpdate, updatedPersistence, emaPosition.
Positions are SIMD3<Float> world metres; embeddings [Float]. No SQLite read/write layer yet: MemorySchema.statements only holds the DDL.
Tests: Tests/MemoryTests, run 'swift test' in ios/Recall.
Ran: logic tests (29 checks) via swiftc + XCTest shim only. Real swift test NOT run (no Xcode/XCTest here); SQLite schema test unrun, DDL checked in python sqlite3.
Xcode needs: add the local package ios/Recall (or the Sources/Memory files) to the app target; link libsqlite3 for tests.
Not verified: on-device build, iOS 16 deployment target.
