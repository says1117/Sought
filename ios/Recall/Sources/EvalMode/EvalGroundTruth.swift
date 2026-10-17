import Foundation

/// One annotated object: floor position (x, z) in metres in the Teach world frame.
/// Shape matches `evals/ground_truth.json` objects (docs/03_CONTRACTS.md section 4).
public struct EvalGroundTruthObject: Codable, Equatable {
    public var id: String
    public var label: String
    public var x: Double
    public var z: Double
    public init(id: String, label: String, x: Double, z: Double) {
        self.id = id; self.label = label; self.x = x; self.z = z
    }
}

public struct EvalPoint: Codable, Equatable {
    public var x: Double
    public var z: Double
    public init(x: Double, z: Double) { self.x = x; self.z = z }
}

/// Scripted change record. The eval tool only preserves these; it never invents them.
public struct EvalGroundTruthChange: Codable, Equatable {
    public var id: String
    public var type: String
    public var objectID: String
    public var from: EvalPoint?
    public var to: EvalPoint?
    enum CodingKeys: String, CodingKey { case id, type, objectID = "object_id", from, to }
}

/// The whole `ground_truth.json` document.
public struct EvalGroundTruth: Codable, Equatable {
    public var objects: [EvalGroundTruthObject]
    public var changes: [EvalGroundTruthChange]

    public init(objects: [EvalGroundTruthObject] = [], changes: [EvalGroundTruthChange] = []) {
        self.objects = objects; self.changes = changes
    }

    public func object(id: String) -> EvalGroundTruthObject? { objects.first { $0.id == id } }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> EvalGroundTruth {
        try JSONDecoder().decode(EvalGroundTruth.self, from: data)
    }
}

/// A point on the floor in the Teach world frame, in metres.
public struct EvalFloorPoint: Equatable {
    public var x: Double
    public var z: Double
    public init(x: Double, z: Double) { self.x = x; self.z = z }
}

/// Thin seam for the AR raycast. The app adapter converts a tap (normalised 0...1 view coordinates)
/// to a world-frame floor point; no ARKit code lives in this module.
public protocol EvalFloorRaycasting {
    func floorPoint(atNormalizedX x: Double, y: Double) -> EvalFloorPoint?
}

public enum EvalAnnotationError: Error, Equatable {
    case emptyLabel
    case nonFinitePosition
    case noFloorHit
    case unknownObject(String)
}

/// View model for capturing ground truth: tap a floor point, name the object, repeat.
public final class EvalGroundTruthAnnotator: ObservableObject {
    @Published public private(set) var truth: EvalGroundTruth

    public init(truth: EvalGroundTruth = EvalGroundTruth()) { self.truth = truth }

    public var objects: [EvalGroundTruthObject] { truth.objects }

    /// Next unused `obj_NN` id (two digits minimum, never reuses an id of a removed object's neighbour).
    func nextID() -> String {
        let used = Set(truth.objects.map { $0.id })
        var n = 1
        while used.contains(String(format: "obj_%02d", n)) { n += 1 }
        return String(format: "obj_%02d", n)
    }

    @discardableResult
    public func addObject(label: String, at point: EvalFloorPoint) throws -> EvalGroundTruthObject {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EvalAnnotationError.emptyLabel }
        guard point.x.isFinite, point.z.isFinite else { throw EvalAnnotationError.nonFinitePosition }
        let object = EvalGroundTruthObject(id: nextID(), label: name, x: point.x, z: point.z)
        truth.objects.append(object)
        return object
    }

    /// Resolve a screen tap through the raycast seam, then add.
    @discardableResult
    public func addObject(label: String, tapX: Double, tapY: Double, raycaster: EvalFloorRaycasting) throws -> EvalGroundTruthObject {
        guard let p = raycaster.floorPoint(atNormalizedX: tapX, y: tapY) else { throw EvalAnnotationError.noFloorHit }
        return try addObject(label: label, at: p)
    }

    /// Re-place an object, for example after a tape-measure spot check.
    public func move(id: String, to point: EvalFloorPoint) throws {
        guard point.x.isFinite, point.z.isFinite else { throw EvalAnnotationError.nonFinitePosition }
        guard let i = truth.objects.firstIndex(where: { $0.id == id }) else { throw EvalAnnotationError.unknownObject(id) }
        truth.objects[i].x = point.x; truth.objects[i].z = point.z
    }

    public func remove(id: String) throws {
        guard let i = truth.objects.firstIndex(where: { $0.id == id }) else { throw EvalAnnotationError.unknownObject(id) }
        truth.objects.remove(at: i)
    }

    public func replace(with loaded: EvalGroundTruth) { truth = loaded }

    public func exportData() throws -> Data { try truth.jsonData() }
}
