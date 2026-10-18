import SwiftUI

// Top-down floor map. World x goes right and z goes down on screen (03_CONTRACTS section 0).
// Draws the occupancy grid when the robot sends one, otherwise the room outlines (SAMPLE). Then the dotted trail,
// waypoints, optional object pins and the robot with its signal glow.

struct MapCanvas: View {
    let map: MapSnapshot
    let robot: Pose2D?
    var pins: [TrackedObject] = []
    var highlight: String? = nil
    var showLabels = true
    var active = true
    var onPin: ((TrackedObject) -> Void)? = nil
    /// Widget mode: fill the width and keep this point vertically centered (clamped to the map).
    var fillWidth = false
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let tf = Transform(bounds: map.bounds, size: geo.size, inset: 12, fillWidth: fillWidth, focusZ: robot?.z)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    if let g = map.grid { drawGrid(g, tf, &ctx) } else { drawRooms(tf, &ctx) }
                    drawTrail(tf, &ctx)
                    for w in map.waypoints {
                        let pt = tf.point(w.x, w.z)
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)), with: .color(p.surface))
                        ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)),
                                   with: .color(p.mapPath.opacity(0.4)), lineWidth: 2)
                    }
                }
                if showLabels && map.grid == nil {
                    ForEach(map.rooms) { r in
                        Text(r.name.uppercased()).font(SoughtFont.findIt).tracking(0.8).foregroundStyle(p.text.opacity(0.8))
                            .position(tf.point((r.minX + r.maxX) / 2, r.maxZ - 0.3))
                            .accessibilityHidden(true)
                    }
                }
                ForEach(pins) { o in
                    let pt = tf.point(o.x, o.z)
                    Button { onPin?(o) } label: {
                        PhotoView(photo: o.photo)
                            .frame(width: 28, height: 28)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(highlight == o.id ? p.found : p.surface, lineWidth: 2.5))
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .position(pt)
                    .accessibilityLabel("\(o.label), \(o.whereText.lowercased())")
                    .accessibilityHint("Double tap for details.")
                }
                if let r = robot {
                    let pt = tf.point(r.x, r.z)
                    ZStack {
                        if active {
                            Circle().fill(RadialGradient(colors: [p.signal.opacity(0.45), p.signal.opacity(0)], center: .center,
                                                         startRadius: 0, endRadius: 28))
                                .frame(width: 56, height: 56)
                                .scaleEffect(pulse ? 1.15 : 0.9)
                            Circle().stroke(p.signal.opacity(0.45), lineWidth: 1.5).frame(width: 34, height: 34)
                        }
                        Circle().fill(p.mapPath).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                    }
                    .position(pt)
                    .accessibilityElement()
                    .accessibilityLabel("Soughtbot")
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.6), value: r)
                }
            }
        }
        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 1.4).repeatForever()) { pulse = true } } }
    }

    private func drawRooms(_ tf: Transform, _ ctx: inout GraphicsContext) {
        let b = map.bounds
        let outer = tf.rect(b.minX, b.minZ, b.maxX, b.maxZ)
        ctx.fill(Path(roundedRect: outer, cornerRadius: 6), with: .color(p.surface))
        for r in map.rooms {
            let rect = tf.rect(r.minX, r.minZ, r.maxX, r.maxZ).insetBy(dx: 3, dy: 3)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(p.mapRoom.opacity(0.6)))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(p.mapWall), lineWidth: 2.5)
        }
    }

    private func drawGrid(_ g: OccupancyGrid, _ tf: Transform, _ ctx: inout GraphicsContext) {
        let b = map.bounds
        ctx.fill(Path(tf.rect(b.minX, b.minZ, b.maxX, b.maxZ)), with: .color(p.surface))
        let cell = CGFloat(g.resolution) * tf.scale
        for row in 0..<g.height {
            for col in 0..<g.width {
                let v = g.cells[row * g.width + col]
                guard v != 1 else { continue }
                let pt = tf.point(g.originX + Double(col) * g.resolution, g.originZ + Double(row) * g.resolution)
                let color: Color = v == 0 ? p.mapRoom : v == 2 ? p.mapWall.opacity(0.6) : p.mapWall
                ctx.fill(Path(CGRect(x: pt.x, y: pt.y, width: cell + 0.5, height: cell + 0.5)), with: .color(color))
            }
        }
    }

    private func drawTrail(_ tf: Transform, _ ctx: inout GraphicsContext) {
        var pts = map.trail.map { tf.point($0.x, $0.z) }
        if let r = robot { pts.append(tf.point(r.x, r.z)) }
        guard pts.count > 1 else { return }
        var path = Path()
        path.addLines(pts)
        ctx.stroke(path, with: .linearGradient(Gradient(colors: [p.mapPath.opacity(0.2), p.mapPath]),
                                               startPoint: pts.first!, endPoint: pts.last!),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 6]))
    }

    struct Transform {
        let minX: Double, minZ: Double, scale: CGFloat, offset: CGPoint

        init(bounds b: (minX: Double, minZ: Double, maxX: Double, maxZ: Double), size: CGSize, inset: CGFloat,
             fillWidth: Bool = false, focusZ: Double? = nil) {
            let w = max(0.1, b.maxX - b.minX), h = max(0.1, b.maxZ - b.minZ)
            let fitW = (size.width - inset * 2) / CGFloat(w)
            let s = fillWidth ? fitW : min(fitW, (size.height - inset * 2) / CGFloat(h))
            minX = b.minX; minZ = b.minZ; scale = s
            var y = (size.height - CGFloat(h) * s) / 2
            if fillWidth, CGFloat(h) * s > size.height {
                let fz = focusZ ?? (b.minZ + b.maxZ) / 2
                y = size.height / 2 - CGFloat(fz - b.minZ) * s
                y = min(inset, max(size.height - inset - CGFloat(h) * s, y))
            }
            offset = CGPoint(x: (size.width - CGFloat(w) * s) / 2, y: y)
        }

        func point(_ x: Double, _ z: Double) -> CGPoint {
            CGPoint(x: offset.x + CGFloat(x - minX) * scale, y: offset.y + CGFloat(z - minZ) * scale)
        }

        func rect(_ x0: Double, _ z0: Double, _ x1: Double, _ z1: Double) -> CGRect {
            let a = point(x0, z0), b = point(x1, z1)
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
    }
}
