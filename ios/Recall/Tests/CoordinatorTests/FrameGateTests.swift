import XCTest
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

// PR 33 re-review finding 1: stored coordinates are only driven to after relocalization (or if created this frame).

final class FrameGateStub: CoordinatorFrameValidity {
    var relocalized = false
    func isInCurrentFrame(createdAt isoTimestamp: String) -> Bool { false }
}

final class FrameGateCoordinatorTests: XCTestCase {
    func testStoredWaypointRefusedUntilRelocalized() async throws {
        let frame = FrameGateStub()
        let r = CoordRig(frame: frame)               // "kitchen" is a stored waypoint (not in the current frame)
        try await r.coordinator.execute(.goToWaypoint(name: "kitchen"))
        XCTAssertFalse(r.navigator.isRunning)
        XCTAssertTrue(r.navigator.started.isEmpty)
        XCTAssertEqual(r.speaker.said.last, CoordinatorConfig.notRecognisedSpoken)
        XCTAssertTrue(r.speaker.said.last?.contains("not recognised this room") == true)
        XCTAssertEqual(r.drive.stops, 0)

        frame.relocalized = true
        let t = await r.launch(.goToWaypoint(name: "kitchen"))
        XCTAssertEqual(r.navigator.started, ["go:kitchen"])
        r.navigator.finish(.completed(summary: "x"))
        _ = try? await t.value
    }

    func testSameFrameWaypointAllowedWithoutRelocalization() async throws {
        let frame = FrameGateStub()
        let r = CoordRig(frame: frame)
        r.waypoints.known["porch"] = CoordinatorWaypoint(name: "porch", x: 3, z: 4, inCurrentFrame: true)
        let t = await r.launch(.goToWaypoint(name: "porch"))
        XCTAssertEqual(r.navigator.started, ["go:porch"])
        r.navigator.finish(.completed(summary: "x"))
        _ = try? await t.value
    }
}

final class FrameGateUnitTests: XCTestCase {
    private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    func testRelocalizesOnlyWithLoadedMapAndNormalMapped() {
        let g = WorldFrameGate()
        g.update(tracking: .normal, mapping: .mapped)
        XCTAssertFalse(g.relocalized, "no session started")
        g.sessionStarted(loadedSavedMap: false)
        g.update(tracking: .normal, mapping: .mapped)
        XCTAssertFalse(g.relocalized, "no saved map to recognise (missing, corrupt or reset)")
        g.sessionStarted(loadedSavedMap: true)
        g.update(tracking: .limited, mapping: .mapped)
        XCTAssertFalse(g.relocalized)
        g.update(tracking: .normal, mapping: .extending)
        XCTAssertFalse(g.relocalized)
        g.update(tracking: .normal, mapping: .mapped)
        XCTAssertTrue(g.relocalized)
        g.update(tracking: .normal, mapping: .extending)
        XCTAssertTrue(g.relocalized, "stays recognised while mapping status moves on")
    }

    func testRestartAndLostTrackingInvalidate() {
        let g = WorldFrameGate()
        g.sessionStarted(loadedSavedMap: true)
        g.update(tracking: .normal, mapping: .mapped)
        XCTAssertTrue(g.relocalized)
        g.update(tracking: .notAvailable, mapping: .notAvailable)
        XCTAssertFalse(g.relocalized)
        g.update(tracking: .normal, mapping: .mapped)
        XCTAssertTrue(g.relocalized, "recognised again")
        g.sessionStarted(loadedSavedMap: true)             // resume / fresh Teach reset
        XCTAssertFalse(g.relocalized)
    }

    func testCreatedAtIsComparedToFrameStart() {
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        let g = WorldFrameGate(now: { t })
        g.sessionStarted(loadedSavedMap: false)
        XCTAssertFalse(g.isInCurrentFrame(createdAt: iso(t.addingTimeInterval(-60))), "older session")
        XCTAssertTrue(g.isInCurrentFrame(createdAt: iso(t.addingTimeInterval(5))))
        XCTAssertFalse(g.isInCurrentFrame(createdAt: "garbage"))
        t = t.addingTimeInterval(100)
        g.sessionStarted(loadedSavedMap: false)             // new frame: the earlier mark is stale now
        XCTAssertFalse(g.isInCurrentFrame(createdAt: iso(t.addingTimeInterval(-50))))
    }
}
