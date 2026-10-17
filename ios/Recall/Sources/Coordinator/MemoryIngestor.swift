import Foundation
#if canImport(Memory)
import Memory
#endif
#if canImport(PerceptionCore)
import PerceptionCore
#endif

/// Feeds perception output into the track store with the Memory association rules (plan 4.5).
/// Pure logic plus the store; the camera side lives in the app's PerceptionLoop.
final class MemoryIngestor {
    struct Summary: Equatable { var matched = 0, created = 0 }

    private let store: TrackStore
    private let now: () -> Date
    private let newId: () -> String

    init(store: TrackStore, now: @escaping () -> Date = Date.init, newId: @escaping () -> String = TrackStore.newId) {
        self.store = store; self.now = now; self.newId = newId
    }

    /// Each object is associated against the tracks as updated by the previous object in the same frame.
    @discardableResult
    func ingest(_ objects: [PerceivedObject]) throws -> Summary {
        var tracks = try store.allTracks()
        var summary = Summary()
        for o in objects {
            let assoc = associate(o.observation, tracks: tracks)
            switch assoc.result {
            case .matched(let id, let sim, let dist):
                guard let i = tracks.firstIndex(where: { $0.id == id }) else { continue }
                let (updated, plan) = applyMatch(track: tracks[i], observation: o.observation, cosine: sim, distance: dist)
                tracks[i] = updated
                try store.recordMatch(updated, plan: plan, height: o.heightAboveFloor, at: now())
                summary.matched += 1
            case .newTrack:
                let t = newTrack(id: newId(), from: o.observation)
                tracks.append(t)
                try store.upsert(t, height: o.heightAboveFloor, at: now())
                summary.created += 1
            }
        }
        return summary
    }
}
