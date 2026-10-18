import SwiftUI

// Settings tab. The Figma frame is still empty, so it reuses the Home language.

struct SettingsScreen: View {
    @EnvironmentObject private var robot: RobotSource
    @EnvironmentObject private var sources: SourceHolder
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.palette) private var p
    @State private var showComeToMeTest = false
    @AppStorage("useSampleData") private var useSample = false
    @AppStorage("showTouches") private var showTouches = false
    @AppStorage("backendURL") private var backendURL = ""
    @State private var token = Keychain.read("backendToken") ?? ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Data", value: robot.sourceName)
                    LabeledContent("Status", value: StatusCopy.line(robot.status, now: robot.now))
                    if let b = robot as? BackendRobotSource, let problem = b.connectionProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(SoughtFont.cardMeta).foregroundStyle(p.text)
                    }
                    if robot.isSample {
                        Text("Sought is showing sample data. Real items appear once Soughtbot shares what it has seen.")
                            .font(SoughtFont.cardMeta)
                    }
                } header: { Text("Soughtbot").foregroundStyle(p.text) }
                .listRowBackground(p.surface)

                Section {
                    Toggle("Use sample data", isOn: $useSample)
                        .onChange(of: useSample) { _, _ in sources.reload() }
                    if !useSample {
                        TextField("Server address", text: $backendURL, prompt: Text("https://…"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        SecureField("Token", text: $token)
                        Button("Connect") {
                            Keychain.write("backendToken", token)
                            sources.reload()
                        }
                        .disabled(BackendConfig.clean(backendURL) == nil && BackendConfig.current() == nil)
                    }
                } header: { Text("Connection").foregroundStyle(p.text) } footer: {
                    Text("Sought reads Soughtbot\u{2019}s status, items and map from its server. The token is kept in this iPhone\u{2019}s Keychain.")
                }
                .listRowBackground(p.surface)

                Section {
                    TextField("Your name", text: $settings.userName).textContentType(.givenName)
                } header: { Text("You").foregroundStyle(p.text) }
                .listRowBackground(p.surface)

                Section {
                    Toggle("High contrast", isOn: $settings.highContrast)
                    Toggle("Speak updates", isOn: $settings.voiceFeedback)
                    Toggle("Haptics while guiding", isOn: $settings.haptics)
                } header: { Text("Seeing and hearing").foregroundStyle(p.text) } footer: {
                    Text("Sought also follows your iPhone's text size, Reduce Motion and Reduce Transparency settings.")
                }
                .listRowBackground(p.surface)

                Section {
                    Text("Video and Soughtbot's memory of your home stay on your devices. Only item photos, names, positions and status are shared with this app.")
                    Text("Sample data is always labeled. Nothing in Sought pretends to be live when it is not.")
                } header: { Text("Privacy").foregroundStyle(p.text) }
                .listRowBackground(p.surface)

                Section {
                    Toggle("Show touches (for recording)", isOn: $showTouches)
                        .onChange(of: showTouches) { _, on in if on { TouchIndicators.installIfRequested() } }
                    Button("Come to me test (two iPhones)") { showComeToMeTest = true }
                } header: { Text("For testing").foregroundStyle(p.text) } footer: {
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
