import Foundation
#if canImport(OccupancyGridCore)
import OccupancyGridCore
#endif

struct FrontierCluster {
    var cells: [GridCell]
    /// Approximate boundary length in meters (cell count x resolution).
    var sizeM: Double
    var centroid: (x: Double, z: Double)
}

enum FrontierDetector {
    /// Frontier cell = free cell with at least one 4-neighbor that is unknown inside the grid.
    static func frontierCells(in map: ExploreMap) -> [GridCell] {
        var out: [GridCell] = []
        for row in 0..<map.height {
            for col in 0..<map.width {
                let c = GridCell(col: col, row: row)
                guard map.state(c) == .free else { continue }
                for (dc, dr) in ExploreMap.neighbors4 {
                    let n = GridCell(col: col + dc, row: row + dr)
                    if map.contains(n) && map.state(n) == .unknown { out.append(c); break }
                }
            }
        }
        return out
    }

    /// 8-connected clusters; clusters shorter than `minSizeM` are dropped.
    static func clusters(in map: ExploreMap, minSizeM: Double = 0.3) -> [FrontierCluster] {
        let cells = frontierCells(in: map)
        let set = Set(cells)
        var seen = Set<GridCell>()
        var out: [FrontierCluster] = []
        for start in cells where !seen.contains(start) {
            var comp: [GridCell] = []
            var stack = [start]
            seen.insert(start)
            while let cur = stack.popLast() {
                comp.append(cur)
                for (dc, dr) in ExploreMap.neighbors8 {
                    let n = GridCell(col: cur.col + dc, row: cur.row + dr)
                    if set.contains(n) && !seen.contains(n) { seen.insert(n); stack.append(n) }
                }
            }
            let size = Double(comp.count) * Double(map.resolution)
            // Small epsilon so exactly-0.3 m (6 cells at 5 cm) is kept despite float rounding.
            guard size + 1e-6 >= minSizeM else { continue }
            let cs = comp.map { map.center($0) }
            let cx = cs.map(\.x).reduce(0, +) / Double(cs.count)
            let cz = cs.map(\.z).reduce(0, +) / Double(cs.count)
            out.append(FrontierCluster(cells: comp, sizeM: size, centroid: (cx, cz)))
        }
        return out
    }
}
