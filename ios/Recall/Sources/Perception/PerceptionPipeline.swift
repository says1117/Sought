import Foundation
import simd
#if canImport(Memory)
import Memory
#endif

/// Crops a frame and makes thumbnails. Adapter-backed (CoreImage); tests use a fake.
public protocol CropSource {
    associatedtype Crop
    func crop(_ box: NormBox) -> Crop?
    /// JPEG with the long edge at most `maxEdge` pixels.
    func thumbnailJPEG(_ crop: Crop, maxEdge: Int) -> Data?
}

/// Image encoder for crops (MobileCLIP-class Core ML model behind it). Returns unit-length vectors,
/// one per crop, in order. This is the per-crop sibling of FindExecutor's camera-level `ImageEmbedder`
/// (which re-looks at a stored point); the same Core ML model backs both adapters.
public protocol CropEmbedder {
    associatedtype Crop
    func embed(_ crops: [Crop]) throws -> [[Float]]
}

public struct PerceptionPipeline<Embedder: CropEmbedder> {
    public static var thumbnailEdge: Int { 320 }
    public var embedder: Embedder
    public var maxCrops: Int

    public init(embedder: Embedder, maxCrops: Int = ProposalMath.maxCrops) {
        self.embedder = embedder; self.maxCrops = maxCrops
    }

    /// Proposals -> NMS/cap -> depth lift (drops invalid/far) -> crop -> embed -> Observations.
    public func process<Frame: CropSource>(frame: Frame, depth: DepthMap, geometry: KeyframeGeometry,
                                           proposalLists: [[Proposal]]) throws -> [PerceivedObject]
        where Frame.Crop == Embedder.Crop {
        var items: [(Proposal, LiftedPoint, Embedder.Crop)] = []
        for p in ProposalMath.merge(proposalLists, limit: maxCrops) {
            guard let lifted = DepthLift.lift(box: p.box, depth: depth, geometry: geometry),
                  let crop = frame.crop(p.box) else { continue }
            items.append((p, lifted, crop))
        }
        guard !items.isEmpty else { return [] }
        let embeddings = try embedder.embed(items.map { $0.2 })
        guard embeddings.count == items.count else { return [] }
        return zip(items, embeddings).map { item, emb in
            let (p, lifted, crop) = item
            return PerceivedObject(
                observation: Observation(position: lifted.world, embedding: Self.unit(emb), confidence: p.score, time: geometry.time),
                heightAboveFloor: lifted.heightAboveFloor, box: p.box, origin: p.origin,
                thumbnailJPEG: frame.thumbnailJPEG(crop, maxEdge: Self.thumbnailEdge))
        }
    }

    static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}
