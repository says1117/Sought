import XCTest
#if canImport(RobotToolsCore)
@testable import RobotToolsCore
#endif
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

// PR 38 review P1: global STOP / backgrounding must cancel the scan and revoke its drive lease. These run the REAL
// ScanHereModel, ScanRoutine, Controller, DriveLease, LeasedDriveSink and SerialDriveSink with a recording base sink.
// Only the clock, the pose and the wheels are synthetic. Nothing here measures a real rover.
// Prefixed RTLease because the RecallTests bundle compiles every test file into one module.

final class RTLeaseRecorder: DriveSink {
    enum Event: Equatable { case drive(Int, Int), stop }
    private let lock = NSLock()
    private var log: [Event] = []
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return log }
    var driveCount: Int { events.filter { if case .drive = $0 { return true } else { return false } }.count }
    /// Drive commands after the last STOP (nil-safe: all drives when there was never a STOP).
    var drivesAfterLastStop: Int {
        let e = events
        guard let i = e.lastIndex(of: .stop) else { return e.count }
        return e[(i + 1)...].filter { if case .drive = $0 { return true } else { return false } }.count
    }
    func drive(left: Int, right: Int) { lock.lock(); log.append(.drive(left, right)); lock.unlock() }
    func stop() { lock.lock(); log.append(.stop); lock.unlock() }
}

final class RTLeasePose: PoseSource, ExplorePoseSource {
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (Pose2D(x: 0, z: 0, yawDeg: 0), .normal) }   // never turns
}

/// Dwell that waits until released, but returns early on task cancellation like the real clock.
final class RTLeaseClock: ExploreClock {
    private let lock = NSLock()
    private var _dwells = 0, _released = 0
    var dwells: Int { lock.lock(); defer { lock.unlock() }; return _dwells }
    func releaseAll() { lock.lock(); _released = Int.max; lock.unlock() }
    func now() -> Double { 0 }
    private func enter() { lock.lock(); _dwells += 1; lock.unlock() }
    private var released: Bool { lock.lock(); defer { lock.unlock() }; return _released == Int.max }
    func sleep(_ seconds: Double) async {
        enter()
        while !Task.isCancelled {
            if released { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

final class RTLeaseTicker {
    private let lock = NSLock()
    private var t = 0.0
    func tick() -> Double { lock.lock(); defer { lock.unlock() }; t += 0.001; return t }
}

@MainActor
final class RTLeaseRig {
    let lease = DriveLease()
    let recorder = RTLeaseRecorder()
    let serial: SerialDriveSink
    let queue = DispatchQueue(label: "rt.lease.serial")
    let clock = RTLeaseClock()
    let poses = RTLeasePose()
    var coordinatorBusy = false
    var registeredCancel: (() -> Void)?
    var scanEnded = 0
    var model: ScanHereModel!
    private let ticker = RTLeaseTicker()

    init() {
        serial = SerialDriveSink(target: recorder, queue: queue, isOnQueue: { false })
        let controller = Controller(
            poses: poses, sink: LeasedDriveSink(base: serial, lease: lease), guardState: { .clear },
            clock: { [ticker] in ticker.tick() },
            sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        let gate = LeaseScanGate(lease: lease, coordinatorBusy: { [weak self] in self?.coordinatorBusy ?? false },
                                 register: { [weak self] c in self?.registeredCancel = c },
                                 unregister: { [weak self] in self?.registeredCancel = nil; self?.scanEnded += 1 })
        // The real stopAll is runtime.stopEverything: coordinator.stopAll (lease.revoke + drive.stop) + link.stop.
        model = ScanHereModel(drive: ControllerScanDrive(controller: controller), clock: clock, poses: poses, gate: gate,
                              stopAll: { [weak self] in self?.coordinatorStop() })
    }

    /// What RobotCoordinator.stopAll does to the drive path: revoke the lease, then STOP through the serial sink.
    func coordinatorStop() { lease.revoke(); serial.stop() }

    func drain() { queue.sync {} }

    func wait(_ what: String, _ cond: () -> Bool) async {
        for _ in 0..<2000 where !cond() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }
}

@MainActor
final class RobotToolsLeaseTests: XCTestCase {
    /// Global STOP that does NOT reach the scan's own cancel (only the coordinator-level revoke + brake), during dwell.
    /// This is the reviewer's harness: before the fix the scan kept its own sink and drove again after the STOPs.
    func testGlobalStopDuringDwellLeavesNoDriveAfterTheStop() async {
        let r = RTLeaseRig()
        r.model.start()
        await r.wait("first dwell") { r.clock.dwells == 1 }
        r.coordinatorStop(); r.coordinatorStop()          // STOP, STOP
        r.clock.releaseAll()                              // the dwell ends and the scan would turn next
        await r.wait("scan to end") { !r.model.state.isRunning }
        try? await Task.sleep(nanoseconds: 30_000_000)
        r.drain()
        XCTAssertEqual(r.recorder.drivesAfterLastStop, 0, "\(r.recorder.events)")
        XCTAssertEqual(r.recorder.driveCount, 0, "a revoked scan must not even start turning")
        XCTAssertEqual(r.model.state, .cancelled)
    }

    func testGlobalStopDuringRotationLeavesNoDriveAfterTheStop() async {
        let r = RTLeaseRig()
        r.clock.releaseAll()
        r.model.start()
        await r.wait("rotation drives") { r.recorder.driveCount >= 3 }
        r.coordinatorStop()
        r.drain()
        let atStop = r.recorder.driveCount
        await r.wait("scan to end") { !r.model.state.isRunning }
        try? await Task.sleep(nanoseconds: 50_000_000)
        r.drain()
        XCTAssertEqual(r.recorder.drivesAfterLastStop, 0, "\(r.recorder.events.suffix(8))")
        XCTAssertEqual(r.recorder.driveCount, atStop, "no drive command lands after the STOP")
        XCTAssertEqual(r.recorder.events.last, .stop)
        XCTAssertEqual(r.model.state, .cancelled)
    }

    /// pause() / stopEverything() call the cancel the scan registered with the runtime.
    func testRuntimeCancelDuringRotationRevokesAndStops() async {
        let r = RTLeaseRig()
        r.clock.releaseAll()
        r.model.start()
        await r.wait("rotation drives") { r.recorder.driveCount >= 2 }
        XCTAssertNotNil(r.registeredCancel, "a running scan is registered for runtime cancellation")
        r.registeredCancel?()
        r.drain()
        let atCancel = r.recorder.driveCount
        await r.wait("scan to end") { !r.model.state.isRunning }
        try? await Task.sleep(nanoseconds: 50_000_000)
        r.drain()
        XCTAssertEqual(r.recorder.driveCount, atCancel)
        XCTAssertEqual(r.recorder.drivesAfterLastStop, 0)
        XCTAssertEqual(r.model.state, .cancelled)
        XCTAssertNil(r.registeredCancel, "unregistered once the scan ended")
    }

    /// Background (pause) then active: nothing resumes; a new scan needs an explicit start and a fresh lease.
    func testBackgroundThenActiveDoesNotResumeWithoutFreshStart() async {
        let r = RTLeaseRig()
        r.model.start()
        await r.wait("first dwell") { r.clock.dwells == 1 }
        r.registeredCancel?()                 // scene phase left active -> runtime.pause() -> stopEverything()
        r.coordinatorStop()
        await r.wait("scan to end") { !r.model.state.isRunning }
        // Back to active: nothing restarts by itself, even if the dwell would now finish.
        r.clock.releaseAll()
        try? await Task.sleep(nanoseconds: 80_000_000)
        r.drain()
        XCTAssertEqual(r.recorder.driveCount, 0)
        XCTAssertEqual(r.model.state, .cancelled)
        XCTAssertFalse(r.model.state.isRunning)

        // A fresh explicit start takes a fresh lease and works.
        r.model.start()
        await r.wait("fresh scan drives") { r.recorder.driveCount >= 1 }
        r.model.cancel()
        await r.wait("fresh scan to end") { !r.model.state.isRunning }
        r.drain()
        XCTAssertEqual(r.recorder.drivesAfterLastStop, 0)
    }

    /// A stale tick (a scan task that is still alive after revocation, including a child task) sends nothing.
    func testStaleScanTickAfterRevocationSendsNothing() async {
        let r = RTLeaseRig()
        let gate = LeaseScanGate(lease: r.lease, coordinatorBusy: { false }, register: { _ in }, unregister: {})
        let grant = gate.acquireDrive()!
        let leased = LeasedDriveSink(base: r.serial, lease: r.lease)
        let release = RTLeaseAsyncGate()
        let done = RTLeaseAsyncGate()
        Task {
            await grant.run {
                leased.drive(left: -150, right: 150)                         // a live tick
                await release.wait()
                leased.drive(left: -150, right: 150)                         // stale tick in the same task
                await Task { leased.drive(left: -150, right: 150) }.value    // stale tick in a child task
            }
            await done.open()
        }
        await r.wait("live tick") { r.recorder.driveCount == 0 ? { r.drain(); return r.recorder.driveCount == 1 }() : true }
        r.coordinatorStop()
        await release.open()
        await done.wait()
        r.drain()
        XCTAssertEqual(r.recorder.events, [.drive(-150, 150), .stop])
        XCTAssertFalse(grant.isCurrent)
    }

    func testRefusedWhileCoordinatorHasTaskOrManualToolHolds() async {
        let r = RTLeaseRig()
        r.coordinatorBusy = true
        await r.model.run()
        guard case .refused = r.model.state else { return XCTFail("\(r.model.state)") }

        r.coordinatorBusy = false
        r.lease.holdManual("drive")
        await r.model.run()
        guard case .refused = r.model.state else { return XCTFail("\(r.model.state)") }
        r.lease.releaseManual("drive")
        r.drain()
        XCTAssertEqual(r.recorder.driveCount, 0)
        XCTAssertEqual(r.scanEnded, 0, "a refused scan never registered")
    }

    /// A coordinator task starting mid-scan takes a new lease token, which ends the scan; it never fights for the wheels.
    func testCoordinatorTakingTheLeaseEndsTheScan() async {
        let r = RTLeaseRig()
        r.clock.releaseAll()
        r.model.start()
        await r.wait("rotation drives") { r.recorder.driveCount >= 2 }
        _ = r.lease.grant()                   // what RobotCoordinator.runActive does for a new task
        await r.wait("scan to end") { !r.model.state.isRunning }
        let after = r.recorder.driveCount
        try? await Task.sleep(nanoseconds: 40_000_000)
        r.drain()
        XCTAssertEqual(r.recorder.driveCount, after)
        XCTAssertEqual(r.model.state, .cancelled)
    }
}

actor RTLeaseAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async { if isOpen { return }; await withCheckedContinuation { waiters.append($0) } }
}
