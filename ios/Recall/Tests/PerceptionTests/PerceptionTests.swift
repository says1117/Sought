import XCTest
import simd
#if canImport(Memory)
import Memory
#endif
#if canImport(RecallShared)
import RecallShared
#endif
#if canImport(PerceptionCore)
@testable import PerceptionCore
#endif

final class KeyframeGateTests: XCTestCase {
    func testCapturesWhenSlowAndNormal() {
        var g = KeyframeGate()
        XCTAssertEqual(g.evaluate(now: 0, speed: 0.05, atScanStop: false, trackingNormal: true), .capture)
    }
    func testRejectsFastUnknownAndBadTracking() {
        var g = KeyframeGate()
        XCTAssertNotEqual(g.evaluate(now: 0, speed: 0.3, atScanStop: false, trackingNormal: true), .capture)
        XCTAssertNotEqual(g.evaluate(now: 0, speed: nil, atScanStop: false, trackingNormal: true), .capture)
        XCTAssertNotEqual(g.evaluate(now: 0, speed: 0, atScanStop: true, trackingNormal: false), .capture)
    }
    func testScanStopOverridesSpeed() {
        var g = KeyframeGate()
        XCTAssertEqual(g.evaluate(now: 0, speed: 0.5, atScanStop: true, trackingNormal: true), .capture)
    }
    func testMinInterval() {
        var g = KeyframeGate()
        XCTAssertEqual(g.evaluate(now: 0, speed: 0, atScanStop: false, trackingNormal: true), .capture)
        XCTAssertNotEqual(g.evaluate(now: 0.4, speed: 0, atScanStop: false, trackingNormal: true), .capture)
        XCTAssertEqual(g.evaluate(now: 0.5, speed: 0, atScanStop: false, trackingNormal: true), .capture)
    }
    func testRateCapIndependentOfInterval() {
        var cfg = KeyframeGateConfig(); cfg.minInterval = 0.1
        var g = KeyframeGate(config: cfg)
        XCTAssertEqual(g.evaluate(now: 0, speed: 0, atScanStop: false, trackingNormal: true), .capture)
        XCTAssertEqual(g.evaluate(now: 0.2, speed: 0, atScanStop: false, trackingNormal: true), .capture)
        XCTAssertEqual(g.evaluate(now: 0.4, speed: 0, atScanStop: false, trackingNormal: true), .skip(reason: "rate cap"))
        XCTAssertEqual(g.evaluate(now: 1.0, speed: 0, atScanStop: false, trackingNormal: true), .capture)
    }
}

final class ProposalMathTests: XCTestCase {
    func testGridCountsAndCoverage() {
        let g23 = ProposalMath.gridBoxes(rows: 2, cols: 3)
        XCTAssertEqual(g23.count, 6)
        XCTAssertEqual(ProposalMath.gridBoxes(rows: 3, cols: 4).count, 12)
        XCTAssertEqual(ProposalMath.gridBackstop().count, 18)
        let tw: Float = 1 / (3 - 2 * 0.25)
        XCTAssertEqual(g23[0].w, tw, accuracy: 1e-5)
        // Adjacent tiles overlap by 25% of a tile width.
        XCTAssertEqual((g23[0].x + g23[0].w) - g23[1].x, 0.25 * tw, accuracy: 1e-5)
        XCTAssertEqual(g23[2].x + g23[2].w, 1, accuracy: 1e-5)
        for b in g23 { XCTAssertGreaterThanOrEqual(b.x, 0); XCTAssertLessThanOrEqual(b.y + b.h, 1.0001) }
    }
    func testIoU() {
        let a = NormBox(x: 0, y: 0, w: 0.5, h: 0.5)
        XCTAssertEqual(a.iou(a), 1, accuracy: 1e-6)
        XCTAssertEqual(a.iou(NormBox(x: 0.5, y: 0, w: 0.5, h: 0.5)), 0, accuracy: 1e-6)
        XCTAssertEqual(a.iou(NormBox(x: 0.25, y: 0, w: 0.5, h: 0.5)), 1.0 / 3.0, accuracy: 1e-5)
    }
    func testNMSKeepsHigherScoreAndDistinct() {
        let hi = Proposal(box: NormBox(x: 0.1, y: 0.1, w: 0.3, h: 0.3), score: 0.9, origin: .yolo)
        let dup = Proposal(box: NormBox(x: 0.11, y: 0.1, w: 0.3, h: 0.3), score: 0.5, origin: .saliency)
        let far = Proposal(box: NormBox(x: 0.6, y: 0.6, w: 0.3, h: 0.3), score: 0.2, origin: .grid)
        let out = ProposalMath.nms([dup, far, hi])
        XCTAssertEqual(out, [hi, far])
    }
    func testMergeCapsAt24AndPrefersDetections() {
        var many: [Proposal] = []
        for i in 0..<10 { for j in 0..<10 {
            many.append(Proposal(box: NormBox(x: Float(i) * 0.1, y: Float(j) * 0.1, w: 0.08, h: 0.08), score: 0.1, origin: .grid))
        } }
        let yolo = Proposal(box: NormBox(x: 0.2, y: 0.2, w: 0.05, h: 0.05), score: 0.95, origin: .yolo)
        let out = ProposalMath.merge([many, [yolo]])
        XCTAssertEqual(out.count, 24)
        XCTAssertEqual(out.first?.origin, .yolo); XCTAssertEqual(out.first?.score, 0.95)
    }
    func testMergeTreatsNonpositiveLimitAsEmpty() {
        let proposal = Proposal(box: NormBox(x: 0.1, y: 0.1, w: 0.2, h: 0.2), score: 1, origin: .grid)
        XCTAssertTrue(ProposalMath.merge([[proposal]], limit: 0).isEmpty)
        XCTAssertTrue(ProposalMath.merge([[proposal]], limit: -1).isEmpty)
    }
    func testYOLOStubEmptyWithoutDetectorAndFiltersLowConfidence() {
        XCTAssertTrue(YOLOProposalSource<Int>().proposals(in: 0).isEmpty)
        let src = YOLOProposalSource<Int> { _ in [
            Proposal(box: NormBox(x: 0, y: 0, w: 0.2, h: 0.2), score: 0.1, origin: .grid),
            Proposal(box: NormBox(x: 0.5, y: 0.5, w: 0.2, h: 0.2), score: 0.4, origin: .grid)] }
        let out = src.proposals(in: 0)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].origin, .yolo)
    }
}

final class DepthLiftTests: XCTestCase {
    /// 100x100 depth, everything 2 m.
    func flat(_ d: Float, w: Int = 100, h: Int = 100) -> DepthMap {
        DepthMap(width: w, height: h, values: [Float](repeating: d, count: w * h))
    }
    func testMedianIgnoresOutliersOutsideCentre() {
        var m = flat(2)
        for v in 0..<100 { for u in 0..<100 where u < 20 { m.values[v * 100 + u] = 0.2 } }  // left strip close
        let d = DepthLift.medianDepth(m, box: NormBox(x: 0, y: 0, w: 1, h: 1))
        XCTAssertEqual(d!, 2, accuracy: 1e-6)
    }
    func testMedianSkipsInvalidAndRejectsFar() {
        var m = flat(0)
        XCTAssertNil(DepthLift.medianDepth(m, box: NormBox(x: 0.2, y: 0.2, w: 0.6, h: 0.6)))
        m.values[50 * 100 + 50] = .nan
        XCTAssertNil(DepthLift.medianDepth(m, box: NormBox(x: 0.2, y: 0.2, w: 0.6, h: 0.6)))
        XCTAssertNil(DepthLift.medianDepth(flat(5.5), box: NormBox(x: 0, y: 0, w: 1, h: 1)))
        XCTAssertNotNil(DepthLift.medianDepth(flat(5.0), box: NormBox(x: 0, y: 0, w: 1, h: 1)))
    }
    func testCentralRegionIs30PercentArea() {
        let c = NormBox(x: 0, y: 0, w: 1, h: 1).central(areaFraction: 0.3)
        XCTAssertEqual(c.area, 0.3, accuracy: 1e-5)
        XCTAssertEqual(c.center.x, 0.5, accuracy: 1e-6)
    }
    func testUnprojectPrincipalPointForward() {
        let k = DepthIntrinsics(fx: 500, fy: 500, cx: 320, cy: 240)
        let p = DepthLift.unproject(u: 320, v: 240, depth: 2, intrinsics: k, cameraToWorld: matrix_identity_float4x4)
        XCTAssertEqual(p.x, 0, accuracy: 1e-6); XCTAssertEqual(p.y, 0, accuracy: 1e-6); XCTAssertEqual(p.z, -2, accuracy: 1e-6)
    }
    func testUnprojectOffAxisAndPose() {
        let k = DepthIntrinsics(fx: 500, fy: 500, cx: 320, cy: 240)
        // 100 px right, 50 px above centre (v smaller) at 2 m: x = +0.4, y = +0.2.
        let p = DepthLift.unproject(u: 420, v: 190, depth: 2, intrinsics: k, cameraToWorld: matrix_identity_float4x4)
        XCTAssertEqual(p.x, 0.4, accuracy: 1e-5); XCTAssertEqual(p.y, 0.2, accuracy: 1e-5)
        // Camera at (1, 1.5, 3), yawed 90 deg left (about +y): forward -z becomes -x.
        var t = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        t.columns.3 = SIMD4(1, 1.5, 3, 1)
        let q = DepthLift.unproject(u: 320, v: 240, depth: 2, intrinsics: k, cameraToWorld: t)
        XCTAssertEqual(q.x, -1, accuracy: 1e-5); XCTAssertEqual(q.y, 1.5, accuracy: 1e-5); XCTAssertEqual(q.z, 3, accuracy: 1e-5)
    }
    func testLiftScalesIntrinsicsAndHeightAboveFloor() {
        // Colour 640x480, depth 160x120 (quarter). Box centred at principal point + 100 colour px right.
        var t = matrix_identity_float4x4; t.columns.3 = SIMD4(0, 1.0, 0, 1)
        let g = KeyframeGeometry(cameraToWorld: t, fx: 500, fy: 500, cx: 320, cy: 240,
                                 imageWidth: 640, imageHeight: 480, floorY: -0.2, time: 7)
        let box = NormBox(x: 0.6875 - 0.05, y: 0.5 - 0.05, w: 0.1, h: 0.1)  // centre u = 440 of 640
        let lifted = DepthLift.lift(box: box, depth: flat(2, w: 160, h: 120), geometry: g)!
        XCTAssertEqual(lifted.world.x, (440 - 320) / 500 * 2, accuracy: 1e-4)
        XCTAssertEqual(lifted.world.y, 1.0, accuracy: 1e-4)
        XCTAssertEqual(lifted.world.z, -2, accuracy: 1e-5)
        XCTAssertEqual(lifted.heightAboveFloor, 1.2, accuracy: 1e-4)
    }
    func testLiftNilForInvalidDepth() {
        let g = KeyframeGeometry(cameraToWorld: matrix_identity_float4x4, fx: 500, fy: 500, cx: 50, cy: 50,
                                 imageWidth: 100, imageHeight: 100, floorY: 0, time: 0)
        XCTAssertNil(DepthLift.lift(box: NormBox(x: 0.4, y: 0.4, w: 0.2, h: 0.2), depth: flat(0), geometry: g))
    }
}

struct FakeFrame: CropSource {
    func crop(_ box: NormBox) -> NormBox? { box }
    func thumbnailJPEG(_ crop: NormBox, maxEdge: Int) -> Data? { Data([UInt8(maxEdge % 256)]) }
}
struct FakeEmbedder: CropEmbedder {
    func embed(_ crops: [NormBox]) throws -> [[Float]] { crops.map { [$0.x + 1, 0, 3 * ($0.y + 1)] } }
}

final class PipelineTests: XCTestCase {
    func testPipelineProducesObservationsAndDropsFar() throws {
        let g = KeyframeGeometry(cameraToWorld: matrix_identity_float4x4, fx: 100, fy: 100, cx: 50, cy: 50,
                                 imageWidth: 100, imageHeight: 100, floorY: -1, time: 12.5)
        var values = [Float](repeating: 2, count: 100 * 100)
        for v in 0..<100 { for u in 50..<100 { values[v * 100 + u] = 6 } }  // right half too far
        let depth = DepthMap(width: 100, height: 100, values: values)
        let near = Proposal(box: NormBox(x: 0.1, y: 0.4, w: 0.2, h: 0.2), score: 0.8, origin: .saliency)
        let far = Proposal(box: NormBox(x: 0.7, y: 0.4, w: 0.2, h: 0.2), score: 0.9, origin: .yolo)
        let out = try PerceptionPipeline(embedder: FakeEmbedder())
            .process(frame: FakeFrame(), depth: depth, geometry: g, proposalLists: [[near, far]])
        XCTAssertEqual(out.count, 1)
        let o = out[0]
        XCTAssertEqual(o.observation.time, 12.5)
        XCTAssertEqual(o.observation.confidence, 0.8, accuracy: 1e-6)
        XCTAssertEqual(o.observation.position.z, -2, accuracy: 1e-5)
        XCTAssertEqual(o.heightAboveFloor, o.observation.position.y + 1, accuracy: 1e-5)
        XCTAssertEqual(o.thumbnailJPEG, Data([UInt8(320 % 256)]))
        let n = o.observation.embedding.reduce(0) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(n, 1, accuracy: 1e-5)
    }
    func testObservationFeedsMemoryAssociation() throws {
        let g = KeyframeGeometry(cameraToWorld: matrix_identity_float4x4, fx: 100, fy: 100, cx: 50, cy: 50,
                                 imageWidth: 100, imageHeight: 100, floorY: 0, time: 1)
        let depth = DepthMap(width: 10, height: 10, values: [Float](repeating: 1.5, count: 100))
        let p = Proposal(box: NormBox(x: 0.4, y: 0.4, w: 0.2, h: 0.2), score: 1, origin: .grid)
        let pipe = PerceptionPipeline(embedder: FakeEmbedder())
        let o = try pipe.process(frame: FakeFrame(), depth: depth, geometry: g, proposalLists: [[p]])[0].observation
        let track = newTrack(id: "obj_a", from: o)
        if case .matched = associate(o, tracks: [track]).result {} else { XCTFail("identical observation should match") }
    }
}
