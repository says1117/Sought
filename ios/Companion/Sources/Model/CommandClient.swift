import Foundation

// Remote commands, docs/03_CONTRACTS.md section 2.9:
//   POST /api/commands        {"text": "find the bottle"}  -> {id, text, created_at, status, result}
//   GET  /api/commands/{id}   same shape; status queued | running | done | failed
// The robot runs `text` through its own planner, so the app sends plain phrases ("find red umbrella", "go to kitchen").
// Same bearer token as the read routes. The transport and poll timing are injectable for the unit tests.

struct RobotCommand: Decodable, Equatable {
    enum Status: String, Decodable { case queued, running, done, failed }
    var id: String
    var text: String
    var created_at: String?
    var status: Status
    var result: String?
}

enum CommandError: Error, Equatable {
    case unauthorized, busy, notAvailable, http(Int), network, timeout
    case failed(String?)

    /// Plain words for the Find flow and the Come-to-me sheet.
    var message: String {
        switch self {
        case .unauthorized: return "The server refused the token. Check it in Settings."
        case .busy: return "Soughtbot is busy with something else. Try again when it\u{2019}s done."
        case .notAvailable: return "This server can\u{2019}t send Soughtbot commands yet."
        case .http(let c): return "The server answered with an error (\(c))."
        case .network: return "Can\u{2019}t reach Soughtbot\u{2019}s server. Check the Wi-Fi and try again."
        case .timeout: return "Soughtbot didn\u{2019}t finish in time. It may still be working; watch the status line."
        case .failed(let r):
            let t = r?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? "Soughtbot couldn\u{2019}t do that." : t
        }
    }
}

@MainActor
struct CommandClient {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    var config: BackendConfig
    var transport: Transport = { try await URLSession.shared.data(for: $0) }
    var pollInterval: TimeInterval = 1
    var timeout: TimeInterval = 90

    func send(_ text: String) async throws -> RobotCommand {
        var req = request("api/commands")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        return try await call(req)
    }

    func get(_ id: String) async throws -> RobotCommand { try await call(request("api/commands/\(id)")) }

    /// Sends `text`, then polls every `pollInterval` until done or failed. `onUpdate` sees each new status.
    /// Returns the done command; throws `CommandError.failed(result)` when the robot reports failure.
    func run(_ text: String, onUpdate: (RobotCommand) -> Void = { _ in }) async throws -> RobotCommand {
        var cmd = try await send(text)
        onUpdate(cmd)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch cmd.status {
            case .done: return cmd
            case .failed:
                if cmd.result?.lowercased().contains("busy") == true { throw CommandError.busy }
                throw CommandError.failed(cmd.result)
            case .queued, .running: break
            }
            guard Date() < deadline else { throw CommandError.timeout }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            do {
                let next = try await get(cmd.id)
                if next != cmd { onUpdate(next) }
                cmd = next
            } catch CommandError.network {
                continue   // one dropped poll on hotel Wi-Fi is not a failure; the deadline still applies
            }
        }
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appending(path: path))
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        return req
    }

    private func call(_ req: URLRequest) async throws -> RobotCommand {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await transport(req) } catch is CancellationError { throw CancellationError() } catch {
            throw CommandError.network
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: break
        case 401, 403: throw CommandError.unauthorized
        case 404, 405: throw CommandError.notAvailable
        case 409, 423, 429: throw CommandError.busy
        default: throw CommandError.http(code)
        }
        do { return try JSONDecoder().decode(RobotCommand.self, from: data) } catch { throw CommandError.http(code) }
    }
}
