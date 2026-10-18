#if os(iOS)
import SwiftUI

/// Robot tools > Explore (only when RecallFeatureFlags.exploreEnabled). "Show next goal" plans without driving;
/// "Start explore" asks the coordinator, so STOP, the drive lease, tracking loss and the obstacle guard apply.
/// Closing Robot tools sends STOP (ScanHereModel.cancel), which also ends a running explore.
struct ExplorePreviewSection: View {
    @ObservedObject var runtime: AppRuntime
    @State private var preview: ExplorePreview?
    @State private var map: ExploreMap?
    @State private var stats: ExploreGridStore.Stats?
    @State private var busy = false
    static let runMinutes = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shows where Explore would drive next and why, without moving. Check the goal, then start a short run with your hand on STOP.")
                .font(.callout).foregroundStyle(.secondary)
            if let stats { Text(statsText(stats)).font(.system(.footnote, design: .monospaced)) }
            HStack {
                Button { refresh() } label: { Label("Show next goal", systemImage: "scope") }
                    .buttonStyle(.bordered).disabled(busy)
                Button("Reset map") { runtime.explore.store.reset(); refresh() }
                    .buttonStyle(.bordered)
            }
            if let preview {
                Text(preview.title).font(.title2.bold())
                ForEach(Array(preview.detail.enumerated()), id: \.offset) { Text($0.element).font(.body) }
                if let map { ExploreMiniMap(map: map, preview: preview).frame(height: 280) }
            }
            Button {
                Task { try? await runtime.coordinator.execute(.explore(maxMinutes: Self.runMinutes)) }
            } label: {
                Label("Start explore (\(Self.runMinutes) min)", systemImage: "map")
                    .font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(preview?.ready != true || runtime.coordinatorStatus.state != .idle)
            Text("Robot: \(runtime.coordinatorStatus.state.heartbeatValue)\(runtime.coordinatorStatus.task.map { " · \($0)" } ?? "")")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .onAppear(perform: refresh)
    }

    private func refresh() {
        busy = true
        Task { @MainActor in
            let (p, m, s) = await runtime.explore.preview()
            preview = p; map = m; stats = s; busy = false
        }
    }

    private func statsText(_ s: ExploreGridStore.Stats) -> String {
        let age = s.ageS.map { String(format: "%.1f s ago", $0) } ?? "never"
        return "Map: \(s.frames) frames, updated \(age)\nfree \(s.free) · occupied \(s.occupied) · unknown \(s.unknown) cells (5 cm)"
    }
}

/// Top-down map: grey = seen floor, red = obstacle, dark = unknown; blue = rover, green = goal and path.
/// x to the right, z downward.
private struct ExploreMiniMap: View {
    let map: ExploreMap
    let preview: ExplorePreview

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.15)))
            // Crop to the seen cells plus a margin so a 10 m grid with a 2 m seen patch is still readable.
            var minC = map.width, maxC = -1, minR = map.height, maxR = -1
            for r in 0..<map.height { for c in 0..<map.width where map.cells[r * map.width + c] != .unknown {
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
            } }
            guard maxC >= 0 else { return }
            minC = max(0, minC - 10); minR = max(0, minR - 10)
            maxC = min(map.width - 1, maxC + 10); maxR = min(map.height - 1, maxR + 10)
            let cols = CGFloat(maxC - minC + 1), rows = CGFloat(maxR - minR + 1)
            let cell = min(size.width / cols, size.height / rows)
            func point(_ x: Double, _ z: Double) -> CGPoint {
                CGPoint(x: (CGFloat((Float(x) - map.originX) / map.resolution) - CGFloat(minC)) * cell,
                        y: (CGFloat((Float(z) - map.originZ) / map.resolution) - CGFloat(minR)) * cell)
            }
            for r in minR...maxR {
                for c in minC...maxC {
                    let color: Color
                    switch map.cells[r * map.width + c] {
                    case .unknown: continue
                    case .free: color = Color(white: 0.75)
                    case .occupiedLow, .occupiedHigh: color = .red
                    }
                    let rect = CGRect(x: CGFloat(c - minC) * cell, y: CGFloat(r - minR) * cell, width: cell + 0.5, height: cell + 0.5)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
            if let robot = preview.robot, let goal = preview.goal {
                var path = Path()
                path.move(to: point(robot.x, robot.z))
                for wp in goal.path { path.addLine(to: point(wp.x, wp.z)) }
                ctx.stroke(path, with: .color(.green), lineWidth: 2)
                let g = point(goal.x, goal.z)
                ctx.fill(Path(ellipseIn: CGRect(x: g.x - 6, y: g.y - 6, width: 12, height: 12)), with: .color(.green))
                let f = point(goal.frontierX, goal.frontierZ)
                ctx.stroke(Path(ellipseIn: CGRect(x: f.x - 5, y: f.y - 5, width: 10, height: 10)), with: .color(.yellow), lineWidth: 2)
            }
            if let robot = preview.robot {
                let p = point(robot.x, robot.z)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.blue))
            }
        }
        .accessibilityLabel("Explore map preview")
    }
}
#endif
