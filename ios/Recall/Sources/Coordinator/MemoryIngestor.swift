import Foundation
#if canImport(Memory)
import Memory
#endif
#if canImport(PerceptionCore)
import PerceptionCore
#endif
#if canImport(PoseCore)
import PoseCore
#endif

/// Feeds perception output into the track store with the Memory association rules (plan 4.5).
/// Pure logic plus the store; the camera side lives in the app's PerceptionLoop.
///
/// FRAME VALIDITY (PR 39 review): the persistent store holds x/z positions in the frame of the saved ARKit world
/// map. Writes are therefore only allowed while the session has relocalized against that map (`frame.relocalized`).
/// A fresh map (first run, Teach reset, unrecognised map) writes nothing, so old and new coordinates are never mixed
/// and nothing associates across frames. The caller reads `generation` when it grabs the camera frame and passes it
/// back to `ingest`; if the frame changed meanwhile (new session, tracking lost) the result is dropped.
///
/// LIFT SANITY (live data 2026-10-18): keyframes taken while the camera pose was off lifted whole sets of objects
/// 4-5 m below a floor estimate that was right everywhere else. The loop only captures keyframes with normal
/// tracking (`admitsKeyframe`), and `write` drops objects whose height above the floor is impossible, or the whole
/// keyframe when most of its objects are under the floor (the pose, not the objects, is wrong).
final class MemoryIngestor {
    struct Summary: Equatable {
        var matched = 0, created = 0
        /// True when nothing was written because the frame is not valid for the persistent store.
        var rejected = false
        /// Objects not written because their lifted height was impossible (all of them when `badPose`).
        var implausible = 0
        /// True when the whole keyframe was dropped: most of its objects were below the floor.
        var badPose = false
    }

    /// Heights above the floor an object can really have. A few centimetres under the floor is depth noise; the
    /// same range as the uploader's `LocalStoreReader.plausibleHeight`.
    static let plausibleHeight: ClosedRange<Float> = -0.3...3.5

    /// Only a keyframe whose camera tracking is normal is lifted into the world: with limited tracking the pose
    /// (and so every lifted position) can be metres off.
    static func admitsKeyframe(tracking: TrackingKind) -> Bool { tracking == .normal }

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

    /// Test seam: runs after the frame check passed, before anything is written.
    var beforeWrite: (() -> Void)?

    /// Each object is associated against the tracks as updated by the previous object in the same frame.
    /// Validation and writes are ONE step: `WorldFrameGate` holds its lock across the whole ingest, so a reset, new
    /// session or tracking loss waits for it; and the writes run in one SQLite transaction that is rolled back if the
    /// frame or map id is no longer current just before COMMIT (covers gates that cannot hold a lock). Reads and
    /// writes use the map id the frame reported, so tracks of other maps are neither associated with nor touched.
    @discardableResult
    func ingest(_ objects: [PerceivedObject], generation: Int? = nil) throws -> Summary {
        let outcome: Summary?? = try frame.performIfCurrent(generation: generation) { mapId -> Summary? in
            let gen = generation ?? frame.generation
            beforeWrite?()
            return try store.transaction(commitIf: { frame.isCurrent(mapId: mapId, generation: gen) }) {
                try write(objects, mapId: mapId)
            }
        }
        return (outcome ?? nil) ?? Summary(rejected: true)
    }

    private func write(_ objects: [PerceivedObject], mapId: String) throws -> Summary {
        var summary = Summary()
        let belowFloor = objects.filter { $0.heightAboveFloor < Self.plausibleHeight.lowerBound }.count
        if belowFloor * 2 > objects.count {
            summary.implausible = objects.count; summary.badPose = true
            return summary
        }
        let plausible = objects.filter { Self.plausibleHeight.contains($0.heightAboveFloor) }
        summary.implausible = objects.count - plausible.count
        var tracks = try store.allTracks(mapId: mapId)
        for o in plausible {
            let assoc = associate(o.observation, tracks: tracks)
            switch assoc.result {
            case .matched(let id, let sim, let dist):
                guard let i = tracks.firstIndex(where: { $0.id == id }) else { continue }
                let (updated, plan) = applyMatch(track: tracks[i], observation: o.observation, cosine: sim, distance: dist)
                tracks[i] = updated
                try store.recordMatch(updated, plan: plan, height: o.heightAboveFloor, at: now(), mapId: mapId)
                summary.matched += 1
            case .newTrack:
                let t = newTrack(id: newId(), from: o.observation)
                tracks.append(t)
                try store.upsert(t, height: o.heightAboveFloor, at: now(), mapId: mapId)
                summary.created += 1
            }
        }
        return summary
    }
}
