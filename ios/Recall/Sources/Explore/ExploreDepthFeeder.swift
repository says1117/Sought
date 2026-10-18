#if os(iOS) && canImport(ARKit)
import ARKit
import Combine

// App glue for Explore (behind RecallFeatureFlags.exploreEnabled). Fills ExploreGridStore from ARKit LiDAR depth
// and builds the coordinator's explore runner. App target only: excluded from every SwiftPM target.
// NOT RUN ON A DEVICE YET. Rates and thresholds are placeholders.

final class ExploreRuntime: ObservableObject {
    let enabled: Bool
    let store = ExploreGridStore()
    /// Builds the coordinator's explore task on the coordinator's own Controller (see CoordinatorWiring.makeExplorer).
    let makeExplorer: (Controller) -> CoordinatorExploring

    private let pose: PoseTracker
    private let poses: ExplorePoseSource
    private let queue = DispatchQueue(label: "com.recall.explore.grid", qos: .utility)
    private let inFlight = ExploreFeedGate()
    private var timer: Timer?
    private var lastTimestamp: TimeInterval = 0
    /// Two frames a second: enough for a slow rover, cheap next to the 10 Hz obstacle guard.
    static let feedIntervalS = 0.5

    @MainActor
    init(enabled: Bool, pose: PoseTracker, poses: ExplorePoseSource, speaker: CoordinatorSpeaking) {
        self.enabled = enabled
        self.pose = pose
        self.poses = poses
        let store = self.store
        makeExplorer = { controller in
            ExploreRunner(drive: ControllerExploreDrive(controller: controller), poses: poses, grid: store,
                          clock: ScanSystemClock(), speaker: speaker)
        }
        guard enabled else { return }       // flag off: no timer, no depth copies, grid stays empty
        let t = Timer(timeInterval: Self.feedIntervalS, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.feed() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    /// Main thread: copy one depth frame out of ARKit (never retain the ARFrame), integrate it on a background queue.
    /// Frames are skipped while tracking is not normal or the floor height is unknown, so the grid goes stale
    /// (and a running explore stops) instead of smearing bad depth into the map.
    @MainActor
    private func feed() {
        guard let frame = pose.session.currentFrame, frame.timestamp != lastTimestamp else { return }
        lastTimestamp = frame.timestamp
        guard pose.tracking == .normal, let floorY = pose.floorY else { return }
        guard inFlight.begin() else { return }      // previous frame still integrating: drop this one
        guard let depth = Self.depthFrame(from: frame, floorY: Float(floorY)) else { inFlight.end(); return }
        let robot = pose.pose.map { (x: Float($0.x), z: Float($0.z)) }
        queue.async { [store, inFlight] in
            store.integrate(depth, robot: robot)
            inFlight.end()
        }
    }

    /// Scene depth as plain arrays, low-confidence pixels dropped (0 = no return), intrinsics scaled to the depth map.
    private static func depthFrame(from frame: ARFrame, floorY: Float) -> DepthFrame? {
        guard let sd = frame.sceneDepth else { return nil }
        let map = sd.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowFloats = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
        let src = base.assumingMemoryBound(to: Float32.self)

        var conf: UnsafePointer<UInt8>?
        var confRow = 0
        if let cm = sd.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            if let raw = CVPixelBufferGetBaseAddress(cm) { conf = UnsafePointer(raw.assumingMemoryBound(to: UInt8.self)) }
            confRow = CVPixelBufferGetBytesPerRow(cm)
        }
        defer { if let cm = sd.confidenceMap { CVPixelBufferUnlockBaseAddress(cm, .readOnly) } }

        var values = [Float](repeating: 0, count: w * h)
        for v in 0..<h {
            for u in 0..<w {
                if let conf, conf[v * confRow + u] < UInt8(ARConfidenceLevel.medium.rawValue) { continue }
                values[v * w + u] = src[v * rowFloats + u]
            }
        }
        let k = frame.camera.intrinsics, res = frame.camera.imageResolution
        let intr = DepthIntrinsics(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1])
            .scaled(fromWidth: Int(res.width), fromHeight: Int(res.height), toWidth: w, toHeight: h)
        return DepthFrame(depth: values, width: w, height: h, intrinsics: intr,
                          cameraToWorld: frame.camera.transform, floorY: floorY)
    }

    /// What Explore would do next from here. Plans off the main thread (a full plan can take tens of ms).
    func preview() async -> (ExplorePreview, ExploreMap, ExploreGridStore.Stats) {
        let store = self.store, poses = self.poses
        return await Task.detached(priority: .userInitiated) {
            let snap = poses.latest()
            let map = store.currentMap()
            let p = ExplorePreview.make(map: map, pose: snap.pose, tracking: snap.tracking, readiness: store.readiness())
            return (p, map, store.stats())
        }.value
    }
}

/// One frame integrating at a time.
private final class ExploreFeedGate {
    private let lock = NSLock()
    private var busy = false
    func begin() -> Bool { lock.lock(); defer { lock.unlock() }; if busy { return false }; busy = true; return true }
    func end() { lock.lock(); busy = false; lock.unlock() }
}
#endif
