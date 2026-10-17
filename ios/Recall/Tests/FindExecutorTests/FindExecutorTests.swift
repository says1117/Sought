import XCTest
import Foundation
#if canImport(Memory)
import Memory
#endif
#if canImport(Retrieval)
import Retrieval
#endif
#if canImport(FindExecutor)
@testable import FindExecutor
#endif

private struct FixedEncoder: TextEncoder {
    func encode(_ text: String) throws -> [Float] { [1, 0] }
}

private final class FakeDriver: ApproachDriver {
    var script: [Double: ApproachReport] = [:]      // keyed by x
    var visited: [(x: Double, z: Double, stop: Double)] = []
    func approach(x: Double, z: Double, stopDistance: Double) async -> ApproachReport {
        visited.append((x, z, stopDistance))
        return script[x] ?? ApproachReport(outcome: .arrived)
    }
}

private final class FakeImages: ImageEmbedder {
    var byX: [Float: [[Float]]] = [:]
    var failing = false
    var calls: [(Float, Int, Float)] = []
    func captureEmbeddings(around p: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [[Float]] {
        calls.append((p.x, count, cropScale))
        if failing { throw NSError(domain: "cam", code: 1) }
        return byX[p.x] ?? []
    }
}

final class FindExecutorTests: XCTestCase {
    // Query is [1,0]. Track embeddings: sorted by cosine to the query, then by id for equal scores.
    private func tracks() -> [Track] {
        [
            Track(id: "a", position: SIMD3(1, 0, 1), embedding: [1, 0], sightings: 4, persistence: 1.0),       // score 1.0
            Track(id: "b", position: SIMD3(2, 0, 2), embedding: [0.8, 0.6], sightings: 4, persistence: 1.0),   // 0.8
            Track(id: "c", position: SIMD3(3, 0, 3), embedding: [0.6, 0.8], sightings: 4, persistence: 1.0),   // 0.6
            Track(id: "d", position: SIMD3(4, 0, 4), embedding: [0.0, 1.0], sightings: 4, persistence: 1.0),   // 0.0
        ]
    }

    private func make(driver: FakeDriver, images: FakeImages, config: FindConfig = FindConfig()) -> FindExecutor {
        var t = 0.0
        return FindExecutor(retriever: Retriever(encoder: FixedEncoder()), driver: driver, images: images, config: config,
                            clock: { t += 1; return t })
    }

    func testAcceptsFirstCandidateThatPassesBothChecks() async {
        let d = FakeDriver(), im = FakeImages()
        im.byX[1] = [[0.2, 0.9], [1, 0.05], [0.9, 0.3]]        // best crop [1,0.05]: cos to track ~0.9988, to q same
        let r = await make(driver: d, images: im).find(phrase: "mug", tracks: tracks(), queryID: "q1", targetTrackID: "a")
        XCTAssertEqual(r.outcome, .success)
        XCTAssertEqual(r.foundTrackID, "a")
        XCTAssertEqual(d.visited.count, 1)
        XCTAssertEqual(d.visited[0].stop, 0.8)
        XCTAssertEqual(im.calls[0].1, 3)
        XCTAssertEqual(im.calls[0].2, 1.5)
        XCTAssertTrue(r.spoken.hasPrefix("Found mug"))
        XCTAssertEqual(r.trace.outcome, "success")
        XCTAssertEqual(r.trace.target, "a")
        XCTAssertTrue(r.notHereTrackIDs.isEmpty)
    }

    func testRejectsLowImageSimilarityThenAcceptsNext() async {
        let d = FakeDriver(), im = FakeImages()
        im.byX[1] = [[0, 1]]                                    // s_img = 0 -> not here
        im.byX[2] = [[0.8, 0.6]]                                // identical to track b: s_img 1, s_text 0.8 >= 0.9*0.8
        let r = await make(driver: d, images: im).find(phrase: "mug", tracks: tracks())
        XCTAssertEqual(r.outcome, .success)
        XCTAssertEqual(r.foundTrackID, "b")
        XCTAssertEqual(r.notHereTrackIDs, ["a"])
        XCTAssertEqual(r.attempts.map { $0.verdict }, [.notHere, .accepted])
        XCTAssertTrue(r.attempts[0].reason.contains("s_img below tau_img"))
    }

    func testTextCheckAloneCanReject() async {
        // Crop matches track b's embedding (s_img 1.0) but is far from the query, so s_text < 0.9 * 0.8.
        let ts = [Track(id: "b", position: SIMD3(2, 0, 2), embedding: [0.8, 0.6], sightings: 4, persistence: 1.0)]
        let d = FakeDriver(), im = FakeImages()
        im.byX[2] = [[0.3, 0.954]]                              // cos to q ~0.30; to track ~0.81 (>= 0.80)
        var cfg = FindConfig(); cfg.tauImg = 0.5
        let r = await make(driver: d, images: im, config: cfg).find(phrase: "mug", tracks: ts)
        XCTAssertEqual(r.outcome, .notFound)
        XCTAssertTrue(r.attempts[0].reason.contains("s_text below"))
        XCTAssertFalse(r.attempts[0].reason.contains("s_img below"))
    }

    func testStopsAfterThreeCandidates() async {
        let d = FakeDriver(), im = FakeImages()
        for x: Float in [1, 2, 3, 4] { im.byX[x] = [[0, 1]] }  // nothing passes
        let r = await make(driver: d, images: im).find(phrase: "mug", tracks: tracks())
        XCTAssertEqual(r.outcome, .notFound)
        XCTAssertEqual(d.visited.map { $0.x }, [1, 2, 3])
        XCTAssertEqual(Set(r.notHereTrackIDs), ["a", "b", "c"])
        XCTAssertTrue(r.spoken.hasPrefix("I couldn't confirm mug"))
        XCTAssertEqual(r.trace.attempts.count, 3)
    }

    func testUnreachableCandidateIsSkippedAndNearMissesAccumulate() async {
        let d = FakeDriver(), im = FakeImages()
        d.script[1] = ApproachReport(outcome: .failed(reason: "blocked"), nearMisses: 2)
        d.script[2] = ApproachReport(outcome: .arrived, nearMisses: 1)
        im.byX[2] = [[0.8, 0.6]]
        let r = await make(driver: d, images: im).find(phrase: "mug", tracks: tracks())
        XCTAssertEqual(r.outcome, .success)
        XCTAssertEqual(r.foundTrackID, "b")
        XCTAssertEqual(r.attempts[0].verdict, .unreachable)
        XCTAssertFalse(r.notHereTrackIDs.contains("a"))         // never looked, so not marked "not here"
        XCTAssertEqual(r.trace.nearMisses, 3)
    }

    func testCancelledDriveAborts() async {
        let d = FakeDriver(), im = FakeImages()
        d.script[1] = ApproachReport(outcome: .cancelled)
        let r = await make(driver: d, images: im).find(phrase: "mug", tracks: tracks())
        XCTAssertEqual(r.outcome, .aborted)
        XCTAssertEqual(d.visited.count, 1)
        XCTAssertEqual(r.trace.outcome, "aborted")
    }

    func testCameraFailureAndEmptyCropsMeanNoView() async {
        let d = FakeDriver(), im = FakeImages()
        im.failing = true
        var r = await make(driver: d, images: im).find(phrase: "mug", tracks: Array(tracks().prefix(1)))
        XCTAssertEqual(r.attempts[0].verdict, .noView)
        im.failing = false                                      // byX empty -> zero crops
        r = await make(driver: d, images: im).find(phrase: "mug", tracks: Array(tracks().prefix(1)))
        XCTAssertEqual(r.attempts[0].verdict, .noView)
        XCTAssertEqual(r.outcome, .notFound)
    }

    func testEmptyMemorySpeaksHonestlyAndDrivesNowhere() async {
        let d = FakeDriver(), im = FakeImages()
        let r = await make(driver: d, images: im).find(phrase: "mug", tracks: [])
        XCTAssertEqual(r.outcome, .notFound)
        XCTAssertTrue(d.visited.isEmpty)
        XCTAssertEqual(r.spoken, "I don't have anything in memory that matches mug.")
    }

    func testTraceJSONUsesEvalRunFieldNames() async throws {
        let d = FakeDriver(), im = FakeImages()
        im.byX[1] = [[1, 0]]
        let r = await make(driver: d, images: im).find(phrase: "mug", tracks: tracks(), queryID: "q07", targetTrackID: "a")
        let obj = try JSONSerialization.jsonObject(with: r.trace.jsonData()) as! [String: Any]
        for k in ["query_id", "text", "target", "ranked", "outcome", "time_s", "near_misses", "notes"] {
            XCTAssertNotNil(obj[k], k)
        }
        let first = (obj["ranked"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(first.keys), ["track_id", "score", "x", "z"])
        XCTAssertEqual(obj["outcome"] as? String, "success")
        XCTAssertEqual(obj["time_s"] as? Double, 1.0)         
    }
}
