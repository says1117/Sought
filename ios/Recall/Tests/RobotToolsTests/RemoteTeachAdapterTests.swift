import XCTest
#if canImport(RobotToolsLease)
@testable import RobotToolsLease
#endif
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(ExploreCore)
@testable import ExploreCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

/// Kinematic rover in virtual time: wheel commands integrate into the pose on every sleep. Not a model of the real
/// rover's speeds; only directions and stop behaviour matter here.
final class RTSimRover: DriveSink, PoseSource {
    private let lock = NSLock()
    private var pose: Pose2D
    private var cmd = (l: 0, r: 0)
    private var t = 0.0
    private(set) var commands: [(Int, Int)] = []
    var tracking: TrackingKind = .normal
    init(pose: Pose2D = Pose2D(x: 0, z: 0, yawDeg: 0)) { self.pose = pose }

    func drive(left: Int, right: Int) { lock.lock(); cmd = (left, right); commands.append((left, right)); lock.unlock() }
    func stop() { lock.lock(); cmd = (0, 0); lock.unlock() }
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) {
        lock.lock(); defer { lock.unlock() }
        return (tracking == .normal ? pose : nil, tracking)
    }
    var now: Double { lock.lock(); defer { lock.unlock() }; return t }
    var current: Pose2D { lock.lock(); defer { lock.unlock() }; return pose }

    func advance(_ dt: Double) {
        lock.lock(); defer { lock.unlock() }
        t += dt
        let linear = Double(cmd.l + cmd.r) / 2 * 0.002          // m/s per wheel unit
        let angular = Double(cmd.r - cmd.l) / 2 * 0.6           // deg/s per wheel unit, positive = left (CCW)
        pose.yawDeg += angular * dt
        let yaw = pose.yawDeg * .pi / 180
        pose.x += -sin(yaw) * linear * dt
        pose.z += -cos(yaw) * linear * dt
    }
}

final class RemoteTeachAdapterTests: XCTestCase {
    private func make(_ rover: RTSimRover, rearHold: @escaping () -> Bool = { false },
                      scan: ScanConfig = ScanConfig(rotations: 4, stepDeg: 90, dwellS: 0.2),
                      onSleep: (() -> Void)? = nil,
                      save: @escaping () async -> String? = { nil }) -> (RemoteTeachAdapter, Controller) {
        let controller = Controller(poses: rover, sink: rover, clock: { rover.now }, sleep: { rover.advance($0); await Task.yield() })
        let adapter = RemoteTeachAdapter(controller: controller, poses: rover, reverseSink: rover, rearHold: rearHold,
                                         scanConfig: scan, saveMap: save, clock: { rover.now },
                                         sleep: { onSleep?(); rover.advance($0); await Task.yield() })
        return (adapter, controller)
    }

    func testForwardDrivesAlongTheHeadingAndArrivesWithinATenth() async throws {
        let rover = RTSimRover(pose: Pose2D(x: 1, z: 1, yawDeg: 90))   // facing -x
        let (teach, _) = make(rover)
        let r = try await teach.move(meters: 0.5)
        XCTAssertEqual(r, .completed(summary: "moved 0.5 m"))
        XCTAssertEqual(rover.current.x, 0.5, accuracy: 0.1)
        XCTAssertEqual(rover.current.z, 1, accuracy: 0.1)
    }

    func testBackReversesStraightAndReports() async throws {
        let rover = RTSimRover()
        let (teach, _) = make(rover)
        let r = try await teach.move(meters: -0.3)
        XCTAssertEqual(r, .completed(summary: "moved back 0.3 m"))
        XCTAssertEqual(rover.current.z, 0.3, accuracy: 0.08)   // backing up from yaw 0 (facing -z) goes +z
        XCTAssertFalse(rover.commands.isEmpty)
        XCTAssertTrue(rover.commands.allSatisfy { $0.0 < 0 && $0.1 < 0 }, "reverse must only send backward commands")
    }

    func testBackNeverDrivesWhileTheRearGuardHolds() async throws {
        let rover = RTSimRover()
        let (teach, _) = make(rover, rearHold: { true })
        let r = try await teach.move(meters: -0.5)
        XCTAssertEqual(r, .blocked(reason: "something is behind me"))
        XCTAssertTrue(rover.commands.isEmpty, "drove backwards with the rear blocked")
        XCTAssertEqual(rover.current.z, 0, accuracy: 1e-9)
    }

    func testStopDuringReverseCancels() async throws {
        let rover = RTSimRover()
        var calls = 0
        var teach: RemoteTeachAdapter!
        (teach, _) = make(rover, rearHold: {
            calls += 1
            if calls == 3 { teach.cancel() }   // STOP lands mid-reverse
            return false
        })
        let r = try await teach.move(meters: -1.0)
        XCTAssertEqual(r, .cancelled)
        XCTAssertLessThan(rover.current.z, 0.5)
    }

    func testStopDuringForwardCancels() async throws {
        let rover = RTSimRover()
        var ticks = 0
        var teach: RemoteTeachAdapter!
        let controller = Controller(poses: rover, sink: rover, clock: { rover.now }, sleep: {
            ticks += 1
            if ticks == 3 { teach.cancel() }   // STOP lands mid-drive
            rover.advance($0)
        })
        teach = RemoteTeachAdapter(controller: controller, poses: rover, reverseSink: rover, rearHold: { false },
                                   scanConfig: ScanConfig(), saveMap: { nil }, clock: { rover.now }, sleep: { rover.advance($0) })
        let r = try await teach.move(meters: 1.0)
        XCTAssertEqual(r, .cancelled)
        XCTAssertGreaterThan(rover.current.z, -0.5, "kept driving after STOP")
    }

    func testTurnLeftAndRight() async throws {
        let rover = RTSimRover()
        let (teach, _) = make(rover)
        let left = try await teach.turn(degrees: 90)
        XCTAssertEqual(left, .completed(summary: "turned left 90°"))
        XCTAssertEqual(rover.current.yawDeg, 90, accuracy: 15)
        let right = try await teach.turn(degrees: -45)
        XCTAssertEqual(right, .completed(summary: "turned right 45°"))
        XCTAssertEqual(rover.current.yawDeg, 45, accuracy: 20)
    }

    func testScanTurnsFourTimesAndReports() async throws {
        let rover = RTSimRover()
        let (teach, _) = make(rover)
        let r = try await teach.scanHere()
        XCTAssertEqual(r, .completed(summary: "scan done 4/4"))
    }

    func testStopDuringScanDwellCancels() async throws {
        let rover = RTSimRover()
        var sleeps = 0
        var teach: RemoteTeachAdapter!
        (teach, _) = make(rover, onSleep: { sleeps += 1; if sleeps == 2 { teach.cancel() } })
        let r = try await teach.scanHere()
        XCTAssertEqual(r, .cancelled)
    }

    func testScanStopsWhenTrackingIsLost() async throws {
        let rover = RTSimRover()
        var sleeps = 0
        let (teach, _) = make(rover, onSleep: { sleeps += 1; if sleeps == 2 { rover.tracking = .limited } })
        let r = try await teach.scanHere()
        guard case .blocked(let why) = r else { return XCTFail("expected blocked, got \(r)") }
        XCTAssertTrue(why.contains("1/4"), why)
    }

    func testMoveWithoutTrackingIsBlocked() async throws {
        let rover = RTSimRover()
        rover.tracking = .limited
        let (teach, _) = make(rover)
        let r = try await teach.move(meters: 0.5)
        XCTAssertEqual(r, .blocked(reason: CoordinatorConfig.rescanReason))
        XCTAssertTrue(rover.commands.isEmpty)
    }

    func testSaveMapPassesThroughTheSaver() async {
        let (ok, _) = make(RTSimRover())
        let saved = await ok.saveMap()
        XCTAssertNil(saved)
        let (bad, _) = make(RTSimRover(), save: { "ARKit has no world map yet" })
        let why = await bad.saveMap()
        XCTAssertEqual(why, "ARKit has no world map yet")
    }
}
