import SwiftUI

// Home, redesign (Isaac, 2026-10-17). Search is the hero: it sits under the greeting and pins to the top as a glass
// bar while the rest scrolls under it. Then the map, the Figma card grid (glass Call + glass Activity | tall Live View),
// and Recent Finds with names. VoiceOver order follows the layout, so search comes first without sort hacks.

struct HomeView: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.palette) private var p
    @State private var query = ""
    @State private var showActivity = false
    @State private var showLive = false
    @State private var pinned = false

    var body: some View {
        GeometryReader { geo in
            let col = max(140, (geo.size.width - Space.margin * 2 - Space.l) / 2)
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.l, pinnedViews: [.sectionHeaders]) {
                    greeting
                    Section {
                        MapWidget()
                            .onTapGesture { router.tab = .map }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Double tap to open the map.")
                        HStack(alignment: .top, spacing: Space.l) {
                            VStack(spacing: Space.l) {
                                CallCard().frame(width: col)
                                ActivityCard { showActivity = true }.frame(width: col)
                            }
                            LiveViewCard { showLive = true }.frame(width: col, height: 87 + Space.l + 147)
                        }
                        recentFinds(col: col).id("recent")
                    } header: {
                        searchHeader
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.xl)
            }
            .coordinateSpace(name: "home")
            .scrollDismissesKeyboard(.interactively)
            .task {   // screenshot hook: launch with `-homeScrolled YES`
                guard UserDefaults.standard.bool(forKey: "homeScrolled") else { return }
                try? await Task.sleep(nanoseconds: 600_000_000)
                proxy.scrollTo("recent", anchor: .bottom)
            }
            }
        }
        .sheet(isPresented: $showActivity) { ActivitySheet().presentationDetents([.medium, .large]) }
        .fullScreenCover(isPresented: $showLive) { LiveViewScreen() }
    }

    // MARK: Pieces

    private var greeting: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    SampleBanner().fixedSize()
                    Spacer(minLength: Space.s)
                    StatusPill()
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    SampleBanner().fixedSize()
                    StatusPill(singleLine: false)
                }
            }
            Text("Welcome \(settings.userName)").font(SoughtFont.screenTitle).foregroundStyle(p.title)
                .accessibilityAddTraits(.isHeader)
            Text("What are we seeking today?").font(SoughtFont.largeTitle).foregroundStyle(p.text)
                .accessibilityHidden(true)   // the search field's label says the same thing
        }
        .padding(.top, Space.l)
    }

    /// Pinned header. A wash of the page color sits behind the glass bar once it pins, so scrolled content
    /// under it is softened rather than fighting the placeholder text.
    private var searchHeader: some View {
        SearchBar(text: $query, placeholder: "Find my charger", hero: true) { q in
            router.search(q, in: robot)
            query = ""
        }
        .padding(.vertical, Space.s)
        .background(alignment: .top) {
            GeometryReader { g in
                let y = g.frame(in: .named("home")).minY
                Color.clear
                    .onAppear { pinned = y <= 1 }
                    .onChange(of: y <= 1) { _, now in pinned = now }
            }
        }
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color(hex: 0xDFEEF1, alpha: 0.7))
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(.horizontal, -Space.margin)
                .padding(.top, -200)            // reaches up under the status bar
                .opacity(pinned ? 1 : 0)
                .animation(Motion.quick, value: pinned)
        }
    }

    private func recentFinds(col: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Recent Finds").font(SoughtFont.sectionTitle).foregroundStyle(p.sectionTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("See all") { router.tab = .items }
                    .font(SoughtFont.findIt).foregroundStyle(p.text).frame(minHeight: 44)
            }
            if robot.recentFinds.isEmpty {
                Text("Soughtbot has not found anything yet. Items appear here once it has looked around.")
                    .font(SoughtFont.body).foregroundStyle(p.text)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Space.l) {
                        ForEach(robot.recentFinds.prefix(8)) { o in
                            ItemCard(item: o, width: col, onFind: router.find, onOpen: router.open)
                        }
                    }
                    .padding(.vertical, Space.s)
                    .padding(.horizontal, Space.margin)
                }
                .padding(.horizontal, -Space.margin)
            }
        }
    }
}

/// Status line as a small glass pill (top right of Home).
struct StatusPill: View {
    var singleLine = true
    @EnvironmentObject private var robot: RobotSource
    var body: some View {
        StatusLine(singleLine: singleLine)
            .padding(.horizontal, Space.m)
            .padding(.vertical, 6)
            .soughtGlass(.pill, in: Capsule())
            .contentTransition(.opacity)
            .animation(Motion.fade, value: robot.status.state)
    }
}
