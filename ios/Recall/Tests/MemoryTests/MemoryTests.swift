import XCTest
import SQLite3
#if canImport(Memory)
@testable import Memory
#endif

final class SchemaTests: XCTestCase {
    func testSchemaCreatesAllContractTables() {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for s in MemorySchema.statements { XCTAssertEqual(sqlite3_exec(db, s, nil, nil, nil), SQLITE_OK, s) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &stmt, nil)
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(stmt, 0))) }
        sqlite3_finalize(stmt)
        let expected: Set = ["waypoints", "routes", "tracks", "sightings", "keyframes",
                             "patrols", "events", "occupancy", "sync_queue"]
        XCTAssertTrue(expected.isSubset(of: names))
    }
}

final class AssociationTests: XCTestCase {
    let e1: [Float] = [1, 0, 0]
    // cosine with e1 is ~0.9 (> 0.85): same object, slightly different view.
    let near: [Float] = [0.9, 0.436, 0]

    func track(_ id: String, at p: SIMD3<Float>, emb: [Float]) -> Track { Track(id: id, position: p, embedding: emb) }

    func testMatchWhenBothThresholdsPass() {
        let a = associate(Observation(position: [0.2, 0, 0], embedding: near), tracks: [track("a", at: [0, 0, 0], emb: e1)])
        guard case .matched(let id, _, _) = a.result else { return XCTFail("expected match") }
        XCTAssertEqual(id, "a")
    }

    func testTooFarStartsNewTrack() {
        let a = associate(Observation(position: [0.6, 0, 0], embedding: e1), tracks: [track("a", at: [0, 0, 0], emb: e1)])
        XCTAssertEqual(a.result, .newTrack)
    }

    func testDissimilarStartsNewTrack() {
        let a = associate(Observation(position: [0, 0, 0], embedding: [0, 1, 0]), tracks: [track("a", at: [0, 0, 0], emb: e1)])
        XCTAssertEqual(a.result, .newTrack)
    }

    func testBestCosineWinsAndAllCandidatesLogged() {
        let tracks = [track("worse", at: [0, 0, 0], emb: near), track("better", at: [0.1, 0, 0], emb: e1)]
        let a = associate(Observation(position: [0, 0, 0], embedding: e1), tracks: tracks)
        guard case .matched(let id, _, _) = a.result else { return XCTFail("expected match") }
        XCTAssertEqual(id, "better")
        XCTAssertEqual(a.candidates.count, 2)
    }

    func testNoTracksIsNewTrack() {
        XCTAssertEqual(associate(Observation(position: [0, 0, 0], embedding: e1), tracks: []).result, .newTrack)
    }

    func testUnconfirmedUntilSeenTwice() {
        let obs = Observation(position: [0, 0, 0], embedding: e1)
        var t = newTrack(id: "a", from: obs)
        XCTAssertFalse(t.isConfirmed)
        (t, _) = applyMatch(track: t, observation: obs, cosine: 1, distance: 0)
        XCTAssertTrue(t.isConfirmed)
    }
}

final class UpdateTests: XCTestCase {
    func testPersistenceRule() {
        XCTAssertEqual(updatedPersistence(0.5, seen: true), 0.65, accuracy: 1e-6)
        XCTAssertEqual(updatedPersistence(0.5, seen: false), 0.35, accuracy: 1e-6)
        XCTAssertEqual(updatedPersistence(1, seen: true), 1, accuracy: 1e-6)
        XCTAssertEqual(updatedPersistence(0, seen: false), 0)
    }

    func testEMAPosition() {
        let p = emaPosition(old: [0, 0, 0], observed: [1, 0, 0], alpha: 0.3)
        XCTAssertEqual(p.x, 0.3, accuracy: 1e-6)
    }

    func testStableMatchOnlyTouchesBookkeeping() {
        let t = Track(id: "a", position: [0, 0, 0], embedding: [1, 0, 0], sightings: 3, persistence: 0.9, lastSeen: 1)
        let obs = Observation(position: [0.05, 0, 0], embedding: [1, 0, 0], time: 5)
        let (u, plan) = applyMatch(track: t, observation: obs, cosine: 0.99, distance: 0.05)
        XCTAssertEqual(plan, UpdatePlan())
        XCTAssertEqual(u.position, t.position)
        XCTAssertEqual(u.embedding, t.embedding)
        XCTAssertEqual(u.sightings, 4)
        XCTAssertEqual(u.lastSeen, 5)
        XCTAssertGreaterThan(u.persistence, t.persistence)
    }

    func testMovedRewritesPosition() {
        let t = Track(id: "a", position: [0, 0, 0], embedding: [1, 0, 0], sightings: 3, persistence: 0.9)
        let obs = Observation(position: [0.4, 0, 0], embedding: [1, 0, 0])
        let (u, plan) = applyMatch(track: t, observation: obs, cosine: 0.99, distance: 0.4)
        XCTAssertTrue(plan.rewritePosition)
        XCTAssertEqual(u.position.x, 0.12, accuracy: 1e-5)
    }

    func testLowSimilarityRewritesEmbedding() {
        let t = Track(id: "a", position: [0, 0, 0], embedding: [1, 0, 0], sightings: 3, persistence: 0.9)
        let obs = Observation(position: [0, 0, 0], embedding: [0.9, 0.436, 0])
        let (u, plan) = applyMatch(track: t, observation: obs, cosine: 0.88, distance: 0)
        XCTAssertTrue(plan.rewriteEmbedding)
        XCTAssertNotEqual(u.embedding, t.embedding)
        XCTAssertEqual(cosine(u.embedding, u.embedding), 1, accuracy: 1e-5)
    }

    func testPersistenceCrossingRewrites() {
        // 0.4 -> 0.58 crosses 0.5 upward.
        let t = Track(id: "a", position: [0, 0, 0], embedding: [1, 0, 0], sightings: 3, persistence: 0.4)
        let plan = planUpdate(track: t, observation: Observation(position: [0, 0, 0], embedding: [1, 0, 0]),
                              cosine: 0.99, distance: 0)
        XCTAssertTrue(plan.rewriteThumbnail)
    }

    func testBestConfidencePolicy() {
        let t = Track(id: "a", position: [0, 0, 0], embedding: [1, 0, 0], sightings: 3, persistence: 0.9)
        let obs = Observation(position: [0, 0, 0], embedding: [0.9, 0.436, 0], confidence: 0.4)
        let (low, _) = applyMatch(track: t, observation: obs, cosine: 0.88, distance: 0,
                                  embeddingPolicy: .bestConfidence(storedConfidence: 0.8))
        XCTAssertEqual(low.embedding, t.embedding)
        let (high, _) = applyMatch(track: t, observation: obs, cosine: 0.88, distance: 0,
                                   embeddingPolicy: .bestConfidence(storedConfidence: 0.2))
        XCTAssertEqual(high.embedding, obs.embedding)
    }

    func testKeyframeOnlyWhenBecomingConfirmed() {
        let obs = Observation(position: [0, 0, 0], embedding: [1, 0, 0])
        let t1 = newTrack(id: "a", from: obs)
        XCTAssertTrue(planUpdate(track: t1, observation: obs, cosine: 1, distance: 0).storeKeyframe)
        let t2 = Track(id: "a", position: [0, 0, 0], embedding: [1, 0, 0], sightings: 2)
        XCTAssertFalse(planUpdate(track: t2, observation: obs, cosine: 1, distance: 0).storeKeyframe)
    }
}
