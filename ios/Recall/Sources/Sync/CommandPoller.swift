import Foundation

/// Remote command (docs/03_CONTRACTS.md section 2.9). Sought posts free text; the robot claims it with
/// `GET /api/commands/next` (the server marks it `running`; 204 when nothing is queued) and acks the result.
public struct WireCommand: Codable, Equatable {
    public var id: String
    public var text: String
    public var createdAt: String
    public var status: String
    public var result: String?
    public init(id: String, text: String, createdAt: String, status: String, result: String?) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.status = status; self.result = result
    }
    enum CodingKeys: String, CodingKey { case id, text, createdAt = "created_at", status, result }
}

/// Body of `POST /api/commands/{id}/ack`. `result` is always sent (null for the running ack).
public struct WireCommandAck: Encodable, Equatable {
    public var status: String
    public var result: String?
    public init(status: String, result: String?) { self.status = status; self.result = result }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(result, forKey: .result)
    }
    enum CodingKeys: String, CodingKey { case status, result }
}

/// The poller needs response bodies, which `SyncTransport` does not return. Throws only when no response came.
public protocol CommandTransport {
    func exchange(_ request: SyncRequest) async throws -> (status: Int, body: Data)
}

extension URLSessionTransport: CommandTransport {
    public func exchange(_ r: SyncRequest) async throws -> (status: Int, body: Data) {
        var req = URLRequest(url: URL(string: config.baseURL.absoluteString.trimmingSlash + r.path)!)
        req.httpMethod = r.method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body = r.body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

public enum CommandOutcome: Equatable {
    case done(String)
    case failed(String)
}

/// Runs one command's text (planner + coordinator in the app). Must refuse with `.failed(CommandPoller.busy)`
/// instead of queueing motion when the robot is busy or a manual tool is open; a stop is always obeyed.
public protocol CommandRunning: AnyObject {
    func run(_ text: String) async -> CommandOutcome
}

/// Polls `GET /api/commands/next` every 2 s while started. Each claimed command is acked `running`, handed to
/// the runner, then acked `done` with the result or `failed` with the reason. Polling continues while a
/// command runs so a remote "stop" still gets through; the runner refuses anything else as busy.
/// Network errors and non-2xx answers back off quietly (2, 4, 8 ... 30 s) and never reach the robot loop.
public final class CommandPoller {
    public static let interval: TimeInterval = 2
    public static let busy = "busy"
    public static let maxResultLength = 500
    private let transport: CommandTransport
    private let runner: CommandRunning
    private let backoff: Backoff
    private let sleep: (TimeInterval) async throws -> Void
    private let lock = NSLock()
    private var loop: Task<Void, Never>?
    private var failures = 0
    public private(set) var acksFailed = 0

    public init(transport: CommandTransport, runner: CommandRunning,
                backoff: Backoff = Backoff(base: 2, factor: 2, cap: 30),
                sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.transport = transport; self.runner = runner; self.backoff = backoff; self.sleep = sleep
    }

    /// Nil when no backend is configured: then nothing ever touches the network.
    public static func make(config: SyncConfig?, runner: CommandRunning) -> CommandPoller? {
        config.map { CommandPoller(transport: URLSessionTransport(config: $0), runner: runner) }
    }

    public var consecutiveFailures: Int { lock.lock(); defer { lock.unlock() }; return failures }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard loop == nil else { return }
        loop = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.pollOnce().delay
                do { try await self.sleep(delay) } catch { return }
            }
        }
    }

    /// Stops polling. A command already running keeps going and still sends its final ack.
    public func stop() {
        lock.lock(); let l = loop; loop = nil; lock.unlock()
        l?.cancel()
    }

    /// One poll. Returns the delay before the next poll and the task handling a claimed command (tests await it).
    @discardableResult
    public func pollOnce() async -> (delay: TimeInterval, work: Task<Void, Never>?) {
        let response: (status: Int, body: Data)
        do {
            response = try await transport.exchange(SyncRequest(method: "GET", path: "/api/commands/next", body: nil, media: nil))
        } catch {
            return (failed(), nil)
        }
        if response.status == 204 { return (succeeded(), nil) }
        guard response.status == 200, let command = try? JSONDecoder().decode(WireCommand.self, from: response.body) else {
            return (failed(), nil)
        }
        let delay = succeeded()
        let work = Task.detached(priority: .userInitiated) { [self] in await handle(command) }
        return (delay, work)
    }

    private func handle(_ command: WireCommand) async {
        await ack(command.id, status: "running", result: nil)
        let outcome = await runner.run(command.text)
        switch outcome {
        case .done(let text): await ack(command.id, status: "done", result: text)
        case .failed(let text): await ack(command.id, status: "failed", result: text)
        }
    }

    /// Up to three tries. 2xx and 409 (already finished, e.g. a retried final ack) count as delivered.
    private func ack(_ id: String, status: String, result: String?) async {
        let trimmed = result.map { String($0.prefix(Self.maxResultLength)) }
        guard let path = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).map({ "/api/commands/\($0)/ack" }),
              let body = try? SyncJSON.encode(WireCommandAck(status: status, result: trimmed)) else { return }
        for attempt in 0..<3 {
            if attempt > 0 { try? await sleep(1) }
            if let r = try? await transport.exchange(SyncRequest(method: "POST", path: path, body: body, media: nil)),
               r.status / 100 == 2 || r.status == 409 { return }
        }
        ackGaveUp()
    }

    private func ackGaveUp() { lock.lock(); acksFailed += 1; lock.unlock() }

    private func succeeded() -> TimeInterval {
        lock.lock(); failures = 0; lock.unlock()
        return Self.interval
    }

    private func failed() -> TimeInterval {
        lock.lock(); failures += 1; let n = failures; lock.unlock()
        return max(Self.interval, backoff.delay(afterFailures: n))
    }
}
