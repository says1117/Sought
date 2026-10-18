import Foundation
import Combine
#if canImport(ExploreCore)
@testable import ExploreCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

// "Scan here": turn in place 4 x 90 degrees, pausing at each stop so the perception loop (which captures while the
// robot is parked with normal tracking) can look. This reuses Explore's ScanRoutine for the turn/dwell order and its
// ExploreDrive / ExploreClock / ExplorePoseSource protocols; it adds progress, cancel, and the start preconditions.
// No capture code here and no drive tuning: the turn speed is whatever Controller.rotateBy already uses.

enum ScanHereState: Equatable {
    case idle
    /// Parked at stop `step` of `total`, waiting for the dwell to finish.
    case dwelling(step: Int, total: Int)
    /// Turning to the next heading after stop `step`.
    case turning(step: Int, total: Int)
    case finished
    case cancelled
    /// Ended early on its own (tracking lost, turn failed). The rover was stopped.
    case stopped(reason: String)
    /// Never started.
    case refused(reason: String)

    var isRunning: Bool {
        switch self {
        case .dwelling, .turning: return true
        default: return false
        }
    }

    /// Short line for the screen, e.g. "Looking: stop 2 of 4".
    var progressText: String {
        switch self {
        case .idle: return "Ready"
        case .dwelling(let s, let t): return "Looking: stop \(s) of \(t)"
        case .turning(let s, let t): return "Turning after stop \(s) of \(t)"
        case .finished: return "Done: all stops scanned"
        case .cancelled: return "Stopped"
        case .stopped(let r): return "Stopped: \(r)"
        case .refused(let r): return "Not started: \(r)"
        }
    }

    /// Progress label like "2/4", nil when not scanning.
    var stepLabel: String? {
        switch self {
        case .dwelling(let s, let t), .turning(let s, let t): return "\(s)/\(t)"
        default: return nil
        }
    }
}

/// What else might own the drive. The app answers from the coordinator; tests use a fake.
protocol ScanHereGate: AnyObject {
    /// A coordinator task (find, go to, explore...) is running or queued.
    var otherTaskActive: Bool { get }
    /// A manual tool (Manual drive, Teach, Self-test) holds the drive lease.
    var manualToolHeld: Bool { get }
}

/// Lock-protected flags read by the scan routine's synchronous `shouldAbort` from any thread.
private final class ScanFlags {
    private let lock = NSLock()
    private var _cancelled = false
    private var _trackingLost = false
    var cancelled: Bool { get { lock.lock(); defer { lock.unlock() }; return _cancelled } set { lock.lock(); _cancelled = newValue; lock.unlock() } }
    var trackingLost: Bool { get { lock.lock(); defer { lock.unlock() }; return _trackingLost } set { lock.lock(); _trackingLost = newValue; lock.unlock() } }
}

@MainActor
final class ScanHereModel: ObservableObject {
    /// 4 x 90 degrees, 1.5 s at each stop. PLACEHOLDER dwell: long enough for a capture to fire, not tuned.
    static let defaultConfig = ScanConfig(rotations: 4, stepDeg: 90, dwellS: 1.5)

    @Published private(set) var state = ScanHereState.idle

    private let drive: ExploreDrive
    private let clock: ExploreClock
    private let poses: ExplorePoseSource
    private let gate: ScanHereGate
    private let stopAll: () -> Void
    private let config: ScanConfig
    private var task: Task<Void, Never>?
    private var flags = ScanFlags()

    /// `stopAll` brakes everything the app drives (coordinator and link); it is called on every cancel.
    init(drive: ExploreDrive, clock: ExploreClock, poses: ExplorePoseSource, gate: ScanHereGate,
         stopAll: @escaping () -> Void, config: ScanConfig = ScanHereModel.defaultConfig) {
        self.drive = drive; self.clock = clock; self.poses = poses; self.gate = gate
        self.stopAll = stopAll; self.config = config
    }

    var total: Int { config.rotations }

    /// Start button. Ignored while a scan is running.
    func start() {
        guard !state.isRunning, task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    /// The whole scan; `start()` runs this in a task. Tests await it directly.
    func run() async {
        guard !state.isRunning else { return }
        if gate.manualToolHeld { state = .refused(reason: "a manual tool is open"); return }
        if gate.otherTaskActive { state = .refused(reason: "another task is running, stop it first"); return }
        guard poses.latest().tracking == .normal else {
            state = .refused(reason: "tracking is not normal, wait until the camera tracks the room")
            return
        }
        let flags = ScanFlags()
        self.flags = flags
        state = .dwelling(step: 1, total: total)
        let poses = self.poses
        let result = await ScanRoutine(config: config).run(
            stopIndex: 0,
            drive: ProgressDrive(model: self, inner: drive, flags: flags),
            hook: NoCaptureHook(),
            clock: ProgressClock(model: self, inner: clock),
            shouldAbort: {
                if flags.cancelled { return true }
                if poses.latest().tracking != .normal { flags.trackingLost = true; return true }
                return false
            })
        drive.stop()
        if flags.cancelled { state = .cancelled; return }
        if flags.trackingLost || result == .trackingLost { state = .stopped(reason: "tracking was lost"); return }
        switch result {
        case .reached: state = .finished
        case .cancelled: state = .cancelled
        case .failed: state = .stopped(reason: "a turn did not finish")
        case .trackingLost: state = .stopped(reason: "tracking was lost")
        }
    }

    /// STOP button, leaving the screen, backgrounding. Always sends STOP, even when no scan is running.
    func cancel() {
        flags.cancelled = true
        drive.stop()
        stopAll()
        task?.cancel()
        if state.isRunning { state = .cancelled }
    }

    fileprivate func beginStop(_ n: Int) { if !flags.cancelled { state = .dwelling(step: min(n, total), total: total) } }
    fileprivate func beginTurn(after n: Int) { if !flags.cancelled { state = .turning(step: min(n, total), total: total) } }

    // The perception loop captures by itself while parked; the scan only provides the dwell.
    private final class NoCaptureHook: ScanHook {
        func captureKeyframe(stopIndex: Int, headingIndex: Int) async {}
    }

    /// Counts dwells so the screen shows which stop we are at.
    private final class ProgressClock: ExploreClock {
        private weak var model: ScanHereModel?
        private let inner: ExploreClock
        private var stops = 0
        init(model: ScanHereModel, inner: ExploreClock) { self.model = model; self.inner = inner }
        func now() -> Double { inner.now() }
        func sleep(_ seconds: Double) async {
            stops += 1
            await model?.beginStop(stops)
            await inner.sleep(seconds)
        }
    }

    private final class ProgressDrive: ExploreDrive {
        private weak var model: ScanHereModel?
        private let inner: ExploreDrive
        private let flags: ScanFlags
        private var turns = 0
        init(model: ScanHereModel, inner: ExploreDrive, flags: ScanFlags) { self.model = model; self.inner = inner; self.flags = flags }
        func goTo(x: Double, z: Double, stopDistance: Double) async -> DriveResult { .failed }   // never used by a scan
        func rotateBy(_ deg: Double) async -> DriveResult {
            if flags.cancelled || Task.isCancelled { return .cancelled }
            turns += 1
            await model?.beginTurn(after: turns)
            return await inner.rotateBy(deg)
        }
        func stop() { inner.stop() }
    }
}
