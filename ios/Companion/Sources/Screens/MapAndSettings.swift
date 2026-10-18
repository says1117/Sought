import SwiftUI

// Map tab and Settings tab. The Figma frames for these are still empty, so they reuse the Home language.

struct MapScreen: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var router: Router
    @Environment(\.palette) private var p
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SampleBanner()
            ScreenHeader(title: "Map")
            if let map = robot.map {
                let b = map.bounds
                let aspect = max(0.4, min(2.5, (b.maxZ - b.minZ) / max(0.1, b.maxX - b.minX)))
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        MapCanvas(map: map, robot: robot.status.pose, pins: robot.objects,
                                  active: robot.status.isOnline(now: robot.now) && robot.status.state != .idle,
                                  onPin: router.open)
                            .frame(width: geo.size.width * zoom * pinch, height: geo.size.width * aspect * zoom * pinch)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1 / aspect, contentMode: .fit)
                .background(p.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .softShadow()
                .gesture(MagnificationGesture().updating($pinch) { v, s, _ in s = v }.onEnded { zoom = max(1, min(3, zoom * $0)) })
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Floor map with \(robot.objects.count) items")
                HStack(spacing: Space.l) {
                    legend(Circle().fill(p.mapPath).frame(width: 12, height: 12), "Soughtbot")
                    legend(Circle().fill(p.primary).frame(width: 12, height: 12).overlay(Circle().stroke(p.surface, lineWidth: 2)), "Item photo")
                    legend(Circle().stroke(p.mapPath.opacity(0.4), lineWidth: 2).frame(width: 9, height: 9), "Taught spot")
                    Spacer()
                    if zoom > 1 { Button("Reset") { withAnimation { zoom = 1 } }.font(SoughtFont.findIt).foregroundStyle(p.text) }
                }
                .font(SoughtFont.cardMeta).foregroundStyle(p.text)
                Text("Map updated \(StatusCopy.ago(map.updatedAt, now: robot.now)). Tap a pin for the item.")
                    .font(SoughtFont.cardMeta).foregroundStyle(p.text)
            } else {
                Spacer()
                Text("No map yet").font(SoughtFont.sectionTitle).foregroundStyle(p.sectionTitle)
                Text("Soughtbot draws the map as it learns the room. Start a Teach walk on the robot phone.")
                    .font(SoughtFont.body).foregroundStyle(p.text)
                Spacer()
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.top, Space.l)
        .padding(.bottom, Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
    }

    private func legend<V: View>(_ mark: V, _ text: String) -> some View {
        HStack(spacing: 6) { mark.accessibilityHidden(true); Text(text) }
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.palette) private var p
    @State private var showComeToMeTest = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Data", value: robot.sourceName)
                    LabeledContent("Status", value: StatusCopy.line(robot.status, now: robot.now))
                    if robot.isSample {
                        Text("Sought is showing sample data. Real items appear once Soughtbot shares what it has seen.")
                            .font(SoughtFont.cardMeta)
                    }
                } header: { Text("Soughtbot") }
                .listRowBackground(p.surface)

                Section {
                    TextField("Your name", text: $settings.userName).textContentType(.givenName)
                } header: { Text("You") }
                .listRowBackground(p.surface)

                Section {
                    Toggle("High contrast", isOn: $settings.highContrast)
                    Toggle("Speak updates", isOn: $settings.voiceFeedback)
                    Toggle("Haptics while guiding", isOn: $settings.haptics)
                } header: { Text("Seeing and hearing") } footer: {
                    Text("Sought also follows your iPhone's text size, Reduce Motion and Reduce Transparency settings.")
                }
                .listRowBackground(p.surface)

                Section {
                    Text("Video and Soughtbot's memory of your home stay on your devices. Only item photos, names, positions and status are shared with this app.")
                    Text("Sample data is always labeled. Nothing in Sought pretends to be live when it is not.")
                } header: { Text("Privacy") }
                .listRowBackground(p.surface)

                Section {
                    Button("Come to me test (two iPhones)") { showComeToMeTest = true }
                } header: { Text("For testing") } footer: {
                    Text("Ultra Wideband distance test from the original companion app. Needs the robot phone nearby.")
                }
                .listRowBackground(p.surface)
            }
            .font(SoughtFont.body)
            .foregroundStyle(p.text)
            .environment(\.defaultMinListRowHeight, 48)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading, spacing: Space.s) {
                    SampleBanner()
                    ScreenHeader(title: "Settings")
                }
                .padding(.horizontal, Space.margin).padding(.top, Space.l)
            }
            
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showComeToMeTest) { ComeToMeTestView() }
        }
    }
}
