import Foundation

/// Backend location and credentials. Values come from Secrets.xcconfig (gitignored) via Info.plist
/// keys BACKEND_BASE_URL and RECALL_TOKEN. Nothing here is a real secret, and the token is never logged.
public struct SyncConfig {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) { self.baseURL = baseURL; self.token = token }

    /// Returns nil when unconfigured (missing or still the example placeholders). The robot then
    /// runs fully offline and the queue simply accumulates.
    public init?(info: [String: Any]) {
        guard let url = (info["BACKEND_BASE_URL"] as? String).flatMap(Self.cleanURL),
              let token = info["RECALL_TOKEN"] as? String,
              !token.isEmpty, token != "change-me" else { return nil }
        self.init(baseURL: url, token: token)
    }
    public static func fromBundle(_ bundle: Bundle = .main) -> SyncConfig? {
        SyncConfig(info: bundle.infoDictionary ?? [:])
    }
    private static func cleanURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains("example.com"), let u = URL(string: t),
              let scheme = u.scheme, scheme == "https" || scheme == "http", u.host != nil else { return nil }
        return u
    }
}
