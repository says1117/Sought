import XCTest
#if canImport(RobotToolsCore)
@testable import RobotToolsCore
#endif
#if canImport(ExploreCore)
@testable import ExploreCore
#endif
#if canImport(PoseCore)
@testable import PoseCore
#endif

// Synthetic fakes only. Nothing here measures a real rover.

final class RTFakeScanRig: ExploreDrive, ExploreClock, ExplorePoseSource, ScanHereGate {
    // The scan runs turns on background tasks while tests read and write from the main actor: every field is behind one lock.
    private let lock = NSLock()
    private var _tracking: TrackingKind = .normal
    private var _otherTaskActive = false, _manualToolHeld = false
    private var _rotations: [Double] = [], _sleeps: [Double] = [], _events: [String] = []
    private var _stops = 0
    private var _rotateResults: [DriveResult] = []
    private var _onSleep: ((Int) -> Void)?, _onRotate: ((Int) -> Void)?
    private var _blockRotate = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var _driveAvailable = true, _grantCurrent = true
    private var _registeredCancel: (() -> Void)?
    private var _scanEndedCount = 0
    private var _acquireCount = 0

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var tracking: TrackingKind { get { locked { _tracking } } set { locked { _tracking = newValue } } }
    var otherTaskActive: Bool { get { locked { _otherTaskActive } } set { locked { _otherTaskActive = newValue } } }
    var manualToolHeld: Bool { get { locked { _manualToolHeld } } set { locked { _manualToolHeld = newValue } } }
    var rotations: [Double] { get { locked { _rotations } } set { locked { _rotations = newValue } } }
    var stops: Int { locked { _stops } }
    var sleeps: [Double] { locked { _sleeps } }
    var events: [String] { locked { _events } }
    var rotateResults: [DriveResult] { get { locked { _rotateResults } } set { locked { _rotateResults = newValue } } }
    var onSleep: ((Int) -> Void)? { get { locked { _onSleep } } set { locked { _onSleep = newValue } } }
    var onRotate: ((Int) -> Void)? { get { locked { _onRotate } } set { locked { _onRotate = newValue } } }
    /// When set, rotateBy suspends until stop() is called, like a real turn in progress.
    var blockRotate: Bool { get { locked { _blockRotate } } set { locked { _blockRotate = newValue } } }
    var driveAvailable: Bool { get { locked { _driveAvailable } } set { locked { _driveAvailable = newValue } } }
    var grantCurrent: Bool { get { locked { _grantCurrent } } set { locked { _grantCurrent = newValue } } }
    var registeredCancel: (() -> Void)? { get { locked { _registeredCancel } } set { locked { _registeredCancel = newValue } } }
    var scanEndedCount: Int { locked { _scanEndedCount } }
    var acquireCount: Int { locked { _acquireCount } }

    func acquireDrive() -> ScanDriveGrant? { locked { _acquireCount += 1 }; guard driveAvailable else { return nil }; grantCurrent = true; return RTFakeGrant(rig: self) }
    func scanStarted(cancel: @escaping () -> Void) { registeredCancel = cancel }
    func scanEnded() { locked { _scanEndedCount += 1; _registeredCancel = nil } }

    func goTo(x: Double, z: Double, stopDistance: Double) async -> DriveResult { .failed }
    func rotateBy(_ deg: Double) async -> DriveResult {
        let (count, hook, block) = locked { () -> (Int, ((Int) -> Void)?, Bool) in
            _rotations.append(deg); _events.append("rotate")
            return (_rotations.count, _onRotate, _blockRotate)
        }
        hook?(count)
        if block {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in locked { blocked = c } }
            return .cancelled
        }
        return locked { _rotateResults.isEmpty ? .reached : _rotateResults.removeFirst() }
    }
    func stop() {
        let c = locked { () -> CheckedContinuation<Void, Never>? in
            _stops += 1; _events.append("stop"); let c = blocked; blocked = nil; return c
        }
        c?.resume()
    }
    func now() -> Double { 0 }
    func sleep(_ seconds: Double) async {
        let (n, hook) = locked { () -> (Int, ((Int) -> Void)?) in
            _sleeps.append(seconds); _events.append("dwell"); return (_sleeps.count, _onSleep)
        }
        hook?(n)
    }
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (Pose2D(x: 0, z: 0, yawDeg: 0), tracking) }
}

final class RTFakeGrant: ScanDriveGrant {
    private let rig: RTFakeScanRig   // strong: the scan's watcher can outlive the test by a tick
    init(rig: RTFakeScanRig) { self.rig = rig }
    var isCurrent: Bool { rig.grantCurrent }
    func run(_ body: () async -> Void) async { await body() }
    func revoke() { rig.grantCurrent = false }
}

@MainActor
final class RobotToolsScanTests: XCTestCase {
    private var stopAllCalls = 0

    private func model(_ rig: RTFakeScanRig) -> ScanHereModel {
        stopAllCalls = 0
        return ScanHereModel(drive: rig, clock: rig, poses: rig, gate: rig, stopAll: { [weak self] in self?.stopAllCalls += 1 })
    }

    func testFullScanIsFourTurnsOf90WithDwellEach() async {
        let rig = RTFakeScanRig()
        let m = model(rig)
        await m.run()
        XCTAssertEqual(rig.rotations, [90, 90, 90, 90])
        XCTAssertEqual(rig.sleeps, [1.5, 1.5, 1.5, 1.5])
        XCTAssertEqual(rig.events, ["dwell", "rotate", "dwell", "rotate", "dwell", "rotate", "dwell", "rotate", "stop"])
        XCTAssertEqual(m.state, .finished)
    }

    func testProgressShowsOneToFourWhileDwelling() async {
        let rig = RTFakeScanRig()
        let m = model(rig)
        var labels: [String?] = []
        rig.onSleep = { _ in labels.append(m.state.stepLabel) }
        await m.run()
        XCTAssertEqual(labels, ["1/4", "2/4", "3/4", "4/4"])
    }

    func testCancelDuringDwellStopsAndEnds() async {
        let rig = RTFakeScanRig()
        let m = model(rig)
        rig.onSleep = { n in if n == 2 { m.cancel() } }
        await m.run()
        XCTAssertEqual(m.state, .cancelled)
        XCTAssertEqual(rig.rotations.count, 1)             // only the turn after stop 1
        XCTAssertGreaterThanOrEqual(rig.stops, 1)
        XCTAssertGreaterThanOrEqual(stopAllCalls, 1)
    }

    func testCancelAtEveryStepSendsStop() async {
        for cancelAt in 1...4 {
            let rig = RTFakeScanRig()
            let m = model(rig)
            rig.onSleep = { n in if n == cancelAt { m.cancel() } }
            await m.run()
            XCTAssertEqual(m.state, .cancelled, "cancel at stop \(cancelAt)")
            XCTAssertEqual(rig.rotations.count, cancelAt - 1)
            XCTAssertGreaterThanOrEqual(rig.stops, 1)
        }
    }

    func testCancelMidTurnEndsAndStops() async {
        let rig = RTFakeScanRig()
        rig.blockRotate = true
        let m = model(rig)
        m.start()
        while rig.rotations.isEmpty { await Task.yield() }
        XCTAssertEqual(m.state, .turning(step: 1, total: 4))
        m.cancel()
        while m.state.isRunning { await Task.yield() }
        XCTAssertEqual(m.state, .cancelled)
        XCTAssertGreaterThanOrEqual(rig.stops, 1)
        XCTAssertEqual(rig.rotations.count, 1)
    }

    func testRefusesWhenTrackingNotNormal() async {
        let rig = RTFakeScanRig()
        rig.tracking = .limited
        let m = model(rig)
        await m.run()
        guard case .refused = m.state else { return XCTFail("\(m.state)") }
        XCTAssertTrue(rig.rotations.isEmpty)
        XCTAssertTrue(rig.sleeps.isEmpty)
    }

    func testRefusesWhenAnotherTaskActive() async {
        let rig = RTFakeScanRig()
        rig.otherTaskActive = true
        let m = model(rig)
        await m.run()
        guard case .refused = m.state else { return XCTFail("\(m.state)") }
        XCTAssertTrue(rig.rotations.isEmpty)
    }

    func testRefusesWhenManualToolHoldsLease() async {
        let rig = RTFakeScanRig()
        rig.manualToolHeld = true
        let m = model(rig)
        await m.run()
        guard case .refused = m.state else { return XCTFail("\(m.state)") }
        XCTAssertTrue(rig.rotations.isEmpty)
    }

    func testTrackingLossBetweenStepsAbortsAndStops() async {
        let rig = RTFakeScanRig()
        let m = model(rig)
        rig.onSleep = { n in if n == 2 { rig.tracking = .limited } }
        await m.run()
        guard case .stopped(let reason) = m.state else { return XCTFail("\(m.state)") }
        XCTAssertTrue(reason.contains("tracking"))
        XCTAssertEqual(rig.rotations.count, 1)
        XCTAssertGreaterThanOrEqual(rig.stops, 1)
    }

    func testTrackingLostDuringTurnAbortsAndStops() async {
        let rig = RTFakeScanRig()
        rig.rotateResults = [.reached, .trackingLost]
        let m = model(rig)
        await m.run()
        guard case .stopped = m.state else { return XCTFail("\(m.state)") }
        XCTAssertEqual(rig.rotations.count, 2)
        XCTAssertGreaterThanOrEqual(rig.stops, 1)
    }

    func testFailedTurnAbortsAndStops() async {
        let rig = RTFakeScanRig()
        rig.rotateResults = [.failed]
        let m = model(rig)
        await m.run()
        guard case .stopped = m.state else { return XCTFail("\(m.state)") }
        XCTAssertGreaterThanOrEqual(rig.stops, 1)
    }

    func testStopButtonAlwaysSendsStopEvenWhenIdle() {
        let rig = RTFakeScanRig()
        let m = model(rig)
        m.cancel()
        XCTAssertEqual(rig.stops, 1)
        XCTAssertEqual(stopAllCalls, 1)
        XCTAssertEqual(m.state, .idle)
    }

    func testStartWhileRunningIsIgnored() async {
        let rig = RTFakeScanRig()
        rig.blockRotate = true
        let m = model(rig)
        m.start()
        while rig.rotations.isEmpty { await Task.yield() }
        m.start()
        await m.run()                                       // returns at once: already running
        XCTAssertEqual(rig.rotations.count, 1)
        m.cancel()
        while m.state.isRunning { await Task.yield() }
    }

    func testRestartAfterCancelWorks() async {
        let rig = RTFakeScanRig()
        let m = model(rig)
        rig.onSleep = { n in if n == 1 { m.cancel() } }
        await m.run()
        XCTAssertEqual(m.state, .cancelled)
        rig.onSleep = nil
        rig.rotations = []
        await m.run()
        XCTAssertEqual(m.state, .finished)
        XCTAssertEqual(rig.rotations.count, 4)
    }

    func testProgressText() {
        XCTAssertEqual(ScanHereState.dwelling(step: 2, total: 4).progressText, "Looking: stop 2 of 4")
        XCTAssertNil(ScanHereState.finished.stepLabel)
    }

    /// The runtime's global STOP: take the registered cancel out of its slot and call it, exactly as stopEverything does.
    private func globalStop(_ rig: RTFakeScanRig) {
        let cancel = rig.registeredCancel
        rig.registeredCancel = nil
        cancel?()
    }

    func testStopBetweenStartAndQueuedTaskNeverDrives() async {
        let rig = RTFakeScanRig()
        let m = model(rig)
        m.start()
        XCTAssertNotNil(rig.registeredCancel, "start() must register cancellation before the task runs")
        globalStop(rig)                                     // no suspension between start() and STOP
        for _ in 0..<50 { await Task.yield() }              // let the queued task run
        XCTAssertEqual(rig.acquireCount, 0, "no lease after STOP")
        XCTAssertTrue(rig.rotations.isEmpty, "no drive command after STOP")
        XCTAssertFalse(m.state.isRunning)
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(rig.registeredCancel)
    }

    func testBackgroundThenActiveBeforeQueuedTaskDoesNotStart() async {
        let rig = RTFakeScanRig()
        let m = model(rig)
        m.start()
        globalStop(rig)                                     // background
        // returning to active starts nothing by itself
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(rig.acquireCount, 0)
        XCTAssertTrue(rig.rotations.isEmpty)
        XCTAssertEqual(m.state, .idle)
        // a fresh explicit Start works
        m.start()
        while m.state != .finished { await Task.yield() }
        XCTAssertEqual(rig.rotations, [90, 90, 90, 90])
    }

    func testNormalStartStillRunsAndUnregisters() async {
        let rig = RTFakeScanRig()
        let m = model(rig)
        m.start()
        XCTAssertNotNil(rig.registeredCancel)
        while m.state != .finished { await Task.yield() }
        XCTAssertEqual(rig.rotations, [90, 90, 90, 90])
        XCTAssertEqual(rig.acquireCount, 1)
        while rig.registeredCancel != nil { await Task.yield() }
    }

    func testRefusedStartUnregisters() async {
        let rig = RTFakeScanRig()
        rig.tracking = .limited
        let m = model(rig)
        m.start()
        while rig.registeredCancel != nil { await Task.yield() }
        guard case .refused = m.state else { return XCTFail("\(m.state)") }
    }

    func testGlobalStopDuringDwellViaRegisteredCancel() async {
        let rig = RTFakeScanRig()
        let m = model(rig)
        rig.onSleep = { [unowned self] n in if n == 2 { self.globalStop(rig) } }
        m.start()
        while m.state.isRunning || m.state == .idle { await Task.yield() }
        XCTAssertEqual(m.state, .cancelled)
        XCTAssertEqual(rig.rotations.count, 1)
    }

    func testGlobalStopDuringRotationViaRegisteredCancel() async {
        let rig = RTFakeScanRig()
        rig.blockRotate = true
        let m = model(rig)
        m.start()
        while rig.rotations.isEmpty { await Task.yield() }
        globalStop(rig)
        while m.state.isRunning { await Task.yield() }
        XCTAssertEqual(m.state, .cancelled)
        XCTAssertEqual(rig.rotations.count, 1)
    }
}
