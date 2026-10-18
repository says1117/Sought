import Foundation
#if canImport(Memory)
import Memory
#endif

/// Plain strings for the "Memory" part of the screen. Read-only; built from the stored tracks.
/// The tracks table has a label/description column but `Track` does not carry it, and thumbnails live in media
/// files that Track does not reference, so rows show the id and no thumbnail.
struct MemoryInspectorDisplay: Equatable {
    struct Row: Equatable {
        var id: String
        var positionText: String
        var sightingsText: String
        var persistenceText: String
        var lastSeenText: String
        var hasThumbnail: Bool
    }

    var countText = ""
    var rows: [Row] = []
    /// Shown above the list (models not installed, perception state).
    var notices: [String] = []
    var emptyMessage: String?
    var errorMessage: String?

    static let modelsMissingNotice = "Models not installed: memory is not filling, and Find cannot run."

    /// `now` and `Track.lastSeen` are Unix seconds. `modelsInstalled` false adds the notice.
    static func make(tracks: Result<[Track], Error>, now: Double, modelsInstalled: Bool,
                     perceptionNote: String? = nil) -> MemoryInspectorDisplay {
        var notices: [String] = []
        if !modelsInstalled { notices.append(modelsMissingNotice) }
        if let n = perceptionNote, !n.isEmpty { notices.append(n) }
        switch tracks {
        case .failure(let e):
            return MemoryInspectorDisplay(countText: "Memory unavailable", notices: notices,
                                          errorMessage: "Could not read stored objects: \(e.localizedDescription)")
        case .success(let list):
            let sorted = list.sorted { a, b in a.lastSeen != b.lastSeen ? a.lastSeen > b.lastSeen : a.id < b.id }
            let rows = sorted.map { t in
                Row(id: t.id, positionText: String(format: "x %.1f, z %.1f", t.position.x, t.position.z),
                    sightingsText: "\(t.sightings) sighting\(t.sightings == 1 ? "" : "s")",
                    persistenceText: String(format: "persistence %.2f", t.persistence),
                    lastSeenText: lastSeen(t.lastSeen, now: now), hasThumbnail: false)
            }
            return MemoryInspectorDisplay(
                countText: "\(rows.count) object\(rows.count == 1 ? "" : "s") in memory", rows: rows, notices: notices,
                emptyMessage: rows.isEmpty ? "Nothing remembered yet. Objects are added while the robot is parked and looking at them." : nil)
        }
    }

    static func lastSeen(_ t: Double, now: Double) -> String {
        guard t > 0 else { return "last seen: unknown" }
        let s = max(0, now - t)
        switch s {
        case ..<10: return "last seen just now"
        case ..<60: return "last seen \(Int(s)) s ago"
        case ..<3600: return "last seen \(Int(s / 60)) min ago"
        case ..<86400: return "last seen \(Int(s / 3600)) h ago"
        default: return "last seen \(Int(s / 86400)) d ago"
        }
    }
}
