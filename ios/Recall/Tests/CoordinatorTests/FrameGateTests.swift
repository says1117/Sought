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

    func testRelocalizesOnlyWithLoadedMapAndLimitedThenNormal() {
        let g = WorldFrameGate()
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .mapped)
        XCTAssertFalse(g.relocalized, "no session started")
        g.sessionStarted(loadedSavedMap: false)
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .mapped)
        XCTAssertFalse(g.relocalized, "no saved map to recognise (missing, corrupt or reset)")
        g.sessionStarted(loadedSavedMap: true)
        g.update(tracking: .normal, mapping: .mapped)
        XCTAssertFalse(g.relocalized, "a normal frame before any limited state may be the previous run's")
        g.update(tracking: .limited, mapping: .extending, relocalizing: true)
        XCTAssertFalse(g.relocalized)
        g.update(tracking: .normal, mapping: .extending)
        XCTAssertTrue(g.relocalized, "mapped status is not required")
        g.update(tracking: .limited, mapping: .limited)
        XCTAssertTrue(g.relocalized, "stays recognised through limited tracking")
        XCTAssertEqual(g.relocalizationState(), .relocalized)
    }

    func testLostTrackingNeedsARelocalizingTransitionToRecover() {
        let g = WorldFrameGate()
        g.sessionStarted(loadedSavedMap: true, mapId: "map-A")
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .mapped)
        XCTAssertTrue(g.relocalized)
        g.update(tracking: .notAvailable, mapping: .notAvailable)
        g.update(tracking: .limited, mapping: .limited)
        g.update(tracking: .normal, mapping: .mapped)
        XCTAssertFalse(g.relocalized, "came back without relocalizing: may be a new frame")
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .limited)
        XCTAssertTrue(g.relocalized)
    }

    func testAdoptSavedMapFromFreshSession() {
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        let g = WorldFrameGate(now: { t })
        g.sessionStarted(loadedSavedMap: false)
        let fresh = g.activeMapId!
        XCTAssertEqual(g.relocalizationState(), .idle)
        XCTAssertFalse(g.usesSavedMap)
        let gen = g.generation
        t = t.addingTimeInterval(30)
        let r = g.adoptSavedMap(mapId: "map-B", ifGeneration: gen)
        XCTAssertEqual(r, MapAdoption(previousMapId: fresh, wasRelocalized: false,
                                      waypointCutoff: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertTrue(g.relocalized); XCTAssertTrue(g.usesSavedMap)
        XCTAssertEqual(g.activeMapId, "map-B")
        XCTAssertGreaterThan(g.generation, gen, "in-flight ingests of the fresh id are dropped")
        XCTAssertTrue(g.isInCurrentFrame(createdAt: iso(t.addingTimeInterval(-20))), "frame start unchanged")
        XCTAssertTrue(g.predatesActiveMap(createdAt: iso(t.addingTimeInterval(-3600))), "older map's waypoint")
        XCTAssertFalse(g.predatesActiveMap(createdAt: iso(t.addingTimeInterval(-20))))
        g.update(tracking: .normal, mapping: .limited)
        XCTAssertTrue(g.relocalized, "stays adopted")
        g.update(tracking: .notAvailable, mapping: .notAvailable)
        XCTAssertFalse(g.relocalized)
        XCTAssertEqual(g.relocalizationState(), .waiting(elapsed: 0))
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .limited)
        XCTAssertTrue(g.relocalized, "ARKit relocalized after the interruption")
    }

    func testAdoptWhileRelocalizedKeepsCutoffAndReportsPreviousMap() {
        let g = WorldFrameGate()
        g.sessionStarted(loadedSavedMap: true, mapId: "map-A", waypointCutoff: nil)
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .mapped)
        let r = g.adoptSavedMap(mapId: "map-B", ifGeneration: g.generation)
        XCTAssertEqual(r, MapAdoption(previousMapId: "map-A", wasRelocalized: true, waypointCutoff: nil))
        XCTAssertFalse(g.predatesActiveMap(createdAt: "2001-01-01T00:00:00Z"), "same frame as A: A's waypoints stay valid")
    }

    func testAdoptRefusedWhenTheFrameChangedDuringTheSave() {
        let g = WorldFrameGate()
        g.sessionStarted(loadedSavedMap: false)
        let gen = g.generation
        g.sessionStarted(loadedSavedMap: false)   // app came back from background and re-ran ARKit
        XCTAssertNil(g.adoptSavedMap(mapId: "map-B", ifGeneration: gen))
        XCTAssertFalse(g.relocalized)
        XCTAssertNotEqual(g.activeMapId, "map-B")
    }

    func testLoadedCutoffRefusesOlderWaypoints() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let g = WorldFrameGate(now: { t })
        g.sessionStarted(loadedSavedMap: true, mapId: "map-B", waypointCutoff: t.addingTimeInterval(-100))
        XCTAssertTrue(g.predatesActiveMap(createdAt: iso(t.addingTimeInterval(-500))))
        XCTAssertFalse(g.predatesActiveMap(createdAt: iso(t.addingTimeInterval(-50))))
        g.sessionStarted(loadedSavedMap: false, waypointCutoff: t)
        XCTAssertFalse(g.predatesActiveMap(createdAt: iso(t.addingTimeInterval(-500))), "no map, no cutoff")
    }

    func testRestartAndLostTrackingInvalidate() {
        let g = WorldFrameGate()
        g.sessionStarted(loadedSavedMap: true)
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .mapped)
        XCTAssertTrue(g.relocalized)
        g.update(tracking: .notAvailable, mapping: .notAvailable)
        XCTAssertFalse(g.relocalized)
        g.update(tracking: .limited, mapping: .limited, relocalizing: true); g.update(tracking: .normal, mapping: .mapped)
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
