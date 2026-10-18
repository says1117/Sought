import Foundation
#if canImport(FindExecutor)
import FindExecutor
#endif

/// Where the screen gets the last find from. The real find runner should call `FindTraceRecorder.shared.record`
/// with `FindResult.trace` after each find; until it does, the screen says tracing is not connected.
protocol FindTraceSource: AnyObject {
    func lastTrace() -> FindTrace?
    /// False while nothing has ever recorded into this source, so "no trace" is not mistaken for "no find yet".
    var isConnected: Bool { get }
}

final class FindTraceRecorder: FindTraceSource {
    static let shared = FindTraceRecorder()
    private let lock = NSLock()
    private var trace: FindTrace?
    private var connected = false
    func record(_ t: FindTrace) { lock.lock(); trace = t; connected = true; lock.unlock() }
    func lastTrace() -> FindTrace? { lock.lock(); defer { lock.unlock() }; return trace }
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }
}

/// Plain strings for the "Last find" part of the screen. Read-only; built from a FindTrace.
struct FindTraceDisplay: Equatable {
    struct Attempt: Equatable {
        var verdictTitle: String
        var isAccept: Bool
        var scoresText: String
        var reason: String
    }
    struct Candidate: Equatable {
        var rank: Int
        var trackID: String
        var scoreText: String
        var positionText: String
        /// nil: the executor never went to this candidate.
        var attempt: Attempt?
    }

    var emptyMessage: String?
    var query = ""
    var outcomeTitle = ""
    var candidates: [Candidate] = []
    var noCandidatesMessage: String?
    var spoken = ""
    var timeText = ""
    var nearMissesText = ""
    var notes = ""

    static let notConnected = "Find tracing is not connected in this build yet, so no trace is saved. The find runner has to record it."
    static let noFindYet = "No find has run since the app opened."

    static func make(from trace: FindTrace?, connected: Bool = true) -> FindTraceDisplay {
        guard let t = trace else {
            return FindTraceDisplay(emptyMessage: connected ? noFindYet : notConnected)
        }
        var attempts = Dictionary(t.attempts.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [Candidate] = []
        for (i, r) in t.ranked.enumerated() {
            let a = attempts.removeValue(forKey: r.trackID).map(attempt)
            rows.append(Candidate(rank: i + 1, trackID: r.trackID, scoreText: score(r.score),
                                  positionText: position(r.x, r.z), attempt: a))
        }
        // An attempt whose track is not in the ranked list should not happen; show it rather than hide it.
        for a in t.attempts where attempts[a.trackID] != nil {
            rows.append(Candidate(rank: rows.count + 1, trackID: a.trackID, scoreText: score(a.retrievalScore),
                                  positionText: "position unknown", attempt: attempt(a)))
        }
        return FindTraceDisplay(
            emptyMessage: nil,
            query: t.text,
            outcomeTitle: outcomeTitle(t.outcome),
            candidates: rows,
            noCandidatesMessage: rows.isEmpty ? "Nothing in memory matched this query." : nil,
            spoken: t.spoken,
            timeText: String(format: "%.1f s", t.timeS),
            nearMissesText: t.nearMisses == 0 ? "no near misses" : "\(t.nearMisses) near miss\(t.nearMisses == 1 ? "" : "es")",
            notes: t.notes)
    }

    static func outcomeTitle(_ raw: String) -> String {
        switch raw {
        case "success": return "Found it"
        case "not_found": return "Not found"
        case "aborted": return "Stopped"
        default: return raw
        }
    }

    private static func attempt(_ a: AttemptEntry) -> Attempt {
        let title: String
        switch a.verdict {
        case "accepted": title = "Accepted"
        case "not_here": title = "Rejected: not here"
        case "unreachable": title = "Could not reach"
        case "no_view": title = "Rejected: no view"
        default: title = a.verdict
        }
        return Attempt(verdictTitle: title, isAccept: a.verdict == "accepted",
                       scoresText: "s_img \(optional(a.sImg)), s_text \(optional(a.sText))", reason: a.reason)
    }

    private static func score(_ v: Float) -> String { String(format: "%.2f", v) }
    private static func optional(_ v: Float?) -> String { v.map(score) ?? "n/a" }
    private static func position(_ x: Float, _ z: Float) -> String { String(format: "x %.1f, z %.1f", x, z) }
}
