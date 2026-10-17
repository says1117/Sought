import Foundation
import simd

/// Cell state exported to the map snapshot. Raw values are the contract encoding (docs/03_CONTRACTS.md 2.7).
public enum CellState: UInt8 {
    case free = 0
    case unknown = 1
    case occupiedLow = 2
    case occupiedHigh = 3
}

/// Pinhole intrinsics in depth-image pixels (u right, v down).
public struct DepthIntrinsics: Equatable {
    public var fx: Float, fy: Float, cx: Float, cy: Float
    public init(fx: Float, fy: Float, cx: Float, cy: Float) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
    }

    /// Scale intrinsics captured at `from` resolution to the depth buffer resolution.
    public func scaled(fromWidth: Int, fromHeight: Int, toWidth: Int, toHeight: Int) -> DepthIntrinsics {
        let sx = Float(toWidth) / Float(fromWidth), sy = Float(toHeight) / Float(fromHeight)
        return DepthIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy)
    }
}

/// One depth frame. `depth` is row-major meters along the optical axis (ARKit sceneDepth, ~256x192).
/// `cameraToWorld` is the ARKit camera transform (camera looks down -z, y up); world is y-up meters.
public struct DepthFrame {
    public var depth: [Float]
    public var width: Int
    public var height: Int
    public var intrinsics: DepthIntrinsics
    public var cameraToWorld: simd_float4x4
    public var floorY: Float
    public init(depth: [Float], width: Int, height: Int, intrinsics: DepthIntrinsics,
                cameraToWorld: simd_float4x4, floorY: Float) {
        self.depth = depth; self.width = width; self.height = height
        self.intrinsics = intrinsics; self.cameraToWorld = cameraToWorld; self.floorY = floorY
    }
}

/// JSON shape of the contract map snapshot.
public struct MapSnapshot: Codable, Equatable {
    public struct Origin: Codable, Equatable {
        public var x: Double, z: Double
        public init(x: Double, z: Double) { self.x = x; self.z = z }
    }
    public var resolutionM: Double
    public var origin: Origin
    public var width: Int
    public var height: Int
    public var cellsB64: String
    public var updatedAt: String?

    public init(resolutionM: Double, origin: Origin, width: Int, height: Int, cellsB64: String, updatedAt: String? = nil) {
        self.resolutionM = resolutionM; self.origin = origin; self.width = width
        self.height = height; self.cellsB64 = cellsB64; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case resolutionM = "resolution_m", origin, width, height
        case cellsB64 = "cells_b64", updatedAt = "updated_at"
    }
}

public struct OccupancyGridConfig {
    public var resolution: Float = 0.05
    /// World x/z of the corner of cell (col 0, row 0).
    public var originX: Float = -4.0
    public var originZ: Float = -6.0
    public var width: Int = 160      // cells along +x
    public var height: Int = 240     // cells along +z
    /// Heights above floor_y (m). Floor hits: |h| < lowMin. Low: lowMin..<highMin. High: highMin...highMax.
    public var lowMin: Float = 0.03
    public var highMin: Float = 0.40
    public var highMax: Float = 1.8
    /// Depth validity range (m); out-of-range returns are ignored.
    public var minDepth: Float = 0.2
    public var maxDepth: Float = 4.0
    /// Hits needed (accumulated over frames) before a cell changes state.
    public var occupiedHitThreshold: UInt16 = 3
    public var freeHitThreshold: UInt16 = 2
    /// Use every Nth depth pixel in each axis.
    public var pixelStride: Int = 2
    public init() {}
}

/// 5 cm occupancy grid around floor_y built from LiDAR depth. Pure logic: no ARKit types.
public struct OccupancyGrid {
    public let config: OccupancyGridConfig
    private var floorHits: [UInt16]
    private var lowHits: [UInt16]
    private var highHits: [UInt16]

    public init(config: OccupancyGridConfig = OccupancyGridConfig()) {
        self.config = config
        let n = config.width * config.height
        floorHits = [UInt16](repeating: 0, count: n)
        lowHits = floorHits
        highHits = floorHits
    }

    public var width: Int { config.width }
    public var height: Int { config.height }

    // MARK: Indexing

    public func cellIndex(x: Float, z: Float) -> (col: Int, row: Int)? {
        let c = Int(((x - config.originX) / config.resolution).rounded(.down))
        let r = Int(((z - config.originZ) / config.resolution).rounded(.down))
        guard c >= 0, c < config.width, r >= 0, r < config.height else { return nil }
        return (c, r)
    }

    /// World x/z of the center of a cell.
    public func cellCenter(col: Int, row: Int) -> (x: Float, z: Float) {
        (config.originX + (Float(col) + 0.5) * config.resolution,
         config.originZ + (Float(row) + 0.5) * config.resolution)
    }

    // MARK: Integration

    /// Integrates one depth frame; returns the number of points that landed in the grid.
    @discardableResult
    public mutating func integrate(_ frame: DepthFrame) -> Int {
        guard frame.width > 0, frame.height > 0, frame.depth.count >= frame.width * frame.height else { return 0 }
        let K = frame.intrinsics
        guard K.fx > 0, K.fy > 0 else { return 0 }
        let step = max(1, config.pixelStride)
        let T = frame.cameraToWorld
        var used = 0
        // Per-frame hits are capped at one per cell per band so a single dense frame
        // cannot satisfy the multi-frame threshold alone.
        var seenFloor = Set<Int>(), seenLow = Set<Int>(), seenHigh = Set<Int>()

        var v = 0
        while v < frame.height {
            var u = 0
            while u < frame.width {
                defer { u += step }
                let d = frame.depth[v * frame.width + u]
                guard d.isFinite, d >= config.minDepth, d <= config.maxDepth else { continue }
                let p = T * SIMD4<Float>((Float(u) - K.cx) / K.fx * d, -(Float(v) - K.cy) / K.fy * d, -d, 1)
                guard let cell = cellIndex(x: p.x, z: p.z) else { continue }
                let h = p.y - frame.floorY
                let idx = cell.row * config.width + cell.col
                if abs(h) < config.lowMin {
                    if seenFloor.insert(idx).inserted { floorHits[idx] = floorHits[idx] &+ (floorHits[idx] == .max ? 0 : 1) }
                } else if h >= config.lowMin && h < config.highMin {
                    if seenLow.insert(idx).inserted { lowHits[idx] = lowHits[idx] &+ (lowHits[idx] == .max ? 0 : 1) }
                } else if h >= config.highMin && h <= config.highMax {
                    if seenHigh.insert(idx).inserted { highHits[idx] = highHits[idx] &+ (highHits[idx] == .max ? 0 : 1) }
                } else { continue }   // below floor or overhead: ignored
                used += 1
            }
            v += step
        }
        return used
    }

    // MARK: Query / export

    public func state(col: Int, row: Int) -> CellState {
        guard col >= 0, col < config.width, row >= 0, row < config.height else { return .unknown }
        let i = row * config.width + col
        if highHits[i] >= config.occupiedHitThreshold { return .occupiedHigh }
        if lowHits[i] >= config.occupiedHitThreshold { return .occupiedLow }
        if floorHits[i] >= config.freeHitThreshold { return .free }
        return .unknown
    }

    public func state(x: Float, z: Float) -> CellState {
        guard let c = cellIndex(x: x, z: z) else { return .unknown }
        return state(col: c.col, row: c.row)
    }

    public func cellBytes() -> [UInt8] {
        var out = [UInt8](repeating: CellState.unknown.rawValue, count: config.width * config.height)
        for r in 0..<config.height {
            for c in 0..<config.width { out[r * config.width + c] = state(col: c, row: r).rawValue }
        }
        return out
    }

    public func snapshot(updatedAt: String? = nil) -> MapSnapshot {
        MapSnapshot(resolutionM: Double(config.resolution),
                    origin: .init(x: Double(config.originX), z: Double(config.originZ)),
                    width: config.width, height: config.height,
                    cellsB64: Data(cellBytes()).base64EncodedString(), updatedAt: updatedAt)
    }

    /// Rebuilds a grid from a snapshot. States are restored as exactly-at-threshold hit counts.
    public init?(snapshot s: MapSnapshot, config base: OccupancyGridConfig = OccupancyGridConfig()) {
        guard s.width > 0, s.height > 0, let data = Data(base64Encoded: s.cellsB64),
              data.count == s.width * s.height else { return nil }
        var cfg = base
        cfg.resolution = Float(s.resolutionM)
        cfg.originX = Float(s.origin.x); cfg.originZ = Float(s.origin.z)
        cfg.width = s.width; cfg.height = s.height
        self.init(config: cfg)
        for (i, b) in data.enumerated() {
            switch CellState(rawValue: b) {
            case .free: floorHits[i] = cfg.freeHitThreshold
            case .occupiedLow: lowHits[i] = cfg.occupiedHitThreshold
            case .occupiedHigh: highHits[i] = cfg.occupiedHitThreshold
            case .unknown: break
            case nil: return nil
            }
        }
    }
}
