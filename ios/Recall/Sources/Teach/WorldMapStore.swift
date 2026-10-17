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

    /// Atomic write, so a crash mid-save never leaves a half-written map replacing a good one.
    public func save(_ data: Data) throws {
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// nil when there is no file or it is empty.
    public func loadData() throws -> Data? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let d = try Data(contentsOf: url)
        return d.isEmpty ? nil : d
    }

    public func discard() { try? fm.removeItem(at: url) }
}

/// When it is worth saving the map: tracking is good and ARKit says the space is mapped.
/// Saving a map that is still `limited` or `notAvailable` would make relocalization fail later.
public enum WorldMapSavePolicy {
    public static func canSave(tracking: TrackingKind, mapping: MappingKind) -> Bool {
        tracking == .normal && (mapping == .mapped || mapping == .extending)
    }
}
