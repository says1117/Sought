import Foundation

/// A source of candidate boxes for one image. `Frame` is whatever the adapter needs (CVPixelBuffer, CGImage...).
/// Sources must not throw into the pipeline; return [] on failure.
public protocol ProposalSource {
    associatedtype Frame
    func proposals(in frame: Frame) -> [Proposal]
}

public enum ProposalMath {
    public static let maxCrops = 24
    public static let nmsIoU: Float = 0.5

    /// Overlapping grid of `rows` x `cols` tiles. `overlap` is the fraction of a tile shared with its neighbour.
    public static func gridBoxes(rows: Int, cols: Int, overlap: Float = 0.25) -> [NormBox] {
        guard rows > 0, cols > 0 else { return [] }
        func axis(_ n: Int) -> (size: Float, stride: Float) {
            guard n > 1 else { return (1, 0) }
            let size = 1 / (Float(n) - Float(n - 1) * overlap)
            return (size, size * (1 - overlap))
        }
        let (tw, sx) = axis(cols), (th, sy) = axis(rows)
        var out: [NormBox] = []
        for r in 0..<rows { for c in 0..<cols {
            out.append(NormBox(x: min(Float(c) * sx, 1 - tw), y: min(Float(r) * sy, 1 - th), w: tw, h: th))
        } }
        return out
    }

    /// The 2x3 and 3x4 backstop grids at 25% overlap, as low-score proposals.
    public static func gridBackstop(score: Float = 0.05) -> [Proposal] {
        (gridBoxes(rows: 2, cols: 3) + gridBoxes(rows: 3, cols: 4))
            .map { Proposal(box: $0, score: score, origin: .grid) }
    }

    /// Greedy non-maximum suppression by score; stable for equal scores. Empty boxes are dropped.
    public static func nms(_ props: [Proposal], iou threshold: Float = nmsIoU) -> [Proposal] {
        let sorted = props.enumerated().filter { $0.element.box.area > 0 }
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
        var kept: [Proposal] = []
        for p in sorted where !kept.contains(where: { $0.box.iou(p.box) > threshold }) { kept.append(p) }
        return kept
    }

    /// Union of sources -> clamp -> NMS -> cap.
    public static func merge(_ lists: [[Proposal]], limit: Int = maxCrops, iou: Float = nmsIoU) -> [Proposal] {
        let clamped = lists.flatMap { $0 }.map { Proposal(box: $0.box.clamped(), score: $0.score, origin: $0.origin) }
        return Array(nms(clamped, iou: iou).prefix(limit))
    }
}

/// YOLO source stub. No model file is committed (see Sources/Perception/README.md).
/// Inject `detector` (a Core ML YOLO wrapper exported with `nms=True`, any class, confidence > 0.15)
/// to turn it on; with no detector it contributes nothing and the pipeline relies on saliency + grid.
public struct YOLOProposalSource<Frame>: ProposalSource {
    public static var minConfidence: Float { 0.15 }
    public var detector: ((Frame) -> [Proposal])?
    public init(detector: ((Frame) -> [Proposal])? = nil) { self.detector = detector }
    public func proposals(in frame: Frame) -> [Proposal] {
        (detector?(frame) ?? []).filter { $0.score > Self.minConfidence }
            .map { Proposal(box: $0.box, score: $0.score, origin: .yolo) }
    }
}
