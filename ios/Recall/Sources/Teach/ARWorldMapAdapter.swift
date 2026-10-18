import ARKit

/// Thin ARKit adapter: archives and restores `ARWorldMap` through `WorldMapStore`. Decision logic
/// (when to save, when relocalization succeeded) lives in WorldMapSavePolicy and RelocalizationMonitor.
/// Not compiled in `swift test`; needs a real device to exercise.
final class ARWorldMapAdapter: TeachMapSaving {
    private let store: WorldMapStore
    private let tracker: PoseTracker
    /// Frame generation, read before asking ARKit for the map (see `onSaved`).
    var currentGeneration: (() -> Int)?
    /// Called on the main queue after a successful save with the new map id and the generation read before the save.
    var onSaved: ((_ mapId: String, _ generation: Int?) -> Void)?

    init(store: WorldMapStore = WorldMapStore(url: WorldMapStore.defaultURL()), tracker: PoseTracker) {
        self.store = store
        self.tracker = tracker
    }

    var hasSavedMap: Bool { store.hasSavedMap }

    /// Load on launch and pass to `PoseTracker.start(initialWorldMap:)`. A corrupt archive is discarded.
    var initialWorldMap: ARWorldMap? {
        guard let data = try? store.loadData() else { return nil }
        if let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) { return map }
        store.discard()
        return nil
    }

    func saveCurrentMap(completion: @escaping (Result<Void, Error>) -> Void) {
        guard WorldMapSavePolicy.canSave(tracking: tracker.tracking, mapping: tracker.mapping) else {
            completion(.failure(TeachError.notReadyToSave)); return
        }
        let generation = currentGeneration?()
        let onSaved = onSaved   // still adopt if Teach closes while ARKit builds the map
        tracker.currentWorldMap { [store] map in
            DispatchQueue.main.async {
                guard let map else { completion(.failure(TeachError.noWorldMap)); return }
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    let id = try store.save(data)
                    onSaved?(id, generation)
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
        }
    }
}

enum TeachError: LocalizedError {
    case notReadyToSave, noWorldMap
    var errorDescription: String? {
        switch self {
        case .notReadyToSave: return "Keep scanning until tracking is normal and the area is mapped"
        case .noWorldMap: return "ARKit has no world map yet"
        }
    }
}
