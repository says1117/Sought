import Foundation

public struct SyncRequest: Equatable {
    public var method: String
    public var path: String
    public var body: Data?
    public var media: Media?
    public struct Media: Equatable { public var id: String; public var fileURL: URL }
}

/// The network seam. Returns the HTTP status for any response; throws only when no response was
/// obtained (offline, timeout, DNS, TLS). Tests inject a fake.
public protocol SyncTransport {
    func send(_ request: SyncRequest) async throws -> Int
}

public struct URLSessionTransport: SyncTransport {
    let config: SyncConfig
    let session: URLSession
    public init(config: SyncConfig, session: URLSession? = nil) {
        self.config = config
        if let session { self.session = session } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 5       // never hang the sender; the queue retries
            c.timeoutIntervalForResource = 30
            c.waitsForConnectivity = false
            self.session = URLSession(configuration: c)
        }
    }

    public func send(_ r: SyncRequest) async throws -> Int {
        var req = URLRequest(url: URL(string: config.baseURL.absoluteString.trimmingSlash + r.path)!)
        req.httpMethod = r.method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let payload: Data
        if let m = r.media {
            let boundary = "recall-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            payload = Multipart.body(boundary: boundary, id: m.id, jpeg: try Data(contentsOf: m.fileURL))
        } else {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            payload = r.body ?? Data()
        }
        let (_, resp) = try await session.upload(for: req, from: payload)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }
}

extension String { var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self } }

public enum Multipart {
    /// Contract 2: multipart with text field `id` and file field `file` (image/jpeg).
    public static func body(boundary: String, id: String, jpeg: Data) -> Data {
        var d = Data()
        func add(_ s: String) { d.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"id\"\r\n\r\n\(id)\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(id).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
        d.append(jpeg)
        add("\r\n--\(boundary)--\r\n")
        return d
    }
}
