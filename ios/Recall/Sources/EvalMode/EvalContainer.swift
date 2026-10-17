import SwiftUI

/// Entry point for the Fallback tools menu. With no arguments it shows the ground-truth and query tools;
/// retrieval runs stay disabled until a track store and text encoder are passed in.
struct EvalContainer: View {
    @StateObject private var model: EvalViewModel

    init(tracks: (() throws -> [Track])? = nil, encoder: TextEncoder? = nil, currentPoint: (() -> EvalFloorPoint?)? = nil) {
        let commit = (Bundle.main.object(forInfoDictionaryKey: "RecallGitCommit") as? String) ?? "unknown"
        _model = StateObject(wrappedValue: EvalViewModel(directory: EvalViewModel.defaultDirectory(), tracks: tracks,
                                                         encoder: encoder, currentPoint: currentPoint, commit: commit))
    }

    var body: some View { EvalView(model: model) }
}
