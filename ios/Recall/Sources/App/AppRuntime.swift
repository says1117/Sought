import SwiftUI
import ARKit
import CoreImage

/// Builds and owns the real robot stack: DriveLink, PoseTracker, stores, the coordinator, the heartbeat, and the
/// perception loop. Everything with logic lives in Sources/Coordinator and is unit tested; this file is wiring.
///
/// Threading: the coordinator and Controller run off the main thread. They only read `SensorCache`, which the main
/// thread refreshes at 10 Hz under a lock, so they never touch @Published ARKit or BLE state directly.
@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var coordinatorStatus = CoordinatorStatus.idle
    @Published private(set) var perceptionNote = "Perception idle"

    let link: DriveLink
    let pose: PoseTracker
    let speaker = AppleSpeaker()
    let features = RecallFeatureFlags()
    let encoderSet: EncoderSet
    let coordinator: RobotCoordinator

    private let waypointStore: WaypointStore
    private let cache = SensorCache()
    private let heartbeatSource = CoordinatorHeartbeatSource()
    private var heartbeat: HeartbeatPublisher?
    private var sensorTimer: Timer?
    private var perception: PerceptionLoop?
    private var scheduler = PerceptionScheduler()

    init(link: DriveLink, pose: PoseTracker,
         encoders: EncoderProvider = EncoderProviders.makeDefault(),
         cropEmbedder: (([CIImage]) throws -> [[Float]])? = nil) {
        self.link = link
        self.pose = pose
        self.encoderSet = encoders.encoders()

        let dir = WorldMapStore.defaultURL().deletingLastPathComponent()
        let dbPath = dir.appendingPathComponent("recall.sqlite").path
        let waypoints: WaypointStore
        let tracks: TrackStore
        do { waypoints = try WaypointStore(path: dbPath) } catch { waypoints = try! WaypointStore(path: ":memory:") }
        do { tracks = try TrackStore(path: dbPath) } catch { tracks = try! TrackStore(path: ":memory:") }

        self.waypointStore = waypoints
        let cache = self.cache
        let wiring = CoordinatorWiring(
            poses: pose, drive: link, guardState: { cache.guardState() }, waypointStore: waypoints, trackStore: tracks,
            encoders: encoders, speaker: SpeakerAdapter(speaker: speaker), features: features)
        let coordinator = wiring.makeCoordinator()
        self.coordinator = coordinator

        if let embed = cropEmbedder, encoderSet.isAvailable {
            perception = PerceptionLoop(session: pose.session, ingestor: MemoryIngestor(store: tracks), embed: embed,
                                        floorY: { [weak pose] in pose?.floorY })
        }
        perceptionNote = perception == nil ? "Memory is not filling: image models not installed" : "Memory fills while parked"

        let hb = heartbeatSource
        coordinator.onChange = { [weak self] status in
            hb.update(status: status)                       // lock only; safe inside the coordinator's lock
            DispatchQueue.main.async { self?.coordinatorStatus = status }
        }
        if let cfg = SyncConfig.fromBundle() {
            heartbeat = HeartbeatPublisher(transport: URLSessionTransport(config: cfg), provider: { hb.snapshot() })
        }
    }

    /// One line for the find bar: what the robot is doing now.
    var statusLine: String {
        var s = "Robot: \(coordinatorStatus.state.heartbeatValue)"
        if let task = coordinatorStatus.task { s += " · \(task)" }
        if !encoderSet.isAvailable { s += "\nFinding objects is off: image models not installed" }
        return s
    }

    /// Saved place names so the planner can resolve "go to the kitchen".
    func plannerContext() -> PlannerContext {
        PlannerContext(waypointNames: ((try? waypointStore.waypoints()) ?? []).map(\.name))
    }

    func start() {
        refreshSensors()
        sensorTimer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        sensorTimer = t
        heartbeat?.start()
    }

    /// Stop button, backgrounding: brake and cancel the task. Safe to call any time.
    func stopEverything() {
        coordinator.stopAll()
        link.stop()
    }

    func pause() {
        stopEverything()
        heartbeat?.stop()
        sensorTimer?.invalidate()
        sensorTimer = nil
    }

    private func tick() {
        refreshSensors()
        guard let perception else { return }
        let ok = scheduler.decide(now: ProcessInfo.processInfo.systemUptime, robotStationary: link.isRobotStationary,
                                  trackingNormal: pose.tracking == .normal, modelsAvailable: true)
        if ok { perception.capture() }
    }

    private func refreshSensors() {
        let frame = pose.session.currentFrame
        let corridor = frame.flatMap { DepthAdapter.corridorResult(from: $0) }
        let sonar = link.isConnected ? link.robot.map { SonarSample(frontCm: $0.frontCm, rearCm: $0.rearCm, flags: $0.flags.rawValue) } : nil
        cache.update(corridor: corridor, sonar: sonar)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = Double(max(0, UIDevice.current.batteryLevel))
        heartbeatSource.update(sensors: .init(
            pose: pose.pose, tracking: pose.tracking, mapping: pose.mapping,
            frontCm: link.robot?.frontDistanceCm, rearCm: link.robot?.rearDistanceCm,
            phoneBattery: battery, firmwareLink: link.isConnected))
    }
}

/// Main-thread writer, any-thread reader. A stale cache means the main thread stalled, so fail closed.
final class SensorCache {
    private let lock = NSLock()
    private var corridor: CorridorResult?
    private var sonar: SonarSample?
    private var stamp = ProcessInfo.processInfo.systemUptime
    static let maxAgeS = 0.5

    func update(corridor: CorridorResult?, sonar: SonarSample?) {
        lock.lock(); self.corridor = corridor; self.sonar = sonar
        stamp = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }

    func guardState() -> GuardState {
        lock.lock(); let c = corridor, s = sonar, t = stamp; lock.unlock()
        if ProcessInfo.processInfo.systemUptime - t > Self.maxAgeS { return .stop }
        return GuardStateMapper.state(corridor: c, sonar: s)
    }
}

/// CoordinatorSpeaking on top of the main-actor Speaker.
final class SpeakerAdapter: CoordinatorSpeaking {
    private let speaker: AppleSpeaker
    init(speaker: AppleSpeaker) { self.speaker = speaker }
    func say(_ text: String) { Task { @MainActor [speaker] in speaker.speak(text) } }
}

/// Grabs a keyframe, runs the perception pipeline off the main thread, and feeds Memory.
/// Only constructed when a crop embedder exists (image models installed). NOT run on a device yet.
final class PerceptionLoop {
    private struct Embed: CropEmbedder {
        let f: ([CIImage]) throws -> [[Float]]
        func embed(_ crops: [CIImage]) throws -> [[Float]] { try f(crops) }
    }
    private let session: ARSession
    private let ingestor: MemoryIngestor
    private let pipeline: PerceptionPipeline<Embed>
    private let floorY: () -> Double?
    private let lock = NSLock()
    private var busy = false

    init(session: ARSession, ingestor: MemoryIngestor, embed: @escaping ([CIImage]) throws -> [[Float]], floorY: @escaping () -> Double?) {
        self.session = session; self.ingestor = ingestor; self.floorY = floorY
        self.pipeline = PerceptionPipeline(embedder: Embed(f: embed))
    }

    func capture() {
        lock.lock(); if busy { lock.unlock(); return }; busy = true; lock.unlock()
        guard let frame = session.currentFrame, let floor = floorY(),
              let (geometry, depth) = ARKitKeyframeAdapter.extract(from: frame, floorY: Float(floor)) else { finish(); return }
        let buffer = frame.capturedImage
        Task.detached(priority: .utility) { [self] in
            defer { finish() }
            let source = CIFrameCropSource(pixelBuffer: buffer)
            let lists = [SaliencyProposalSource().proposals(in: buffer), ProposalMath.gridBackstop()]
            if let objects = try? pipeline.process(frame: source, depth: depth, geometry: geometry, proposalLists: lists) {
                _ = try? ingestor.ingest(objects)
            }
        }
    }

    private func finish() { lock.lock(); busy = false; lock.unlock() }
}
