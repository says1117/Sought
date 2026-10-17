import Foundation

// Pure BLE protocol helpers (docs/03_CONTRACTS.md section 1). Foundation only, so they are unit testable.

enum DriveProtocol {
    static let maxSpeed = 255
    /// Phone must resend at least every 100 ms; the ESP32 watchdog trips at 300 ms.
    static let heartbeatInterval: TimeInterval = 0.1

    static func clamp(_ v: Int) -> Int { max(-maxSpeed, min(maxSpeed, v)) }

    /// `L,R\n` with both values clamped to -255...255.
    static func driveCommand(left: Int, right: Int) -> String {
        "\(clamp(left)),\(clamp(right))\n"
    }

    static let stopCommand = "STOP\n"
    static let pingCommand = "PING\n"

    /// Contract convention: angular > 0 turns left. L = linear - angular, R = linear + angular.
    static func mix(linear: Double, angular: Double) -> (left: Int, right: Int) {
        (clamp(Int((linear - angular).rounded())), clamp(Int((linear + angular).rounded())))
    }
}

struct RobotFlags: OptionSet, Equatable {
    let rawValue: Int
    static let watchdogStopped = RobotFlags(rawValue: 1)
    static let frontBlocked    = RobotFlags(rawValue: 2)
    static let rearBlocked     = RobotFlags(rawValue: 4)
    static let bleConnected    = RobotFlags(rawValue: 8)
}

/// `T,<uptime_ms>,<L>,<R>,<front_cm>,<rear_cm>,<flags>`
struct RobotStatus: Equatable {
    static let noEcho = 999

    var uptimeMs: Int
    var left: Int
    var right: Int
    var frontCm: Int
    var rearCm: Int
    var flags: RobotFlags

    /// Returns nil for anything that is not a well-formed status line (PONG, partial, garbage).
    static func parse(_ line: String) -> RobotStatus? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 7, parts[0] == "T" else { return nil }
        let nums = parts.dropFirst().map { Int($0) }
        guard !nums.contains(where: { $0 == nil }) else { return nil }
        let n = nums.compactMap { $0 }
        guard n[0] >= 0, n[4] >= 0, n[3] >= 0, n[5] >= 0 else { return nil }
        return RobotStatus(uptimeMs: n[0], left: n[1], right: n[2], frontCm: n[3], rearCm: n[4], flags: RobotFlags(rawValue: n[5]))
    }

    var frontDistanceCm: Int? { frontCm == Self.noEcho ? nil : frontCm }
    var rearDistanceCm: Int? { rearCm == Self.noEcho ? nil : rearCm }
}

/// TX notifications can split a line across packets. Feed chunks, get complete lines back.
struct LineBuffer {
    private var pending = ""
    mutating func append(_ chunk: String) -> [String] {
        pending += chunk
        var lines: [String] = []
        while let i = pending.firstIndex(of: "\n") {
            lines.append(String(pending[..<i]))
            pending.removeSubrange(...i)
        }
        return lines
    }
}
