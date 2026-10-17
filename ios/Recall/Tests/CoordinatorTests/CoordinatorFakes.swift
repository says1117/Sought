import Foundation
#if canImport(CoordinatorCore)
@testable import CoordinatorCore
#endif
#if canImport(PlannerCore)
@testable import PlannerCore
#endif

/// Manual clock. `advance` moves time in 0.1 s steps and wakes sleepers, yielding so watchers run.
final class CoordTestClock: CoordinatorClock {
    private let lock = NSLock()
    private var t: TimeInterval = 0
    private var waiters: [(id: UUID, deadline: TimeInterval, cont: CheckedContinuation<Void, Error>)] = []
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                waiters.append((id, t + seconds, c)); lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            let own = self.waiters.filter { $0.id == id }
            self.waiters.removeAll { $0.id == id }
            self.lock.unlock()
            for w in own { w.cont.resume(throwing: CancellationError()) }
        }
    }
    func advance(by s: TimeInterval) async {
        let steps = Int((s / 0.1).rounded())
        for _ in 0..<steps {
            lock.lock(); t += 0.1
            let due = waiters.filter { $0.deadline <= t + 1e-9 }
            waiters.removeAll { $0.deadline <= t + 1e-9 }
            lock.unlock()
            for w in due { w.cont.resume() }
            // Do not advance virtual time again until the monitor has consumed this tick
            // and registered its next sleep (or exited). Yield counts alone lose short dips.
            for _ in 0..<10_000 {
                lock.lock(); let registered = !waiters.isEmpty; lock.unlock()
                if registered { break }
                await Task.yield()
            }
            await coordSettle()
        }
    }
}

func coordSettle() async {
    for _ in 0..<100 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 1_000_000)
}

final class CoordTestPose: CoordinatorPoseSource {
    private let lock = NSLock()
    private var stored: CoordinatorTracking = .normal
    var value: CoordinatorTracking {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func tracking() -> CoordinatorTracking { value }
}

final class CoordTestDrive: CoordinatorDriveStopping {
    private let lock = NSLock()
    private var count = 0
    var stops: Int { lock.lock(); defer { lock.unlock() }; return count }
    func stop() { lock.lock(); count += 1; lock.unlock() }
}

final class CoordTestSpeaker: CoordinatorSpeaking {
    private let lock = NSLock()
    private var words: [String] = []
    var said: [String] { lock.lock(); defer { lock.unlock() }; return words }
    /// Runs after the text is recorded, on the speaking thread (may be inside the coordinator's lock).
    var onSay: ((String) -> Void)?
    func say(_ text: String) { lock.lock(); words.append(text); lock.unlock(); onSay?(text) }
}

final class CoordTestWaypoints: CoordinatorWaypoints {
    var known: [String: CoordinatorWaypoint] = ["kitchen": CoordinatorWaypoint(name: "kitchen", x: 1, z: 2)]
    var marked: [String] = []
    var markError: Error?
    func lookup(_ name: String) -> CoordinatorWaypoint? { known[name.lowercased()] }
    func markHere(name: String) throws -> CoordinatorWaypoint {
        if let markError { throw markError }
        marked.append(name)
        return CoordinatorWaypoint(name: name, x: 0, z: 0)
    }
}

struct CoordTestFailure: Error {}

/// One fake sub-task runner that suspends until the test finishes it or the coordinator cancels it.
final class CoordTestRunner: CoordinatorExploring, CoordinatorFinding, CoordinatorComingToUser, CoordinatorNavigating {
    private let lock = NSLock()
    private var cont: CheckedContinuation<CoordinatorTaskResult, Error>?
    private var starts: [String] = []
    private var cancelCount = 0
    var started: [String] { lock.lock(); defer { lock.unlock() }; return starts }
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return cancelCount }
    /// Deliberately uncooperative cancellation to test ownership while a runner drains.
    var finishOnCancel = true
    var onStart: ((String) -> Void)?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return cont != nil }

    private func run(_ name: String) async throws -> CoordinatorTaskResult {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CoordinatorTaskResult, Error>) in
            lock.lock()
            if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
            starts.append(name)
            cont = c; lock.unlock()
            onStart?(name)
        }
    }
    func finish(_ r: CoordinatorTaskResult) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: r) }
    func fail(_ e: Error) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(throwing: e) }

    func explore(maxMinutes: Int?) async throws -> CoordinatorTaskResult { try await run("explore") }
    func find(description: String) async throws -> CoordinatorTaskResult { try await run("find:\(description)") }
    func comeToMe() async throws -> CoordinatorTaskResult { try await run("come") }
    func goTo(_ waypoint: CoordinatorWaypoint) async throws -> CoordinatorTaskResult { try await run("go:\(waypoint.name)") }
    func cancel() {
        lock.lock(); cancelCount += 1; let shouldFinish = finishOnCancel; lock.unlock()
        if shouldFinish { finish(.cancelled) }
    }
}

struct CoordRig {
    let explorer = CoordTestRunner(), finder = CoordTestRunner(), comer = CoordTestRunner(), navigator = CoordTestRunner()
    let waypoints = CoordTestWaypoints()
    let drive = CoordTestDrive(), speaker = CoordTestSpeaker(), clock = CoordTestClock(), pose = CoordTestPose()
    let coordinator: RobotCoordinator
    let states: StateLog

    final class StateLog {
        private let lock = NSLock()
        private var statuses: [CoordinatorStatus] = []
        var seen: [CoordinatorStatus] { lock.lock(); defer { lock.unlock() }; return statuses }
        func append(_ status: CoordinatorStatus) { lock.lock(); statuses.append(status); lock.unlock() }
    }

    init() {
        let e = explorer, f = finder, c = comer, n = navigator, w = waypoints, d = drive, s = speaker, k = clock, p = pose
        coordinator = RobotCoordinator(dependencies: CoordinatorDependencies(
            explorer: e, finder: f, comer: c, navigator: n, waypoints: w, drive: d, speaker: s, clock: k, pose: p),
            // These tests exercise sequencing for every task type, so all features are on here.
            config: CoordinatorConfig(features: RecallFeatureFlags(exploreEnabled: true, comeToMeEnabled: true)))
        let log = StateLog()
        states = log
        coordinator.onChange = { log.append($0) }
    }

    /// Start a call in the background and let it reach its first suspension.
    @discardableResult
    func launch(_ call: ToolCall) async -> Task<Void, Error> {
        let co = coordinator
        let t = Task { try await co.execute(call) }
        await coordSettle()
        return t
    }
}
