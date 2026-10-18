import Foundation
#if canImport(Memory)
import Memory
#endif
#if canImport(PerceptionCore)
import PerceptionCore
#endif

/// Feeds perception output into the track store with the Memory association rules (plan 4.5).
/// Pure logic plus the store; the camera side lives in the app's PerceptionLoop.
///
/// FRAME VALIDITY (PR 39 review): the persistent store holds x/z positions in the frame of the saved ARKit world
/// map. Writes are therefore only allowed while the session has relocalized against that map (`frame.relocalized`).
/// A fresh map (first run, Teach reset, unrecognised map) writes nothing, so old and new coordinates are never mixed
/// and nothing associates across frames. The caller reads `generation` when it grabs the camera frame and passes it
/// back to `ingest`; if the frame changed meanwhile (new session, tracking lost) the result is dropped.
final class MemoryIngestor {
    struct Summary: Equatable {
        var matched = 0, created = 0
        /// True when nothing was written because the frame is not valid for the persistent store.
        var rejected = false
    }

    private let store: TrackStore
    private let now: () -> Date
    private let newId: () -> String
    private let frame: CoordinatorFrameValidity

    /// `frame` defaults to trusting every frame (tests). The app passes its `WorldFrameGate`.
    init(store: TrackStore, frame: CoordinatorFrameValidity = TrustedFrame(), now: @escaping () -> Date = Date.init,
         newId: @escaping () -> String = TrackStore.newId) {
        self.store = store; self.frame = frame; self.now = now; self.newId = newId
    }

    /// True when observations may be written right now.
    var canIngest: Bool { frame.relocalized }
    /// Read when capturing a camera frame; pass to `ingest(_:generation:)`.
    var generation: Int { frame.generation }

    /// Each object is associated against the tracks as updated by the previous object in the same frame.
    @discardableResult
    func ingest(_ objects: [PerceivedObject], generation: Int? = nil) throws -> Summary {
        guard frame.relocalized, generation == nil || generation == frame.generation else {
            return Summary(rejected: true)
        }
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
