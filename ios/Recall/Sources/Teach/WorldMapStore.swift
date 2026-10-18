import Foundation
#if canImport(PoseCore)
import PoseCore
#endif

/// Persists the archived ARWorldMap bytes under Application Support. Pure file logic: the ARKit
/// archive/unarchive lives in `ARWorldMapAdapter` so this compiles and tests without ARKit.
public final class WorldMapStore {
    public let url: URL
    private let fm: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fm = fileManager
    }

    /// `Application Support/Recall/teach.worldmap`.
    public static func defaultURL(fileManager fm: FileManager = .default) -> URL {
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("Recall", isDirectory: true).appendingPathComponent("teach.worldmap")
    }

    /// True when a non-empty archive is on disk.
    public var hasSavedMap: Bool { (try? loadData())?.isEmpty == false }

    /// Sidecar holding the stable id of the archive. Stored tracks are tagged with it (phone-local, see TrackStore).
    public var idURL: URL { url.appendingPathExtension("id") }

    /// Atomic write, so a crash mid-save never leaves a half-written map replacing a good one. Every save is a new
    /// map: it gets a new id, written BEFORE the archive, so a crash in between leaves a new id with the old archive,
    /// which only hides stored tracks (fails closed) and never attaches them to the wrong map.
    /// Returns the new id.
    @discardableResult
    public func save(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString
        try Data(id.utf8).write(to: idURL, options: .atomic)
        try data.write(to: url, options: .atomic)
        return id
    }

    /// Id of the saved archive, nil when there is no map. An archive without an id (saved before ids existed) is
    /// given one now, so it is a map of its own; tracks recorded before ids existed never match it.
    public func currentMapId() -> String? {
        guard hasSavedMap else { return nil }
        if let d = try? Data(contentsOf: idURL), let id = String(data: d, encoding: .utf8), !id.isEmpty { return id }
        let id = UUID().uuidString
        do { try Data(id.utf8).write(to: idURL, options: .atomic) } catch { return nil }
        return id
    }

    /// nil when there is no file or it is empty.
    public func loadData() throws -> Data? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let d = try Data(contentsOf: url)
        return d.isEmpty ? nil : d
    }

    /// Sidecar holding "<map id>\n<ISO 8601 date>": waypoints created before that date predate the map (it was saved
    /// from a fresh scan, not from a session relocalized against the previous map), so they are not in its frame.
    public var cutoffURL: URL { url.appendingPathExtension("since") }

    /// Records the cutoff for `mapId`; nil removes it (every stored waypoint is in this map's frame).
    public func setWaypointCutoff(_ date: Date?, mapId: String) {
        guard let date else { try? fm.removeItem(at: cutoffURL); return }
        let text = mapId + "\n" + ISO8601DateFormatter().string(from: date)
        try? Data(text.utf8).write(to: cutoffURL, options: .atomic)
    }

    /// The cutoff stored for `mapId`, nil when none is stored or it belongs to another map.
    public func waypointCutoff(mapId: String) -> Date? {
        guard let d = try? Data(contentsOf: cutoffURL), let text = String(data: d, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == Substring(mapId) else { return nil }
        return ISO8601DateFormatter().date(from: String(parts[1]))
    }

    public func discard() {
        try? fm.removeItem(at: url); try? fm.removeItem(at: idURL); try? fm.removeItem(at: cutoffURL)
    }
}

/// When it is worth saving the map: tracking is good and ARKit says the space is mapped.
/// Saving a map that is still `limited` or `notAvailable` would make relocalization fail later.
public enum WorldMapSavePolicy {
    public static func canSave(tracking: TrackingKind, mapping: MappingKind) -> Bool {
        tracking == .normal && (mapping == .mapped || mapping == .extending)
    }
}
