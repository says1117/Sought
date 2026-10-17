import Foundation

public enum SyncState: Equatable {
    case idle
    case offline            // last attempt hit a network error
    case authRequired       // server said 401; paused until resume() (surface to the user)
}

/// Drains SyncQueue through a SyncTransport.
///  - 2xx: row removed.
///  - network error, 5xx, 408, 429: row kept, attempts+1, next_try = now + backoff; pass stops on network error.
///  - 401: row kept, sender pauses (state .authRequired) until `resume()`; nothing is dropped.
///  - any other 4xx (the payload is wrong and will never succeed): row dropped, error logged.
/// Never throws into callers and never blocks the robot: call from a background Task.
public final class SyncSender {
    public private(set) var state: SyncState = .idle
    public private(set) var dropped = 0
    private let queue: SyncQueue
    private let transport: SyncTransport
    private let backoff: Backoff
    private let clock: () -> Double
    private let random: () -> Double
    private let log: (String) -> Void
    public var onStateChange: ((SyncState) -> Void)?

    public init(queue: SyncQueue, transport: SyncTransport, backoff: Backoff = Backoff(),
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                random: @escaping () -> Double = { Double.random(in: 0..<1) },
                log: @escaping (String) -> Void = { print("[sync] \($0)") }) {
        self.queue = queue; self.transport = transport; self.backoff = backoff
        self.clock = clock; self.random = random; self.log = log
    }

    /// Clear a 401 pause (call after the token is fixed) and make everything due.
    public func resume() {
        set(.idle)
        try? queue.makeAllDue(now: clock())
    }
    /// Call when connectivity returns so backed-off rows retry immediately.
    public func networkRestored() {
        if state == .offline { set(.idle) }
        try? queue.makeAllDue(now: clock())
    }

    /// One pass over everything currently due. Returns the number of rows delivered.
    @discardableResult
    public func drain() async -> Int {
        guard state != .authRequired else { return 0 }
        var delivered = 0
        while let item = (try? queue.nextDue(now: clock())) ?? nil {
            let request: SyncRequest
            if let mp = item.mediaPath {
                let url = URL(fileURLWithPath: mp)
                guard FileManager.default.fileExists(atPath: mp) else {
                    drop(item, "media file missing: \(mp)"); continue
                }
                let id = item.path == "/api/media" ? Self.mediaId(item) : nil
                guard let id else { drop(item, "media row without id"); continue }
                request = SyncRequest(method: item.method, path: item.path, body: nil, media: .init(id: id, fileURL: url))
            } else {
                request = SyncRequest(method: item.method, path: item.path, body: item.body, media: nil)
            }
            do {
                let status = try await transport.send(request)
                switch status {
                case 200..<300:
                    try? queue.remove(item); delivered += 1; set(.idle)
                case 401:
                    log("401 from backend: pausing sync, check RECALL_TOKEN (\(queue.safeCount()) queued)")
                    set(.authRequired); return delivered
                case 408, 429, 500..<600:
                    fail(item, "HTTP \(status)")
                case 400..<500:
                    drop(item, "HTTP \(status) for \(item.method) \(item.path)")
                default:
                    fail(item, "unexpected HTTP \(status)")
                }
            } catch {
                fail(item, "network error: \(error.localizedDescription)")
                set(.offline)
                return delivered
            }
        }
        return delivered
    }

    private static func mediaId(_ item: QueueItem) -> String? {
        guard let b = item.body, let o = try? JSONSerialization.jsonObject(with: b) as? [String: String] else { return nil }
        return o["id"]
    }
    private func fail(_ item: QueueItem, _ why: String) {
        let n = item.attempts + 1
        let d = backoff.delay(afterFailures: n, random: random())
        try? queue.recordFailure(item, attempts: n, nextTry: clock() + d)
        log("\(why); retry #\(n) of \(item.method) \(item.path) in \(String(format: "%.1f", d)) s")
    }
    private func drop(_ item: QueueItem, _ why: String) {
        dropped += 1
        try? queue.remove(item)
        log("ERROR dropping queued write: \(why)")
    }
    private func set(_ s: SyncState) {
        guard s != state else { return }
        state = s; onStateChange?(s)
    }
}

extension SyncQueue { func safeCount() -> Int { (try? count()) ?? -1 } }
