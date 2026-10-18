import XCTest
#if canImport(TeachCore)
@testable import TeachCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

private final class FakeClock: RelocClock {
    var t = 100.0
    func now() -> Double { t }
}

final class RelocalizationMonitorTests: XCTestCase {
    func testNoSavedMapStaysIdle() {
        let m = RelocalizationMonitor(clock: FakeClock())
        m.start(hasSavedMap: false)
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .idle)
    }

    func testSucceedsOnLimitedThenNormalWhateverTheMappingStatus() {
        let c = FakeClock(); let m = RelocalizationMonitor(clock: c)
        m.start(hasSavedMap: true)
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited, relocalizing: true), .waiting(elapsed: 0))
        c.t += 5
        XCTAssertEqual(m.update(tracking: .normal, mapping: .extending), .relocalized, "mapped is not required")
        c.t += 60
        XCTAssertEqual(m.tick(), .relocalized)   // success is sticky
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited), .relocalized)
    }

    func testNormalWithoutALimitedStateFirstIsIgnored() {
        let m = RelocalizationMonitor(clock: FakeClock())
        m.start(hasSavedMap: true)
        // A leftover .normal from the previous run (or any normal before ARKit reported relocalizing) proves nothing.
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .waiting(elapsed: 0))
        m.trackingLost()   // startup notAvailable before any limited state changes nothing
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .normal, mapping: .limited), .relocalized)
    }

    func testAfterTrackingLossOnlyRelocalizingCounts() {
        let m = RelocalizationMonitor(clock: FakeClock())
        m.start(hasSavedMap: true)
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited, relocalizing: true), .waiting(elapsed: 0))
        m.trackingLost()
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited), .waiting(elapsed: 0), "initializing, not relocalizing")
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .waiting(elapsed: 0), "may be a new frame")
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited, relocalizing: true), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .normal, mapping: .limited), .relocalized)
    }

    func testRearmAfterLossWaitsForRelocalizingAgain() {
        let c = FakeClock(); let m = RelocalizationMonitor(clock: c)
        m.startFreshTeach()   // adopted map: idle
        c.t += 50
        m.rearmAfterLoss()
        XCTAssertEqual(m.state, .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited, relocalizing: true), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .relocalized)
    }

    func testRearmInRunRecoversOnNextNormal() {
        let m = RelocalizationMonitor(clock: FakeClock())
        m.startFreshTeach()
        m.rearmInRun()
        XCTAssertEqual(m.state, .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited), .waiting(elapsed: 0), "excessive motion")
        XCTAssertEqual(m.update(tracking: .normal, mapping: .limited), .relocalized)
    }

    func testInterruptionAfterRearmInRunNeedsRelocalizing() {
        let m = RelocalizationMonitor(clock: FakeClock())
        m.startFreshTeach()
        m.rearmInRun()
        m.interrupted()
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited, relocalizing: true), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .relocalized)
    }

    func testTrackingDroppedKeepsAnEarlierInterruptionRequirement() {
        let m = RelocalizationMonitor(clock: FakeClock())
        m.start(hasSavedMap: true)
        m.interrupted()
        m.trackingDropped()
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited, relocalizing: true), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .relocalized)
    }

    func testRescanNeededAtTwentySeconds() {
        let c = FakeClock(); let m = RelocalizationMonitor(clock: c)
        m.start(hasSavedMap: true)
        c.t += 19.75
        XCTAssertEqual(m.tick(), .waiting(elapsed: 19.75))
        c.t += 0.25
        XCTAssertEqual(m.tick(), .rescanNeeded)
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited), .rescanNeeded)
    }

    func testLateSuccessAfterTimeoutRecovers() {
        let c = FakeClock(); let m = RelocalizationMonitor(clock: c)
        m.start(hasSavedMap: true)
        c.t += 30
        XCTAssertEqual(m.tick(), .rescanNeeded)
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited, relocalizing: true), .rescanNeeded)
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .relocalized)
    }

    func testFreshTeachStopsWatching() {
        let c = FakeClock(); let m = RelocalizationMonitor(clock: c)
        m.start(hasSavedMap: true)
        c.t += 30
        m.startFreshTeach()
        XCTAssertEqual(m.state, .idle)
        c.t += 30
        XCTAssertEqual(m.tick(), .idle)
    }

    func testRestartResetsTimer() {
        let c = FakeClock(); let m = RelocalizationMonitor(clock: c)
        m.start(hasSavedMap: true); c.t += 25
        XCTAssertEqual(m.tick(), .rescanNeeded)
        m.start(hasSavedMap: true)
        XCTAssertEqual(m.state, .waiting(elapsed: 0))
    }
}

final class WorldMapStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString)/Recall/teach.worldmap")
    }

    func testSaveLoadRoundTripAndOverwrite() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let s = WorldMapStore(url: url)
        XCTAssertFalse(s.hasSavedMap)
        XCTAssertNil(try s.loadData())
        try s.save(Data([1, 2, 3]))
        XCTAssertTrue(s.hasSavedMap)
        XCTAssertEqual(try s.loadData(), Data([1, 2, 3]))
        try s.save(Data([9]))
        XCTAssertEqual(try s.loadData(), Data([9]))
        s.discard()
        XCTAssertFalse(s.hasSavedMap)
    }

    func testSaveReturnsTheNewIdAndCutoffIsPerMap() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let s = WorldMapStore(url: url)
        let id = try s.save(Data([1]))
        XCTAssertEqual(s.currentMapId(), id)
        XCTAssertNil(s.waypointCutoff(mapId: id))
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        s.setWaypointCutoff(when, mapId: id)
        XCTAssertEqual(s.waypointCutoff(mapId: id), when)
        XCTAssertNil(s.waypointCutoff(mapId: "other"), "a cutoff belongs to one map")
        s.setWaypointCutoff(nil, mapId: id)
        XCTAssertNil(s.waypointCutoff(mapId: id))
        s.setWaypointCutoff(when, mapId: id)
        s.discard()
        XCTAssertNil(s.waypointCutoff(mapId: id))
    }

    func testEmptyDataIsRejectedAndEmptyFileCountsAsMissing() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let s = WorldMapStore(url: url)
        XCTAssertThrowsError(try s.save(Data()))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        XCTAssertNil(try s.loadData())
        XCTAssertFalse(s.hasSavedMap)
    }

    func testSavePolicy() {
        XCTAssertTrue(WorldMapSavePolicy.canSave(tracking: .normal, mapping: .mapped))
        XCTAssertTrue(WorldMapSavePolicy.canSave(tracking: .normal, mapping: .extending))
        XCTAssertFalse(WorldMapSavePolicy.canSave(tracking: .normal, mapping: .limited))
        XCTAssertFalse(WorldMapSavePolicy.canSave(tracking: .limited, mapping: .mapped))
        XCTAssertFalse(WorldMapSavePolicy.canSave(tracking: .notAvailable, mapping: .notAvailable))
    }
}
