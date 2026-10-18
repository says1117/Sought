import Foundation
import XCTest
#if canImport(ComeToMeCore)
@testable import ComeToMeCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif

/// Synthetic UWB clock/range, not device accuracy or stopping-distance measurements.
private final class PairedTestRange: RangingSource {
    private let lock = NSLock()
    private var time = 10.0
    private var reading = RangeSample(distanceM: 1.6, bearingDeg: 0, updatedAt: 10)
    var onSleep: (() -> Void)?
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func latest() -> RangeSample { lock.lock(); defer { lock.unlock() }; return reading }
    func change(_ update: (inout RangeSample) -> Void) { lock.lock(); update(&reading); lock.unlock() }
    func advance(_ dt: Double, refresh: Bool = true) {
        lock.lock(); time += dt; if refresh { reading.updatedAt = time }; lock.unlock()
        onSleep?()
    }
    func sleep(_ dt: Double) async { advance(dt); try? await Task.sleep(nanoseconds: 1_000_000) }
}

private final class PairedTestMotion: ApproachMotion {
    private let lock = NSLock()
    private var segments: [Double] = []
    private var turns: [Double] = []
    private var caps: [Int] = []
    private var stopCount = 0
    var work: () async -> ControlStatus = { .done }
    var onDrive: ((Double) -> Void)?
    var onTurn: (() -> Void)?
    var drives: [Double] { lock.lock(); defer { lock.unlock() }; return segments }
    var rotations: [Double] { lock.lock(); defer { lock.unlock() }; return turns }
    var speedCaps: [Int] { lock.lock(); defer { lock.unlock() }; return caps }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
    private func recordDrive(_ meters: Double, _ cap: Int) { lock.lock(); segments.append(meters); caps.append(cap); lock.unlock() }
    private func recordTurn(_ deg: Double, _ cap: Int) { lock.lock(); turns.append(deg); caps.append(cap); lock.unlock() }
    func drive(meters: Double, bearingDeg: Double, speedCap: Int) async -> ControlStatus {
        recordDrive(meters, speedCap); onDrive?(meters); return await work()
    }
    func rotate(deg: Double, speedCap: Int) async -> ControlStatus {
        recordTurn(deg, speedCap); onTurn?(); return await work()
    }
    func stop() { lock.lock(); stopCount += 1; lock.unlock() }
}

private final class PairedDrainGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var returned = false
    let began: XCTestExpectation
    init(began: XCTestExpectation) { self.began = began }
    func hold() async {
        await withCheckedContinuation { value in
            lock.lock(); continuation = value; lock.unlock()
            began.fulfill()
        }
    }
    func release() {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume()
    }
    func markReturned() { lock.lock(); returned = true; lock.unlock() }
    var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }
}

final class PairedApproachRunnerTests: XCTestCase {
    private func runner(_ range: PairedTestRange, _ motion: PairedTestMotion,
                        config: PairedApproachConfig = PairedApproachConfig()) -> PairedApproachRunner {
        PairedApproachRunner(config: config, ranging: range, motion: motion, clock: range.now, sleep: range.sleep)
    }

    func testUsesBoundedSegmentsAndStopsAtPairedPhoneStandOff() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        motion.onDrive = { meters in range.change { $0.distanceM! -= meters } }
        let result = await runner(range, motion).run()
        XCTAssertEqual(result, .arrived)
        XCTAssertFalse(motion.drives.isEmpty)
        XCTAssertTrue(motion.drives.allSatisfy { $0 > 0 && $0 <= 0.25 })
        XCTAssertTrue(motion.speedCaps.allSatisfy { $0 <= 120 })
        XCTAssertGreaterThanOrEqual(range.latest().distanceM!, 1)
        XCTAssertGreaterThan(motion.stops, 0)
    }

    func testMissingDirectionNeverProbesOrDrives() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        range.change { $0.bearingDeg = nil }
        let result1 = await runner(range, motion).run()
        XCTAssertEqual(result1, .blocked("range_or_direction_unavailable"))
        XCTAssertTrue(motion.drives.isEmpty)
        XCTAssertTrue(motion.rotations.isEmpty)
    }

    func testInvalidAndFutureSamplesNeverMove() async {
        for sample in [RangeSample(distanceM: .nan, bearingDeg: 0, updatedAt: 10),
                       RangeSample(distanceM: -1, bearingDeg: 0, updatedAt: 10),
                       RangeSample(distanceM: 2, bearingDeg: .infinity, updatedAt: 10),
                       RangeSample(distanceM: 2, bearingDeg: 0, updatedAt: 1000)] {
            let range = PairedTestRange(), motion = PairedTestMotion()
            range.change { $0 = sample }
            let subject = PairedApproachRunner(ranging: range, motion: motion, clock: range.now,
                                               sleep: { range.advance($0, refresh: false); await Task.yield() })
            let result2 = await subject.run()
            XCTAssertEqual(result2, .blocked("range_or_direction_unavailable"))
            XCTAssertTrue(motion.drives.isEmpty)
        }
    }

    func testBearingLossDuringMotionStopsAndCancelsWork() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        motion.onDrive = { _ in range.change { $0.bearingDeg = nil } }
        motion.work = { while !Task.isCancelled { await Task.yield() }; return .failed(.cancelled) }
        let result3 = await runner(range, motion).run()
        XCTAssertEqual(result3, .blocked("range_or_direction_lost"))
        XCTAssertGreaterThan(motion.stops, 0)
    }

    func testStaleSampleDuringMotionStops() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        motion.work = { while !Task.isCancelled { await Task.yield() }; return .failed(.cancelled) }
        let subject = PairedApproachRunner(ranging: range, motion: motion, clock: range.now,
                                           sleep: { range.advance($0, refresh: false); try? await Task.sleep(nanoseconds: 1_000_000) })
        let result = await subject.run()
        XCTAssertEqual(result, .blocked("range_or_direction_lost"))
        XCTAssertEqual(motion.drives.count, 1)
        XCTAssertGreaterThan(motion.stops, 0)
    }

    func testAlreadyWithinStandOffNeverMoves() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        range.change { $0.distanceM = 1.1 }
        let result = await runner(range, motion).run()
        XCTAssertEqual(result, .arrived)
        XCTAssertTrue(motion.drives.isEmpty)
        XCTAssertTrue(motion.rotations.isEmpty)
    }

    func testMotionFailureIsNotIgnored() async {
        for failure in [FailureReason.timeout, .trackingLost] {
            let range = PairedTestRange(), motion = PairedTestMotion()
            motion.work = { .failed(failure) }
            let result4 = await runner(range, motion).run()
            XCTAssertEqual(result4, .blocked("motion_failed"))
            XCTAssertEqual(motion.drives.count, 1)
        }
    }

    func testCompletedSegmentRequiresNewMeasurement() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        let subject = PairedApproachRunner(ranging: range, motion: motion, clock: range.now,
                                           sleep: { range.advance($0, refresh: false); try? await Task.sleep(nanoseconds: 1_000_000) })
        let result = await subject.run()
        XCTAssertTrue(result == .blocked("range_or_direction_unavailable") || result == .blocked("range_or_direction_lost"))
        XCTAssertEqual(motion.drives.count, 1)
    }

    func testRotationIsBoundedAndRequiresDirectionBeforeForwardMotion() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        range.change { $0.bearingDeg = 80 }
        motion.onTurn = { range.change { $0.bearingDeg = 0 } }
        motion.onDrive = { meters in range.change { $0.distanceM! -= meters } }
        let result5 = await runner(range, motion).run()
        XCTAssertEqual(result5, .arrived)
        XCTAssertEqual(motion.rotations, [30])
    }

    func testCancelBeforeRunIsStickyAndNeverMoves() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        let subject = runner(range, motion)
        subject.cancel()
        let result6 = await subject.run()
        XCTAssertEqual(result6, .cancelled)
        let result7 = await subject.run()
        XCTAssertEqual(result7, .cancelled)
        XCTAssertTrue(motion.drives.isEmpty)
    }

    func testCancelDuringMotionStopsAndPreventsAnotherSegment() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        let subject = runner(range, motion)
        motion.onDrive = { _ in subject.cancel() }
        motion.work = { while !Task.isCancelled { await Task.yield() }; return .failed(.cancelled) }
        let result8 = await subject.run()
        XCTAssertEqual(result8, .cancelled)
        XCTAssertEqual(motion.drives.count, 1)
        XCTAssertGreaterThan(motion.stops, 0)
    }

    func testOverallDeadlineBoundsMotionEvenWithFreshSamples() async {
        let range = PairedTestRange(), motion = PairedTestMotion()
        motion.work = { while !Task.isCancelled { await Task.yield() }; return .failed(.cancelled) }
        let config = PairedApproachConfig(overallTimeout: 1)
        let result9 = await runner(range, motion, config: config).run()
        XCTAssertEqual(result9, .blocked("timeout"))
        XCTAssertLessThan(range.now(), 11.3)
        XCTAssertGreaterThan(motion.stops, 0)
    }

    func testConfigCannotRaiseMotionOrTimeBounds() {
        let config = PairedApproachConfig(stopDistance: -1, segmentMax: 100, overallTimeout: .infinity, sampleWait: 100)
        XCTAssertGreaterThanOrEqual(config.stopDistance, 1)
        XCTAssertLessThanOrEqual(config.segmentMax, 0.25)
        XCTAssertLessThanOrEqual(config.overallTimeout, 60)
        XCTAssertLessThanOrEqual(config.sampleWait, 3)
    }

    func testLostDirectionDrainsControllerCleanupBeforeReturningOwnership() async {
        let began = expectation(description: "motion entered")
        let gate = PairedDrainGate(began: began)
        let range = PairedTestRange(), motion = PairedTestMotion()
        motion.onDrive = { _ in range.change { $0.bearingDeg = nil } }
        // Deliberately delay cancellation cleanup, as a controller can do until its next tick.
        motion.work = { await gate.hold(); return .failed(.cancelled) }
        let subject = runner(range, motion)
        let task = Task {
            let result = await subject.run()
            gate.markReturned()
            return result
        }
        await fulfillment(of: [began], timeout: 2)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertGreaterThan(motion.stops, 0)
        XCTAssertFalse(gate.hasReturned, "a late controller STOP must finish before a successor can take ownership")
        gate.release()
        let result = await task.value
        XCTAssertEqual(result, .blocked("range_or_direction_lost"))
    }
}
