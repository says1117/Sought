import XCTest
import SQLite3
import simd
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(Memory)
import Memory
#endif
#if canImport(PerceptionCore)
import PerceptionCore
#endif
#if canImport(TeachCore)
import TeachCore
#endif

// PR 39 review, world-frame P1 (find loop A, round 3): tracks belong to the saved map that produced them, and an
// ingest validates the frame and writes as one step. Prefixed Map* because the RecallTests bundle shares one module.

private func mapObs(_ x: Float, _ e: [Float]) -> PerceivedObject {
    PerceivedObject(observation: Observation(position: SIMD3(x, 0, -2), embedding: e, confidence: 0.9, time: 5),
                    heightAboveFloor: 0.2, box: NormBox(x: 0, y: 0, w: 1, h: 1), origin: .grid, thumbnailJPEG: nil)
}

private func mapTrack(_ id: String) -> Track {
    Track(id: id, position: SIMD3(0, 0, -2), embedding: [1, 0, 0, 0], sightings: 3, persistence: 0.9)
}

/// Gate that can change under an ingest: `performIfCurrent` is the non-atomic default, like a conformer without a lock.
private final class MapRacyFrame: CoordinatorFrameValidity {
    var relocalized = true
    var generation = 1
    var activeMapId: String? = "map-A"
    func isInCurrentFrame(createdAt isoTimestamp: String) -> Bool { false }
}

final class MapIdentityTests: XCTestCase {
    private var paths: [String] = []
    override func tearDown() {
        paths.forEach { try? FileManager.default.removeItem(atPath: $0) }
        paths = []
    }
    private func tempPath() -> String {
        let p = NSTemporaryDirectory() + "mapid-\(UUID().uuidString).sqlite"
        paths.append(p)
        return p
    }

    // MARK: visibility by map id

    func testTracksOfMapAAreInvisibleInMapBAndReturnWhenAIsLoadedAgain() throws {
        var active: String? = "map-A"
        let store = try TrackStore(path: ":memory:", scope: { active })
        try store.upsert(mapTrack("obj_a"), mapId: "map-A")
        try store.upsert(mapTrack("obj_b"), mapId: "map-B")
        XCTAssertEqual(try store.allTracks().map(\.id), ["obj_a"])
        active = "map-B"
        XCTAssertEqual(try store.allTracks().map(\.id), ["obj_b"], "A's tracks are not visible under B")
        active = nil
        XCTAssertTrue(try store.allTracks().isEmpty, "no map identity: nothing is visible")
        active = "map-A"
        XCTAssertEqual(try store.allTracks().map(\.id), ["obj_a"], "relocalizing to A shows A's tracks again")
    }

    func testResetOrFreshSessionHidesOldTracksAndNeverMixes() throws {
        let gate = WorldFrameGate()
        let store = try TrackStore(path: ":memory:", scope: { gate.activeMapId })
        gate.sessionStarted(loadedSavedMap: true, mapId: "map-A")
        gate.update(tracking: .normal, mapping: .mapped)
        let ing = MemoryIngestor(store: store, frame: gate)
        XCTAssertEqual(try ing.ingest([mapObs(0, [1, 0, 0, 0])]), .init(matched: 0, created: 1))
        XCTAssertEqual(try store.allTracks().count, 1)

        gate.sessionStarted(loadedSavedMap: false)            // Teach reset / no usable map
        let fresh = try XCTUnwrap(gate.activeMapId)
        XCTAssertNotEqual(fresh, "map-A")
        XCTAssertTrue(try store.allTracks().isEmpty, "old map's tracks are hidden")
        XCTAssertTrue(try ing.ingest([mapObs(0, [1, 0, 0, 0])]).rejected, "not recognised yet: nothing is written")
        gate.update(tracking: .normal, mapping: .mapped)
        XCTAssertFalse(gate.relocalized, "no saved map to recognise")

        gate.sessionStarted(loadedSavedMap: true, mapId: "map-A")   // the real map comes back
        XCTAssertEqual(try store.allTracks().count, 1, "A's tracks are visible again, unchanged")
        XCTAssertNotEqual(gate.activeMapId, fresh)
    }

    func testIngestAssociatesOnlyWithTheActiveMapsTracks() throws {
        let store = try TrackStore(path: ":memory:")
        try store.upsert(mapTrack("obj_old"), mapId: "map-A")
        let frame = MapRacyFrame(); frame.activeMapId = "map-B"
        let s = try MemoryIngestor(store: store, frame: frame).ingest([mapObs(0, [1, 0, 0, 0])], generation: 1)
        XCTAssertEqual(s, .init(matched: 0, created: 1), "same place, same embedding, but another map: a new track")
        XCTAssertEqual(try store.allTracks(mapId: "map-A").map(\.id), ["obj_old"])
        XCTAssertEqual(try store.allTracks(mapId: "map-A").first?.sightings, 3, "A's track untouched")
        XCTAssertEqual(try store.allTracks(mapId: "map-B").count, 1)
    }

    func testPurgeOtherMapsDeletesEverythingExceptTheLoadedMap() throws {
        let path = tempPath()
        let store = try TrackStore(path: path)
        try store.upsert(mapTrack("obj_a"), mapId: "map-A")
        try store.upsert(mapTrack("obj_b"), mapId: "map-B")
        XCTAssertEqual(try store.purgeOtherMaps(keeping: "map-A"), 1)
        XCTAssertEqual(try store.allTracks(mapId: "map-B").count, 0)
        XCTAssertEqual(try store.allTracks(mapId: "map-A").count, 1)
    }

    func testFindRefusesStoredDestinationsUntilRelocalized() async throws {
        let gate = WorldFrameGate()
        let rig = try CoordIntegrationRig(encoders: CoordIntegrationRig.working(), frame: gate, trackMapId: "map-A")
        gate.sessionStarted(loadedSavedMap: true, mapId: "map-A")
        try await rig.coordinator.execute(.findObject(description: "blue backpack"))
        XCTAssertEqual(rig.robot.movingCommands, 0)
        XCTAssertTrue(rig.speaker.said.contains(CoordinatorConfig.notRecognisedSpoken), "\(rig.speaker.said)")
    }

    // MARK: migration

    func testOldDatabaseWithoutMapIdColumnOpensMigratesAndOldRowsAreInvisible() throws {
        let path = tempPath()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        // The contract's tracks table exactly as shipped before map identity.
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE tracks (id TEXT PRIMARY KEY, label TEXT, label_source TEXT, description TEXT,
          x REAL, y REAL, z REAL, height_above_floor REAL, embedding BLOB, embedding_dim INTEGER,
          first_seen TEXT, last_seen TEXT, sightings INTEGER, persistence REAL, media_id TEXT, active INTEGER DEFAULT 1);
        INSERT INTO tracks (id,x,y,z,embedding,embedding_dim,sightings,persistence,last_seen,active)
        VALUES ('obj_legacy',0,0,-2, zeroblob(8), 4, 3, 0.9, '2026-01-01T00:00:00Z', 1);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = try TrackStore(path: path)               // migrates in place
        XCTAssertTrue(try store.allTracks(mapId: TrackStore.defaultMapId).isEmpty, "unknown-map rows match no map")
        XCTAssertTrue(try store.allTracks(mapId: "map-A").isEmpty)
        try store.upsert(mapTrack("obj_new"), mapId: "map-A")
        XCTAssertEqual(try store.allTracks(mapId: "map-A").map(\.id), ["obj_new"])
        let again = try TrackStore(path: path)               // reopening a migrated database is fine
        XCTAssertEqual(try again.allTracks(mapId: "map-A").count, 1)
        XCTAssertEqual(try again.purgeOtherMaps(keeping: "map-A"), 1, "the legacy row is cleaned up once a map is loaded")
    }

    // MARK: atomic ingest

    func testFrameChangingDuringIngestPersistsNothing() throws {
        let store = try TrackStore(path: ":memory:")
        try store.upsert(mapTrack("obj_a"), mapId: "map-A")
        let frame = MapRacyFrame()
        let ing = MemoryIngestor(store: store, frame: frame)
        ing.beforeWrite = { frame.generation += 1 }           // frame changes between validation and the writes
        let s = try ing.ingest([mapObs(0, [1, 0, 0, 0]), mapObs(5, [0, 1, 0, 0])], generation: 1)
        XCTAssertTrue(s.rejected)
        XCTAssertEqual(try store.allTracks(mapId: "map-A").count, 1, "no new track")
        XCTAssertEqual(try store.allTracks(mapId: "map-A").first?.sightings, 3, "no sightings bump from the old frame")
    }

    func testMapChangingDuringIngestPersistsNothing() throws {
        let store = try TrackStore(path: ":memory:")
        let frame = MapRacyFrame()
        let ing = MemoryIngestor(store: store, frame: frame)
        ing.beforeWrite = { frame.activeMapId = "map-B" }
        XCTAssertTrue(try ing.ingest([mapObs(0, [1, 0, 0, 0])], generation: 1).rejected)
        XCTAssertTrue(try store.allTracks(mapId: "map-A").isEmpty)
        XCTAssertTrue(try store.allTracks(mapId: "map-B").isEmpty)
    }

    func testRealGateWaitsForTheWholeIngestBeforeAResetCanLand() throws {
        let gate = WorldFrameGate()
        let store = try TrackStore(path: ":memory:", scope: { gate.activeMapId })
        gate.sessionStarted(loadedSavedMap: true, mapId: "map-A")
        gate.update(tracking: .normal, mapping: .mapped)
        let ing = MemoryIngestor(store: store, frame: gate)
        let resetDone = DispatchSemaphore(value: 0)
        var resetBlockedDuringIngest = false
        ing.beforeWrite = {
            DispatchQueue.global().async { gate.sessionStarted(loadedSavedMap: false); resetDone.signal() }
            resetBlockedDuringIngest = resetDone.wait(timeout: .now() + 0.3) == .timedOut
        }
        let gen = gate.generation
        XCTAssertEqual(try ing.ingest([mapObs(0, [1, 0, 0, 0])], generation: gen), .init(matched: 0, created: 1))
        XCTAssertTrue(resetBlockedDuringIngest, "the reset had to wait for the validate-and-write step")
        XCTAssertEqual(resetDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try store.allTracks(mapId: "map-A").count, 1, "the write finished before the reset, under the old map id")
        XCTAssertTrue(try store.allTracks().isEmpty, "and after the reset it is hidden")
        XCTAssertTrue(try ing.ingest([mapObs(0, [1, 0, 0, 0])], generation: gen).rejected, "a frame captured before the reset is dropped")
        XCTAssertEqual(try store.allTracks(mapId: "map-A").count, 1)
    }

    // MARK: map ids on disk

    func testEverySavedMapGetsANewIdAndDiscardRemovesIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorldMapStore(url: dir.appendingPathComponent("teach.worldmap"))
        XCTAssertNil(s.currentMapId())
        let a = try s.save(Data([1]))
        XCTAssertEqual(s.currentMapId(), a)
        let b = try s.save(Data([2]))                          // replaced map
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(s.currentMapId(), b)
        s.discard()
        XCTAssertNil(s.currentMapId())
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.idURL.path))
    }

    func testArchiveSavedBeforeIdsExistedGetsAStableIdOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("teach.worldmap")
        try Data([7]).write(to: url)
        let s = WorldMapStore(url: url)
        let id = try XCTUnwrap(s.currentMapId())
        XCTAssertEqual(s.currentMapId(), id)
    }
}
