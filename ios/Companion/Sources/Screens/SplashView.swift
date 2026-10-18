import SwiftUI

// Opening splash, built from the Figma logo (node 5:145) and wordmark (node 3:122). The logo is drawn live so each
// part can move: the ring draws in, the arc drops, the wedge opens like an eye, the cyan dot lights, then the mark
// glides into the "o" of the wordmark and the letters arrive. About 2 s; tap to skip; Reduce Motion shows the
// finished wordmark and fades. The static launch screen is the same night color, so there is no jump.

/// Logo geometry in the Figma's own units: mark box x 316...708, y 138...620; ring centre (512, 424).
private enum Logo {
    static let box = CGRect(x: 316, y: 138, width: 392, height: 482)
    static let ringCenter = CGPoint(x: 512, y: 424)
    static let ringOuter: CGFloat = 196
    static let ringInner: CGFloat = 162.5
    static let wedgeCenter = CGPoint(x: 513.5, y: 425.5)
    static let wedgeDegrees: Double = 30.7
    static let dot = CGPoint(x: 642, y: 391)
    static let dotR: CGFloat = 18
    static let light = Color(hex: 0xD3DEE1)
    static let cyan = Color(hex: 0x22D3EE)
    static let night = Color(hex: 0x0F1E24)

    // Wordmark text box (508, 376, 904 x 327); the logo's ring sits in the "o" at (745, 561), radius 74.
    static let wordBox = CGRect(x: 508, y: 376, width: 904, height: 327)
    static let oCenter = CGPoint(x: 745, y: 561)
    static let oRadius: CGFloat = 74
}

struct LogoMark: View {
    var ring: CGFloat = 1        // 0...1 how much of the ring is drawn
    var arc: CGFloat = 1         // 0...1 arc drop-in
    var wedge: CGFloat = 1       // 0...1 eye opening
    var dot: CGFloat = 1         // 0...1 dot size
    var glow: CGFloat = 0        // 0...1 signal glow around the dot

    var body: some View {
        Canvas { ctx, size in
            let u = size.width / Logo.box.width
            func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - Logo.box.minX) * u, y: (p.y - Logo.box.minY) * u) }
            // Dark centre, as in the Figma: it covers the font's own "o" once the mark docks into the wordmark.
            let ic = pt(Logo.ringCenter), ir = Logo.ringOuter * u
            ctx.fill(Path(ellipseIn: CGRect(x: ic.x - ir, y: ic.y - ir, width: ir * 2, height: ir * 2)), with: .color(Logo.night))
            // Ring as a thick stroke so it can draw in.
            let mid = (Logo.ringOuter + Logo.ringInner) / 2 * u
            var ringPath = Path()
            let rc = pt(Logo.ringCenter)
            if ring >= 1 {   // a closed circle once drawn, so there is no seam where the stroke started
                ringPath.addEllipse(in: CGRect(x: rc.x - mid, y: rc.y - mid, width: mid * 2, height: mid * 2))
            } else {
                ringPath.addArc(center: rc, radius: mid, startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
                ringPath = ringPath.trimmedPath(from: 0, to: ring)
            }
            ctx.stroke(ringPath, with: .color(Logo.light),
                       style: StrokeStyle(lineWidth: (Logo.ringOuter - Logo.ringInner) * u, lineCap: ring < 1 ? .round : .butt))
            // The wedge ("beak"): light from the centre out to the ring, opening upward from 0 degrees.
            if wedge > 0 {
                var w = Path()
                let c = pt(Logo.wedgeCenter)
                w.move(to: c)
                w.addArc(center: c, radius: Logo.ringInner * u + 1, startAngle: .degrees(0),
                         endAngle: .degrees(-Logo.wedgeDegrees * Double(wedge)), clockwise: true)
                w.closeSubpath()
                ctx.fill(w, with: .color(Logo.light))
            }
            // Arc above the ring.
            if arc > 0 {
                var a = Path()
                func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { pt(CGPoint(x: x, y: y - (1 - arc) * 60)) }
                a.move(to: q(316, 215.647))
                a.addCurve(to: q(708, 215.647), control1: q(446.667, 138.784), control2: q(577.333, 138.784))
                a.addLine(to: q(708, 256))
                a.addCurve(to: q(316, 256), control1: q(577.333, 179.137), control2: q(446.667, 179.137))
                a.closeSubpath()
                ctx.opacity = Double(arc)
                ctx.fill(a, with: .color(Logo.light))
                ctx.opacity = 1
            }
            // Cyan dot with its glow.
            let d = pt(Logo.dot)
            if glow > 0 {
                let g = Logo.dotR * u * (2.2 + 2.5 * glow)
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - g, y: d.y - g, width: g * 2, height: g * 2)),
                         with: .radialGradient(Gradient(colors: [Logo.cyan.opacity(0.55 * Double(glow)), Logo.cyan.opacity(0)]),
                                               center: d, startRadius: 0, endRadius: g))
            }
            if dot > 0 {
                let r = Logo.dotR * u * dot
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2)), with: .color(Logo.cyan))
            }
        }
        .aspectRatio(Logo.box.width / Logo.box.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct SplashView: View {
    var onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring: CGFloat = 0
    @State private var arc: CGFloat = 0
    @State private var wedge: CGFloat = 0
    @State private var dot: CGFloat = 0
    @State private var glow: CGFloat = 0
    @State private var docked = false        // mark has moved into the "o"
    @State private var letters = false
    @State private var edges = false
    @State private var leaving = false
    @State private var finished = false

    private let markWidth: CGFloat = 150     // the ring's diameter while centred
    private let wordWidth: CGFloat = 290

    var body: some View {
        GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            // Where things sit once docked: the wordmark is centred; the ring lands on its "o".
            let s = wordWidth / Logo.wordBox.width
            let wordH = Logo.wordBox.height * s
            let oCenter = CGPoint(x: c.x - wordWidth / 2 + (Logo.oCenter.x - Logo.wordBox.minX) * s,
                                  y: c.y - wordH / 2 + (Logo.oCenter.y - Logo.wordBox.minY) * s)
            let dockedWidth = Logo.oRadius * 2 * s
            let width = docked ? dockedWidth : markWidth
            let u = width / Logo.box.width
            // The mark's frame centre sits 45 units above its ring centre.
            let ringToFrame = (Logo.box.midY - Logo.ringCenter.y) * u
            let ringCenter = docked ? oCenter : CGPoint(x: c.x, y: c.y + 20)
            ZStack {
                Logo.night
                // The icon's teal edges, brought in after the first beat so the launch screen hands over cleanly.
                // Pulled back (Isaac): thinner, softer teal edges so the night color dominates.
                LinearGradient(stops: [.init(color: Color(hex: 0x3A7084).opacity(0.55), location: 0),
                                       .init(color: Logo.night.opacity(0), location: 0.16),
                                       .init(color: Logo.night.opacity(0), location: 0.84),
                                       .init(color: Color(hex: 0x3A7084).opacity(0.55), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .opacity(edges ? 1 : 0)
                Image("WordmarkLetters").resizable().scaledToFit()
                    .frame(width: wordWidth)
                    .position(c)
                    .opacity(letters ? 1 : 0)
                    .offset(x: letters ? 0 : 10)
                LogoMark(ring: ring, arc: arc, wedge: wedge, dot: dot, glow: glow)
                    .frame(width: width)
                    .position(x: ringCenter.x, y: ringCenter.y + ringToFrame)
            }
            .ignoresSafeArea()
            .opacity(leaving ? 0 : 1)
            .scaleEffect(leaving && !reduceMotion ? 1.06 : 1)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { await run() }
        .accessibilityElement()
        .accessibilityLabel("Sought")
        .accessibilityAddTraits(.isImage)
    }

    private func run() async {
        if reduceMotion {
            ring = 1; arc = 1; wedge = 1; dot = 1; docked = true; letters = true; edges = true
            try? await Task.sleep(nanoseconds: 700_000_000)
            finish(); return
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        await wait(0.15)
        withAnimation(.easeInOut(duration: 0.55)) { ring = 1 }
        withAnimation(.easeOut(duration: 0.8)) { edges = true }
        await wait(0.35)
        withAnimation(.spring(duration: 0.45, bounce: 0.25)) { arc = 1 }
        await wait(0.3)
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { wedge = 1 }
        await wait(0.2)
        withAnimation(.spring(duration: 0.35, bounce: 0.5)) { dot = 1; glow = 1 }
        Haptics.shared.tap()
        await wait(0.3)
        withAnimation(.easeOut(duration: 0.4)) { glow = 0.25 }
        withAnimation(.spring(duration: 0.55, bounce: 0.15)) { docked = true }
        await wait(0.15)
        withAnimation(.easeOut(duration: 0.4)) { letters = true }
        await wait(0.75)
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeIn(duration: 0.3)) { leaving = true }
        Task { try? await Task.sleep(nanoseconds: 300_000_000); onFinish() }
    }
}
