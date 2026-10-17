import XCTest
#if canImport(ObstacleGuardCore)
@testable import ObstacleGuardCore
#endif

final class ObstacleGuardTests: XCTestCase {
    // Synthetic 64x48 depth camera, ~70 deg horizontal FOV, level, 0.20 m above the floor.
    let w = 64, h = 48
    var k: DepthIntrinsics { DepthIntrinsics(fx: 45, fy: 45, cx: 32, cy: 24) }
    let mount = CameraMount(heightM: 0.20, pitchDownDeg: 0, rollDeg: 0)

    struct Box { var frontM: Float; var halfWidthM: Float; var heightM: Float; var centerX: Float = 0 }

    /// Ray-casts a flat floor plus optional boxes (front face only) into a depth buffer.
    func render(boxes: [Box] = [], floor: Bool = true) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        for v in 0..<h {
            for u in 0..<w {
                let dx = (Float(u) - k.cx) / k.fx, dy = (Float(v) - k.cy) / k.fy
                var best: Float = 0
                if floor && dy > 0 { best = mount.heightM / dy }  // depth along z equals t since dz = 1
                for b in boxes {
                    let x = dx * b.frontM, down = dy * b.frontM
                    let height = mount.heightM - down
                    if abs(x - b.centerX) <= b.halfWidthM, height >= 0, height <= b.heightM {
                        if best == 0 || b.frontM < best { best = b.frontM }
                    }
                }
                out[v * w + u] = best
            }
        }
        return out
    }

    func sample(_ d: [Float]) -> CorridorResult {
        CorridorSampler.sample(depth: d, width: w, height: h, intrinsics: k, mount: mount)
    }

    // MARK: sampling

    func testBoxInPathIsFoundAtItsDistance() {
        let r = sample(render(boxes: [Box(frontM: 0.5, halfWidthM: 0.3, heightM: 0.3)]))
        XCTAssertNotNil(r.minDistanceM)
        XCTAssertEqual(r.minDistanceM!, 0.5, accuracy: 0.01)
    }

    func testOpenFloorIsNotAnObstacle() {
        let r = sample(render())
        XCTAssertNil(r.minDistanceM)
        XCTAssertEqual(r.obstacleSamples, 0)
        XCTAssertFalse(r.isBlind())
    }

    func testFloorPointsAreExcluded() {
        // Floor ahead of a level camera lies at height 0, below floorClearance, so none count.
        let r = sample(render())
        XCTAssertEqual(r.obstacleSamples, 0)
        XCTAssertGreaterThan(r.validSamples, 0)
    }

    func testBoxOutsideCorridorIgnored() {
        let r = sample(render(boxes: [Box(frontM: 0.5, halfWidthM: 0.1, heightM: 0.3, centerX: 0.6)]))
        XCTAssertNil(r.minDistanceM)
    }

    func testObstacleAboveCorridorTopIgnored() {
        // Camera is 0.20 m up; a thin "ceiling" slab entirely above 0.40 m cannot be hit at pitch 0,
        // so shrink the corridor top to prove the upper bound is applied.
        let d = render(boxes: [Box(frontM: 0.5, halfWidthM: 0.3, heightM: 0.3)])
        let c = Corridor(topM: 0.04, lidarMinRangeM: 0.2)
        let r = CorridorSampler.sample(depth: d, width: w, height: h, intrinsics: k, mount: mount, corridor: c)
        XCTAssertNil(r.minDistanceM)
    }

    func testInvalidDepthIsBlindNotClear() {
        let r = sample([Float](repeating: 0, count: w * h))
        XCTAssertNil(r.minDistanceM)
        XCTAssertTrue(r.isBlind())
    }

    func testSamplesNearerThanLidarMinRangeAreDropped() {
        let r = sample(render(boxes: [Box(frontM: 0.1, halfWidthM: 0.3, heightM: 0.3)]))
        XCTAssertNil(r.minDistanceM)  // sonar must cover this range
    }

    func testBadInputsDoNotCrash() {
        let r = CorridorSampler.sample(depth: [1, 2], width: 64, height: 48, intrinsics: k)
        XCTAssertEqual(r.totalSamples, 0)
    }

    // MARK: decision

    func corridor(_ m: Float?) -> CorridorResult {
        CorridorResult(minDistanceM: m, obstacleSamples: m == nil ? 0 : 50, validSamples: 900, totalSamples: 1000)
    }
    let noSonar = SonarSample(frontCm: 999, rearCm: 999, flags: 0)

    func testThresholds() {
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(nil), sonar: noSonar).level, .clear)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(0.8), sonar: noSonar).level, .clear)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(0.5), sonar: noSonar).level, .slow)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(0.3), sonar: noSonar).level, .stop)
    }

    func testNoEchoIsNotADistance() {
        // 999 cm must not be read as 9.99 m "clear" evidence nor as a close reading.
        let r = ObstacleLogic.evaluate(corridor: corridor(0.5), sonar: noSonar)
        XCTAssertEqual(r.level, .slow)
        XCTAssertNil(SonarSample.meters(fromCm: 999))
        XCTAssertNil(SonarSample.meters(fromCm: 0))
        XCTAssertEqual(SonarSample.meters(fromCm: 30)!, 0.30, accuracy: 1e-6)
    }

    func testFrontFlagAlwaysWins() {
        let s = SonarSample(frontCm: 999, rearCm: 999, flags: 2)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(nil), sonar: s).level, .stop)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: nil, sonar: s).level, .stop)
    }

    func testRearFlagOnlyAffectsReverse() {
        let s = SonarSample(frontCm: 999, rearCm: 10, flags: 4)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(nil), sonar: s, direction: .forward).level, .clear)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(nil), sonar: s, direction: .reverse).level, .stop)
    }

    func testSonarDistanceBeatsClearLidar() {
        let s = SonarSample(frontCm: 20, rearCm: 999, flags: 0)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(nil), sonar: s).level, .stop)
        let s2 = SonarSample(frontCm: 50, rearCm: 999, flags: 0)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(nil), sonar: s2).level, .slow)
    }

    func testMissingDepthIsSlowNotClear() {
        let r = ObstacleLogic.evaluate(corridor: nil, sonar: noSonar)
        XCTAssertEqual(r.level, .slow)
        XCTAssertEqual(r.reason, .lidarBlind)
    }

    func testWatchdogFlagAloneIsNotAnObstacle() {
        let s = SonarSample(frontCm: 999, rearCm: 999, flags: 1 | 8)
        XCTAssertEqual(ObstacleLogic.evaluate(corridor: corridor(nil), sonar: s).level, .clear)
    }

    // MARK: detour state machine

    func testLidarStopNeedsConfirmationFrames() {
        var g = ObstacleGuard()
        for _ in 0..<2 {
            let o = g.update(corridor: corridor(0.2), sonar: noSonar)
            XCTAssertEqual(o.level, .stop)       // stops immediately
            XCTAssertTrue(o.events.isEmpty)      // but does not detour on one noisy frame
        }
        let o = g.update(corridor: corridor(0.2), sonar: noSonar)
        XCTAssertEqual(o.events, [.announceBlocked, .startDetour(degrees: 30, attempt: 1)])
    }

    func testSonarFlagDetoursImmediately() {
        var g = ObstacleGuard()
        let o = g.update(corridor: corridor(nil), sonar: SonarSample(frontCm: 10, rearCm: 999, flags: 2))
        XCTAssertEqual(o.events, [.announceBlocked, .startDetour(degrees: 30, attempt: 1)])
    }

    func testThreeDetoursThenGiveUp() {
        var g = ObstacleGuard(confirmFrames: 1)
        let blocked = corridor(0.2)
        var events: [GuardEvent] = []
        for _ in 0..<3 {
            events += g.update(corridor: blocked, sonar: noSonar).events
            // While rotating, still reports stop and emits nothing new.
            let mid = g.update(corridor: blocked, sonar: noSonar)
            XCTAssertEqual(mid.level, .stop); XCTAssertTrue(mid.events.isEmpty)
            g.detourFinished()
        }
        let last = g.update(corridor: blocked, sonar: noSonar)
        events += last.events
        XCTAssertEqual(events, [
            .announceBlocked, .startDetour(degrees: 30, attempt: 1),
            .startDetour(degrees: 30, attempt: 2),
            .startDetour(degrees: 30, attempt: 3),
            .gaveUp(attempts: 3),
        ])
        XCTAssertEqual(last.state, .gaveUp)
        XCTAssertEqual(g.update(corridor: corridor(nil), sonar: noSonar).level, .stop)  // latched
        g.reset()
        XCTAssertEqual(g.update(corridor: corridor(nil), sonar: noSonar).level, .clear)
    }

    func testClearAfterDetourResumes() {
        var g = ObstacleGuard(confirmFrames: 1)
        _ = g.update(corridor: corridor(0.2), sonar: noSonar)
        g.detourFinished()
        let o = g.update(corridor: corridor(nil), sonar: noSonar)
        XCTAssertEqual(o.state, .driving)
        XCTAssertEqual(o.level, .clear)
        XCTAssertEqual(o.speedScale, 1)
    }

    func testTravelRefillsDetourBudget() {
        var g = ObstacleGuard(confirmFrames: 1)
        _ = g.update(corridor: corridor(0.2), sonar: noSonar)
        g.detourFinished()
        _ = g.update(corridor: corridor(nil), sonar: noSonar)
        XCTAssertEqual(g.detoursUsed, 1)
        g.noteTravel(meters: 1.2)
        XCTAssertEqual(g.detoursUsed, 0)
    }

    func testSlowScalesSpeed() {
        var g = ObstacleGuard()
        let o = g.update(corridor: corridor(0.5), sonar: noSonar)
        XCTAssertEqual(o.level, .slow)
        XCTAssertEqual(o.speedScale, ObstacleGuard.slowSpeedScale)
    }
}
