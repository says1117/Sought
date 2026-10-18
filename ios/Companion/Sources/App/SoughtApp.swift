import SwiftUI

// Sought: the user-phone app for Soughtbot. Code names stay Companion/Recall; only the display name is Sought.
// Data source: MockRobotSource (SAMPLE DATA) until BackendRobotSource can show real objects (board task T-071).

@main
struct SoughtApp: App {
    @StateObject private var robot: RobotSource = MockRobotSource()
    @StateObject private var router = Router()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(robot)
                .environmentObject(router)
                .environmentObject(settings)
                .onAppear { robot.start(); router.applyLaunchArguments(robot: robot) }
        }
    }
}

/// Keeps every tab alive (scroll position survives) and crossfades between them.
struct TabContainer: View {
    let selection: AppTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("homeV1") private var homeV1 = false

    var body: some View {
        ZStack {
            ForEach(AppTab.allCases) { tab in
                let on = tab == selection
                page(tab)
                    .opacity(on ? 1 : 0)
                    .offset(y: on || reduceMotion ? 0 : 8)
                    .allowsHitTesting(on)
                    .accessibilityHidden(!on)
            }
        }
        .animation(reduceMotion ? Motion.fade : Motion.spring, value: selection)
    }

    @ViewBuilder private func page(_ t: AppTab) -> some View {
        switch t {
        case .home: if homeV1 { HomeViewClassic() } else { HomeView() }
        case .map: MapScreen()
        case .items: ItemLogView()
        case .settings: SettingsScreen()
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var settings: AppSettings
    @State private var lastSpokenState: RobotState?

    private var palette: Palette { settings.highContrast ? .highContrast : .standard }
    private var mood: BackgroundMood {
        BackgroundMood(tab: router.tab, state: robot.status.state, online: robot.status.isOnline(now: robot.now))
    }

    var body: some View {
        TabContainer(selection: router.tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SoughtBackground())
            .safeAreaInset(edge: .bottom, spacing: 0) { SoughtTabBar(selection: $router.tab) }
        .environment(\.palette, palette)
        .environment(\.backgroundMood, mood)
        .preferredColorScheme(settings.highContrast ? .dark : .light)
        .tint(palette.text)
        .sheet(item: $router.detail) { o in
            ItemDetailView(itemId: o.id).background(SoughtBackground()).environment(\.palette, palette).environment(\.backgroundMood, mood).presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $router.findRequest) { r in
            FindFlowView(request: r).background(SoughtBackground()).environment(\.palette, palette).environment(\.backgroundMood, mood)
        }
        .onChange(of: robot.status.state) { _, s in announce(s) }
        .onChange(of: settings.haptics) { _, v in Haptics.shared.enabled = v }
        .onAppear { Haptics.shared.enabled = settings.haptics }
    }

    /// Announce status changes that matter (plan section 7). Roaming and resting flip often, so they stay quiet.
    private func announce(_ s: RobotState) {
        guard s != lastSpokenState else { return }
        lastSpokenState = s
        switch s {
        case .blocked, .error, .comingToUser:
            UIAccessibility.post(notification: .announcement, argument: StatusCopy.spoken(robot.status, now: robot.now))
        default: break
        }
    }
}
