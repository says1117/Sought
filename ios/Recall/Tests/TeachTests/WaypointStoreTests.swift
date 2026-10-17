import XCTest
#if canImport(TeachCore)
@testable import TeachCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

final class WaypointStoreTests: XCTestCase {
    private var counter = 0
    private func makeStore() throws -> WaypointStore {
        counter = 0
        return try WaypointStore(path: ":memory:", now: { Date(timeIntervalSince1970: 1_800_000_000) },
                                 makeId: { [unowned self] p in self.counter += 1; return "\(p)_\(self.counter)" })
    }

    func testHomeIsCreatedOnceAtOrigin() throws {
        let s = try makeStore()
        let h = try s.ensureHome(at: Pose2D(x: 0.1, z: -0.2, yawDeg: 30))
        XCTAssertEqual(h.id, "wpt_home"); XCTAssertEqual(h.name, "home")
        _ = try s.ensureHome(at: Pose2D(x: 9, z: 9, yawDeg: 0))
        let all = try s.waypoints()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].x, 0.1, accuracy: 1e-9)
    }

    func testAddAndFetchRoundTrip() throws {
        let s = try makeStore()
        let w = try s.addWaypoint(name: "  kitchen ", pose: Pose2D(x: 2.1, z: -4.8, yawDeg: 180), mediaId: "med_1")
        XCTAssertEqual(w.name, "kitchen")
        let got = try XCTUnwrap(try s.waypoint(id: w.id))
        XCTAssertEqual(got, w)
        XCTAssertEqual(got.mediaId, "med_1")
        XCTAssertEqual(got.createdAt, "2027-01-15T08:00:00Z")
        XCTAssertEqual(got.pose, Pose2D(x: 2.1, z: -4.8, yawDeg: 180))
    }

    func testDuplicateNamesRejectedIgnoringCase() throws {
        let s = try makeStore()
        try s.addWaypoint(name: "Kitchen", pose: Pose2D(x: 0, z: 0, yawDeg: 0))
        XCTAssertThrowsError(try s.addWaypoint(name: "kitchen", pose: Pose2D(x: 1, z: 1, yawDeg: 0))) {
            XCTAssertEqual($0 as? WaypointStoreError, .duplicateName("kitchen"))
        }
        XCTAssertThrowsError(try s.addWaypoint(name: "   ", pose: Pose2D(x: 1, z: 1, yawDeg: 0))) {
            XCTAssertEqual($0 as? WaypointStoreError, .emptyName)
        }
    }

    func testRenameAndConflicts() throws {
        let s = try makeStore()
        let a = try s.addWaypoint(name: "a", pose: Pose2D(x: 0, z: 0, yawDeg: 0))
        let b = try s.addWaypoint(name: "b", pose: Pose2D(x: 1, z: 0, yawDeg: 0))
        XCTAssertThrowsError(try s.rename(id: b.id, to: "A")) { XCTAssertEqual($0 as? WaypointStoreError, .duplicateName("A")) }
        XCTAssertEqual(try s.rename(id: a.id, to: "A").name, "A")   // case change of itself is fine
        XCTAssertEqual(try s.waypoint(named: "a")?.id, a.id)
        XCTAssertThrowsError(try s.rename(id: "nope", to: "x")) { XCTAssertEqual($0 as? WaypointStoreError, .notFound("nope")) }
    }

    func testHomeCannotBeRenamedOrDeleted() throws {
        let s = try makeStore()
        try s.ensureHome(at: Pose2D(x: 0, z: 0, yawDeg: 0))
        XCTAssertThrowsError(try s.rename(id: WaypointStore.homeId, to: "base")) { XCTAssertEqual($0 as? WaypointStoreError, .homeIsProtected) }
        XCTAssertThrowsError(try s.deleteWaypoint(id: WaypointStore.homeId)) { XCTAssertEqual($0 as? WaypointStoreError, .homeIsProtected) }
    }

    func testListOrderHomeFirst() throws {
        let s = try makeStore()
        try s.addWaypoint(name: "hall", pose: Pose2D(x: 1, z: 0, yawDeg: 0))
        try s.ensureHome(at: Pose2D(x: 0, z: 0, yawDeg: 0))
        try s.addWaypoint(name: "kitchen", pose: Pose2D(x: 2, z: 0, yawDeg: 0))
        XCTAssertEqual(try s.waypoints().map(\.name), ["home", "hall", "kitchen"])
    }

    func testRoutesOrderedAndDeleteWaypointPrunesRoutes() throws {
        let s = try makeStore()
        let h = try s.ensureHome(at: Pose2D(x: 0, z: 0, yawDeg: 0))
        let hall = try s.addWaypoint(name: "hall", pose: Pose2D(x: 1, z: 0, yawDeg: 0))
        let bath = try s.addWaypoint(name: "bath", pose: Pose2D(x: 2, z: 0, yawDeg: 0))
        let r = try s.addRoute(name: "bathroom route", kind: "patrol", waypointIds: [h.id, hall.id, bath.id])
        XCTAssertEqual(try s.routes(), [r])
        XCTAssertEqual(try s.routes()[0].waypointIds, [h.id, hall.id, bath.id])
        try s.deleteWaypoint(id: hall.id)
        XCTAssertEqual(try s.routes()[0].waypointIds, [h.id, bath.id])
        XCTAssertNil(try s.waypoint(id: hall.id))
    }

    func testRouteValidation() throws {
        let s = try makeStore()
        XCTAssertThrowsError(try s.addRoute(name: "r", waypointIds: ["ghost"])) { XCTAssertEqual($0 as? WaypointStoreError, .unknownWaypoint("ghost")) }
        let w = try s.addWaypoint(name: "a", pose: Pose2D(x: 0, z: 0, yawDeg: 0))
        let r = try s.addRoute(name: "R", waypointIds: [w.id])
        XCTAssertThrowsError(try s.addRoute(name: "r", waypointIds: [w.id])) { XCTAssertEqual($0 as? WaypointStoreError, .duplicateName("r")) }
        try s.deleteRoute(id: r.id)
        XCTAssertTrue(try s.routes().isEmpty)
    }

    func testPersistsAcrossReopen() throws {
        let path = NSTemporaryDirectory() + "wp-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        do { let s = try WaypointStore(path: path); try s.addWaypoint(name: "kitchen", pose: Pose2D(x: 1, z: 2, yawDeg: 3)) }
        XCTAssertEqual(try WaypointStore(path: path).waypoints().map(\.name), ["kitchen"])
    }
}
