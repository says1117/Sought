import Foundation

/// Heartbeat `state` values this layer publishes (docs/03_CONTRACTS.md section 2.1; `exploring` and
/// `coming_to_user` are added to the contract by T-029).
enum CoordinatorState: String, Equatable {
    case idle, exploring, finding
    case comingToUser = "coming_to_user"
    case blocked, error

    var heartbeatValue: String { rawValue }
}

/// What the heartbeat publisher reads: contract state plus the human-readable task string.
struct CoordinatorStatus: Equatable {
    var state: CoordinatorState
    /// e.g. "find: blue backpack". nil when idle.
    var task: String?
    static let idle = CoordinatorStatus(state: .idle, task: nil)
}

enum CoordinatorTaskKind: String, Equatable {
    case explore, find, goToWaypoint = "go_to_waypoint", comeToMe = "come_to_me"
}

/// One recorded decision. `t` is clock time at the decision.
/// How one tool call ended, for a caller that reports results (remote commands). `done` only on a real
/// success; `busy` when remote admission refused it (task running or stopping, manual tool open);
/// every refusal, block, cancellation or missing result is `failed` with "event: detail".
enum CoordinatorCallOutcome: Equatable {
    case done(String)
    case busy(String)
    case failed(String)
}

struct CoordinatorTraceEntry: Equatable {
    var t: TimeInterval
    var event: String
    var detail: String
}

struct CoordinatorConfig {
    /// Tracking must be non-normal for longer than this to cancel motion.
    var trackingLossLimitS: TimeInterval = 1.0
    var trackingPollS: TimeInterval = 0.1
    /// A cancelled runner that has not returned after this long is force-released (the STOP was already sent).
    var drainTimeoutS: TimeInterval = 3.0
    var features = RecallFeatureFlags()
    /// Come to me v2 stop distances (placeholders until measured on the floor).
    var comeToMe = ComeToMeSettings()
    static let rescanReason = "need a rescan"
    static let notRecognisedSpoken = "I have not recognised this room yet, please rescan."
}
