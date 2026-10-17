import XCTest
#if canImport(TeachCore)
@testable import TeachCore
#endif
#if canImport(DriveLinkCore)
@testable import DriveLinkCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

private final class FakeDriver: TeachDriving {
    var isConnected = true
    var calls: [String] = []
    func drive(left: Int, right: Int) { calls.append("drive \(left),\(right)") }
    func stop() { calls.append("stop") }
}

private final class FakeSaver: TeachMapSaving {
    var result: Result<Void, Error> = .success(())
    var count = 0
    func saveCurrentMap(completion: @escaping (Result<Void, Error>) -> Void) { count += 1; completion(result) }
}

final class TeachViewModelTests: XCTestCase {
    private var pose: Pose2D? = Pose2D(x: 1, z: 2, yawDeg: 90)
    private let driver = FakeDriver()
    private let saver = FakeSaver()

    private func makeModel() throws -> TeachViewModel {
        TeachViewModel(store: try WaypointStore(path: ":memory:"), driver: driver, mapSaver: saver, currentPose: { [unowned self] in self.pose })
    }

    func testBeginSessionCreatesHomeAtCurrentPose() throws {
        let m = try makeModel()
        m.beginSession()
        XCTAssertEqual(m.waypoints.map(\.name), ["home"])
        XCTAssertEqual(m.waypoints[0].pose, Pose2D(x: 1, z: 2, yawDeg: 90))
    }

    func testBeginSessionStartsRelocalizationWhenSavedMapExists() throws {
        let m = try makeModel()
        let monitor = RelocalizationMonitor()
        m.beginSession(hasSavedMap: true, monitor: monitor)
        XCTAssertEqual(monitor.state, .waiting(elapsed: 0))
        XCTAssertEqual(m.waypoints.map(\.name), ["home"])
    }

    func testBeginSessionWithoutPoseMakesNoHome() throws {
        pose = nil
        let m = try makeModel()
        m.beginSession()
        XCTAssertTrue(m.waypoints.isEmpty)
    }

    func testMarkWaypointUsesDraftThenClearsIt() throws {
        let m = try makeModel()
        m.nameDraft = "kitchen"
        m.markWaypoint()
        XCTAssertEqual(m.waypoints.map(\.name), ["kitchen"])
        XCTAssertEqual(m.nameDraft, "")
        XCTAssertEqual(m.message, "Marked kitchen")
    }

    func testMarkWaypointWithSpokenNameOverridesDraft() throws {
        let m = try makeModel()
        m.nameDraft = "typed"
        m.markWaypoint(name: "hallway")
        XCTAssertEqual(m.waypoints.map(\.name), ["hallway"])
    }

    func testMarkErrors() throws {
        let m = try makeModel()
        m.markWaypoint()
        XCTAssertEqual(m.message, "Type a name first")
        m.markWaypoint(name: "a"); m.markWaypoint(name: "A")
        XCTAssertEqual(m.message, "A waypoint named A already exists")
        XCTAssertEqual(m.waypoints.count, 1)
        pose = nil
        m.markWaypoint(name: "b")
        XCTAssertEqual(m.message, "No pose yet. Wait for tracking.")
        XCTAssertEqual(m.waypoints.count, 1)
    }

    func testDeleteAndRenameThroughModel() throws {
        let m = try makeModel()
        m.beginSession()
        m.markWaypoint(name: "a")
        let a = try XCTUnwrap(m.waypoints.last)
        m.rename(a, to: "b")
        XCTAssertEqual(m.waypoints.map(\.name), ["home", "b"])
        m.delete(m.waypoints[0])
        XCTAssertEqual(m.message, "Home cannot be deleted")
        m.delete(m.waypoints[1])
        XCTAssertEqual(m.waypoints.map(\.name), ["home"])
    }

    func testHeldButtonDrivesViaDrivePadAndReleaseStops() throws {
        let m = try makeModel()
        m.setHeld(.forward)
        m.setHeld(.left)
        m.setHeld(nil)
        XCTAssertEqual(driver.calls, ["drive 150,150", "drive -150,150", "stop"])
    }

    func testSpeedChangeWhileHeldRedrives() throws {
        let m = try makeModel()
        m.setHeld(.back)
        m.setSpeed(100)
        XCTAssertEqual(driver.calls, ["drive -150,-150", "drive -100,-100"])
    }

    func testDisabledOrDisconnectedAlwaysStops() throws {
        let m = try makeModel()
        m.setHeld(.forward, enabled: false)
        driver.isConnected = false
        m.setHeld(.forward)
        XCTAssertEqual(driver.calls, ["stop", "stop"])
        m.stopDriving()
        m.setSpeed(150)
        XCTAssertEqual(driver.calls.last, "stop")
    }

    func testSaveMapReportsResult() throws {
        let m = try makeModel()
        m.saveMap()
        XCTAssertEqual(m.message, "Map saved"); XCTAssertFalse(m.isSaving)
        saver.result = .failure(NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        m.saveMap()
        XCTAssertEqual(m.message, "Map not saved: boom")
        XCTAssertEqual(saver.count, 2)
    }
}
