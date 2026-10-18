import SwiftUI

// Glass tab bar from the Figma: a pill on an opaque teal band, four icons split by thin white rules.

enum AppTab: String, CaseIterable, Identifiable {
    case home, map, items, settings
    var id: String { rawValue }
    var icon: String { "tab_\(rawValue)" }
    var title: String {
        switch self { case .home: "Home"; case .map: "Map"; case .items: "Item Log"; case .settings: "Settings" }
    }
}

struct SoughtTabBar: View {
    @Binding var selection: AppTab
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { i, tab in
                if i > 0 { Rectangle().fill(p.textOnDark).frame(width: 1, height: 28).accessibilityHidden(true) }
                Button {
                    selection = tab
                    Haptics.shared.tap()
                } label: {
                    Image(tab.icon).renderingMode(.template).resizable().frame(width: 28, height: 28)
                        .foregroundStyle(p.textOnDark)
                        .opacity(selection == tab ? 1 : 0.72)
                        .padding(6)
                        .background(Circle().fill(selection == tab ? p.textOnDark.opacity(0.22) : .clear))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, 9)
        .soughtGlass(.tabBar, in: Capsule())
        .padding(.horizontal, Space.margin)
        .padding(.top, Space.m)
        .padding(.bottom, Space.xs)
        // Opaque band: content never shows through behind the bar (contrast). Starts at the background's bottom
        // color so the seam is invisible, then deepens to the Figma teal.
        .background {
            LinearGradient(stops: [.init(color: p.isHighContrast ? p.background : Color(hex: 0xCDE1E7), location: 0),
                                   .init(color: p.tabGradientBottom, location: 0.58)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
    }
}
