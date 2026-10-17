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
    private var waiters: [(deadline: TimeInterval, cont: CheckedContinuation<Void, Error>)] = []
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func sleep(seconds: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock(); waiters.append((t + seconds, c)); lock.unlock()
            }
        } onCancel: {
            self.lock.lock(); let all = self.waiters; self.waiters = []; self.lock.unlock()
            // Cancel wakes everyone; live sleepers re-check Task.isCancelled and re-sleep via loop.
            for w in all { w.cont.resume(throwing: CancellationError()) }
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
            await coordSettle()
        }
    }
}

func coordSettle() async { for _ in 0..<30 { await Task.yield() } }

final class CoordTestPose: CoordinatorPoseSource {
    var value: CoordinatorTracking = .normal
    func tracking() -> CoordinatorTracking { value }
}

final class CoordTestDrive: CoordinatorDriveStopping {
    private(set) var stops = 0
    func stop() { stops += 1 }
}

final class CoordTestSpeaker: CoordinatorSpeaking {
    private(set) var said: [String] = []
    func say(_ text: String) { said.append(text) }
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
    private(set) var started: [String] = []
    private(set) var cancels = 0
    var onStart: ((String) -> Void)?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return cont != nil }

    private func run(_ name: String) async throws -> CoordinatorTaskResult {
        started.append(name)
        onStart?(name)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<CoordinatorTaskResult, Error>) in
            lock.lock(); cont = c; lock.unlock()
        }
    }
    func finish(_ r: CoordinatorTaskResult) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: r) }
    func fail(_ e: Error) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(throwing: e) }

    func explore(maxMinutes: Int?) async throws -> CoordinatorTaskResult { try await run("explore") }
    func find(description: String) async throws -> CoordinatorTaskResult { try await run("find:\(description)") }
    func comeToMe() async throws -> CoordinatorTaskResult { try await run("come") }
    func goTo(_ waypoint: CoordinatorWaypoint) async throws -> CoordinatorTaskResult { try await run("go:\(waypoint.name)") }
    func cancel() { lock.lock(); cancels += 1; lock.unlock(); finish(.cancelled) }
}

struct CoordRig {
    let explorer = CoordTestRunner(), finder = CoordTestRunner(), comer = CoordTestRunner(), navigator = CoordTestRunner()
    let waypoints = CoordTestWaypoints()
    let drive = CoordTestDrive(), speaker = CoordTestSpeaker(), clock = CoordTestClock(), pose = CoordTestPose()
    let coordinator: RobotCoordinator
    let states: StateLog

    final class StateLog { var seen: [CoordinatorStatus] = [] }

    init() {
        let e = explorer, f = finder, c = comer, n = navigator, w = waypoints, d = drive, s = speaker, k = clock, p = pose
        coordinator = RobotCoordinator(dependencies: CoordinatorDependencies(
            explorer: e, finder: f, comer: c, navigator: n, waypoints: w, drive: d, speaker: s, clock: k, pose: p))
        let log = StateLog()
        states = log
        coordinator.onChange = { log.seen.append($0) }
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
