import Foundation

/// Latest-only camera traffic deliberately bypasses SyncQueue and media storage.
public protocol LiveCameraUploading {
    func upload(jpeg: Data) async throws
}

public struct URLSessionLiveCameraTransport: LiveCameraUploading {
    private let config: SyncConfig
    private let session: URLSession

    public init(config: SyncConfig, session: URLSession? = nil) {
        self.config = config
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 3
            c.timeoutIntervalForResource = 4
            c.waitsForConnectivity = false
            c.urlCache = nil
            self.session = URLSession(configuration: c)
        }
    }

    public func upload(jpeg: Data) async throws {
        try Task.checkCancellation()
        guard !jpeg.isEmpty, jpeg.count <= LiveCameraPublisher.maxBytes else { return }
        let request = makeRequest()
        let (_, response) = try await session.upload(for: request, from: jpeg)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func makeRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: config.baseURL.absoluteString.trimmingSlash + "/api/camera/frame")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}

/// One encode/upload at a time, at most 1 Hz. A missed frame is dropped, never retried or queued.
/// Frame timestamps and `clock` use monotonic seconds since boot (ARFrame.timestamp).
public final class LiveCameraPublisher {
    public static let maxBytes = 512 * 1024
    public static let interval: TimeInterval = 1
    public static let maxFrameAge: TimeInterval = 1
    private let transport: LiveCameraUploading
    private let clock: () -> Double
    private let lock = NSLock()
    private var active = false
    private var generation = 0
    private var lastFrame = -Double.infinity
    private var lastAccepted = -Double.infinity
    private var task: Task<Void, Never>?

    public init(transport: LiveCameraUploading,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.clock = clock
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return }
        active = true
        generation += 1
        lastAccepted = -Double.infinity
    }

    public func stop() {
        lock.lock()
        active = false
        generation += 1
        let pending = task
        // Keep the slot occupied until cancelled work actually finishes, including an encode that cannot cancel.
        lock.unlock()
        pending?.cancel()
    }

    /// `encode` runs on a utility worker; capture only pixels, never an ARFrame or mutable ARSession state.
    /// Returns the admitted work, or nil when dropped. Encodes are not started for dropped frames.
    @discardableResult
    public func offer(timestamp: Double, encode: @escaping () -> Data?) -> Task<Void, Never>? {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        guard active, task == nil, Self.isFresh(timestamp, now: now), timestamp > lastFrame,
              now - lastAccepted >= Self.interval else { return nil }
        lastFrame = timestamp
        lastAccepted = now
        let g = generation
        task = Task.detached(priority: .utility) { [self] in
            defer { finish() }
            guard isActive(g), !Task.isCancelled else { return }
            guard let jpeg = encode(), !jpeg.isEmpty, jpeg.count <= Self.maxBytes,
                  Self.isFresh(timestamp, now: clock()), isActive(g), !Task.isCancelled else { return }
            // URLSession's async upload observes task cancellation, including stop during the request.
            try? await transport.upload(jpeg: jpeg)
        }
        return task
    }

    private static func isFresh(_ timestamp: Double, now: Double) -> Bool {
        timestamp.isFinite && now.isFinite && timestamp >= 0 && now >= timestamp && now - timestamp <= maxFrameAge
    }
    private func isActive(_ g: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && generation == g
    }
    private func finish() {
        lock.lock(); task = nil; lock.unlock()
    }
}
