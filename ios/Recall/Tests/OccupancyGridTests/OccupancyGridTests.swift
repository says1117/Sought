import XCTest
import Foundation
import simd
#if canImport(OccupancyGridCore)
@testable import OccupancyGridCore
#endif

final class OccupancyGridTests: XCTestCase {
    private let W = 256, H = 192
    private let K = DepthIntrinsics(fx: 200, fy: 200, cx: 128, cy: 96)

    private func camera(pitchDeg: Float = -10, y: Float = 0.3) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: pitchDeg * .pi / 180, axis: [1, 0, 0]))
        m.columns.3 = [0, y, 0, 1]
        return m
    }

    /// Ray-casts floor (y=0), optional wall plane z=wallZ, optional box into a depth buffer.
    private func render(wallZ: Float? = nil, box: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil,
                        floor: Bool = true, T: simd_float4x4? = nil) -> DepthFrame {
        let T = T ?? camera()
        let o = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        var depth = [Float](repeating: 0, count: W * H)
        for v in 0..<H {
            for u in 0..<W {
                // Unnormalized camera-space ray with z = -1, so the ray parameter t is the depth.
                let c = SIMD4<Float>((Float(u) - K.cx) / K.fx, -(Float(v) - K.cy) / K.fy, -1, 0)
                let w = T * c
                let dir = SIMD3<Float>(w.x, w.y, w.z)
                var best = Float.infinity
                if floor, dir.y < 0 { best = min(best, -o.y / dir.y) }
                if let wz = wallZ, dir.z < 0 { let t = (wz - o.z) / dir.z; if t > 0 { best = min(best, t) } }
                if let b = box {
                    var t0: Float = 0, t1 = Float.infinity
                    for a in 0..<3 {
                        if abs(dir[a]) < 1e-9 { if o[a] < b.min[a] || o[a] > b.max[a] { t1 = -1 } }
                        else {
                            var ta = (b.min[a] - o[a]) / dir[a], tb = (b.max[a] - o[a]) / dir[a]
                            if ta > tb { swap(&ta, &tb) }
                            t0 = max(t0, ta); t1 = min(t1, tb)
                        }
                    }
                    if t0 <= t1 { best = min(best, t0) }
                }
                depth[v * W + u] = best.isFinite ? best : 0
            }
        }
        return DepthFrame(depth: depth, width: W, height: H, intrinsics: K, cameraToWorld: T, floorY: 0)
    }

    private func integrate(_ grid: inout OccupancyGrid, _ f: DepthFrame, times: Int = 3) {
        for _ in 0..<times { grid.integrate(f) }
    }

    func testFlatFloorGivesFreeCells() {
        var g = OccupancyGrid()
        integrate(&g, render())
        XCTAssertEqual(g.state(x: 0, z: -0.8), .free)
        XCTAssertEqual(g.state(x: 0.1, z: -0.6), .free)
        XCTAssertEqual(g.state(x: 0, z: 2.0), .unknown)          // behind the camera
        XCTAssertFalse(g.cellBytes().contains(CellState.occupiedLow.rawValue))
        XCTAssertFalse(g.cellBytes().contains(CellState.occupiedHigh.rawValue))
    }

    func testSingleFrameBelowThreshold() {
        var g = OccupancyGrid()
        integrate(&g, render(), times: 1)
        XCTAssertEqual(g.state(x: 0, z: -0.8), .unknown)
    }

    func testBoxGivesOccupiedLow() {
        var g = OccupancyGrid()
        let box = (min: SIMD3<Float>(-0.2, 0, -2.0), max: SIMD3<Float>(0.2, 0.2, -1.6))
        integrate(&g, render(box: box))
        // The box top spans only a couple of depth rows at this range, so look across its footprint.
        var lowCells = 0
        for r in 0..<g.height { for c in 0..<g.width where g.state(col: c, row: r) == .occupiedLow {
            let p = g.cellCenter(col: c, row: r)
            XCTAssertTrue(p.x >= -0.25 && p.x <= 0.25 && p.z >= -2.05 && p.z <= -1.55)
            lowCells += 1
        } }
        XCTAssertTrue(lowCells >= 4)
        XCTAssertEqual(g.state(x: 0, z: -0.8), .free)
        XCTAssertFalse(g.cellBytes().contains(CellState.occupiedHigh.rawValue))
    }

    func testWallGivesOccupiedHigh() {
        var g = OccupancyGrid()
        integrate(&g, render(wallZ: -3.0))
        XCTAssertEqual(g.state(x: 0, z: -3.02), .occupiedHigh)   // high wins over the low part of the wall
        XCTAssertEqual(g.state(x: 0, z: -0.8), .free)
    }

    func testOutOfRangeIgnored() {
        var g = OccupancyGrid()
        var f = render(wallZ: -6.0, floor: false)                // beyond maxDepth 4 m
        XCTAssertEqual(g.integrate(f), 0)
        f.depth = [Float](repeating: .nan, count: W * H)
        XCTAssertEqual(g.integrate(f), 0)
        f.depth = [Float](repeating: 0.1, count: W * H)          // closer than minDepth
        XCTAssertEqual(g.integrate(f), 0)
        XCTAssertTrue(g.cellBytes().allSatisfy { $0 == CellState.unknown.rawValue })
    }

    func testPointsOutsideGridIgnored() {
        var cfg = OccupancyGridConfig()
        cfg.originX = 50; cfg.originZ = 50
        var g = OccupancyGrid(config: cfg)
        XCTAssertEqual(g.integrate(render()), 0)
    }

    func testSnapshotRoundTrips() throws {
        var g = OccupancyGrid()
        let box = (min: SIMD3<Float>(-0.2, 0, -2.0), max: SIMD3<Float>(0.2, 0.2, -1.6))
        integrate(&g, render(wallZ: -3.0, box: box))
        let snap = g.snapshot(updatedAt: "2026-10-17T02:12:30Z")
        XCTAssertEqual(snap.resolutionM, 0.05, accuracy: 1e-9)
        XCTAssertEqual(snap.width, 160); XCTAssertEqual(snap.height, 240)
        XCTAssertEqual(Data(base64Encoded: snap.cellsB64)?.count, 160 * 240)

        let json = try JSONEncoder().encode(snap)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"cells_b64\"")); XCTAssertTrue(text.contains("\"resolution_m\""))
        let back = try JSONDecoder().decode(MapSnapshot.self, from: json)
        XCTAssertEqual(back, snap)

        let g2 = try XCTUnwrap(OccupancyGrid(snapshot: back))
        XCTAssertEqual(g2.cellBytes(), g.cellBytes())
        XCTAssertEqual(g2.snapshot(updatedAt: snap.updatedAt), snap)
        XCTAssertNil(OccupancyGrid(snapshot: MapSnapshot(resolutionM: 0.05, origin: .init(x: 0, z: 0), width: 2, height: 2, cellsB64: "AAAA")))
    }
}
