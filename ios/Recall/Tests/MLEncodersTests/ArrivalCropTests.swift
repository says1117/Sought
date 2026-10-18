import XCTest
import Foundation
import simd
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(MLEncoders)
@testable import MLEncoders
#endif

// Helper names are prefixed AC73 because RecallTests compiles every test file into one module.

/// Synthetic pinhole camera in ARKit conventions: looks down -z, +x right, +y up; intrinsics for the captured image.
func ac73Geometry(transform: simd_float4x4 = matrix_identity_float4x4, t: Double = 0,
                  width: Int = 1920, height: Int = 1440, f: Float = 1000) -> CameraGeometry {
    CameraGeometry(cameraToWorld: transform, fx: f, fy: f, cx: Float(width) / 2, cy: Float(height) / 2,
                   imageWidth: width, imageHeight: height, timestamp: t)
}

func ac73RotationZ(degrees: Float) -> simd_float4x4 {
    let r = degrees * .pi / 180
    return simd_float4x4(columns: (SIMD4(cos(r), sin(r), 0, 0), SIMD4(-sin(r), cos(r), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
}

final class AC73Pixels: FrameCropping {
    var rects: [PixelRect] = []
    var color: [UInt8]
    var fail = false
    init(color: [UInt8] = [200, 30, 30, 255]) { self.color = color }
    func crop(_ rect: PixelRect) -> RawImage? {
        rects.append(rect)
        if fail { return nil }
        return RawImage(width: rect.width, height: rect.height,
                        rgba: (0..<(rect.width * rect.height)).flatMap { _ in color })
    }
}

/// Returns a new frame on every call, `step` seconds after the previous one (or the same frame if step is 0).
final class AC73FrameSource: CameraFrameSource {
    var geometry: CameraGeometry
    let pixels: AC73Pixels
    var step: Double
    var calls = 0
    var empty = false
    init(geometry: CameraGeometry = ac73Geometry(), pixels: AC73Pixels = AC73Pixels(), step: Double = 0.25) {
        self.geometry = geometry; self.pixels = pixels; self.step = step
    }
    func latestFrame() -> CameraFrame? {
        calls += 1
        if empty { return nil }
        var g = geometry
        g.timestamp = Double(calls) * step
        return CameraFrame(geometry: g, pixels: pixels)
    }
}

/// 512-d output chosen by the first pixel's red value, so tests can steer the embedding by frame colour.
struct AC73ImageRunner: ImageModelRunning {
    func run(image: RawImage) throws -> [Float] {
        var v = [Float](repeating: 0, count: 512)
        v[image.rgba[0] > 100 ? 0 : 1] = 2
        return v
    }
}

/// Wraps a source, shifting every frame timestamp by `offset` (so early frames are stale for a late clock).
final class AC73OffsetSource: CameraFrameSource {
    let base: AC73FrameSource, offset: Double
    init(base: AC73FrameSource, offset: Double) { self.base = base; self.offset = offset }
    func latestFrame() -> CameraFrame? {
        guard var f = base.latestFrame() else { return nil }
        f.geometry.timestamp += offset
        return f
    }
}

final class AC73Clock {
    var t = 0.0
    var slept: [Double] = []
    func now() -> Double { t }
    func sleep(_ s: Double) async { slept.append(s); t += s }
}

final class ArrivalCropTests: XCTestCase {
    private func embedder(_ src: CameraFrameSource, config: ArrivalCropConfig = ArrivalCropConfig(),
                          sink: ArrivalCropDebugSink = NoOpArrivalCropDebugSink(), clock: AC73Clock = AC73Clock(),
                          lookup: @escaping (SIMD3<Float>) -> String? = { _ in nil }) -> ArrivalCropEmbedder {
        ArrivalCropEmbedder(frames: src, embedder: CoreMLImageEmbedder(runner: AC73ImageRunner()), config: config,
                            debugSink: sink, trackLookup: lookup, jpeg: { Data($0.rgba.prefix(4)) },
                            now: { clock.now() }, sleep: { await clock.sleep($0) })
    }

    // MARK: projection

    func testPointOnOpticalAxisProjectsToImageCenter() throws {
        let p = try CameraProjection.project(world: SIMD3(0, 0, -2), geometry: ac73Geometry())
        XCTAssertEqual(p.u, 960, accuracy: 1e-3); XCTAssertEqual(p.v, 720, accuracy: 1e-3); XCTAssertEqual(p.depth, 2, accuracy: 1e-5)
    }

    func testOffsetPointRightAndUpLandsRightAndAboveCenter() throws {
        // +x is image right; +y world up is image UP, so v DEcreases.
        let p = try CameraProjection.project(world: SIMD3(0.2, 0.1, -2), geometry: ac73Geometry())
        XCTAssertEqual(p.u, 1060, accuracy: 1e-3); XCTAssertEqual(p.v, 670, accuracy: 1e-3)
    }

    func testCameraTranslationAndYawAreApplied() throws {
        // Camera at (1, 0.5, 0) yawed 90 degrees left (about +y): it now looks down world -x. A point 3 m ahead of it.
        let c = cos(Float.pi / 2), s = sin(Float.pi / 2)
        let yaw = simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(1, 0.5, 0, 1)))
        let p = try CameraProjection.project(world: SIMD3(-2, 0.5, 0), geometry: ac73Geometry(transform: yaw))
        XCTAssertEqual(p.depth, 3, accuracy: 1e-4)
        XCTAssertEqual(p.u, 960, accuracy: 1e-2); XCTAssertEqual(p.v, 720, accuracy: 1e-2)
    }

    func testRolledCameraMapsWorldUpToImageSide() throws {
        // Rolled 90 degrees about the viewing axis (phone turned sideways): camera +x now points along world +y.
        let g = ac73Geometry(transform: ac73RotationZ(degrees: 90))
        let p = try CameraProjection.project(world: SIMD3(0, 0.2, -2), geometry: g)
        XCTAssertEqual(p.u, 1060, accuracy: 1e-2); XCTAssertEqual(p.v, 720, accuracy: 1e-2)
    }

    func testPointBehindCameraThrowsBehindCamera() {
        XCTAssertThrowsError(try CameraProjection.project(world: SIMD3(0, 0, 2), geometry: ac73Geometry())) {
            guard case .behindCamera = $0 as? ArrivalCropError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try CameraProjection.project(world: SIMD3(0, 0, -0.01), geometry: ac73Geometry()))
    }

    func testPointOutsideImageThrowsOutsideImage() {
        for w in [SIMD3<Float>(2, 0, -2), SIMD3(-2, 0, -2), SIMD3(0, 2, -2), SIMD3(0, -2, -2)] {
            XCTAssertThrowsError(try CameraProjection.project(world: w, geometry: ac73Geometry())) {
                guard case .outsideImage = $0 as? ArrivalCropError else { return XCTFail("\($0)") }
            }
        }
    }

    func testEdgePixelsInsideAndJustOutside() throws {
        // u = 960 + 1000 * x / 2: x = 1.9 -> 1910 (inside), x = 1.92 -> 1920 (outside, exclusive upper bound).
        XCTAssertNoThrow(try CameraProjection.project(world: SIMD3(1.9, 0, -2), geometry: ac73Geometry()))
        XCTAssertThrowsError(try CameraProjection.project(world: SIMD3(1.92, 0, -2), geometry: ac73Geometry()))
        XCTAssertNoThrow(try CameraProjection.project(world: SIMD3(-1.92, 0, -2), geometry: ac73Geometry()))   // u = 0
    }

    // MARK: crop window

    func testCropSizeFollowsWorldSizeDepthAndScale() throws {
        let g = ac73Geometry()
        let p = try CameraProjection.project(world: SIMD3(0, 0, -2), geometry: g)
        // 1000 px/m focal * 0.35 m * 1.5 / 2 m = 262.5 -> 263 (rounded), centred on (960, 720).
        let r = CameraProjection.cropRect(around: p, geometry: g, worldSize: 0.35, cropScale: 1.5, minSide: 64)
        XCTAssertEqual(r.width, 263); XCTAssertEqual(r.height, 263)
        XCTAssertEqual(r.x, 829); XCTAssertEqual(r.y, 589)
        // Twice as far -> half the size.
        let far = try CameraProjection.project(world: SIMD3(0, 0, -4), geometry: g)
        XCTAssertEqual(CameraProjection.cropRect(around: far, geometry: g, worldSize: 0.35, cropScale: 1.5, minSide: 64).width, 131)
    }

    func testCropIsShiftedNotShrunkAtImageEdges() throws {
        let g = ac73Geometry()
        let p = ProjectedPoint(u: 5, v: 1435, depth: 2)
        let r = CameraProjection.cropRect(around: p, geometry: g, worldSize: 0.35, cropScale: 1.5, minSide: 64)
        XCTAssertEqual(r.width, 263)
        XCTAssertEqual(r.x, 0); XCTAssertEqual(r.y, 1440 - 263)
        XCTAssertLessThanOrEqual(r.x + r.width, 1920); XCTAssertLessThanOrEqual(r.y + r.height, 1440)
    }

    func testCropHasMinimumSizeAndNeverExceedsImage() throws {
        let g = ac73Geometry()
        let farP = ProjectedPoint(u: 960, v: 720, depth: 50)
        XCTAssertEqual(CameraProjection.cropRect(around: farP, geometry: g, worldSize: 0.35, cropScale: 1.5, minSide: 64).width, 64)
        let nearP = ProjectedPoint(u: 960, v: 720, depth: 0.1)
        let r = CameraProjection.cropRect(around: nearP, geometry: g, worldSize: 0.35, cropScale: 1.5, minSide: 64)
        XCTAssertEqual(r, PixelRect(x: 240, y: 0, width: 1440, height: 1440), "clamped to the short image side and kept in bounds")
    }

    // MARK: rotation helper

    func testRotatedClockwiseQuarterTurns() {
        // 2x1 image: [A B]
        let a: [UInt8] = [1, 1, 1, 255], b: [UInt8] = [2, 2, 2, 255]
        let img = RawImage(width: 2, height: 1, rgba: a + b)
        let cw = img.rotatedClockwise(quarterTurns: 1)       // 1x2: A on top, B below
        XCTAssertEqual(cw.width, 1); XCTAssertEqual(cw.height, 2); XCTAssertEqual(Array(cw.rgba), a + b)
        let ccw = img.rotatedClockwise(quarterTurns: -1)     // B on top
        XCTAssertEqual(Array(ccw.rgba), b + a)
        XCTAssertEqual(Array(img.rotatedClockwise(quarterTurns: 2).rgba), b + a)
        XCTAssertEqual(img.rotatedClockwise(quarterTurns: 4), img)
    }

    // MARK: embedder

    func testCapturesCountEmbeddingsFromSpacedFrames() async throws {
        let src = AC73FrameSource(step: 0.25)
        let out = try await embedder(src).captureEmbeddings(around: SIMD3(0, 0, -2), count: 3, cropScale: 1.5)
        XCTAssertEqual(out.count, 3)
        for v in out {
            XCTAssertEqual(v.count, 512)
            XCTAssertEqual(v.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-5, "unit length")
            XCTAssertEqual(v[0], 1, accuracy: 1e-6)
        }
        XCTAssertEqual(src.pixels.rects.count, 3)
        XCTAssertEqual(src.pixels.rects[0], PixelRect(x: 829, y: 589, width: 263, height: 263))
    }

    func testFramesCloserThanSpacingAreSkippedAndWaitedFor() async throws {
        // Camera frames arrive every 0.05 s; crops must be >= 0.2 s apart, so 2 crops consume ~5 frames.
        let src = AC73FrameSource(step: 0.05)
        let clock = AC73Clock()
        let out = try await embedder(src, clock: clock).captureEmbeddings(around: SIMD3(0, 0, -2), count: 2, cropScale: 1.5)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(src.pixels.rects.count, 2, "only spaced frames are cropped")
        XCTAssertGreaterThanOrEqual(src.calls, 5)
        XCTAssertFalse(clock.slept.isEmpty, "polled between frames instead of busy looping")
    }

    func testStaleSingleFrameYieldsOneCropThenGivesUpAtDeadline() async throws {
        let src = AC73FrameSource(step: 0)    // the camera never advances: same timestamp forever
        let clock = AC73Clock()
        let out = try await embedder(src, clock: clock).captureEmbeddings(around: SIMD3(0, 0, -2), count: 3, cropScale: 1.5)
        XCTAssertEqual(out.count, 1, "returns what it has once the deadline passes")
        XCTAssertGreaterThanOrEqual(clock.t, 0.6 + 2.0 - 0.1)
    }

    /// PR 39 review P2: a frozen camera whose newest frame predates the look must NOT yield an embedding.
    func testStaleFirstFrameBeforeCaptureStartProducesNoEmbedding() async {
        let src = AC73FrameSource(step: 0)         // timestamp stays 0 forever
        let clock = AC73Clock(); clock.t = 100     // the look begins at t = 100
        do {
            let out = try await embedder(src, clock: clock).captureEmbeddings(around: SIMD3(0, 0, -2), count: 3, cropScale: 1.5)
            XCTFail("embedded a stale frame: \(out.count)")
        } catch let e as ArrivalCropError {
            XCTAssertEqual(e, .noFreshFrame)
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(src.pixels.rects.isEmpty, "never even cropped the stale frame")
    }

    func testStaleFramesAreSkippedUntilAFreshOneArrives() async throws {
        let src = AC73FrameSource(step: 0.25)
        let clock = AC73Clock(); clock.t = 10
        // Frames at 0.25, 0.5 ... are stale until the timestamps pass 9.5 (the 0.5 s freshness window).
        let late = AC73OffsetSource(base: src, offset: 9.0)
        let sink = ArrivalCropRingBuffer()
        let out = try await embedder(late, sink: sink, clock: clock).captureEmbeddings(around: SIMD3(0, 0, -2), count: 1, cropScale: 1.5)
        XCTAssertEqual(out.count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(sink.recent().first).timestamp, 9.5)
    }

    func testFrameJustInsideFreshnessWindowIsAccepted() async throws {
        let src = AC73FrameSource(step: 0)
        let clock = AC73Clock(); clock.t = 0.4        // frame stamp 0 is 0.4 s old: within 0.5 s
        let out = try await embedder(src, clock: clock).captureEmbeddings(around: SIMD3(0, 0, -2), count: 1, cropScale: 1.5)
        XCTAssertEqual(out.count, 1)
    }

    func testPointNotInViewThrowsTypedErrorImmediately() async {
        let src = AC73FrameSource()
        do {
            _ = try await embedder(src).captureEmbeddings(around: SIMD3(0, 0, 3), count: 3, cropScale: 1.5)
            XCTFail("expected throw")
        } catch let e as ArrivalCropError {
            guard case .behindCamera = e else { return XCTFail("\(e)") }
            XCTAssertEqual(src.calls, 1, "no waiting when the point is simply not visible")
        } catch { XCTFail("\(error)") }
        do {
            _ = try await embedder(src).captureEmbeddings(around: SIMD3(5, 0, -2), count: 3, cropScale: 1.5)
            XCTFail("expected throw")
        } catch let e as ArrivalCropError { guard case .outsideImage = e else { return XCTFail("\(e)") } } catch { XCTFail("\(error)") }
    }

    func testNoFrameThrowsNoFrameAfterWaiting() async {
        let src = AC73FrameSource(); src.empty = true
        let clock = AC73Clock()
        do {
            _ = try await embedder(src, clock: clock).captureEmbeddings(around: SIMD3(0, 0, -2), count: 2, cropScale: 1.5)
            XCTFail("expected throw")
        } catch { XCTAssertEqual(error as? ArrivalCropError, .noFrame) }
        XCTAssertGreaterThan(clock.t, 2.0)
    }

    func testUnreadablePixelsThrowCropUnavailable() async {
        let src = AC73FrameSource(); src.pixels.fail = true
        do {
            _ = try await embedder(src).captureEmbeddings(around: SIMD3(0, 0, -2), count: 1, cropScale: 1.5)
            XCTFail("expected throw")
        } catch { XCTAssertEqual(error as? ArrivalCropError, .cropUnavailable) }
    }

    func testZeroCountReturnsNothing() async throws {
        let out = try await embedder(AC73FrameSource()).captureEmbeddings(around: SIMD3(0, 0, -2), count: 0, cropScale: 1.5)
        XCTAssertTrue(out.isEmpty)
    }

    func testDebugRingBufferKeepsLastNWithTrackIDAndJPEG() async throws {
        let ring = ArrivalCropRingBuffer(capacity: 2)
        let e = embedder(AC73FrameSource(), sink: ring, lookup: { _ in "obj_7" })
        _ = try await e.captureEmbeddings(around: SIMD3(0, 0, -2), count: 3, cropScale: 1.5)
        let recent = ring.recent()
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.map(\.trackID), ["obj_7", "obj_7"])
        XCTAssertEqual(recent[0].timestamp, 0.5, accuracy: 1e-9); XCTAssertEqual(recent[1].timestamp, 0.75, accuracy: 1e-9)
        XCTAssertEqual(recent[1].jpeg, Data([200, 30, 30, 255]))
    }

    func testNoOpSinkSkipsJPEGEncoding() async throws {
        var encoded = 0
        let e = ArrivalCropEmbedder(frames: AC73FrameSource(), embedder: CoreMLImageEmbedder(runner: AC73ImageRunner()),
                                    config: ArrivalCropConfig(), debugSink: NoOpArrivalCropDebugSink(), trackLookup: { _ in nil },
                                    jpeg: { _ in encoded += 1; return nil }, now: { 0 }, sleep: { _ in })
        _ = try await e.captureEmbeddings(around: SIMD3(0, 0, -2), count: 1, cropScale: 1.5)
        XCTAssertEqual(encoded, 0)
    }

    func testOutputQuarterTurnsRotatesCropBeforeEmbedding() async throws {
        var cfg = ArrivalCropConfig(); cfg.outputQuarterTurns = 1
        let ring = ArrivalCropRingBuffer()
        _ = try await embedder(AC73FrameSource(), config: cfg, sink: ring).captureEmbeddings(around: SIMD3(0, 0, -2), count: 1, cropScale: 1.5)
        XCTAssertEqual(ring.recent().count, 1)   // square crops stay square; rotation path ran without error
    }

    func testRealJPEGEncoderProducesJPEGBytes() throws {
        guard let enc = ArrivalCropJPEG.encoder else { throw XCTSkip("no ImageIO") }
        let img = RawImage(width: 8, height: 8, rgba: [UInt8](repeating: 128, count: 8 * 8 * 4))
        let data = try XCTUnwrap(enc(img))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    }
}
