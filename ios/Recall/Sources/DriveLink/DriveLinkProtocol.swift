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

struct DriveLinkSession {
    private(set) var isReady = false
    private(set) var left = 0
    private(set) var right = 0

    mutating func connect() {
        reset()
        isReady = true
    }

    mutating func drive(left: Int, right: Int) {
        guard isReady else { return }
        self.left = DriveProtocol.clamp(left)
        self.right = DriveProtocol.clamp(right)
    }

    mutating func stop() { left = 0; right = 0 }

    mutating func reset() {
        isReady = false
        stop()
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

/// Fail-closed check for speech input: telemetry must be connected, recent, and show both wheels stopped.
enum StationaryStatus {
    private static let telemetryInterval: TimeInterval = 1.0 / 5.0 // BLE contract status rate
    static let freshnessWindow = telemetryInterval * 2 // allow one delayed sample, then fail closed

    static func isStationary(status: RobotStatus?, connected: Bool,
                             receivedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard connected, let status, let receivedAt, receivedAt <= now,
              now - receivedAt <= freshnessWindow else { return false }
        return status.left == 0 && status.right == 0
    }
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

/// Only attach to our rover: it must advertise the Nordic UART service AND be named `Navigator`
/// (docs/03_CONTRACTS.md section 1), so another team's UART peripheral is never adopted.
enum PeripheralMatch {
    static let name = "Navigator"
    static let serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"

    /// `advertisedName` is the advertisement local name, `cachedName` is CBPeripheral.name; either may match.
    static func isNavigator(advertisedName: String?, cachedName: String?, advertisedServiceUUIDs: [String]) -> Bool {
        let nameOK = advertisedName == name || cachedName == name
        let serviceOK = advertisedServiceUUIDs.contains { $0.uppercased() == serviceUUID }
        return nameOK && serviceOK
    }
}

/// Which pad button is held. Decision logic for the hold-to-drive pad, kept pure so it is testable.
public enum DriveIntent: Equatable {
    case forward, back, left, right
}

public enum DriveAction: Equatable {
    case stop
    case drive(left: Int, right: Int)
}

public enum DrivePad {
    /// No held button (never pressed, released, or gesture cancelled) or zero speed means STOP.
    public static func action(held: DriveIntent?, speed: Int, isEnabled: Bool = true) -> DriveAction {
        let s = abs(DriveProtocol.clamp(speed))
        guard isEnabled, let held, s > 0 else { return .stop }
        switch held {
        case .forward: return .drive(left: s, right: s)
        case .back:    return .drive(left: -s, right: -s)
        case .left:    return .drive(left: -s, right: s)
        case .right:   return .drive(left: s, right: -s)
        }
    }
}
