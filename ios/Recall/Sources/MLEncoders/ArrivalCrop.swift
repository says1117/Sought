import Foundation
#if canImport(FindExecutor)
import FindExecutor
#endif
#if canImport(simd)
import simd
#endif

// The camera side of the ARRIVAL CHECK. After the robot drives to a candidate, FindExecutor asks an `ImageEmbedder`
// to look again at the stored 3D point: project it into the newest camera frames, crop a window around it, embed the
// crops with the same image model that built Memory. This file is pure (no ARKit): the ARKit adapter and the JPEG
// encoder live in their own platform-guarded files, and everything here is covered by synthetic pinhole cameras.

/// Pixel rectangle in the captured image (origin top-left, x right, y down).
public struct PixelRect: Equatable {
    public var x: Int, y: Int, width: Int, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}

/// One camera frame's geometry in ARKit conventions: `cameraToWorld` is `ARCamera.transform`; the camera looks down
/// its own -z axis with +x to the right and +y up (in the captured image's orientation); world +y is up.
/// Intrinsics are for the CAPTURED image of `imageWidth` x `imageHeight` (not the screen).
///
/// ORIENTATION: `ARFrame.capturedImage`, `ARCamera.intrinsics`, `imageResolution` and `transform` are all expressed in
/// the sensor's LANDSCAPE-RIGHT orientation, whatever the UI orientation is. So projection and cropping work in that
/// frame directly; nothing here rotates by the device orientation. If the model should see the crop upright,
/// `ArrivalCropConfig.outputQuarterTurns` rotates the finished crop (default 0: same pixels Memory was built from).
public struct CameraGeometry: Equatable {
    public var cameraToWorld: simd_float4x4
    public var fx: Float, fy: Float, cx: Float, cy: Float
    public var imageWidth: Int, imageHeight: Int
    /// Seconds on any monotonic clock (ARFrame.timestamp).
    public var timestamp: Double

    public init(cameraToWorld: simd_float4x4, fx: Float, fy: Float, cx: Float, cy: Float,
                imageWidth: Int, imageHeight: Int, timestamp: Double) {
        self.cameraToWorld = cameraToWorld; self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.timestamp = timestamp
    }
}

/// Reads a rectangle of pixels out of a frame as RGBA bytes. The ARKit adapter wraps the CVPixelBuffer.
public protocol FrameCropping {
    func crop(_ rect: PixelRect) -> RawImage?
}

public struct CameraFrame {
    public var geometry: CameraGeometry
    public var pixels: FrameCropping
    public init(geometry: CameraGeometry, pixels: FrameCropping) { self.geometry = geometry; self.pixels = pixels }
}

/// Newest camera frame, or nil when there is none yet. Must be callable from any thread.
public protocol CameraFrameSource {
    func latestFrame() -> CameraFrame?
}

public struct NoCameraFrameSource: CameraFrameSource {
    public init() {}
    public func latestFrame() -> CameraFrame? { nil }
}

/// Why a look failed. FindExecutor records any error from the embedder as "no view" for the candidate.
public enum ArrivalCropError: Error, Equatable, CustomStringConvertible {
    case noFrame
    case behindCamera(depth: Float)
    case outsideImage(u: Float, v: Float)
    case cropUnavailable

    public var description: String {
        switch self {
        case .noFrame: return "no camera frame available"
        case .behindCamera(let d): return "not visible: point is behind the camera (depth \(d) m)"
        case .outsideImage(let u, let v): return "not visible: point projects outside the image (\(u), \(v))"
        case .cropUnavailable: return "could not read pixels for the crop"
        }
    }
}

public struct ProjectedPoint: Equatable {
    public var u: Float, v: Float
    /// Distance along the camera's viewing axis, metres (> 0 in front).
    public var depth: Float
}

public enum CameraProjection {
    /// Points closer than this to the camera plane count as behind it (also avoids dividing by ~0).
    public static let minDepth: Float = 0.05

    /// World point -> pixel. Throws `behindCamera` / `outsideImage` instead of returning an unusable pixel.
    public static func project(world: SIMD3<Float>, geometry g: CameraGeometry) throws -> ProjectedPoint {
        let c = g.cameraToWorld.inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
        let depth = -c.z                       // camera looks down -z
        guard depth > minDepth, depth.isFinite else { throw ArrivalCropError.behindCamera(depth: depth) }
        let u = g.fx * c.x / depth + g.cx      // image x right
        let v = g.cy - g.fy * c.y / depth      // image y down, camera y up
        guard u.isFinite, v.isFinite, u >= 0, v >= 0, u < Float(g.imageWidth), v < Float(g.imageHeight) else {
            throw ArrivalCropError.outsideImage(u: u, v: v)
        }
        return ProjectedPoint(u: u, v: v, depth: depth)
    }

    /// Square window around `p` that covers `worldSize * cropScale` metres at the point's depth, at least `minSide`
    /// pixels, never larger than the image, shifted (not shrunk) to stay inside the image.
    public static func cropRect(around p: ProjectedPoint, geometry g: CameraGeometry,
                                worldSize: Float, cropScale: Float, minSide: Int) -> PixelRect {
        let focal = max(g.fx, g.fy)
        let wanted = focal * worldSize * max(cropScale, 0.1) / p.depth
        let limit = min(g.imageWidth, g.imageHeight)
        let side = max(1, min(limit, max(minSide, Int(wanted.rounded()))))
        let x = min(max(0, Int((p.u - Float(side) / 2).rounded())), g.imageWidth - side)
        let y = min(max(0, Int((p.v - Float(side) / 2).rounded())), g.imageHeight - side)
        return PixelRect(x: x, y: y, width: side, height: side)
    }
}

extension RawImage {
    /// Rotates by `quarterTurns` x 90 degrees clockwise (negative = counter-clockwise).
    public func rotatedClockwise(quarterTurns: Int) -> RawImage {
        let t = ((quarterTurns % 4) + 4) % 4
        if t == 0 { return self }
        let nw = (t == 2) ? width : height, nh = (t == 2) ? height : width
        var out = [UInt8](repeating: 0, count: rgba.count)
        for y in 0..<height {
            for x in 0..<width {
                let (nx, ny): (Int, Int)
                switch t {
                case 1: (nx, ny) = (height - 1 - y, x)
                case 2: (nx, ny) = (width - 1 - x, height - 1 - y)
                default: (nx, ny) = (y, width - 1 - x)
                }
                let s = (y * width + x) * 4, d = (ny * nw + nx) * 4
                for c in 0..<4 { out[d + c] = rgba[s + c] }
            }
        }
        return RawImage(width: nw, height: nh, rgba: out)
    }
}

// MARK: debug sink

/// One crop the robot looked at during an arrival check.
public struct ArrivalCropRecord {
    public var trackID: String?
    public var position: SIMD3<Float>
    public var timestamp: Double
    public var rect: PixelRect
    /// JPEG of the crop as shown to the model (before resizing); nil when encoding is unavailable.
    public var jpeg: Data?
}

public protocol ArrivalCropDebugSink {
    /// False to skip JPEG encoding entirely (the no-op default).
    var wantsImages: Bool { get }
    func record(_ crop: ArrivalCropRecord)
}

public struct NoOpArrivalCropDebugSink: ArrivalCropDebugSink {
    public init() {}
    public var wantsImages: Bool { false }
    public func record(_ crop: ArrivalCropRecord) {}
}

/// Keeps the last `capacity` crops, newest last. Thread-safe. A viewer reads `recent()`.
public final class ArrivalCropRingBuffer: ArrivalCropDebugSink {
    public let capacity: Int
    private let lock = NSLock()
    private var items: [ArrivalCropRecord] = []

    public init(capacity: Int = 12) { self.capacity = max(1, capacity) }
    public var wantsImages: Bool { true }
    public func record(_ crop: ArrivalCropRecord) {
        lock.lock(); defer { lock.unlock() }
        items.append(crop)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
    }
    public func recent() -> [ArrivalCropRecord] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: embedder

public struct ArrivalCropConfig: Equatable {
    /// Side of the window in the world at the point's depth, before `cropScale`.
    public var worldCropSize: Float = 0.35
    public var minCropSidePx = 64
    /// Minimum gap between the camera timestamps of two crops of one look.
    public var frameSpacingS = 0.2
    /// Extra waiting allowed beyond `count * frameSpacingS` for frames to arrive.
    public var extraWaitS = 2.0
    public var pollIntervalS = 0.05
    /// Clockwise quarter turns applied to each crop before embedding. 0 matches how Memory crops were embedded.
    public var outputQuarterTurns = 0
    public init() {}
}

/// FindExecutor `ImageEmbedder` for the real robot: newest ARKit frames -> projected crop -> Core ML image embedding.
public struct ArrivalCropEmbedder: ImageEmbedder {
    public let frames: CameraFrameSource
    public let embedder: CoreMLImageEmbedder
    public var config: ArrivalCropConfig
    public var debugSink: ArrivalCropDebugSink
    /// Maps a world position to the stored track's id, for the debug record only.
    public var trackLookup: (SIMD3<Float>) -> String?
    public var jpeg: ((RawImage) -> Data?)?
    var now: () -> Double
    var sleep: (Double) async -> Void

    public init(frames: CameraFrameSource, embedder: CoreMLImageEmbedder, config: ArrivalCropConfig = ArrivalCropConfig(),
                debugSink: ArrivalCropDebugSink = NoOpArrivalCropDebugSink(),
                trackLookup: @escaping (SIMD3<Float>) -> String? = { _ in nil },
                jpeg: ((RawImage) -> Data?)? = ArrivalCropJPEG.encoder) {
        self.init(frames: frames, embedder: embedder, config: config, debugSink: debugSink, trackLookup: trackLookup, jpeg: jpeg,
                  now: { ProcessInfo.processInfo.systemUptime },
                  sleep: { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) })
    }

    /// Clock and sleep injected for tests.
    init(frames: CameraFrameSource, embedder: CoreMLImageEmbedder, config: ArrivalCropConfig,
         debugSink: ArrivalCropDebugSink, trackLookup: @escaping (SIMD3<Float>) -> String?, jpeg: ((RawImage) -> Data?)?,
         now: @escaping () -> Double, sleep: @escaping (Double) async -> Void) {
        self.frames = frames; self.embedder = embedder; self.config = config; self.debugSink = debugSink
        self.trackLookup = trackLookup; self.jpeg = jpeg; self.now = now; self.sleep = sleep
    }

    /// Returns up to `count` unit embeddings, one per frame at least `frameSpacingS` apart. Throws when nothing could be
    /// captured: `outsideImage`/`behindCamera` when the point is not in view, `noFrame` when the camera gave nothing.
    public func captureEmbeddings(around position: SIMD3<Float>, count: Int, cropScale: Float) async throws -> [[Float]] {
        guard count > 0 else { return [] }
        let deadline = now() + Double(count) * config.frameSpacingS + config.extraWaitS
        var out: [[Float]] = []
        var lastStamp: Double?
        var lastError: ArrivalCropError = .noFrame

        while out.count < count, now() < deadline {
            try Task.checkCancellation()
            guard let frame = frames.latestFrame() else { lastError = .noFrame; await sleep(config.pollIntervalS); continue }
            let g = frame.geometry
            if let last = lastStamp, g.timestamp - last < config.frameSpacingS { await sleep(config.pollIntervalS); continue }

            let rect: PixelRect
            do {
                let p = try CameraProjection.project(world: position, geometry: g)
                rect = CameraProjection.cropRect(around: p, geometry: g, worldSize: config.worldCropSize,
                                                 cropScale: cropScale, minSide: config.minCropSidePx)
            } catch let e as ArrivalCropError {
                // Not in view now: the robot is parked, so waiting rarely helps. Keep what we have, else report it.
                if out.isEmpty { throw e }
                break
            }
            guard let raw = frame.pixels.crop(rect) else { lastError = .cropUnavailable; await sleep(config.pollIntervalS); continue }
            let crop = raw.rotatedClockwise(quarterTurns: config.outputQuarterTurns)
            out.append(try embedder.embedOne(crop))
            lastStamp = g.timestamp
            debugSink.record(ArrivalCropRecord(trackID: trackLookup(position), position: position, timestamp: g.timestamp, rect: rect,
                                               jpeg: debugSink.wantsImages ? jpeg?(crop) : nil))
        }
        if out.isEmpty { throw lastError }
        return out
    }
}
