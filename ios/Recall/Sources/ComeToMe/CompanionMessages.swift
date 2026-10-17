import Foundation

// Companion link messages, docs/03_CONTRACTS.md section 1.1 (robot iPhone <-> user iPhone, MultipeerConnectivity
// service type `recall-ni`). One JSON object per send. Pure Foundation, shared by the Recall and Companion targets.
//
// The contract table lists message names and fields but not how the name is carried; this file uses a `type`
// field holding the message name ({"type":"come_to_me","id":"cmd_1"}). If the contract later says otherwise, change
// `CodingKeys.type` here only.

enum CompanionRole: String, Codable, Equatable { case robot, companion }

enum CompanionState: String, Codable, Equatable { case accepted, approaching, arrived, failed }

enum CompanionMessage: Equatable {
    case hello(role: CompanionRole, version: Int)
    case niToken(tokenB64: String)
    case comeToMe(id: String)
    case status(id: String, state: CompanionState, distanceM: Double?, reason: String?)
    case cancel(id: String)

    static let protocolVersion = 1
    static let serviceType = "recall-ni"      // MultipeerConnectivity: 1-15 chars, lowercase letters, digits, hyphen
}

extension CompanionMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, role, version, id, state, reason
        case tokenB64 = "token_b64"
        case distanceM = "distance_m"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(role: try c.decode(CompanionRole.self, forKey: .role), version: try c.decode(Int.self, forKey: .version))
        case "ni_token":
            self = .niToken(tokenB64: try c.decode(String.self, forKey: .tokenB64))
        case "come_to_me":
            self = .comeToMe(id: try c.decode(String.self, forKey: .id))
        case "status":
            self = .status(id: try c.decode(String.self, forKey: .id), state: try c.decode(CompanionState.self, forKey: .state),
                           distanceM: try c.decodeIfPresent(Double.self, forKey: .distanceM),
                           reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "cancel":
            self = .cancel(id: try c.decode(String.self, forKey: .id))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown message type \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(role, version):
            try c.encode("hello", forKey: .type); try c.encode(role, forKey: .role); try c.encode(version, forKey: .version)
        case let .niToken(b64):
            try c.encode("ni_token", forKey: .type); try c.encode(b64, forKey: .tokenB64)
        case let .comeToMe(id):
            try c.encode("come_to_me", forKey: .type); try c.encode(id, forKey: .id)
        case let .status(id, state, distance, reason):
            try c.encode("status", forKey: .type); try c.encode(id, forKey: .id); try c.encode(state, forKey: .state)
            try c.encodeIfPresent(distance, forKey: .distanceM); try c.encodeIfPresent(reason, forKey: .reason)
        case let .cancel(id):
            try c.encode("cancel", forKey: .type); try c.encode(id, forKey: .id)
        }
    }
}

enum CompanionCodec {
    static func encode(_ m: CompanionMessage) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return try e.encode(m)
    }
    static func decode(_ d: Data) throws -> CompanionMessage { try JSONDecoder().decode(CompanionMessage.self, from: d) }

    /// Command ids use the `cmd_` prefix (contract).
    static func newCommandId() -> String { "cmd_" + UUID().uuidString.prefix(8).lowercased() }
}
