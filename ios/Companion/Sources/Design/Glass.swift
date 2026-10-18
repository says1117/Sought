import SwiftUI

// Sought glass, drawn to match the Figma PNGs rather than the system Liquid Glass (which reads almost clear on
// light backgrounds): frosted material + a tint + a bright top-left edge + one soft shadow. Looks the same on iOS 17-26.
// Reduce Transparency and High contrast both swap every glass for a solid fill with the same hue.

enum GlassStyle {
    case search, activity, call, pill, tabBar, sheet

    func tint(_ p: Palette) -> Color {
        switch self {
        case .search: Color(hex: 0x98C1CD, alpha: 0.45)
        case .activity: Color(red: 150 / 255, green: 226 / 255, blue: 238 / 255, opacity: 0.32)
        case .call: p.call.opacity(0.96)             // keeps white text above 5:1 even over the busy glow
        case .pill: Color.white.opacity(0.28)
        case .tabBar: Color(hex: 0x57A9B2, alpha: 0.35)
        case .sheet: Color.white.opacity(0.35)
        }
    }

    func solid(_ p: Palette) -> Color {
        if p.isHighContrast { return self == .call ? p.call : p.card }
        switch self {
        case .search: return Color(hex: 0xBDD7DE)
        case .activity: return Color(hex: 0xCBEAF0)
        case .call: return p.call
        case .pill, .sheet: return p.surface
        case .tabBar: return Color(hex: 0x6FB3BB)
        }
    }

    var edge: Double { self == .call ? 0.35 : 0.75 }
}

struct SoughtGlass<S: InsettableShape>: ViewModifier {
    var style: GlassStyle
    var shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        let solid = reduceTransparency || p.isHighContrast
        content
            .background {
                if solid {
                    shape.fill(style.solid(p))
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(style.tint(p))
                    }
                }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(solid ? 0 : style.edge), .white.opacity(0.04)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(style == .call ? 0.15 : 0.08), radius: style == .call ? 4 : 10, x: 0, y: style == .call ? 4 : 8)
    }
}

extension View {
    func soughtGlass<S: InsettableShape>(_ style: GlassStyle, in shape: S) -> some View {
        modifier(SoughtGlass(style: style, shape: shape))
    }
}

extension Palette {
    var isHighContrast: Bool { background == Palette.highContrast.background }
}
