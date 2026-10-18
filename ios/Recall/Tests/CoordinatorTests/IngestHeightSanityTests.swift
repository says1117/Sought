import XCTest
import simd
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(Memory)
import Memory
#endif
#if canImport(PerceptionCore)
import PerceptionCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

// Live data 2026-10-18: whole keyframes lifted 4-5 m under the floor (bad camera pose) were stored as tracks and
// polluted association and find. Perception must not write impossible heights.

final class IngestHeightSanityTests: XCTestCase {
    /// Object `i` sits 1 m from its neighbours with its own one-hot embedding, so each one is a separate track.
    private func object(_ i: Int, height: Float) -> PerceivedObject {
        var e = [Float](repeating: 0, count: 16); e[i] = 1
        return PerceivedObject(observation: Observation(position: SIMD3(Float(i), 0, -2), embedding: e, confidence: 0.9, time: 5),
                               heightAboveFloor: height, box: NormBox(x: 0, y: 0, w: 1, h: 1), origin: .grid, thumbnailJPEG: nil)
    }

    func testOnlyNormalTrackingAdmitsAKeyframe() {
        XCTAssertTrue(MemoryIngestor.admitsKeyframe(tracking: .normal))
        XCTAssertFalse(MemoryIngestor.admitsKeyframe(tracking: .limited))
        XCTAssertFalse(MemoryIngestor.admitsKeyframe(tracking: .notAvailable))
    }

    func testImpossibleHeightsAreDroppedAndTheRestWritten() throws {
        let store = try TrackStore(path: ":memory:")
        let ing = MemoryIngestor(store: store)
        let objects = [object(0, height: 0.2), object(1, height: -0.25), object(2, height: 3.5),
                       object(3, height: -4.7), object(4, height: 3.6), object(5, height: .nan)]
        let s = try ing.ingest(objects)
        XCTAssertEqual(s, .init(matched: 0, created: 3, implausible: 3))
        XCTAssertFalse(s.badPose, "a minority under the floor is per-object noise, not a bad pose")
        let xs = try store.allTracks().map { $0.position.x }.sorted()
        XCTAssertEqual(xs, [0, 1, 2], "floor noise (-0.25 m) and the 3.5 m edge are kept")
    }

    func testKeyframeMostlyUnderTheFloorIsDroppedWhole() throws {
        let store = try TrackStore(path: ":memory:")
        try store.upsert(Track(id: "obj_a", position: SIMD3(0, 0, -2), embedding: object(0, height: 0).observation.embedding,
                               sightings: 3, persistence: 0.9), height: 0.2)
        let ing = MemoryIngestor(store: store)
        // The live case: most objects of one keyframe about 4.7 m under the floor, a couple that happen to look fine.
        let objects = (0..<11).map { object($0, height: -4.7) } + [object(11, height: 0.4), object(0, height: 0.2)]
        let s = try ing.ingest(objects)
        XCTAssertTrue(s.badPose)
        XCTAssertEqual(s, .init(matched: 0, created: 0, implausible: 13, badPose: true))
        let tracks = try store.allTracks()
        XCTAssertEqual(tracks.map(\.id), ["obj_a"], "nothing created, even from the plausible-looking objects")
        XCTAssertEqual(tracks.first?.sightings, 3, "the existing track is not matched by the bad keyframe")
    }

    func testHalfUnderTheFloorIsNotABadPose() throws {
        let store = try TrackStore(path: ":memory:")
        let s = try MemoryIngestor(store: store).ingest([object(0, height: -4.7), object(1, height: 0.5)])
        XCTAssertEqual(s, .init(matched: 0, created: 1, implausible: 1))
        XCTAssertEqual(try store.allTracks().count, 1)
    }
}
