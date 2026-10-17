import XCTest
#if canImport(ComeToMeCore)
@testable import ComeToMeCore
#endif
#if canImport(ControllerCore)
@testable import ControllerCore
#endif
#if canImport(PoseCore)
@testable import PoseCore
#endif

// Logic tests against fakes and a simulated rover. They show the state machine does what it was written to do.
// They say nothing about real UWB behavior, real Vision output, or the real rover.

final class CompanionMessageTests: XCTestCase {
    func json(_ m: CompanionMessage) throws -> String { String(data: try CompanionCodec.encode(m), encoding: .utf8)! }

    func testExactWireFormat() throws {
        XCTAssertEqual(try json(.hello(role: .robot, version: 1)), #"{"role":"robot","type":"hello","version":1}"#)
        XCTAssertEqual(try json(.niToken(tokenB64: "QUJD")), #"{"token_b64":"QUJD","type":"ni_token"}"#)
        XCTAssertEqual(try json(.comeToMe(id: "cmd_ab12")), #"{"id":"cmd_ab12","type":"come_to_me"}"#)
        XCTAssertEqual(try json(.cancel(id: "cmd_ab12")), #"{"id":"cmd_ab12","type":"cancel"}"#)
        XCTAssertEqual(try json(.status(id: "c", state: .approaching, distanceM: 2.5, reason: nil)),
                       #"{"distance_m":2.5,"id":"c","state":"approaching","type":"status"}"#)
        XCTAssertEqual(try json(.status(id: "c", state: .failed, distanceM: nil, reason: "uwb_lost")),
                       #"{"id":"c","reason":"uwb_lost","state":"failed","type":"status"}"#)
    }

    func testRoundTripAndOptionalFieldsAbsent() throws {
        let all: [CompanionMessage] = [.hello(role: .companion, version: 1), .niToken(tokenB64: "x"), .comeToMe(id: "cmd_1"),
            .status(id: "cmd_1", state: .arrived, distanceM: 1.0, reason: nil), .status(id: "cmd_1", state: .accepted, distanceM: nil, reason: nil),
            .cancel(id: "cmd_1")]
        for m in all { XCTAssertEqual(try CompanionCodec.decode(try CompanionCodec.encode(m)), m) }
    }

    func testRejectsUnknownAndMalformed() {
        XCTAssertThrowsError(try CompanionCodec.decode(Data(#"{"type":"explode"}"#.utf8)))
        XCTAssertThrowsError(try CompanionCodec.decode(Data(#"{"type":"come_to_me"}"#.utf8)))
        XCTAssertThrowsError(try CompanionCodec.decode(Data("nope".utf8)))
    }

    func testCommandIdPrefixAndServiceType() {
        XCTAssertTrue(CompanionCodec.newCommandId().hasPrefix("cmd_"))
        XCTAssertEqual(CompanionMessage.serviceType, "recall-ni")
    }
}

final class ApproachPlannerTests: XCTestCase {
    func input(_ now: Double, d: Double?, b: Double?, upd: Double?, person: PersonObservation? = nil, vision: Bool = false) -> ApproachInput {
        ApproachInput(now: now, distanceM: d, bearingDeg: b, lastUpdateAt: upd, person: person, visionAvailable: vision)
    }

    func testTurnsThenDrivesThenStopsAtOneMeter() {
        var p = ApproachPlanner(); p.start(now: 0)
        XCTAssertEqual(p.step(input(0.1, d: 4, b: 40, upd: 0.1)), .rotate(deg: 40, speedCap: 120))
        p.motionFinished(at: 0.5)
        XCTAssertEqual(p.step(input(0.6, d: 4, b: 40, upd: 0.4)), .wait, "old sample must not be used after a motion")
        XCTAssertEqual(p.step(input(0.7, d: 4, b: 3, upd: 0.7)), .drive(meters: 0.4, bearingDeg: 3, speedCap: 120))
        p.motionFinished(at: 1.5)
        // 1.2 m away: remaining 0.2 m, shorter segment
        guard case let .drive(m, _, _) = p.step(input(1.6, d: 1.2, b: 0, upd: 1.6)) else { return XCTFail() }
        XCTAssertEqual(m, 0.2, accuracy: 1e-9)
        XCTAssertEqual(p.step(input(2.0, d: 1.04, b: 0, upd: 2.0)), .stop)
        XCTAssertEqual(p.phase, .arrived(confirmed: false))
        XCTAssertEqual(p.companionStatus.state, .arrived)
    }

    func testNeverDrivesPastStopDistance() {
        var p = ApproachPlanner(); p.start(now: 0)
        if case let .drive(m, _, _) = p.step(input(0.1, d: 1.2, b: 0, upd: 0.1)) { XCTAssertLessThanOrEqual(m, 0.2 + 1e-9) } else { XCTFail() }
        var q = ApproachPlanner(); q.start(now: 0)
        XCTAssertEqual(q.step(input(0.1, d: 0.7, b: 0, upd: 0.1)), .stop)
    }

    func testAbortsAfterTwoSecondsWithoutUpdates() {
        var p = ApproachPlanner(); p.start(now: 0)
        _ = p.step(input(0.1, d: 3, b: 0, upd: 0.1))
        XCTAssertEqual(p.step(input(2.0, d: 3, b: 0, upd: 0.1)).isMotion, true, "1.9 s old: still ok")
        p.motionFinished(at: 2.0)
        XCTAssertEqual(p.step(input(2.2, d: 3, b: 0, upd: 0.1)), .stop)
        XCTAssertEqual(p.phase, .failed("uwb_lost"))
        XCTAssertEqual(p.companionStatus.reason, "uwb_lost")
    }

    func testNoFirstSampleFailsAfterGrace() {
        var p = ApproachPlanner(); p.start(now: 0)
        XCTAssertEqual(p.step(input(3, d: nil, b: nil, upd: nil)), .wait)
        XCTAssertEqual(p.step(input(5.5, d: nil, b: nil, upd: nil)), .stop)
        XCTAssertEqual(p.phase, .failed("no_uwb"))
    }

    func testCancelAndOverallTimeout() {
        var p = ApproachPlanner(); p.start(now: 0); p.cancel()
        XCTAssertEqual(p.step(input(1, d: 3, b: 0, upd: 1)), .stop)
        XCTAssertEqual(p.phase, .cancelled)
        var q = ApproachPlanner(); q.start(now: 0)
        XCTAssertEqual(q.step(input(121, d: 3, b: 0, upd: 121)), .stop)
        XCTAssertEqual(q.phase, .failed("timeout"))
    }

    func testSearchProbesThenTurnsByEstimatedAngle() {
        var p = ApproachPlanner(); p.start(now: 0)
        XCTAssertEqual(p.step(input(1, d: 3, b: nil, upd: 1)), .drive(meters: 0.4, bearingDeg: 0, speedCap: 120))
        XCTAssertEqual(p.phase, .searching)
        p.motionFinished(at: 1.1)
        // The user is 90 deg off the travel direction: range barely grows (sqrt(3^2 + 0.4^2)).
        guard case let .rotate(deg, _) = p.step(input(2, d: (9.0 + 0.16).squareRoot(), b: nil, upd: 2)) else { return XCTFail() }
        XCTAssertEqual(deg, 90, accuracy: 0.5)
    }

    func testSearchKeepsDrivingWhileRangeFalls() {
        var p = ApproachPlanner(); p.start(now: 0)
        _ = p.step(input(1, d: 3, b: nil, upd: 1)); p.motionFinished(at: 1.1)
        XCTAssertEqual(p.step(input(2, d: 2.6, b: nil, upd: 2)), .drive(meters: 0.4, bearingDeg: 0, speedCap: 120))
    }

    func testSearchFlipsTurnDirectionWhenAngleDoesNotShrink() {
        var p = ApproachPlanner(); p.start(now: 0)
        _ = p.step(input(1, d: 3, b: nil, upd: 1)); p.motionFinished(at: 1.1)
        guard case let .rotate(first, _) = p.step(input(2, d: 3.03, b: nil, upd: 2)) else { return XCTFail() }
        p.motionFinished(at: 2.1)
        _ = p.step(input(3, d: 3.03, b: nil, upd: 3)); p.motionFinished(at: 3.1)     // probe again
        guard case let .rotate(second, _) = p.step(input(4, d: 3.4, b: nil, upd: 4)) else { return XCTFail() }  // turned the wrong way: angle > 90
        XCTAssertTrue(first > 0 && second < 0, "first turn left, then flip: \(first) \(second)")
    }

    func testSearchGivesUpAfterMaxProbesWhenNothingImproves() {
        var p = ApproachPlanner(); p.start(now: 0)
        var t = 0.0, done = false
        for _ in 0..<200 {
            t += 1
            let a = p.step(input(t, d: 3, b: nil, upd: t))      // flat range: no gradient anywhere
            if a == .stop { done = true; break }
            p.motionFinished(at: t + 0.01)
        }
        XCTAssertTrue(done)
        XCTAssertEqual(p.phase, .failed("no_direction"))
    }

    func testSearchEndsWhenDirectionAppears() {
        var p = ApproachPlanner(); p.start(now: 0)
        _ = p.step(input(1, d: 3, b: nil, upd: 1)); p.motionFinished(at: 1.1)
        XCTAssertEqual(p.step(input(2, d: 3, b: 10, upd: 2)), .drive(meters: 0.4, bearingDeg: 10, speedCap: 120))
        XCTAssertEqual(p.phase, .approaching)
    }

    func testVisionPhaseLowersCapAndCentersOnPerson() {
        var p = ApproachPlanner(); p.start(now: 0)
        let person = PersonObservation(bearingDeg: -8, distanceM: 2.0)
        XCTAssertEqual(p.step(input(1, d: 2.2, b: 25, upd: 1, person: person, vision: true)),
                       .drive(meters: 0.4, bearingDeg: -8, speedCap: 100))
        p.motionFinished(at: 1.1)
        XCTAssertEqual(p.step(input(2, d: 3.5, b: 0, upd: 2, person: person, vision: true)),
                       .drive(meters: 0.4, bearingDeg: 0, speedCap: 120), "outside vision range UWB wins and the cap is the far cap")
    }

    func testArrivalNeedsPersonWhenVisionAvailable() {
        var p = ApproachPlanner(); p.start(now: 0)
        XCTAssertEqual(p.step(input(1, d: 1.0, b: 0, upd: 1, vision: true)), .stop)
        XCTAssertEqual(p.phase, .confirming)
        XCTAssertFalse(p.isFinished)
        XCTAssertEqual(p.step(input(2, d: 1.0, b: 0, upd: 2, person: PersonObservation(bearingDeg: 0, distanceM: 1.1), vision: true)), .stop)
        XCTAssertEqual(p.phase, .arrived(confirmed: true))
        var q = ApproachPlanner(); q.start(now: 0)
        _ = q.step(input(1, d: 1.0, b: 0, upd: 1, vision: true))
        _ = q.step(input(9.5, d: 1.0, b: 0, upd: 9.5, vision: true))
        XCTAssertEqual(q.phase, .arrived(confirmed: false))
        XCTAssertEqual(q.companionStatus.reason, "vision_unconfirmed")
    }

    func testPersonDepthStopsEvenIfUWBIsFar() {
        var p = ApproachPlanner(); p.start(now: 0)
        _ = p.step(input(1, d: 1.6, b: 0, upd: 1, person: PersonObservation(bearingDeg: 0, distanceM: 0.9), vision: true))
        XCTAssertEqual(p.phase, .arrived(confirmed: true))
    }
}

extension ApproachAction { var isMotion: Bool { if case .rotate = self { return true }; if case .drive = self { return true }; return false } }

// MARK: runner against a simulated user and rover

final class SimWorld: RangingSource, ApproachMotion {
    var rover = Pose2D(x: 0, z: 0, yawDeg: 0)
    var user = (x: 0.0, z: -4.0)         // 4 m ahead (yaw 0 faces -z)
    var time = 0.0
    var hasDirection = true
    var uwbAlive = true
    var stops = 0
    var maxCapSeen = 0
    var driveCalls = 0
    private let lock = NSLock()

    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func tick(_ dt: Double) { lock.lock(); time += dt; lock.unlock() }

    func latest() -> RangeSample {
        lock.lock(); defer { lock.unlock() }
        guard uwbAlive else { return RangeSample(distanceM: nil, bearingDeg: nil, updatedAt: lastAlive) }
        lastAlive = time
        let dx = user.x - rover.x, dz = user.z - rover.z
        let bearing = PoseMath.shortestDelta(from: rover.yawDeg, to: PoseMath.yawDeg(headingX: dx, headingZ: dz))
        return RangeSample(distanceM: (dx * dx + dz * dz).squareRoot(), bearingDeg: hasDirection ? bearing : nil, updatedAt: time)
    }
    private var lastAlive = 0.0

    func rotate(deg: Double, speedCap: Int) async -> ControlStatus {
        maxCapSeen = max(maxCapSeen, speedCap)
        rover.yawDeg = PoseMath.normalizeDegrees(rover.yawDeg + deg); tick(0.5); return .done
    }
    func drive(meters: Double, bearingDeg: Double, speedCap: Int) async -> ControlStatus {
        maxCapSeen = max(maxCapSeen, speedCap); driveCalls += 1
        let yaw = (rover.yawDeg + bearingDeg) * .pi / 180
        rover.x += meters * -sin(yaw); rover.z += meters * -cos(yaw); rover.yawDeg += bearingDeg; tick(1.0); return .done
    }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
}

final class FakeDetector: PersonDetector {
    var result: PersonObservation?
    func detect() async -> PersonObservation? { result }
}

final class ComeToMeRunnerTests: XCTestCase {
    func makeRunner(_ w: SimWorld, detector: PersonDetector? = nil, _ log: @escaping (CompanionState, Double?, String?) -> Void = { _, _, _ in }) -> ComeToMeRunner {
        ComeToMeRunner(ranging: w, motion: w, detector: detector, clock: { w.now() }, sleep: { _ in w.tick(0.1); await Task.yield() }, onStatus: log)
    }

    func testDrivesFromFourMetersAndStopsAtOneMeter() async {
        let w = SimWorld(); w.user = (0.5, -4)
        var states: [CompanionState] = []
        let phase = await makeRunner(w) { s, _, _ in states.append(s) }.run()
        XCTAssertEqual(phase, .arrived(confirmed: false))
        let d = ((w.user.x - w.rover.x) * (w.user.x - w.rover.x) + (w.user.z - w.rover.z) * (w.user.z - w.rover.z)).squareRoot()
        XCTAssertEqual(d, 1.0, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(d, 0.95)
        XCTAssertEqual(states.first, .accepted); XCTAssertEqual(states.last, .arrived)
        XCTAssertLessThanOrEqual(w.maxCapSeen, 120, "speed cap lower than Controller.maxLinear (160)")
    }

    func testGradientSearchFindsUserWithoutDirection() async {
        let w = SimWorld(); w.hasDirection = false; w.user = (-3, -1)
        let phase = await makeRunner(w).run()
        XCTAssertEqual(phase, .arrived(confirmed: false))
    }

    func testUWBDropoutStopsAndFails() async {
        let w = SimWorld()
        var last: (CompanionState, String?)?
        let r = makeRunner(w) { s, _, why in last = (s, why) }
        Task { while w.rover.z > -1.0 { await Task.yield() }; w.uwbAlive = false }
        let phase = await r.run()
        XCTAssertEqual(phase, .failed("uwb_lost"))
        XCTAssertEqual(last?.0, .failed); XCTAssertEqual(last?.1, "uwb_lost")
        XCTAssertGreaterThan(w.stops, 0)
    }

    func testCancelStops() async {
        let w = SimWorld()
        let r = makeRunner(w)
        Task { while w.driveCalls < 2 { await Task.yield() }; r.cancel() }
        let phase = await r.run()
        XCTAssertEqual(phase, .cancelled)
    }

    func testVisionConfirmedArrival() async {
        let w = SimWorld(); let det = FakeDetector(); det.result = PersonObservation(bearingDeg: 0, distanceM: nil)
        let phase = await makeRunner(w, detector: det).run()
        XCTAssertEqual(phase, .arrived(confirmed: true))
    }
}

final class CappedSinkTests: XCTestCase {
    final class Rec: DriveSink { var l = 0, r = 0; func drive(left: Int, right: Int) { l = left; r = right }; func stop() { l = 0; r = 0 } }
    func testScalesKeepingRatioAndPassesBelowCap() {
        let rec = Rec(); let s = CappedDriveSink(inner: rec, cap: 100)
        s.drive(left: 200, right: 100); XCTAssertEqual(rec.l, 100); XCTAssertEqual(rec.r, 50)
        s.drive(left: -160, right: 160); XCTAssertEqual(rec.l, -100); XCTAssertEqual(rec.r, 100)
        s.drive(left: 90, right: 80); XCTAssertEqual(rec.l, 90); XCTAssertEqual(rec.r, 80)
    }
}
