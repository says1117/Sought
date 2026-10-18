import SwiftUI
import ARKit
import CoreImage
import Combine
import os

/// Builds and owns the real robot stack: DriveLink, PoseTracker, stores, the coordinator, the heartbeat, and the
/// perception loop. Everything with logic lives in Sources/Coordinator and is unit tested; this file is wiring.
///
/// Threading: the coordinator and Controller run off the main thread. They never touch the mutable PoseTracker or
/// DriveLink. Obstacle data comes from `SensorCache`, pose/tracking from `PoseSnapshotBox` (both updated on the
/// main thread under a lock), and every drive write goes through `SerialDriveSink`, which runs it on the main queue.
/// Manual tools take the drive lease exclusively through `beginManualControl` / `endManualControl`.
@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var coordinatorStatus = CoordinatorStatus.idle
    @Published private(set) var perceptionNote = "Perception idle"
    /// Non-nil when waypoints or remembered objects could only be kept in memory this run.
    @Published private(set) var storageWarning: String?

    let link: DriveLink
    let pose: PoseTracker
    let speaker = AppleSpeaker()
    let features = RecallFeatureFlags()
    let encoderSet: EncoderSet
    let coordinator: RobotCoordinator

    private let waypointStore: WaypointStore
    private let cache = SensorCache()
    private let frameGate = WorldFrameGate()
    private let poseBox = PoseSnapshotBox()
    private var poseSubscription: AnyCancellable?
    private var mappingSubscription: AnyCancellable?
    private var storageWarningSpoken = false
    private let heartbeatSource = CoordinatorHeartbeatSource()
    private var heartbeat: HeartbeatPublisher?
    private var sensorTimer: Timer?
    private var perception: PerceptionLoop?
    private var scheduler = PerceptionScheduler()

    /// What the robot looked at during recent arrival checks (JPEG crops), newest last. For a future viewer.
    let arrivalCrops: ArrivalCropRingBuffer
    private static let log = Logger(subsystem: "com.recall", category: "encoders")

    /// `encoders` defaults to the real Core ML set when the models are installed (arrival check reads the shared
    /// ARSession), else the models-missing set. `cropEmbedder` overrides the perception loop's embedder (tests).
    init(link: DriveLink, pose: PoseTracker,
         encoders: EncoderProvider? = nil,
         cropEmbedder: (([CIImage]) throws -> [[Float]])? = nil) {
        self.link = link
        self.pose = pose
        let crops = ArrivalCropRingBuffer(capacity: 12)
        self.arrivalCrops = crops
        let encoders = encoders ?? EncoderProviders.makeDefault(frames: ARKitFrameSource(session: pose.session), debugSink: crops)
        self.encoderSet = encoders.encoders()
        if let why = encoderSet.diagnostic { Self.log.error("Image models unavailable: \(why, privacy: .public)") }

        let dir = WorldMapStore.defaultURL().deletingLastPathComponent()
        let dbPath = dir.appendingPathComponent("recall.sqlite").path
        let waypoints: WaypointStore
        let tracks: TrackStore
        var lost: [String] = []
        do { waypoints = try WaypointStore(path: dbPath) } catch {
            waypoints = try! WaypointStore(path: ":memory:"); lost.append("saved places")
        }
        do { tracks = try TrackStore(path: dbPath) } catch {
            tracks = try! TrackStore(path: ":memory:"); lost.append("remembered objects")
        }
        let waypointsPersistent = !lost.contains("saved places")
        let warning: String? = lost.isEmpty ? nil : "Storage unavailable. New \(lost.joined(separator: " and ")) are temporary and will be lost when the app closes."

        self.waypointStore = waypoints
        let cache = self.cache
        let wiring = CoordinatorWiring(
            poses: poseBox, drive: SerialDriveSink(target: link, queue: .main, isOnQueue: { Thread.isMainThread }),
            guardState: { cache.guardState() }, waypointStore: waypoints, trackStore: tracks,
            encoders: encoders, speaker: SpeakerAdapter(speaker: speaker), features: features,
            waypointsPersistent: waypointsPersistent, frame: frameGate)
        let coordinator = wiring.makeCoordinator()
        self.coordinator = coordinator
        self.storageWarning = warning

        let embed = cropEmbedder ?? encoderSet.imageModel.map(Self.perceptionEmbedder)
        if let embed, encoderSet.isAvailable {
            perception = PerceptionLoop(session: pose.session, ingestor: MemoryIngestor(store: tracks), embed: embed,
                                        floorY: { [weak pose] in pose?.floorY })
        }
        perceptionNote = perception == nil ? "Memory is not filling: image models not installed" : "Memory fills while parked"
        if perception == nil { Self.log.notice("Perception loop not started: image models not installed") }

        let box = poseBox
        poseSubscription = Publishers.CombineLatest(pose.$pose, pose.$tracking)
            .sink { box.update(pose: $0, tracking: $1) }
        // Persisted targets are only valid after ARKit recognises the saved map again in this session.
        let gate = frameGate
        pose.onSessionStart = { gate.sessionStarted(loadedSavedMap: $0) }
        mappingSubscription = Publishers.CombineLatest(pose.$tracking, pose.$mapping)
            .sink { gate.update(tracking: $0, mapping: $1) }

        let hb = heartbeatSource
        coordinator.onChange = { [weak self] status in
            hb.update(status: status)                       // lock only; safe inside the coordinator's lock
            DispatchQueue.main.async { self?.coordinatorStatus = status }
        }
        if let cfg = SyncConfig.fromBundle() {
            heartbeat = HeartbeatPublisher(transport: URLSessionTransport(config: cfg), provider: { hb.snapshot() })
        }
    }

    /// Perception crops are CIImages; the Core ML image model takes preprocessed RGBA, so convert and embed one by one.
    private static func perceptionEmbedder(_ model: CoreMLImageEmbedder) -> ([CIImage]) throws -> [[Float]] {
        let context = CIContext()
        return { crops in
            try crops.map { crop in
                guard let raw = CIImageRaw.rawImage(from: crop, context: context) else { throw ArrivalCropError.cropUnavailable }
                return try model.embedOne(raw)
            }
        }
    }

    /// One line for the find bar: what the robot is doing now.
    var statusLine: String {
        var s = "Robot: \(coordinatorStatus.state.heartbeatValue)"
        if let task = coordinatorStatus.task { s += " · \(task)" }
        if !encoderSet.isAvailable { s += "\nFinding objects is off: image models not installed" }
        if let storageWarning { s += "\n" + storageWarning }
        return s
    }

    /// Saved place names so the planner can resolve "go to the kitchen".
    func plannerContext() -> PlannerContext {
        PlannerContext(waypointNames: ((try? waypointStore.waypoints()) ?? []).map(\.name))
    }

    func start() {
        refreshSensors()
        if let storageWarning, !storageWarningSpoken {
            storageWarningSpoken = true
            speaker.speak(storageWarning)
        }
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

    /// Opening Manual drive, Teach or Self-test: stop and revoke the coordinator's drive access first, and keep it
    /// refused until the tool closes. Call `endManualControl` with the same name when it closes.
    func beginManualControl(_ tool: String) {
        coordinator.beginManualControl(tool)
        link.stop()
    }

    func endManualControl(_ tool: String) {
        link.stop()
        coordinator.endManualControl(tool)
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
