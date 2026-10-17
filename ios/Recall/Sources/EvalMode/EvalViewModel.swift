import Foundation
import Combine
#if canImport(Memory)
import Memory
#endif
#if canImport(Retrieval)
import Retrieval
#endif

/// Drives the Eval screen: ground truth capture, query set loading, an offline retrieval run, and export.
/// Nothing here fabricates data: with no track store or encoder wired, running is refused with a message.
public final class EvalViewModel: ObservableObject {
    public let annotator: EvalGroundTruthAnnotator
    @Published public private(set) var queries: [EvalQuery] = []
    @Published public private(set) var status = ""
    @Published public private(set) var lastRun: EvalRawRun?
    @Published public private(set) var exportURL: URL?
    @Published public var variant: String = EvalVariants.retrieval[1]
    @Published public var commit: String
    @Published public var phoneHeight: String

    /// Where ground_truth.json, queries and run files live on the phone (app Documents/Eval by default).
    public let directory: URL
    private let tracks: (() throws -> [Track])?
    private let encoder: TextEncoder?
    private let currentPoint: (() -> EvalFloorPoint?)?

    public init(directory: URL, tracks: (() throws -> [Track])? = nil, encoder: TextEncoder? = nil,
                currentPoint: (() -> EvalFloorPoint?)? = nil, commit: String = "unknown", phoneHeight: String = "") {
        self.directory = directory; self.tracks = tracks; self.encoder = encoder; self.currentPoint = currentPoint
        self.commit = commit; self.phoneHeight = phoneHeight
        annotator = EvalGroundTruthAnnotator()
    }

    public static func defaultDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Eval", isDirectory: true)
    }

    public var canRun: Bool { tracks != nil && encoder != nil && !queries.isEmpty && !annotator.objects.isEmpty }
    public var hasPoseSource: Bool { currentPoint != nil }
    public var groundTruthURL: URL { directory.appendingPathComponent("ground_truth.json") }
    public var queriesURL: URL { directory.appendingPathComponent("queries.yaml") }

    // MARK: Ground truth

    /// Adds an object at a given floor point (a raycast tap, or typed coordinates).
    public func addObject(label: String, at point: EvalFloorPoint) {
        do {
            let o = try annotator.addObject(label: label, at: point)
            status = String(format: "Added %@ (%@) at x %.2f, z %.2f", o.id, o.label, o.x, o.z)
        } catch { status = "Could not add object: \(error)" }
    }

    /// Adds an object where the phone is standing now (stand over the object, read the floor point).
    public func addObjectAtCurrentPose(label: String) {
        guard let p = currentPoint?() else { status = "No pose available (tracking not ready)."; return }
        addObject(label: label, at: p)
    }

    public func saveGroundTruth() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try annotator.exportData().write(to: groundTruthURL, options: .atomic)
            status = "Saved \(annotator.objects.count) objects."
        } catch { status = "Save failed: \(error)" }
    }

    public func loadGroundTruth() {
        do {
            annotator.replace(with: try EvalGroundTruth.decode(Data(contentsOf: groundTruthURL)))
            status = "Loaded \(annotator.objects.count) objects."
        } catch { status = "Load failed: \(error)" }
    }

    // MARK: Queries

    public func loadQueries() { loadQueries(from: queriesURL) }

    public func loadQueries(from url: URL) {
        do {
            queries = try EvalQueryLoader.load(url: url)
            status = "Loaded \(queries.count) queries."
        } catch { queries = []; status = "Query load failed: \(error)" }
    }

    // MARK: Run and export

    public func runRetrieval() {
        guard let tracks = tracks, let encoder = encoder else {
            status = "No track store or text encoder is wired into this build; nothing was run."
            return
        }
        guard !queries.isEmpty else { status = "Load the query set first."; return }
        do {
            let runner = EvalRetrievalRunner(retriever: Retriever(encoder: encoder))
            let run = try runner.run(queries: queries, tracks: try tracks(), truth: annotator.truth, variant: variant,
                                     commit: commit, phoneHeight: phoneHeight)
            lastRun = run
            exportURL = try run.write(toDirectory: directory.appendingPathComponent("results", isDirectory: true))
            let ok = run.trials.filter { $0.outcome == .success }.count
            status = "Ran \(run.trials.count) queries: \(ok) top-1 correct. Saved \(exportURL!.lastPathComponent)."
        } catch { status = "Run failed: \(error)" }
    }

    /// Outcome tallies for display, as counts (no percentages).
    public var outcomeCounts: [(EvalOutcome, Int)] {
        guard let run = lastRun else { return [] }
        return [EvalOutcome.success, .wrongObject, .notFound, .aborted].map { o in (o, run.trials.filter { $0.outcome == o }.count) }
    }
}
