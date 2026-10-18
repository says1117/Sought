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
    var tracking: TrackingKind = .normal
    var otherTaskActive = false
    var manualToolHeld = false
    var rotations: [Double] = []
    var stops = 0
    var sleeps: [Double] = []
    var events: [String] = []
    var rotateResults: [DriveResult] = []
    var onSleep: ((Int) -> Void)?
    var onRotate: ((Int) -> Void)?
    /// When set, rotateBy suspends until stop() is called, like a real turn in progress.
    var blockRotate = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var stoppedWhileBlocked = false

    func goTo(x: Double, z: Double, stopDistance: Double) async -> DriveResult { .failed }
    func rotateBy(_ deg: Double) async -> DriveResult {
        rotations.append(deg); events.append("rotate")
        onRotate?(rotations.count)
        if blockRotate {
            await withCheckedContinuation { c in blocked = c }
            return .cancelled
        }
        return rotateResults.isEmpty ? .reached : rotateResults.removeFirst()
    }
    func stop() { stops += 1; events.append("stop"); blocked?.resume(); blocked = nil }
    func now() -> Double { 0 }
    func sleep(_ seconds: Double) async { sleeps.append(seconds); events.append("dwell"); onSleep?(sleeps.count) }
    func latest() -> (pose: Pose2D?, tracking: TrackingKind) { (Pose2D(x: 0, z: 0, yawDeg: 0), tracking) }
}

@MainActor
final class RobotToolsScanTests: XCTestCase {
    private var stopAllCalls = 0

    private func model(_ rig: RTFakeScanRig) -> ScanHereModel {
        stopAllCalls = 0
        return ScanHereModel(drive: rig, clock: rig, poses: rig, gate: rig, stopAll: { [unowned self] in self.stopAllCalls += 1 })
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
}
