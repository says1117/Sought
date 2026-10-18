import Foundation

// Drive & Teach (remote teach tour from the user phone). Each button sends one exact phrase over the remote command
// route (RobotSource.sendCommand, contract 2.9), and the panel follows it: queued, running, then the robot's result.
// Robot phrase spec: "forward <x> m" / "back <x> m" (0.1 to 1.0), "turn left <deg>" / "turn right <deg>",
// "scan here", "mark <name>", "save map", "stop".
// One drive or teach command at a time. Stop is never blocked: it posts "stop" at once, even while another command is
// pending, and stops following the pending one so the buttons come back.

@MainActor
final class TeachPanelModel: ObservableObject {
    typealias Sender = (String, @escaping (RobotCommand) -> Void) async throws -> RobotCommand

    enum Phase: Equatable {
        case sending, queued, running
        case done(String)
        case failed(String)
        /// Stop was pressed while this command was pending; the panel no longer follows it.
        case stopped
        /// Accepted, then the app lost track of it (network, timeout, status error). It may still be moving, so the
        /// drive buttons stay locked until Stop.
        case unknown(String)

        var inFlight: Bool {
            switch self { case .sending, .queued, .running, .unknown: return true; default: return false }
        }
    }

    struct Line: Equatable {
        var text: String
        var phase: Phase
    }

    static let steps: [Double] = [0.25, 0.5, 1.0]
    static let turns: [Int] = [90, 45]

    @Published var step: Double = 0.5
    @Published var turn: Int = 90
    @Published var placeName = ""
    /// Last drive or teach command and where it is.
    @Published private(set) var current: Line?
    /// Last Stop and where it is. Separate so a Stop never hides the command it interrupted.
    @Published private(set) var stopLine: Line?

    private let send: Sender
    private var task: Task<Void, Never>?
    private var generation = 0
    private var stopGeneration = 0

    init(send: @escaping Sender) { self.send = send }

    convenience init(robot: RobotSource) {
        self.init { [weak robot] text, onUpdate in
            guard let robot else { throw CommandError.notAvailable }
            return try await robot.sendCommand(text, onUpdate: onUpdate)
        }
    }

    /// True while a drive or teach command is pending. Disables every button except Stop.
    var busy: Bool { current?.phase.inFlight == true }

    var canMark: Bool { !busy && !Self.cleanName(placeName).isEmpty }

    // MARK: Exact command text

    static func forwardText(_ m: Double) -> String { "forward \(meters(m)) m" }
    static func backText(_ m: Double) -> String { "back \(meters(m)) m" }
    static func turnLeftText(_ deg: Int) -> String { "turn left \(deg)" }
    static func turnRightText(_ deg: Int) -> String { "turn right \(deg)" }
    static let scanText = "scan here"
    static func markText(_ name: String) -> String { "mark \(cleanName(name))" }
    static let saveText = "save map"
    static let stopText = "stop"

    /// 0.25 -> "0.25", 0.5 -> "0.5", 1 -> "1.0".
    static func meters(_ m: Double) -> String {
        m == m.rounded() ? String(format: "%.1f", m) : String(format: "%g", m)
    }

    /// Trims and collapses spaces so "  kitchen   table " is sent as "kitchen table".
    static func cleanName(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Buttons

    func forward() { run(Self.forwardText(step)) }
    func back() { run(Self.backText(step)) }
    func turnLeft() { run(Self.turnLeftText(turn)) }
    func turnRight() { run(Self.turnRightText(turn)) }
    func scanHere() { run(Self.scanText) }
    func markPlace() {
        guard canMark else { return }
        run(Self.markText(placeName))
        placeName = ""
    }
    func saveMap() { run(Self.saveText) }

    /// Posts "stop" now, whatever else is pending.
    func stop() {
        if busy {
            generation += 1          // ignore late updates from the interrupted command
            task?.cancel()
            current?.phase = .stopped
        }
        stopGeneration += 1
        let g = stopGeneration
        stopLine = Line(text: Self.stopText, phase: .sending)
        Task { [weak self] in
            guard let self else { return }
            do {
                let cmd = try await self.send(Self.stopText) { [weak self] c in
                    guard let self, self.stopGeneration == g else { return }
                    self.stopLine?.phase = Self.phase(c)
                }
                if self.stopGeneration == g { self.stopLine?.phase = .done(Self.resultWords(cmd)) }
            } catch {
                if self.stopGeneration == g { self.stopLine?.phase = .failed(Self.reason(error)) }
            }
        }
    }

    private func run(_ text: String) {
        guard !busy else { return }
        generation += 1
        let g = generation
        current = Line(text: text, phase: .sending)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let cmd = try await self.send(text) { [weak self] c in
                    guard let self, self.generation == g else { return }
                    self.current?.phase = Self.phase(c)
                }
                if self.generation == g { self.current?.phase = .done(Self.resultWords(cmd)) }
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == g else { return }
                if let e = error as? CommandError, BackendRobotSource.isTransportProblem(e) {
                    self.current?.phase = .unknown(e.message)
                } else {
                    self.current?.phase = .failed(Self.reason(error))
                }
            }
        }
    }

    private static func phase(_ c: RobotCommand) -> Phase {
        switch c.status {
        case .queued: return .queued
        case .running: return .running
        case .done: return .done(resultWords(c))
        case .failed: return .failed(CommandError.failed(c.result).message)
        }
    }

    private static func resultWords(_ c: RobotCommand) -> String {
        let t = c.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "done" : t
    }

    private static func reason(_ error: Error) -> String {
        (error as? CommandError)?.message ?? "Something went wrong sending that."
    }
}
