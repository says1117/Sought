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

    func testSucceedsOnNormalAndMapped() {
        let c = FakeClock(); let m = RelocalizationMonitor(clock: c)
        m.start(hasSavedMap: true)
        XCTAssertEqual(m.update(tracking: .limited, mapping: .limited), .waiting(elapsed: 0))
        XCTAssertEqual(m.update(tracking: .normal, mapping: .extending), .waiting(elapsed: 0))
        c.t += 5
        XCTAssertEqual(m.update(tracking: .normal, mapping: .mapped), .relocalized)
        c.t += 60
        XCTAssertEqual(m.tick(), .relocalized)   // success is sticky
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
