import Foundation
import UIKit
import ImageIO

enum LiveCameraState: Equatable { case idle, waiting, live, unavailable }

struct LiveCameraFrame {
    let image: UIImage
    let receivedAt: TimeInterval
    let responseAge: TimeInterval
    func age(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        responseAge + max(0, now - receivedAt)
    }
}

/// Latest-frame polling, only while the camera screen is visible and the app is active.
/// Nothing is cached on disk. The production transport bounds the body before decoding it.
@MainActor
final class LiveCameraFeed {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    nonisolated static let maxBytes = 512 * 1024
    nonisolated static let maxAge: TimeInterval = 5
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
    private let config: BackendConfig
    private let transport: Transport
    private let clock: () -> TimeInterval
    private let interval: TimeInterval
    private let update: (LiveCameraFrame?, LiveCameraState) -> Void
    private var poll: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var generation = 0

    init(config: BackendConfig, transport: @escaping Transport = LiveCameraFeed.boundedTransport,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         interval: TimeInterval = 1, update: @escaping (LiveCameraFrame?, LiveCameraState) -> Void) {
        self.config = config; self.transport = transport; self.clock = clock
        self.interval = interval; self.update = update
    }

    func start() {
        guard poll == nil else { return }
        generation += 1
        let g = generation
        update(nil, .waiting)
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.fetch(generation: g)
                guard self.generation == g, !Task.isCancelled else { return }
                do { try await Task.sleep(nanoseconds: UInt64(self.interval * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        poll?.cancel(); poll = nil
        expiry?.cancel(); expiry = nil
        update(nil, .idle)
    }

    private func fetch(generation g: Int) async {
        let began = clock()
        var req = URLRequest(url: config.baseURL.appending(path: "api/camera/frame"), cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        req.timeoutInterval = 4
        do {
            let (data, response) = try await transport(req)
            guard generation == g, !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let ageText = http.value(forHTTPHeaderField: "X-Frame-Age-Ms"),
                  let ageMs = Double(ageText), ageMs.isFinite, ageMs >= 0 else {
                clear(.unavailable); return
            }
            // Conservatively include the complete request duration, so slow transfers cannot rejuvenate a frame.
            let received = clock()
            let age = ageMs / 1000 + max(0, received - began)
            guard age < Self.maxAge, let image = Self.decode(data, response: http) else {
                clear(.unavailable); return
            }
            let frame = LiveCameraFrame(image: image, receivedAt: received, responseAge: age)
            expiry?.cancel()
            update(frame, .live)
            expiry = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64((Self.maxAge - age) * 1_000_000_000)) }
                catch { return }
                guard let self, self.generation == g, !Task.isCancelled else { return }
                self.clear(.unavailable)
            }
        } catch {
            guard generation == g, !Task.isCancelled else { return }
            // A failed request cannot establish capture freshness; do not keep a frozen LIVE image.
            clear(.unavailable)
        }
    }

    private func clear(_ state: LiveCameraState) {
        expiry?.cancel(); expiry = nil
        update(nil, state)
    }

    static func decode(_ data: Data, response: HTTPURLResponse) -> UIImage? {
        guard data.count <= maxBytes, data.count >= 3, data.starts(with: [0xff, 0xd8, 0xff]),
              response.mimeType?.lowercased() == "image/jpeg",
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), type as String == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0, width.intValue <= 640, height.intValue <= 640 else { return nil }
        return UIImage(data: data)
    }

    nonisolated static func boundedTransport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        return try await withTaskCancellationHandler(operation: {
            defer { bytes.task.cancel() }
            guard response.expectedContentLength <= Int64(maxBytes) else { throw URLError(.dataLengthExceedsMaximum) }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
            return (data, response)
        }, onCancel: { bytes.task.cancel() })
    }
}
