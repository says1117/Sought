import Foundation
#if canImport(OccupancyGridCore)
import OccupancyGridCore
#endif

// Grid snapshot used by exploration planning. Pure value type so synthetic grids are easy to build in tests.
// Frame: ARKit world, meters, x right, z toward the back; row index runs along +z (same as OccupancyGrid).

struct GridCell: Hashable {
    var col: Int
    var row: Int
}

struct ExploreMap {
    let width: Int
    let height: Int
    let resolution: Float
    let originX: Float
    let originZ: Float
    private(set) var cells: [CellState]

    init(width: Int, height: Int, resolution: Float = 0.05, originX: Float = 0, originZ: Float = 0,
         fill: CellState = .unknown) {
        self.width = width; self.height = height; self.resolution = resolution
        self.originX = originX; self.originZ = originZ
        cells = [CellState](repeating: fill, count: width * height)
    }

    init(grid: OccupancyGrid) {
        self.init(width: grid.width, height: grid.height, resolution: grid.config.resolution,
                  originX: grid.config.originX, originZ: grid.config.originZ)
        for r in 0..<height { for c in 0..<width { cells[r * width + c] = grid.state(col: c, row: r) } }
    }

    func contains(_ c: GridCell) -> Bool { c.col >= 0 && c.col < width && c.row >= 0 && c.row < height }

    func state(_ c: GridCell) -> CellState { contains(c) ? cells[c.row * width + c.col] : .unknown }

    mutating func set(_ c: GridCell, _ s: CellState) {
        guard contains(c) else { return }
        cells[c.row * width + c.col] = s
    }

    func isOccupied(_ c: GridCell) -> Bool {
        let s = state(c)
        return s == .occupiedLow || s == .occupiedHigh
    }

    func cell(x: Double, z: Double) -> GridCell? {
        let c = Int(((Float(x) - originX) / resolution).rounded(.down))
        let r = Int(((Float(z) - originZ) / resolution).rounded(.down))
        let g = GridCell(col: c, row: r)
        return contains(g) ? g : nil
    }

    func center(_ c: GridCell) -> (x: Double, z: Double) {
        (Double(originX + (Float(c.col) + 0.5) * resolution), Double(originZ + (Float(c.row) + 0.5) * resolution))
    }

    static let neighbors4: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    static let neighbors8: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]
}

/// Traversable cells = free cells farther than the rover radius from any occupied cell.
struct TraversalMask {
    let map: ExploreMap
    private var blocked: [Bool]   // true = the rover center may not be here

    init(map: ExploreMap, roverRadiusM: Float) {
        self.map = map
        blocked = [Bool](repeating: false, count: map.width * map.height)
        // Occupied cells represent squares, not points. Measure clearance from each cell's
        // footprint so a rover center cannot pass within roverRadiusM of an occupied square.
        let rc = max(0, Int((roverRadiusM / map.resolution + 0.5).rounded(.up)))
        for row in 0..<map.height {
            for col in 0..<map.width {
                let cell = GridCell(col: col, row: row)
                if map.state(cell) != .free { blocked[row * map.width + col] = true }
                guard map.isOccupied(cell) else { continue }
                for dr in -rc...rc {
                    for dc in -rc...rc {
                        let dx = max(0, (Float(abs(dc)) - 0.5) * map.resolution)
                        let dz = max(0, (Float(abs(dr)) - 0.5) * map.resolution)
                        guard dx * dx + dz * dz <= roverRadiusM * roverRadiusM else { continue }
                        let n = GridCell(col: col + dc, row: row + dr)
                        if map.contains(n) { blocked[n.row * map.width + n.col] = true }
                    }
                }
            }
        }
    }

    func isTraversable(_ c: GridCell) -> Bool { map.contains(c) && !blocked[c.row * map.width + c.col] }

    /// BFS over 4-connected traversable cells. `start` is always expanded even if the rover sits inside an
    /// inflated margin, and cells within `escapeRadiusM` of start are allowed so it can leave that margin.
    func reach(from start: GridCell, escapeRadiusM: Float = 0.3) -> Reach {
        var dist = [Int32](repeating: -1, count: map.width * map.height)
        var parent = [Int32](repeating: -1, count: map.width * map.height)
        guard map.contains(start) else { return Reach(map: map, dist: dist, parent: parent) }
        let esc = Int((escapeRadiusM / map.resolution).rounded(.up))
        func allowed(_ c: GridCell) -> Bool {
            if isTraversable(c) { return true }
            // Escape corridor: not occupied/unknown-looking-blocked ground near start only.
            guard map.state(c) == .free, !map.isOccupied(c) else { return false }
            return abs(c.col - start.col) <= esc && abs(c.row - start.row) <= esc
        }
        var queue = [start]
        var head = 0
        dist[start.row * map.width + start.col] = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            let ci = cur.row * map.width + cur.col
            for (dc, dr) in ExploreMap.neighbors4 {
                let n = GridCell(col: cur.col + dc, row: cur.row + dr)
                guard map.contains(n), allowed(n) else { continue }
                let ni = n.row * map.width + n.col
                if dist[ni] >= 0 { continue }
                dist[ni] = dist[ci] + 1
                parent[ni] = Int32(ci)
                queue.append(n)
            }
        }
        return Reach(map: map, dist: dist, parent: parent)
    }

    /// True when the straight segment between two cells crosses only traversable cells.
    func lineClear(_ a: GridCell, _ b: GridCell, reach: Reach) -> Bool {
        var x0 = a.col, y0 = a.row
        let x1 = b.col, y1 = b.row
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            if !reach.isReached(GridCell(col: x0, row: y0)) { return false }
            if x0 == x1 && y0 == y1 { return true }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
    }
}

struct Reach {
    let map: ExploreMap
    fileprivate let dist: [Int32]
    fileprivate let parent: [Int32]

    func isReached(_ c: GridCell) -> Bool { map.contains(c) && dist[c.row * map.width + c.col] >= 0 }

    /// Path length in meters (4-connected steps), or nil if unreachable.
    func distanceM(to c: GridCell) -> Double? {
        guard isReached(c) else { return nil }
        return Double(dist[c.row * map.width + c.col]) * Double(map.resolution)
    }

    /// Cells from start to `c` inclusive.
    func path(to c: GridCell) -> [GridCell] {
        guard isReached(c) else { return [] }
        var out: [GridCell] = []
        var i = c.row * map.width + c.col
        while i >= 0 {
            out.append(GridCell(col: i % map.width, row: i / map.width))
            i = Int(parent[i])
        }
        return out.reversed()
    }
}
