import SwiftUI

// Hero transitions: a tapped photo or search bar zooms into the screen it opens (iOS 18 zoom transition).
// On iOS 17, or with Reduce Motion on, screens use the system default presentation instead.
// Source ids are unique per place on screen ("home-obj_x", "Essentials-obj_x", "search-home"), because the same
// item can appear in several rows and every tab stays alive in the background.

private struct HeroNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var heroNamespace: Namespace.ID? {
        get { self[HeroNamespaceKey.self] }
        set { self[HeroNamespaceKey.self] = newValue }
    }
}

private struct HeroSource: ViewModifier {
    let id: String
    var radius: CGFloat
    @Environment(\.heroNamespace) private var ns

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let ns {
            content.matchedTransitionSource(id: id, in: ns) { $0.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)) }
        } else {
            content
        }
    }
}

private struct HeroDestination: ViewModifier {
    let id: String?
    @Environment(\.heroNamespace) private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let ns, let id, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            content
        }
    }
}

extension View {
    func heroSource(_ id: String, radius: CGFloat = Radius.photo) -> some View { modifier(HeroSource(id: id, radius: radius)) }
    func heroDestination(_ id: String?) -> some View { modifier(HeroDestination(id: id)) }
}

/// Shimmering placeholder while the first data arrives. Holds still under Reduce Motion.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { g in
                        LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: g.size.width * 0.6)
                            .offset(x: phase * g.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// Card-shaped placeholder that matches ItemCard.
struct SkeletonCard: View {
    var width: CGFloat = 169
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            RoundedRectangle(cornerRadius: Radius.photo, style: .continuous).fill(p.surface.opacity(0.7))
                .frame(width: width, height: width * 141 / 169)
            Capsule().fill(p.surface.opacity(0.7)).frame(width: width * 0.6, height: 10)
            Capsule().fill(p.surface.opacity(0.55)).frame(width: width * 0.85, height: 10)
            Capsule().fill(p.surface.opacity(0.7)).frame(width: width - 11, height: 22)
        }
        .shimmer()
        .accessibilityHidden(true)
    }
}
