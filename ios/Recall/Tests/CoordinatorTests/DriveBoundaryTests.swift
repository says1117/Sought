import XCTest
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

// Findings 1, 2, 3 and the spoken part of 6 from the PR 33 review.
// Prefixed Coord/Lease because the RecallTests bundle compiles every test file into one module.

final class CoordLeaseRecorder: DriveSink {
    enum Event: Equatable { case drive(Int, Int), stop }
    private let lock = NSLock()
    private var log: [Event] = []
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return log }
    var drives: [Int] { events.compactMap { if case .drive(let l, _) = $0 { return l } else { return nil } } }
    var stops: Int { events.filter { $0 == .stop }.count }
    func drive(left: Int, right: Int) { lock.lock(); log.append(.drive(left, right)); lock.unlock() }
    func stop() { lock.lock(); log.append(.stop); lock.unlock() }
}

/// Drives once when it starts, then waits. `cancel()` is deliberately ignored (an uncooperative runner), and
/// after `release()` it drives once more, which a revoked lease must drop.
final class CoordLeaseRunner: CoordinatorFinding, CoordinatorNavigating {
    private let sink: DriveSink
    private let speed: Int
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    init(sink: DriveSink, speed: Int) { self.sink = sink; self.speed = speed }

    private func run() async -> CoordinatorTaskResult {
        sink.drive(left: speed, right: speed)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.lock(); cont = c; lock.unlock() }
        sink.drive(left: speed, right: speed)
        return .cancelled
    }
    func release() { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume() }
    func find(description: String) async throws -> CoordinatorTaskResult { await run() }
    func goTo(_ waypoint: CoordinatorWaypoint) async throws -> CoordinatorTaskResult { await run() }
    func cancel() {}
}

final class CoordLeaseRig {
    let lease = DriveLease()
    let recorder = CoordLeaseRecorder()
    let clock = CoordTestClock(), speaker = CoordTestSpeaker(), waypoints = CoordTestWaypoints()
    let pose = CoordTestPose()
    let finder: CoordLeaseRunner, navigator: CoordLeaseRunner
    let coordinator: RobotCoordinator

    init() {
        let leased = LeasedDriveSink(base: recorder, lease: lease)
        finder = CoordLeaseRunner(sink: leased, speed: 50)
        navigator = CoordLeaseRunner(sink: leased, speed: 7)
        coordinator = RobotCoordinator(dependencies: CoordinatorDependencies(
            explorer: CoordTestRunner(), finder: finder, comer: CoordTestRunner(), navigator: navigator,
            waypoints: waypoints, drive: DriveStopAdapter(sink: recorder), speaker: speaker, clock: clock, pose: pose,
            lease: lease))
    }

    @discardableResult
    func launch(_ call: ToolCall) async -> Task<Void, Error> {
        let co = coordinator
        let t = Task { try await co.execute(call) }
        await coordSettle()
        return t
    }
}

final class CoordDriveLeaseTests: XCTestCase {
    // Finding 1: the drain timeout hands the slot to a new request while the old runner is still alive.
    func testStaleRunnerCannotDriveAfterDrainTimeoutReleasesTheSlot() async throws {
        let r = CoordLeaseRig()
        let old = await r.launch(.findObject(description: "keys"))
        XCTAssertEqual(r.recorder.drives, [50])
        r.coordinator.stopAll()
        await r.clock.advance(by: 3.2)                    // drain timeout releases the slot
        XCTAssertFalse(r.coordinator.isBusy)

        let new = await r.launch(.goToWaypoint(name: "kitchen"))
        XCTAssertEqual(r.recorder.drives, [50, 7], "new navigator owns the link")

        r.finder.release()                                // stale finder wakes and tries to drive
        await coordSettle()
        XCTAssertEqual(r.recorder.drives, [50, 7], "stale runner's command must be dropped at the drive boundary")

        r.navigator.release()
        await coordSettle()
        XCTAssertEqual(r.recorder.drives, [50, 7, 7], "the current request still drives")
        _ = try? await old.value; _ = try? await new.value
    }

    func testStopIsNeverFilteredByTheLease() {
        let lease = DriveLease(), rec = CoordLeaseRecorder()
        let sink = LeasedDriveSink(base: rec, lease: lease)
        sink.drive(left: 1, right: 1)                     // no token: dropped
        sink.stop()
        XCTAssertEqual(rec.events, [.stop])
        lease.holdManual("drive")
        sink.stop()
        XCTAssertEqual(rec.stops, 2)
    }

    // Finding 3: manual tools take the link exclusively.
    func testManualToolCancelsMotionBrakesAndCoordinatorRefusesNewMotionUntilClosed() async throws {
        let r = CoordLeaseRig()
        let running = await r.launch(.findObject(description: "keys"))
        XCTAssertTrue(r.coordinator.isBusy)
        let stopsBefore = r.recorder.stops

        r.coordinator.beginManualControl("drive")
        XCTAssertGreaterThan(r.recorder.stops, stopsBefore, "STOP sent")
        XCTAssertEqual(r.coordinator.status, .idle)

        // The uncooperative old finder wakes while the manual tool is open: its command is dropped.
        r.finder.release()
        await coordSettle()
        XCTAssertEqual(r.recorder.drives, [50])
        _ = try? await running.value

        // New motion is refused while the tool holds the lease, with a spoken reason.
        await r.clock.advance(by: 0.1)
        let refused = await r.launch(.goToWaypoint(name: "kitchen"))
        _ = try? await refused.value
        XCTAssertFalse(r.coordinator.isBusy)
        XCTAssertEqual(r.recorder.drives, [50])
        XCTAssertTrue(r.speaker.said.contains { $0.contains("manual control") }, "\(r.speaker.said)")

        // Closing returns the lease.
        r.coordinator.endManualControl("drive")
        let ok = await r.launch(.goToWaypoint(name: "kitchen"))
        XCTAssertEqual(r.recorder.drives, [50, 7])
        r.navigator.release()
        _ = try? await ok.value
    }

    func testLeaseGrantRefusedWhileAnyManualToolHoldsIt() {
        let lease = DriveLease()
        XCTAssertNotNil(lease.grant())
        lease.holdManual("teach"); lease.holdManual("selftest")
        XCTAssertNil(lease.grant())
        lease.releaseManual("teach")
        XCTAssertNil(lease.grant(), "still held by self-test")
        lease.releaseManual("selftest")
        XCTAssertNotNil(lease.grant())
    }

    // Finding 6 (spoken confirmation).
    func testMarkWaypointSaysWhenItIsNotPersisted() async throws {
        let r = CoordLeaseRig()
        r.waypoints.isPersistent = false
        await r.launch(.markWaypoint(name: "desk"))
        XCTAssertTrue(r.speaker.said.last?.contains("only until the app closes") == true, "\(r.speaker.said)")
        r.waypoints.isPersistent = true
        await r.launch(.markWaypoint(name: "bed"))
        XCTAssertEqual(r.speaker.said.last, "Saved this spot as bed.")
    }
}

// Finding 2: thread-safe pose snapshot and serialized drive writes.
final class CoordDriveBoundaryTests: XCTestCase {
    func testSnapshotBoxReturnsValueCopyAndFailsClosedWhenStale() {
        var t = 100.0
        let box = PoseSnapshotBox(now: { t })
        XCTAssertEqual(box.latest().tracking, .notAvailable, "nothing published yet")
        box.update(pose: Pose2D(x: 1, z: 2, yawDeg: 3), tracking: .normal)
        XCTAssertEqual(box.latest().pose, Pose2D(x: 1, z: 2, yawDeg: 3))
        XCTAssertEqual(box.latest().tracking, .normal)
        t += PoseSnapshotBox.maxAgeS + 0.5
        XCTAssertNil(box.latest().pose)
        XCTAssertEqual(box.latest().tracking, .notAvailable)
    }

    func testSnapshotBoxIsSafeUnderConcurrentReadersAndWriter() {
        let box = PoseSnapshotBox()
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            if i % 4 == 0 { box.update(pose: Pose2D(x: Double(i), z: Double(i), yawDeg: 0), tracking: .normal) }
            let s = box.latest()
            if let p = s.pose { XCTAssertEqual(p.x, p.z, "torn snapshot") }
        }
    }

    func testStopInvalidatesDriveCommandsStillQueuedBehindIt() {
        let q = DispatchQueue(label: "coord.test.serial")
        let rec = CoordLeaseRecorder()
        let sink = SerialDriveSink(target: rec, queue: q)
        let gate = DispatchSemaphore(value: 0)
        q.async { gate.wait() }                           // the queue is busy, like a stalled main thread
        sink.drive(left: 1, right: 1)                     // queued before STOP: must never reach the link
        sink.stop()
        sink.drive(left: 2, right: 2)                     // queued after STOP: allowed
        gate.signal()
        q.sync {}
        XCTAssertEqual(rec.events, [.stop, .drive(2, 2)])
    }

    func testDriveWritesRunOnTheOwningQueueNotTheCaller() {
        let q = DispatchQueue(label: "coord.test.owner")
        let key = DispatchSpecificKey<Bool>()
        q.setSpecific(key: key, value: true)
        final class Probe: DriveSink {
            let key: DispatchSpecificKey<Bool>; var onQueue: [Bool] = []
            init(_ k: DispatchSpecificKey<Bool>) { key = k }
            func drive(left: Int, right: Int) { onQueue.append(DispatchQueue.getSpecific(key: key) == true) }
            func stop() { onQueue.append(DispatchQueue.getSpecific(key: key) == true) }
        }
        let probe = Probe(key)
        let sink = SerialDriveSink(target: probe, queue: q)
        DispatchQueue.global().sync { sink.drive(left: 5, right: 5) }
        q.sync {}
        DispatchQueue.global().sync { sink.stop() }
        q.sync {}
        XCTAssertEqual(probe.onQueue, [true, true])
    }

    // PR 33 re-review finding 3: an old task's drain timer must not brake a manual owner that took over.
    func testDrainTimeoutDoesNotBrakeAManualOwner() async throws {
        let r = CoordLeaseRig()
        let running = await r.launch(.findObject(description: "keys"))   // uncooperative: ignores cancel()
        r.coordinator.beginManualControl("drive")
        let stopsAfterBegin = r.recorder.stops
        XCTAssertEqual(r.recorder.drives, [50])
        // The manual tool is now driving; the old task's timer fires.
        await r.clock.advance(by: 3.2)
        XCTAssertEqual(r.recorder.stops, stopsAfterBegin, "drain timeout must not send STOP while manual holds the link")
        XCTAssertNotEqual(r.recorder.events.last, .some(.drive(50, 50)))
        XCTAssertTrue(r.coordinator.trace.contains { $0.event == "drain-timeout" }, "bookkeeping still finishes")
        XCTAssertFalse(r.coordinator.isBusy, "slot released")
        r.finder.release()
        _ = try? await running.value
    }

    func testDrainTimeoutStillBrakesWhenNobodyTookOver() async throws {
        let r = CoordLeaseRig()
        let running = await r.launch(.findObject(description: "keys"))
        r.coordinator.stopAll()
        let stopsAfterStop = r.recorder.stops
        await r.clock.advance(by: 3.2)
        XCTAssertGreaterThan(r.recorder.stops, stopsAfterStop, "no new owner: the timeout brakes as before")
        r.finder.release()
        _ = try? await running.value
    }
}
