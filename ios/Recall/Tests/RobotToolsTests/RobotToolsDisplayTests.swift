import XCTest
#if canImport(RobotToolsCore)
@testable import RobotToolsCore
#endif
#if canImport(FindExecutor)
@testable import FindExecutor
#endif
#if canImport(Memory)
@testable import Memory
#endif

private func rtTrace(ranked: [RankedEntry], attempts: [AttemptEntry] = [], outcome: String = "success") -> FindTrace {
    FindTrace(queryID: "q", text: "blue backpack", target: nil, ranked: ranked, outcome: outcome, timeS: 12.34,
              nearMisses: 0, notes: "", foundTrackID: nil, attempts: attempts, spoken: "Found blue backpack at x 1.0, z 2.0.")
}

private func rtAttempt(_ id: String, _ verdict: String, si: Float?, st: Float?, reason: String) -> AttemptEntry {
    let v = CandidateVerdict(rawValue: verdict)!
    return AttemptEntry(CandidateAttempt(trackID: id, retrievalScore: 0.3, x: 0, z: 0, verdict: v, sImg: si, sText: st, reason: reason))
}

final class RobotToolsFindTraceTests: XCTestCase {
    func testNoTraceConnectedShowsNotConnectedMessage() {
        let d = FindTraceDisplay.make(from: nil, connected: false)
        XCTAssertEqual(d.emptyMessage, FindTraceDisplay.notConnected)
    }

    func testNoTraceYetShowsNoFindMessage() {
        XCTAssertEqual(FindTraceDisplay.make(from: nil, connected: true).emptyMessage, FindTraceDisplay.noFindYet)
    }

    func testCandidatesJoinAttemptsAndFormatScores() {
        let t = rtTrace(
            ranked: [RankedEntry(trackID: "a", score: 0.4123, x: 1, z: 2), RankedEntry(trackID: "b", score: 0.3, x: -1.25, z: 0),
                     RankedEntry(trackID: "c", score: 0.2, x: 3, z: 3)],
            attempts: [rtAttempt("a", "not_here", si: 0.5, st: 0.12, reason: "s_img below tau_img"),
                       rtAttempt("b", "accepted", si: 0.9, st: 0.3, reason: "ok")])
        let d = FindTraceDisplay.make(from: t)
        XCTAssertEqual(d.query, "blue backpack")
        XCTAssertEqual(d.outcomeTitle, "Found it")
        XCTAssertEqual(d.timeText, "12.3 s")
        XCTAssertEqual(d.candidates.map(\.trackID), ["a", "b", "c"])
        XCTAssertEqual(d.candidates[0].scoreText, "0.41")
        XCTAssertEqual(d.candidates[0].rank, 1)
        XCTAssertEqual(d.candidates[0].attempt?.verdictTitle, "Rejected: not here")
        XCTAssertEqual(d.candidates[0].attempt?.isAccept, false)
        XCTAssertEqual(d.candidates[0].attempt?.scoresText, "s_img 0.50, s_text 0.12")
        XCTAssertEqual(d.candidates[0].attempt?.reason, "s_img below tau_img")
        XCTAssertEqual(d.candidates[1].attempt?.isAccept, true)
        XCTAssertEqual(d.candidates[1].positionText, "x -1.2, z 0.0")   // %.1f of -1.25 rounds to even
        XCTAssertNil(d.candidates[2].attempt)
        XCTAssertEqual(d.spoken, "Found blue backpack at x 1.0, z 2.0.")
    }

    func testUnreachableAndMissingScores() {
        let t = rtTrace(ranked: [RankedEntry(trackID: "a", score: 0.3, x: 0, z: 0)],
                        attempts: [rtAttempt("a", "unreachable", si: nil, st: nil, reason: "drive failed: timeout")],
                        outcome: "not_found")
        let d = FindTraceDisplay.make(from: t)
        XCTAssertEqual(d.outcomeTitle, "Not found")
        XCTAssertEqual(d.candidates[0].attempt?.verdictTitle, "Could not reach")
        XCTAssertEqual(d.candidates[0].attempt?.scoresText, "s_img n/a, s_text n/a")
    }

    func testEmptyRankedShowsNoCandidatesMessage() {
        let d = FindTraceDisplay.make(from: rtTrace(ranked: [], outcome: "not_found"))
        XCTAssertNotNil(d.noCandidatesMessage)
        XCTAssertNil(d.emptyMessage)
    }

    func testAttemptNotInRankedStillShown() {
        let t = rtTrace(ranked: [], attempts: [rtAttempt("z", "no_view", si: nil, st: nil, reason: "no crops captured")])
        let d = FindTraceDisplay.make(from: t)
        XCTAssertEqual(d.candidates.count, 1)
        XCTAssertEqual(d.candidates[0].attempt?.verdictTitle, "Rejected: no view")
    }

    func testNearMissesAndAbortedTitle() {
        var t = rtTrace(ranked: [], outcome: "aborted")
        t.nearMisses = 1
        XCTAssertEqual(FindTraceDisplay.make(from: t).nearMissesText, "1 near miss")
        t.nearMisses = 3
        XCTAssertEqual(FindTraceDisplay.make(from: t).nearMissesText, "3 near misses")
        XCTAssertEqual(FindTraceDisplay.make(from: t).outcomeTitle, "Stopped")
    }

    func testRecorderKeepsLastAndMarksConnected() {
        let r = FindTraceRecorder()
        XCTAssertFalse(r.isConnected)
        XCTAssertNil(r.lastTrace())
        r.record(rtTrace(ranked: []))
        XCTAssertTrue(r.isConnected)
        XCTAssertEqual(r.lastTrace()?.text, "blue backpack")
    }
}

final class RobotToolsMemoryTests: XCTestCase {
    private func track(_ id: String, seen: Double, n: Int = 2) -> Track {
        Track(id: id, position: SIMD3<Float>(1.04, 0, -2.5), embedding: [0.1], sightings: n, persistence: 0.625, lastSeen: seen)
    }

    func testSortsMostRecentFirstThenById() {
        let d = MemoryInspectorDisplay.make(tracks: .success([track("b", seen: 100), track("a", seen: 100), track("c", seen: 500)]),
                                            now: 600, modelsInstalled: true)
        XCTAssertEqual(d.rows.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(d.countText, "3 objects in memory")
    }

    func testRowFormatting() {
        let d = MemoryInspectorDisplay.make(tracks: .success([track("a", seen: 1000, n: 1)]), now: 1000 + 125, modelsInstalled: true)
        let r = d.rows[0]
        XCTAssertEqual(r.positionText, "x 1.0, z -2.5")
        XCTAssertEqual(r.sightingsText, "1 sighting")
        XCTAssertEqual(r.persistenceText, "persistence 0.62")
        XCTAssertEqual(r.lastSeenText, "last seen 2 min ago")
        XCTAssertFalse(r.hasThumbnail)
        XCTAssertEqual(d.countText, "1 object in memory")
    }

    func testRelativeTimes() {
        XCTAssertEqual(MemoryInspectorDisplay.lastSeen(0, now: 100), "last seen: unknown")
        XCTAssertEqual(MemoryInspectorDisplay.lastSeen(95, now: 100), "last seen just now")
        XCTAssertEqual(MemoryInspectorDisplay.lastSeen(70, now: 100), "last seen 30 s ago")
        XCTAssertEqual(MemoryInspectorDisplay.lastSeen(1, now: 7201), "last seen 2 h ago")
        XCTAssertEqual(MemoryInspectorDisplay.lastSeen(1, now: 200_000), "last seen 2 d ago")
        XCTAssertEqual(MemoryInspectorDisplay.lastSeen(500, now: 100), "last seen just now")   // clock skew never negative
    }

    func testEmptyState() {
        let d = MemoryInspectorDisplay.make(tracks: .success([]), now: 0, modelsInstalled: true)
        XCTAssertEqual(d.countText, "0 objects in memory")
        XCTAssertNotNil(d.emptyMessage)
        XCTAssertTrue(d.notices.isEmpty)
    }

    func testModelsMissingNotice() {
        let d = MemoryInspectorDisplay.make(tracks: .success([]), now: 0, modelsInstalled: false,
                                            perceptionNote: "Memory is not filling: image models not installed")
        XCTAssertEqual(d.notices.first, MemoryInspectorDisplay.modelsMissingNotice)
        XCTAssertEqual(d.notices.count, 2)
    }

    func testErrorState() {
        struct Boom: Error {}
        let d = MemoryInspectorDisplay.make(tracks: .failure(Boom()), now: 0, modelsInstalled: true)
        XCTAssertNotNil(d.errorMessage)
        XCTAssertTrue(d.rows.isEmpty)
        XCTAssertEqual(d.countText, "Memory unavailable")
        XCTAssertNil(d.emptyMessage)
    }
}
