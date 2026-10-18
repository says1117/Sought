import SwiftUI

// App background. One system, four ideas (Isaac picked A + B + C + D, E as an alternative renderer):
//   A  blueprint grid on the Map tab only (Isaac: too busy on Home) + fine grain everywhere
//   B  color pools drift on slow 20-30 s loops
//   C  the robot's state tints the scene: calm when resting, cyan when busy, a hint of amber when stuck
//   D  each tab has its own color mix and crossfades when you switch
//   E  default: the same moods drawn with a MeshGradient (iOS 18+); `-bgMesh NO` uses the blurred pools
// Every color stays light enough that the text tokens keep their contrast. Reduce Motion stops the drift,
// Reduce Transparency and High contrast fall back to the flat background.

struct BackgroundMood: Equatable {
    var tab: AppTab
    var state: RobotState
    var online: Bool

    enum Activity { case calm, busy, stuck }
    var activity: Activity {
        guard online else { return .calm }
        switch state {
        case .finding, .exploring, .comingToUser, .teaching, .patrolling, .checkingRoute: return .busy
        case .blocked, .error: return .stuck
        case .idle: return .calm
        }
    }

    /// Three pools per tab (D): top right, middle left, bottom right.
    var pools: [Color] {
        switch tab {
        case .home: [Color(hex: 0x9DBDC6, alpha: 0.30), Color(hex: 0x96E2EE, alpha: 0.45), Color(hex: 0xB4D0D8, alpha: 0.45)]
        case .map: [Color(hex: 0x86B8C2, alpha: 0.34), Color(hex: 0x9DCBD3, alpha: 0.40), Color(hex: 0xA6CAD2, alpha: 0.45)]
        case .items: [Color(hex: 0xB3C8E4, alpha: 0.42), Color(hex: 0xBFD9EE, alpha: 0.45), Color(hex: 0xA9C1DA, alpha: 0.40)]
        case .settings: [Color(hex: 0xC6D3D7, alpha: 0.40), Color(hex: 0xD0DCDF, alpha: 0.40), Color(hex: 0xBACCD1, alpha: 0.40)]
        }
    }

    /// Wash behind the pools, top to bottom.
    var wash: [Color] {
        switch tab {
        case .items: [Color(hex: 0xE0EAF2), Color(hex: 0xD6E2EC), Color(hex: 0xCFDCE8)]
        case .settings: [Color(hex: 0xE3ECEE), Color(hex: 0xDAE5E8), Color(hex: 0xD3DFE3)]
        default: [Color(hex: 0xDFEEF1), Color(hex: 0xD3E6EB), Color(hex: 0xCDE1E7)]
        }
    }

    /// The robot's pool (C). Clear when calm.
    var stateGlow: Color {
        switch activity {
        case .calm: .clear
        case .busy: Color(hex: 0x22D3EE, alpha: 0.30)
        case .stuck: Color(hex: 0xE8A317, alpha: 0.24)
        }
    }
}

private struct MoodKey: EnvironmentKey { static let defaultValue = BackgroundMood(tab: .home, state: .idle, online: false) }
extension EnvironmentValues {
    var backgroundMood: BackgroundMood {
        get { self[MoodKey.self] }
        set { self[MoodKey.self] = newValue }
    }
}

struct SoughtBackground: View {
    @Environment(\.palette) private var p
    @Environment(\.backgroundMood) private var mood
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("bgMesh") private var useMesh = true

    var body: some View {
        Group {
            if reduceTransparency || p.isHighContrast {
                p.background
            } else {
                ZStack {
                    if useMesh, #available(iOS 18.0, *) {
                        MeshBackground(mood: mood, animate: !reduceMotion)
                    } else {
                        PoolBackground(mood: mood, animate: !reduceMotion)
                    }
                    // Grid only where it means something (the map); grain everywhere to stop gradient banding.
                    BlueprintTexture(color: p.text, grid: mood.tab == .map)
                }
                .animation(.easeInOut(duration: 0.9), value: mood)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

// MARK: - A: blueprint grid + grain

struct BlueprintTexture: View {
    var color: Color
    var grid = true

    var body: some View {
        Canvas { ctx, size in
            let minor: CGFloat = 20, major: CGFloat = 100
            var minorPath = Path(), majorPath = Path()
            var x: CGFloat = 0
            while x <= size.width {
                let line = [CGPoint(x: x, y: 0), CGPoint(x: x, y: size.height)]
                if x.truncatingRemainder(dividingBy: major) == 0 { majorPath.addLines(line) } else { minorPath.addLines(line) }
                x += minor
            }
            var y: CGFloat = 0
            while y <= size.height {
                let line = [CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)]
                if y.truncatingRemainder(dividingBy: major) == 0 { majorPath.addLines(line) } else { minorPath.addLines(line) }
                y += minor
            }
            if grid {
                ctx.stroke(minorPath, with: .color(color.opacity(0.035)), lineWidth: 0.5)
                ctx.stroke(majorPath, with: .color(color.opacity(0.06)), lineWidth: 0.75)
            }
            // Grain: a fixed seed so it never shimmers between frames.
            var rng = SeededRandom(seed: 7)
            let count = Int(size.width * size.height / 90)
            for _ in 0..<count {
                let px = CGFloat(rng.next() % 10_000) / 10_000 * size.width
                let py = CGFloat(rng.next() % 10_000) / 10_000 * size.height
                let dark = rng.next() % 2 == 0
                ctx.fill(Path(CGRect(x: px, y: py, width: 1, height: 1)),
                         with: .color(dark ? Color.black.opacity(0.035) : Color.white.opacity(0.08)))
            }
        }
        .drawingGroup()
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

// MARK: - B + C + D: drifting pools

struct PoolBackground: View {
    var mood: BackgroundMood
    var animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { tl in
            let t = animate ? tl.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    LinearGradient(colors: mood.wash, startPoint: .top, endPoint: .bottom)
                    pool(mood.pools[0], d: w * 0.9, blur: 70,
                         at: CGPoint(x: w * 0.95 + drift(t, 23, w * 0.06), y: h * 0.12 + drift(t, 29, h * 0.03, phase: 1)))
                    pool(mood.pools[1], d: w * 0.8, blur: 80,
                         at: CGPoint(x: w * 0.05 + drift(t, 27, w * 0.08, phase: 2), y: h * 0.48 + drift(t, 21, h * 0.04)))
                    pool(mood.pools[2], d: w, blur: 90,
                         at: CGPoint(x: w * 0.85 + drift(t, 31, w * 0.05), y: h * 0.85 + drift(t, 25, h * 0.03, phase: 3)))
                    // C: the robot's glow sits behind the top of the screen, where the status lives.
                    pool(mood.stateGlow, d: w * 1.1, blur: 90,
                         at: CGPoint(x: w * 0.5 + drift(t, 19, w * 0.1, phase: 4), y: h * 0.18))
                }
                .drawingGroup()
            }
        }
    }

    private func pool(_ c: Color, d: CGFloat, blur: CGFloat, at p: CGPoint) -> some View {
        Circle().fill(c).frame(width: d, height: d).blur(radius: blur).position(p)
    }

    private func drift(_ t: Double, _ period: Double, _ amp: CGFloat, phase: Double = 0) -> CGFloat {
        CGFloat(sin(t / period * 2 * .pi + phase)) * amp
    }
}

// MARK: - E: mesh gradient

@available(iOS 18.0, *)
struct MeshBackground: View {
    var mood: BackgroundMood
    var animate: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { tl in
            let t = animate ? tl.date.timeIntervalSinceReferenceDate : 0
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors)
        }
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        func s(_ period: Double, _ amp: Float, _ ph: Double = 0) -> Float { Float(sin(t / period * 2 * .pi + ph)) * amp }
        return [
            [0, 0], [0.5 + s(23, 0.08), 0], [1, 0],
            [0, 0.45 + s(27, 0.06, 1)], [0.5 + s(29, 0.1, 2), 0.5 + s(21, 0.08)], [1, 0.55 + s(25, 0.06, 3)],
            [0, 1], [0.5 + s(31, 0.08, 1), 1], [1, 1],
        ]
    }

    /// Mesh stops, row by row (top-left first). Richer than the pools but every stop keeps luminance high enough for
    /// the title color (3:1) and body text (4.5:1). The top-left stop, behind the screen title, is always the lightest.
    private var colors: [Color] {
        let glow: Color = switch mood.activity {
        case .calm: Color(hex: 0xCFE6EC)
        case .busy: Color(hex: 0xA9E7F1)
        case .stuck: Color(hex: 0xF0DDB0)
        }
        let c: [UInt32] = switch mood.tab {
        case .home: [0xE4F3F5, 0, 0xC4E2E9, 0xBDE8EF, 0xDAEDF1, 0xD2E8EC, 0xD5E9EE, 0xC1DFE6, 0xB9D8E0]
        case .map: [0xDDEEF1, 0, 0xB7D9E0, 0xB5DCE3, 0xD3E8EC, 0xC7E1E6, 0xCFE5EA, 0xB3D5DD, 0xB6D4DC]
        case .items: [0xE3ECF5, 0, 0xC9D9EE, 0xC6DCF0, 0xDCE6F0, 0xD3DFEC, 0xD8E3EE, 0xC3D3E8, 0xC1D1E6]
        case .settings: [0xE6EEF0, 0, 0xD5E1E4, 0xD2DEE1, 0xE0E9EB, 0xD8E2E5, 0xDCE5E7, 0xCCD9DD, 0xC6D4D8]
        }
        return c.enumerated().map { i, h in i == 1 ? glow : Color(hex: h) }
    }
}
