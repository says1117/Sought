import Foundation

/// Posts a heartbeat every 2 s. Fire and forget: it is NOT queued (a stale heartbeat is worse than
/// none), failures are ignored, and the robot loop is never awaited. At most one request is in
/// flight; if the network is slow, ticks are skipped rather than stacked.
public final class HeartbeatPublisher {
    public static let interval: TimeInterval = 2
    private let transport: SyncTransport
    private let provider: () -> WireHeartbeat
    private let lock = NSLock()
    private var inFlight = false
    private var task: Task<Void, Never>?
    public private(set) var sent = 0, failed = 0, skipped = 0

    /// `provider` should be cheap and return the latest cached snapshot (it runs off the robot thread).
    public init(transport: SyncTransport, provider: @escaping () -> WireHeartbeat) {
        self.transport = transport; self.provider = provider
    }

    public func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                self?.fire()
                try? await Task.sleep(nanoseconds: UInt64(HeartbeatPublisher.interval * 1_000_000_000))
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }

    /// Starts one send unless one is already running. Returns immediately.
    @discardableResult
    public func fire() -> Task<Void, Never>? {
        lock.lock()
        if inFlight { skipped += 1; lock.unlock(); return nil }
        inFlight = true; lock.unlock()
        guard let body = try? SyncJSON.encode(provider()) else { finish(ok: false); return nil }
        return Task.detached(priority: .utility) { [self] in
            let status = try? await transport.send(SyncRequest(method: "POST", path: "/api/robot/heartbeat", body: body, media: nil))
            finish(ok: (status ?? 0) / 100 == 2)
        }
    }
    private func finish(ok: Bool) {
        lock.lock(); inFlight = false; if ok { sent += 1 } else { failed += 1 }; lock.unlock()
    }
}
