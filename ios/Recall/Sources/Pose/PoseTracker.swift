import ARKit
import Combine
import simd

/// ARKit session wrapper. Publishes (x, z, yaw_deg) and tracking state at up to 30 Hz.
/// The math lives in PoseMath.swift; this file only adapts ARKit types.
/// Not compiled or run in CI: needs a real device (ARKit world tracking and LiDAR).
final class PoseTracker: NSObject, ObservableObject, ARSessionDelegate {
    static let maxHz = 30.0

    @Published private(set) var pose: Pose2D?
    @Published private(set) var tracking: TrackingKind = .notAvailable
    @Published private(set) var trackingReason: String = ""
    @Published private(set) var mapping: MappingKind = .notAvailable
    /// World y of the detected floor, nil until a horizontal plane of useful size is found.
    @Published private(set) var floorY: Double?
    @Published private(set) var publishedHz: Double = 0
    /// True between `start` and `pause` (or a session failure). The app only re-runs ARKit when this is false,
    /// because every run with a saved map restarts relocalization and invalidates the frame.
    private(set) var isRunning = false

    let session = ARSession()
    private var limiter = RateLimiter(maxHz: PoseTracker.maxHz)
    private var floorPlanes: [UUID: (y: Double, area: Double)] = [:]
    private var lastStamp: Double?
    private var hzEMA = 0.0

    /// Called on every (re)start with whether a saved map was loaded: a new ARKit run is a new coordinate frame.
    var onSessionStart: ((_ loadedSavedMap: Bool) -> Void)?
    /// Called on an interruption or session failure, BEFORE `.notAvailable` is published: the device may have moved
    /// while ARKit was blind, so the frame gate must wait for real relocalization (unlike an in-run tracking drop).
    var onInterruption: ((_ why: String) -> Void)?

    override init() {
        super.init()
        session.delegate = self
    }

    /// Starts world tracking. Pass a saved map to relocalize against it (Teach map).
    func start(initialWorldMap: ARWorldMap? = nil, resetTracking: Bool = false) {
        let config = ARWorldTrackingConfiguration()
        var semantics: ARConfiguration.FrameSemantics = []
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { semantics.insert(.sceneDepth) }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { semantics.insert(.smoothedSceneDepth) }
        config.frameSemantics = semantics
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .none
        config.initialWorldMap = initialWorldMap
        floorPlanes.removeAll()
        floorY = nil
        let options: ARSession.RunOptions = resetTracking || initialWorldMap != nil
            ? [.resetTracking, .removeExistingAnchors] : []
        // Forget the previous run's state BEFORE announcing the new one, so a leftover `.normal` is never read as
        // "recognised" in the new run.
        trackingReason = ""
        tracking = .notAvailable
        mapping = .notAvailable
        pose = nil
        onSessionStart?(initialWorldMap != nil)
        session.run(config, options: options)
        isRunning = true
    }

    func pause() { session.pause(); isRunning = false }

    func currentWorldMap(_ completion: @escaping (ARWorldMap?) -> Void) {
        session.getCurrentWorldMap { map, _ in completion(map) }
    }

    // MARK: ARSessionDelegate (delivered on the main queue by default)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.timestamp
        guard limiter.shouldPublish(at: t) else { return }

        if let last = lastStamp, t > last {
            hzEMA = hzEMA == 0 ? 1 / (t - last) : 0.9 * hzEMA + 0.1 / (t - last)
            publishedHz = hzEMA
        }
        lastStamp = t

        // Reason first: subscribers combine (tracking, reason) and must see the new reason with the new tracking.
        trackingReason = Self.reason(frame.camera.trackingState)
        tracking = Self.kind(frame.camera.trackingState)
        mapping = Self.kind(frame.worldMappingStatus)
        // Do not publish a pose the tracker itself says is unavailable.
        pose = tracking == .notAvailable ? nil : PoseMath.pose(from: frame.camera.transform)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { updatePlanes(anchors) }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for a in anchors { floorPlanes[a.identifier] = nil }
        floorY = PoseMath.floorY(planes: Array(floorPlanes.values))
    }

    func sessionWasInterrupted(_ session: ARSession) { onInterruption?("AR interrupted"); tracking = .notAvailable; pose = nil }
    func sessionInterruptionEnded(_ session: ARSession) { /* tracking state resumes via frames */ }
    /// After an interruption, ask ARKit to relocalize into the same frame (it then reports `limited(.relocalizing)`)
    /// instead of continuing in a frame that may have shifted.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
    func session(_ session: ARSession, didFailWithError error: Error) {
        isRunning = false
        onInterruption?("AR session failed")
        tracking = .notAvailable
        trackingReason = error.localizedDescription
        pose = nil
    }

    private func updatePlanes(_ anchors: [ARAnchor]) {
        var changed = false
        for case let plane as ARPlaneAnchor in anchors where plane.alignment == .horizontal {
            let center = plane.transform * simd_float4(plane.center, 1)
            floorPlanes[plane.identifier] = (Double(center.y), Double(plane.planeExtent.width * plane.planeExtent.height))
            changed = true
        }
        if changed { floorY = PoseMath.floorY(planes: Array(floorPlanes.values)) }
    }

    // MARK: ARKit to contract strings

    static func kind(_ s: ARCamera.TrackingState) -> TrackingKind {
        switch s {
        case .normal: return .normal
        case .limited: return .limited
        case .notAvailable: return .notAvailable
        }
    }

    static func reason(_ s: ARCamera.TrackingState) -> String {
        guard case .limited(let r) = s else { return "" }
        switch r {
        case .initializing: return "initializing"
        case .excessiveMotion: return "excessive motion"
        case .insufficientFeatures: return "insufficient features"
        case .relocalizing: return "relocalizing"
        @unknown default: return "limited"
        }
    }

    static func kind(_ s: ARFrame.WorldMappingStatus) -> MappingKind {
        switch s {
        case .mapped: return .mapped
        case .limited: return .limited
        case .extending: return .extending
        case .notAvailable: return .notAvailable
        @unknown default: return .notAvailable
        }
    }
}
