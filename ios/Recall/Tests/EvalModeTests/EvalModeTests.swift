import XCTest
import Foundation
#if canImport(Memory)
import Memory
#endif
#if canImport(Retrieval)
import Retrieval
#endif
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(EvalCore)
import EvalCore
#endif

// Everything below is SAMPLE/FIXTURE data for unit tests. None of it is a measurement and none of it
// is ever written under evals/results/ (tests write to a temp directory).

private struct EvalTestEncoder: TextEncoder {
    var table: [String: [Float]]
    func encode(_ text: String) throws -> [Float] {
        guard let v = table[text] else { throw NSError(domain: "EvalTestEncoder", code: 1) }
        return v
    }
}


/// FindTrace has no public initializer, so fixtures are decoded from its JSON form (the real wire format).
private func evalTestTrace(outcome: String, found: String?, ranked: [(String, Double, Double, Double)],
                           timeS: Double = 12.5, nearMisses: Int = 2, attempts: [[String: Any]] = []) throws -> FindTrace {
    var json: [String: Any] = [
        "query_id": "SAMPLE_q", "text": "SAMPLE bag", "outcome": outcome, "time_s": timeS, "near_misses": nearMisses,
        "notes": "", "attempts": attempts, "spoken": "",
        "ranked": ranked.map { ["track_id": $0.0, "score": $0.1, "x": $0.2, "z": $0.3] },
    ]
    if let f = found { json["found_track_id"] = f }
    return try JSONDecoder().decode(FindTrace.self, from: JSONSerialization.data(withJSONObject: json))
}

private enum EvalTestFixtures {
    // FIXTURE: three SAMPLE objects, two bags (ambiguous) and one mug.
    static let truth = EvalGroundTruth(objects: [
        EvalGroundTruthObject(id: "SAMPLE_bag_a", label: "SAMPLE bag A", x: 1.0, z: -2.0),
        EvalGroundTruthObject(id: "SAMPLE_bag_b", label: "SAMPLE bag B", x: -1.0, z: 1.0),
        EvalGroundTruthObject(id: "SAMPLE_mug", label: "SAMPLE mug", x: 0.0, z: 0.0),
    ])

    // FIXTURE queries in the YAML subset, with comments, quotes, flow and block lists.
    static let yaml = """
    # FIXTURE queries, SAMPLE only
    - id: q01
      text: "SAMPLE mug"   # trailing comment
      type: exact
      target_object_id: SAMPLE_mug
    - id: q02
      text: 'SAMPLE bag'
      type: ambiguous
      target_object_id: [SAMPLE_bag_a, SAMPLE_bag_b]
    - id: q03
      text: the SAMPLE thing: with colon
      type: descriptive
      target_object_id:
        - SAMPLE_mug
    """

    // FIXTURE tracks, confirmed (sightings >= 2). Embeddings are 3-d unit-ish vectors.
    static let tracks: [Track] = [
        Track(id: "trk_1", position: SIMD3(1.1, 0, -2.0), embedding: [1, 0, 0], sightings: 3, persistence: 1),
        Track(id: "trk_2", position: SIMD3(-1.0, 0, 1.1), embedding: [0.9, 0.1, 0], sightings: 3, persistence: 1),
        Track(id: "trk_3", position: SIMD3(0.05, 0, 0.0), embedding: [0, 1, 0], sightings: 3, persistence: 1),
        Track(id: "trk_far", position: SIMD3(4, 0, 4), embedding: [0, 0, 1], sightings: 3, persistence: 1),
    ]

    static let encoder = EvalTestEncoder(table: [
        "SAMPLE mug": [0, 1, 0], "a photo of SAMPLE mug": [0, 1, 0],
        "SAMPLE bag": [1, 0, 0], "a photo of SAMPLE bag": [1, 0, 0],
        "the SAMPLE thing: with colon": [0, 0, 1], "a photo of the SAMPLE thing: with colon": [0, 0, 1],
    ])
}

final class EvalModeTests: XCTestCase {
    // MARK: Ground truth

    func testAnnotatorAddsObjectsWithSequentialIDsAndRoundTrips() throws {
        let a = EvalGroundTruthAnnotator()
        let o1 = try a.addObject(label: "  SAMPLE slipper ", at: EvalFloorPoint(x: 1.25, z: -0.5))
        let o2 = try a.addObject(label: "SAMPLE box", at: EvalFloorPoint(x: 0, z: 2))
        XCTAssertEqual(o1.id, "obj_01"); XCTAssertEqual(o1.label, "SAMPLE slipper")
        XCTAssertEqual(o2.id, "obj_02")
        try a.remove(id: "obj_01")
        XCTAssertEqual(try a.addObject(label: "SAMPLE cup", at: EvalFloorPoint(x: 3, z: 3)).id, "obj_01")

        let data = try a.exportData()
        let decoded = try EvalGroundTruth.decode(data)
        XCTAssertEqual(decoded, a.truth)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["objects", "changes"])
        let first = try XCTUnwrap((json["objects"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["id", "label", "x", "z"])
    }

    func testAnnotatorRejectsBadInputAndUsesRaycastSeam() throws {
        struct Hit: EvalFloorRaycasting {
            func floorPoint(atNormalizedX x: Double, y: Double) -> EvalFloorPoint? { x < 0.5 ? EvalFloorPoint(x: x * 10, z: y * 10) : nil }
        }
        let a = EvalGroundTruthAnnotator()
        XCTAssertThrowsError(try a.addObject(label: "  ", at: EvalFloorPoint(x: 0, z: 0))) { XCTAssertEqual($0 as? EvalAnnotationError, .emptyLabel) }
        XCTAssertThrowsError(try a.addObject(label: "x", at: EvalFloorPoint(x: .nan, z: 0)))
        XCTAssertThrowsError(try a.addObject(label: "x", tapX: 0.9, tapY: 0.1, raycaster: Hit())) { XCTAssertEqual($0 as? EvalAnnotationError, .noFloorHit) }
        let o = try a.addObject(label: "SAMPLE x", tapX: 0.2, tapY: 0.3, raycaster: Hit())
        XCTAssertEqual(o.x, 2.0, accuracy: 1e-9); XCTAssertEqual(o.z, 3.0, accuracy: 1e-9)
        try a.move(id: o.id, to: EvalFloorPoint(x: 5, z: 6))
        XCTAssertEqual(a.objects[0].x, 5)
        XCTAssertThrowsError(try a.move(id: "nope", to: EvalFloorPoint(x: 0, z: 0)))
    }

    func testGroundTruthKeepsChangesFromTheSharedShape() throws {
        // FIXTURE in the shape of evals/schemas/ground_truth.schema.json
        let text = """
        {"objects":[{"id":"SAMPLE_a","label":"SAMPLE","x":1,"z":2}],
         "changes":[{"id":"c1","type":"moved","object_id":"SAMPLE_a","from":{"x":1,"z":2},"to":{"x":2,"z":2}}]}
        """
        let t = try EvalGroundTruth.decode(Data(text.utf8))
        XCTAssertEqual(t.changes.first?.objectID, "SAMPLE_a")
        XCTAssertEqual(try EvalGroundTruth.decode(t.jsonData()), t)
    }

    // MARK: Queries

    func testYAMLLoaderOnLabeledFixture() throws {
        let qs = try EvalQueryLoader.load(EvalTestFixtures.yaml)
        XCTAssertEqual(qs.count, 3)
        XCTAssertEqual(qs[0], EvalQuery(id: "q01", text: "SAMPLE mug", type: .exact, targets: ["SAMPLE_mug"]))
        XCTAssertEqual(qs[1].text, "SAMPLE bag")
        XCTAssertEqual(qs[1].targets, ["SAMPLE_bag_a", "SAMPLE_bag_b"])
        XCTAssertEqual(qs[1].type, .ambiguous)
        XCTAssertEqual(qs[2].text, "the SAMPLE thing: with colon")
        XCTAssertEqual(qs[2].targets, ["SAMPLE_mug"])
    }

    func testLoaderAcceptsJSONIncludingTheEmptyPlaceholder() throws {
        XCTAssertEqual(try EvalQueryLoader.load("[]"), [])
        let qs = try EvalQueryLoader.load(#"[{"id":"q1","text":"SAMPLE","type":"attribute","target_object_id":["a","b"]}]"#)
        XCTAssertEqual(qs.first?.targets, ["a", "b"])
    }

    func testLoaderRejectsBadQueries() {
        XCTAssertThrowsError(try EvalQueryLoader.load("- id: q1\n  text: t\n  type: bogus\n  target_object_id: a")) {
            XCTAssertEqual($0 as? EvalQueryError, .invalidType(queryID: "q1", value: "bogus"))
        }
        XCTAssertThrowsError(try EvalQueryLoader.load("- id: q1\n  text: t\n  type: exact")) {
            XCTAssertEqual($0 as? EvalQueryError, .missingField(queryIndex: 0, field: "target_object_id"))
        }
        XCTAssertThrowsError(try EvalQueryLoader.load("- id: q1\n  text: t\n  type: exact\n  target_object_id: a\n- id: q1\n  text: u\n  type: exact\n  target_object_id: a")) {
            XCTAssertEqual($0 as? EvalQueryError, .duplicateID("q1"))
        }
        XCTAssertThrowsError(try EvalQueryLoader.load("id: q1"))
    }

    // MARK: Scoring

    func testOutcomeSuccessWrongObjectNotFound() {
        let r = { (id: String) in EvalRankedEntry(trackID: id, score: 0.3, x: 0, z: 0) }
        XCTAssertEqual(EvalScoring.retrievalOutcome(ranked: [r("a"), r("b")], targets: ["a"]), .success)
        XCTAssertEqual(EvalScoring.retrievalOutcome(ranked: [r("b"), r("a")], targets: ["a"]), .wrongObject)
        XCTAssertTrue(EvalScoring.top3Hit(ranked: [r("b"), r("c"), r("a")], targets: ["a"]))
        XCTAssertFalse(EvalScoring.top3Hit(ranked: [r("b"), r("c"), r("d"), r("a")], targets: ["a"]))
        XCTAssertEqual(EvalScoring.retrievalOutcome(ranked: [], targets: ["a"]), .notFound)
    }

    func testPositionErrorAndResolveRadius() {
        let t = EvalTestFixtures.truth
        XCTAssertEqual(EvalScoring.positionError(x: 1.3, z: -2.4, targets: ["SAMPLE_bag_a"], in: t)!, 0.5, accuracy: 1e-9)
        // Two valid targets: the nearer one counts.
        XCTAssertEqual(EvalScoring.positionError(x: -1.0, z: 1.2, targets: ["SAMPLE_bag_a", "SAMPLE_bag_b"], in: t)!, 0.2, accuracy: 1e-9)
        XCTAssertNil(EvalScoring.positionError(x: 0, z: 0, targets: ["missing"], in: t))
        XCTAssertEqual(EvalScoring.resolve(x: 1.1, z: -2.0, in: t)?.id, "SAMPLE_bag_a")
        XCTAssertNil(EvalScoring.resolve(x: 4, z: 4, in: t))
    }

    // MARK: Retrieval runner

    private func runFixture(queries: [EvalQuery]) throws -> EvalRawRun {
        var t = 0.0
        let runner = EvalRetrievalRunner(retriever: Retriever(encoder: EvalTestFixtures.encoder),
                                         clock: { t += 0.25; return t })
        return try runner.run(queries: queries, tracks: EvalTestFixtures.tracks, truth: EvalTestFixtures.truth,
                              variant: "clip_full_proposals", commit: "SAMPLE", phoneHeight: "SAMPLE")
    }

    func testRetrievalRunProducesSpecShapedFile() throws {
        let run = try runFixture(queries: EvalQueryLoader.load(EvalTestFixtures.yaml))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EvalModeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try run.write(toDirectory: dir, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(url.lastPathComponent, "run_19700101T000000Z_retrieval.json")
        XCTAssertFalse(url.path.contains("evals/results"))

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["kind", "commit", "variant", "phone_height", "thresholds", "trials"])
        XCTAssertEqual(obj["kind"] as? String, "retrieval")
        XCTAssertEqual(obj["variant"] as? String, "clip_full_proposals")
        let thresholds = try XCTUnwrap(obj["thresholds"] as? [String: Double])
        XCTAssertNotNil(thresholds["assoc_sim"])
        let trials = try XCTUnwrap(obj["trials"] as? [[String: Any]])
        XCTAssertEqual(trials.count, 3)
        let required: Set<String> = ["query_id", "text", "target", "ranked", "outcome", "time_s", "near_misses", "notes"]
        for tr in trials {
            XCTAssertTrue(required.isSubset(of: Set(tr.keys)))
            let ranked = try XCTUnwrap(tr["ranked"] as? [[String: Any]])
            XCTAssertTrue(Set(["track_id", "score", "x", "z"]).isSubset(of: Set(ranked[0].keys)))
            XCTAssertTrue(["success", "wrong_object", "not_found", "aborted"].contains(tr["outcome"] as? String ?? ""))
        }
        XCTAssertEqual(trials[0]["target"] as? String, "SAMPLE_mug")
        XCTAssertEqual(trials[1]["target"] as? [String], ["SAMPLE_bag_a", "SAMPLE_bag_b"])
        XCTAssertEqual(try JSONDecoder().decode(EvalRawRun.self, from: Data(contentsOf: url)), run)
    }

    func testRetrievalOutcomesAndPositionError() throws {
        let run = try runFixture(queries: EvalQueryLoader.load(EvalTestFixtures.yaml))
        // q01: mug track is top-1 and resolves to the mug object.
        XCTAssertEqual(run.trials[0].outcome, .success)
        XCTAssertEqual(run.trials[0].ranked[0].trackID, "SAMPLE_mug")
        XCTAssertEqual(run.trials[0].ranked[0].memoryTrackID, "trk_3")
        XCTAssertEqual(run.trials[0].positionErrorM!, 0.05, accuracy: 1e-6)
        // q02 (ambiguous, two valid targets): top-1 is bag A, top-3 includes bag B. Success either way.
        XCTAssertEqual(run.trials[1].outcome, .success)
        XCTAssertTrue(run.trials[1].ranked.prefix(2).map { $0.trackID }.contains("SAMPLE_bag_b"))
        // q03: the far, unresolved track wins top-1 for the descriptive query but the target is the mug.
        XCTAssertEqual(run.trials[2].outcome, .wrongObject)
        XCTAssertEqual(run.trials[2].ranked[0].trackID, "trk_far")
        XCTAssertTrue(run.trials[2].notes.contains("top3="))
    }

    func testAmbiguousQueryCountsEitherTargetAndPicksNearer() throws {
        // Only bag B is stored: still a success for the ambiguous query.
        let runner = EvalRetrievalRunner(retriever: Retriever(encoder: EvalTestFixtures.encoder))
        let q = EvalQuery(id: "q02", text: "SAMPLE bag", type: .ambiguous, targets: ["SAMPLE_bag_a", "SAMPLE_bag_b"])
        let only = [EvalTestFixtures.tracks[1]]
        let run = try runner.run(queries: [q], tracks: only, truth: EvalTestFixtures.truth, variant: "clip_yolo_proposals",
                                 commit: "SAMPLE", phoneHeight: "SAMPLE")
        XCTAssertEqual(run.trials[0].outcome, .success)
        XCTAssertEqual(run.trials[0].ranked[0].trackID, "SAMPLE_bag_b")
    }

    func testNoTracksIsNotFoundAndEncoderFailureIsAborted() throws {
        let runner = EvalRetrievalRunner(retriever: Retriever(encoder: EvalTestFixtures.encoder))
        let q = EvalQuery(id: "q1", text: "SAMPLE mug", type: .exact, targets: ["SAMPLE_mug"])
        let none = try runner.run(queries: [q], tracks: [], truth: EvalTestFixtures.truth, variant: "clip_full_proposals", commit: "SAMPLE", phoneHeight: "SAMPLE")
        XCTAssertEqual(none.trials[0].outcome, .notFound)
        let bad = EvalQuery(id: "q2", text: "SAMPLE unknown phrase", type: .exact, targets: ["SAMPLE_mug"])
        let aborted = try runner.run(queries: [bad], tracks: EvalTestFixtures.tracks, truth: EvalTestFixtures.truth, variant: "clip_full_proposals", commit: "SAMPLE", phoneHeight: "SAMPLE")
        XCTAssertEqual(aborted.trials[0].outcome, .aborted)
    }

    func testRunnerRefusesUnimplementedVariantsAndUnknownTargets() {
        let runner = EvalRetrievalRunner(retriever: Retriever(encoder: EvalTestFixtures.encoder))
        let q = EvalQuery(id: "q1", text: "SAMPLE mug", type: .exact, targets: ["SAMPLE_mug"])
        for v in ["yolo_labels_only", "clip_plus_gemini_rerank", "clip_plus_adapter", "made_up"] {
            XCTAssertThrowsError(try runner.run(queries: [q], tracks: [], truth: EvalTestFixtures.truth, variant: v, commit: "c", phoneHeight: "h"))
        }
        let ghost = EvalQuery(id: "q9", text: "SAMPLE mug", type: .exact, targets: ["ghost"])
        XCTAssertThrowsError(try runner.run(queries: [ghost], tracks: [], truth: EvalTestFixtures.truth, variant: "clip_full_proposals", commit: "c", phoneHeight: "h")) {
            XCTAssertEqual($0 as? EvalRunError, .unknownTarget(queryID: "q9", objectID: "ghost"))
        }
        XCTAssertThrowsError(try runner.run(queries: [q], tracks: [], truth: EvalGroundTruth(), variant: "clip_full_proposals", commit: "c", phoneHeight: "h")) {
            XCTAssertEqual($0 as? EvalRunError, .emptyGroundTruth)
        }
    }

    // MARK: Find logger

    func testFindLoggerRecordsTraceAndFlagsWrongObject() throws {
        let logger = EvalFindTrialLogger(truth: EvalTestFixtures.truth)
        let ranked = [("trk_1", 0.9, 1.1, -2.0), ("trk_3", 0.5, 0.05, 0.0)]
        let t1 = logger.record(trace: try evalTestTrace(outcome: "success", found: "trk_1", ranked: ranked),
                               queryID: "q1", targets: ["SAMPLE_bag_a"], arrivalDistM: 0.4)
        XCTAssertEqual(t1.outcome, .success)
        XCTAssertEqual(t1.acceptedTrackID, "SAMPLE_bag_a")
        XCTAssertEqual(t1.nearMisses, 2)
        XCTAssertEqual(t1.timeS, 12.5, accuracy: 1e-9)
        XCTAssertEqual(t1.arrivalDistM, 0.4)

        XCTAssertEqual(logger.record(trace: try evalTestTrace(outcome: "success", found: "trk_3", ranked: ranked),
                                     queryID: "q2", targets: ["SAMPLE_bag_a"]).outcome, .wrongObject)
        XCTAssertEqual(logger.record(trace: try evalTestTrace(outcome: "not_found", found: nil, ranked: ranked),
                                     queryID: "q3", targets: ["SAMPLE_bag_a"]).outcome, .notFound)
        XCTAssertEqual(logger.record(trace: try evalTestTrace(outcome: "aborted", found: nil, ranked: ranked),
                                     queryID: "q4", targets: ["SAMPLE_bag_a"]).outcome, .aborted)

        let run = try logger.makeRun(variant: "clip_plus_arrival_check", commit: "SAMPLE", phoneHeight: "SAMPLE", tauImg: 0.8, textFraction: 0.9)
        XCTAssertEqual(run.kind, .find)
        XCTAssertEqual(run.thresholds["tau_img"], 0.8)
        XCTAssertEqual(run.trials.count, 4)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: run.jsonData()) as? [String: Any])
        XCTAssertEqual(obj["kind"] as? String, "find")
        XCTAssertThrowsError(try logger.makeRun(variant: "clip_full_proposals", commit: "c", phoneHeight: "h", tauImg: 0.8, textFraction: 0.9))
    }

    func testFindLoggerRecordsAttemptDetail() throws {
        let logger = EvalFindTrialLogger(truth: EvalTestFixtures.truth)
        let attempt: [String: Any] = ["track_id": "trk_1", "verdict": "not_here", "retrieval_score": 0.8,
                                      "s_img": 0.7, "s_text": 0.2, "reason": "s_img below tau_img"]
        let trace = try evalTestTrace(outcome: "not_found", found: nil, ranked: [], timeS: 3, nearMisses: 0, attempts: [attempt])
        let t = logger.record(trace: trace, queryID: "q1", targets: ["SAMPLE_bag_a"])
        XCTAssertEqual(t.attempts?.first?.verdict, "not_here")
        XCTAssertEqual(try XCTUnwrap(t.attempts?.first?.sImg), 0.7, accuracy: 1e-6)
    }

    // MARK: View model

    func testViewModelRefusesToRunWithoutWiring() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EvalVM-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = EvalViewModel(directory: dir)
        XCTAssertFalse(vm.canRun)
        vm.runRetrieval()
        XCTAssertNil(vm.lastRun)
        XCTAssertTrue(vm.status.contains("nothing was run"))
    }

    func testViewModelEndToEndWithFixtures() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EvalVM-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try EvalTestFixtures.yaml.write(to: dir.appendingPathComponent("queries.yaml"), atomically: true, encoding: .utf8)
        let vm = EvalViewModel(directory: dir, tracks: { EvalTestFixtures.tracks }, encoder: EvalTestFixtures.encoder,
                               currentPoint: { EvalFloorPoint(x: 0.1, z: 0.2) }, commit: "SAMPLE", phoneHeight: "SAMPLE")
        vm.annotator.replace(with: EvalTestFixtures.truth)
        vm.saveGroundTruth()
        vm.annotator.replace(with: EvalGroundTruth())
        vm.loadGroundTruth()
        XCTAssertEqual(vm.annotator.objects.count, 3)
        vm.addObjectAtCurrentPose(label: "SAMPLE extra")
        XCTAssertEqual(vm.annotator.objects.last?.x, 0.1)
        vm.loadQueries()
        XCTAssertEqual(vm.queries.count, 3)
        XCTAssertTrue(vm.canRun)
        vm.runRetrieval()
        let url = try XCTUnwrap(vm.exportURL)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("_retrieval.json"))
        XCTAssertEqual(vm.outcomeCounts.map { $0.1 }.reduce(0, +), 3)
    }
}
