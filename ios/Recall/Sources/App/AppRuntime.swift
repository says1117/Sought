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
    // Robot tools accessors (find-loop B): the stored tracks, a Controller on the same drive path, the pose reader.
    let trackProvider: TrackProviding
    /// Explore (flag-gated): live LiDAR grid + the coordinator's explore task. See the EXPLORE block in init.
    let explore: ExploreRuntime
    let pairedPhone: PairedPhoneLink
    var scanPoses: ExplorePoseSource { poseBox }
    /// Scan here drives only through the coordinator's drive lease and its serialized sink, so global STOP,
    /// pause and backgrounding revoke it exactly like a coordinator task. Its turns in place skip the 35 cm
    /// forward stops but hold on the ESP32 close flags, missing sonar and stale readings (see TurnGuard).
    func makeScanController() -> Controller {
        Controller(poses: poseBox, sink: LeasedDriveSink(base: driveSink, lease: driveLease),
                   guardState: { [cache] in cache.guardState() }, turnGuard: { [cache] in cache.turnGuardState() })
    }
    /// Live forward-guard text for the Scan here screen.
    func guardReadout() -> String { cache.readout() }
    /// Start preconditions for a scan, and the lease it drives under. Registers the scan for runtime cancellation.
    func makeScanGate() -> ScanHereGate {
        LeaseScanGate(lease: driveLease, coordinatorBusy: { [coordinator] in coordinator.isBusy || coordinator.hasPending },
                      register: { [weak self] cancel in self?.scanCancel = cancel },
                      unregister: { [weak self] in self?.scanCancel = nil })
    }

    private let driveLease: DriveLease
    private let driveSink: SerialDriveSink
    /// Cancels the running scan (revokes its lease). Set while a scan runs; called by stop, pause, backgrounding.
    private var scanCancel: (() -> Void)?
    private let waypointStore: WaypointStore
    private let cache = SensorCache()
    private let frameGate = WorldFrameGate()
    private let poseBox = PoseSnapshotBox()
    private var poseSubscription: AnyCancellable?
    private var mappingSubscription: AnyCancellable?
    /// Adopts a map Teach just saved (id, frame generation read before the save). Set in init.
    private var adoptSavedMap: ((_ mapId: String, _ generation: Int?) -> Void)?
    private var storageWarningSpoken = false
    private let heartbeatSource = CoordinatorHeartbeatSource()
    private var heartbeat: HeartbeatPublisher?
    private var uploader: BackendUploader?          // T-071 backend uploads (see the T-071 block in init)
    private var commandPoller: CommandPoller?       // remote commands from Sought (see the REMOTE COMMANDS block in init)
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
        // Tracks are scoped to the saved map the gate says this session uses (see TrackStore, WorldFrameGate).
        let gateForScope = frameGate
        let scope: () -> String? = { gateForScope.activeMapId }
        do { tracks = try TrackStore(path: dbPath, scope: scope) } catch {
            tracks = try! TrackStore(path: ":memory:", scope: scope); lost.append("remembered objects")
        }
        let waypointsPersistent = !lost.contains("saved places")
        let warning: String? = lost.isEmpty ? nil : "Storage unavailable. New \(lost.joined(separator: " and ")) are temporary and will be lost when the app closes."

        self.waypointStore = waypoints
        self.trackProvider = tracks
        let cache = self.cache
        let sink = SerialDriveSink(target: link, queue: .main, isOnQueue: { Thread.isMainThread })
        let lease = DriveLease()
        self.driveSink = sink
        self.driveLease = lease
        var wiring = CoordinatorWiring(
            poses: poseBox, drive: sink,
            guardState: { cache.guardState() }, turnGuard: { cache.turnGuardState() }, waypointStore: waypoints, trackStore: tracks,
            encoders: encoders, speaker: SpeakerAdapter(speaker: speaker), features: features,
            waypointsPersistent: waypointsPersistent, frame: frameGate)
        wiring.lease = lease
        wiring.onFindTrace = { FindTraceRecorder.shared.record($0) }   // Robot tools 'Last find'
        // EXPLORE (explore-wire branch) BEGIN: grid fed from LiDAR only when the flag is on; runs as a coordinator task.
        let explore = ExploreRuntime(enabled: features.exploreEnabled, pose: pose, poses: poseBox,
                                     speaker: SpeakerAdapter(speaker: speaker))
        self.explore = explore
        wiring.makeExplorer = explore.makeExplorer
        // EXPLORE END
        let pairedPhone = PairedPhoneLink()
        self.pairedPhone = pairedPhone
        let guidance = pairedPhone.guidance
        let approachPoses = poseBox
        let pairedComer = PairedComeToMeAdapter(ranging: guidance, isReady: { guidance.isEnabled },
            makeMotion: {
                PairedControllerMotion(poses: approachPoses, sink: LeasedDriveSink(base: sink, lease: lease),
                                       guardState: { cache.guardState() }, turnGuard: { cache.turnGuardState() })
            }, onStatus: { [weak pairedPhone] request, state, distance, reason in
                Task { @MainActor in pairedPhone?.progress(request, state: state, distance: distance, reason: reason) }
            })
        wiring.makeComer = { pairedComer }
        // REMOTE TEACH BEGIN: move / turn / scan here / save map from remote commands, on the coordinator's Controller and
        // lease. Save map uses Teach's ARWorldMapAdapter and adopts the map through mapSaved (onSaved is set at the end of init).
        let teachMapSaver = ARWorldMapAdapter(tracker: pose)
        teachMapSaver.currentGeneration = { [frameGate] in frameGate.generation }
        let teachPoses = poseBox
        let scanConfig = ScanHereModel.defaultConfig
        wiring.makeRemoteTeach = { controller in
            RemoteTeachAdapter(controller: controller, poses: teachPoses, reverseSink: LeasedDriveSink(base: sink, lease: lease),
                               rearHold: { cache.rearHold() }, scanConfig: scanConfig,
                               saveMap: { await Self.saveWorldMap(teachMapSaver) })
        }
        // REMOTE TEACH END
        let coordinator = wiring.makeCoordinator()
        self.coordinator = coordinator
        pairedPhone.bind(coordinator: coordinator, adapter: pairedComer)
        self.storageWarning = warning

        let embed = cropEmbedder ?? encoderSet.imageModel.map(Self.perceptionEmbedder)
        if let embed, encoderSet.isAvailable {
            perception = PerceptionLoop(session: pose.session, ingestor: MemoryIngestor(store: tracks, frame: frameGate), embed: embed,
                                        floorY: { [weak pose] in pose?.floorY })
        }
        perceptionNote = perception == nil ? "Memory is not filling: image models not installed" : "Memory fills while parked"
        if perception == nil { Self.log.notice("Perception loop not started: image models not installed") }

        let box = poseBox
        poseSubscription = Publishers.CombineLatest(pose.$pose, pose.$tracking)
            .sink { box.update(pose: $0, tracking: $1) }
        // Persisted targets are only valid after ARKit recognises the saved map again in this session.
        let gate = frameGate
        // The saved map's id scopes remembered objects; tracks of any other map are deleted once this one is loaded.
        pose.onSessionStart = { loaded in
            let mapStore = WorldMapStore(url: WorldMapStore.defaultURL())
            let id = loaded ? mapStore.currentMapId() : nil
            gate.sessionStarted(loadedSavedMap: loaded, mapId: id, waypointCutoff: id.flatMap { mapStore.waypointCutoff(mapId: $0) })
            if let id { _ = try? tracks.purgeOtherMaps(keeping: id) }
        }
        pose.onInterruption = { gate.interrupted($0) }
        mappingSubscription = Publishers.CombineLatest3(pose.$tracking, pose.$mapping, pose.$trackingReason)
            .sink { gate.update(tracking: $0, mapping: $1, relocalizing: $2 == "relocalizing") }
        // Teach saved the running session's map: it is this frame, so use it now (no relaunch). If the session was
        // already relocalized against the previous map, that map's objects are in the same frame and move over;
        // otherwise they belong to a map that no longer exists on disk and go.
        adoptSavedMap = { id, generation in
            let mapStore = WorldMapStore(url: WorldMapStore.defaultURL())
            guard let adopted = gate.adoptSavedMap(mapId: id, ifGeneration: generation) else {
                // The frame changed during the save: the map is used from the next run. Nothing stored predates
                // it safely, so refuse older waypoints against it.
                mapStore.setWaypointCutoff(Date(), mapId: id)
                Self.log.notice("Saved map not adopted: the AR session changed during the save")
                return
            }
            mapStore.setWaypointCutoff(adopted.waypointCutoff, mapId: id)
            if adopted.wasRelocalized { _ = try? tracks.retagMap(from: adopted.previousMapId, to: id) }
            _ = try? tracks.purgeOtherMaps(keeping: id)
        }

        let hb = heartbeatSource
        coordinator.onChange = { [weak self] status in
            hb.update(status: status)                       // lock only; safe inside the coordinator's lock
            DispatchQueue.main.async { self?.coordinatorStatus = status }
        }
        if let cfg = SyncConfig.fromBundle() {
            heartbeat = HeartbeatPublisher(transport: URLSessionTransport(config: cfg), provider: { hb.snapshot() })
        }
        // BEGIN T-071 backend uploads: objects of the active map + waypoints, in the background (Sources/Sync).
        // Objects only while the session is relocalized against that map (one locked read of both).
        if let cfg = SyncConfig.fromBundle() {
            uploader = BackendUploader.make(config: cfg, databasePath: dbPath,
                                            queuePath: dir.appendingPathComponent("sync-queue.sqlite").path,
                                            mapId: { [frameGate] in frameGate.performIfCurrent(generation: nil) { $0 } })
            uploader?.start()
        }
        // END T-071
        // BEGIN REMOTE COMMANDS: only with a backend configured. Polls /api/commands/next every 2 s while active
        // (start/pause below); text goes through the find bar's planner and this coordinator. Busy -> acked failed.
        commandPoller = CommandPoller.make(config: SyncConfig.fromBundle(), runner: RemoteCommandRunner(
            planner: FallbackPlanner.make(), coordinator: coordinator, context: { [waypoints] in
                PlannerContext(waypointNames: ((try? waypoints.waypoints()) ?? []).map(\.name))
            }))
        // END REMOTE COMMANDS
        // REMOTE TEACH: a remote save map is adopted exactly like Teach's (main queue, see ARWorldMapAdapter.onSaved).
        teachMapSaver.onSaved = { [weak self] id, generation in
            MainActor.assumeIsolated { self?.mapSaved(mapId: id, generation: generation) }
        }
    }

    /// REMOTE TEACH: Teach's Save map, awaited. nil when saved, else the reason Teach would show.
    private nonisolated static func saveWorldMap(_ saver: ARWorldMapAdapter) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            DispatchQueue.main.async {
                saver.saveCurrentMap { result in
                    switch result {
                    case .success: c.resume(returning: nil)
                    case .failure(let e): c.resume(returning: e.localizedDescription)
                    }
                }
            }
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

    /// True when a backend is configured, so the robot is polling for commands from the Sought app.
    var remoteLinked: Bool { commandPoller != nil }

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
        commandPoller?.start()
        pairedPhone.resume()
    }

    /// Stop button, backgrounding: brake and cancel the task. Safe to call any time.
    func stopEverything() {
        // The scan first: revoke its lease and brake, then the coordinator (which revokes the lease for good).
        let cancelScan = scanCancel
        scanCancel = nil
        cancelScan?()
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

    /// Frame generation, read by Teach before saving a map (see `mapSaved`).
    var frameGeneration: Int { frameGate.generation }

    /// Teach banner state: recognised, relocalizing (elapsed), rescan needed, or idle (no saved map in use).
    func relocalizationState() -> RelocalizationState { frameGate.relocalizationState() }

    /// Why and when recognition was last lost, refused or regained (Teach banner, Memory note).
    func relocalizationDetail() -> String? { frameGate.statusDetail }

    /// Teach saved the current world map as `mapId`; `generation` is `frameGeneration` read before the save began.
    func mapSaved(mapId: String, generation: Int?) { adoptSavedMap?(mapId, generation) }

    func pause() {
        pairedPhone.suspend()
        // Remote commands first, so nothing claimed before the pause can start after the brake below.
        commandPoller?.stop()
        stopEverything()
        heartbeat?.stop()
        sensorTimer?.invalidate()
        sensorTimer = nil
    }

    private func tick() {
        refreshSensors()
        guard let perception else { return }
        // Persistent memory is only written in the saved map's frame (see MemoryIngestor), so wait for it.
        let why = frameGate.statusDetail.map { " (\($0))" } ?? ""
        let note = perception.ingestor.canIngest ? "Memory fills while parked"
            : frameGate.usesSavedMap ? "Room not recognised yet: look around, not saving objects" + why
            : "No room map in use: Teach → Save map"
        if perceptionNote != note { perceptionNote = note }
        guard perception.ingestor.canIngest else { return }
        let ok = scheduler.decide(now: ProcessInfo.processInfo.systemUptime, robotStationary: link.isRobotStationary,
                                  trackingNormal: pose.tracking == .normal, modelsAvailable: true)
        if ok { perception.capture() }
    }

    private func refreshSensors() {
        let frame = pose.session.currentFrame
        let corridor = frame.flatMap { DepthAdapter.corridorResult(from: $0, floorY: pose.floorY) }
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

    /// Guard for Scan here's turns in place: drops the 35 cm forward stops, keeps the ESP32 close-range flags,
    /// missing sonar and stale readings as holds (see TurnGuard).
    func turnGuardState() -> GuardState {
        lock.lock(); let s = sonar, t = stamp; lock.unlock()
        let stale = ProcessInfo.processInfo.systemUptime - t > Self.maxAgeS
        return TurnGuard.hold(sonar: s, stale: stale) == nil ? .clear : .stop
    }

    /// REMOTE TEACH: true = do not reverse now (rear flag, rear sonar too close, no sonar, stale; see RearGuard).
    func rearHold() -> Bool {
        lock.lock(); let s = sonar, t = stamp; lock.unlock()
        return RearGuard.hold(sonar: s, stale: ProcessInfo.processInfo.systemUptime - t > Self.maxAgeS)
    }

    /// What the forward guard sees now, as text for the Scan here debug line.
    func readout() -> String {
        lock.lock(); let c = corridor, s = sonar, t = stamp; lock.unlock()
        return GuardReadout.text(corridor: c, sonar: s, ageS: ProcessInfo.processInfo.systemUptime - t, staleAfterS: Self.maxAgeS)
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
    let ingestor: MemoryIngestor
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
        // A keyframe taken with limited tracking lifts objects with a wrong pose (metres under the floor).
        guard let frame = session.currentFrame, MemoryIngestor.admitsKeyframe(tracking: PoseTracker.kind(frame.camera.trackingState)),
              let floor = floorY(),
              let (geometry, depth) = ARKitKeyframeAdapter.extract(from: frame, floorY: Float(floor)) else { finish(); return }
        let buffer = frame.capturedImage
        let generation = ingestor.generation          // the frame this keyframe belongs to
        Task.detached(priority: .utility) { [self] in
            defer { finish() }
            let source = CIFrameCropSource(pixelBuffer: buffer)
            let lists = [SaliencyProposalSource().proposals(in: buffer), ProposalMath.gridBackstop()]
            if let objects = try? pipeline.process(frame: source, depth: depth, geometry: geometry, proposalLists: lists) {
                _ = try? ingestor.ingest(objects, generation: generation)
            }
        }
    }

    private func finish() { lock.lock(); busy = false; lock.unlock() }
}
