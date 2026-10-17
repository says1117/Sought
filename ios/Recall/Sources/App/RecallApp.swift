import SwiftUI

@main
struct RecallApp: App {
    @StateObject private var link: DriveLink
    @StateObject private var pose: PoseTracker
    @StateObject private var findBar: FindBarViewModel
    @Environment(\.scenePhase) private var phase
    @State private var showSelfTest = false
    @State private var showDrive = false

    init() {
        let link = DriveLink()
        let pose = PoseTracker()
        _link = StateObject(wrappedValue: link)
        _pose = StateObject(wrappedValue: pose)
        _findBar = StateObject(wrappedValue: Self.makeFindBar(link: link))
    }

    /// Planner = Gemini when a key is configured, offline keywords otherwise. The tool executor remains
    /// a logging stand-in until the coordinator exists; STOP and speech gating use live DriveLink state.
    @MainActor
    private static func makeFindBar(link: DriveLink) -> FindBarViewModel {
        let talk = PushToTalk(recognizer: AppleSpeechRecognizer(), isStationary: {
            link.isRobotStationary
        })
        return FindBarViewModel(planner: FallbackPlanner.make(), executor: LoggingToolExecutor(stop: { link.stop() }),
                                speaker: AppleSpeaker(), talk: talk)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                FindBarView(model: findBar)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("Manual drive") { showDrive = true }
                                Button("Self-test") { showSelfTest = true }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "wrench.and.screwdriver")
                                    Text("Fallback tools")
                                }
                                .font(.headline)
                            }
                            .accessibilityLabel("Fallback tools")
                            .accessibilityHint("Manual drive and self-test")
                        }
                    }
                    .navigationBarTitleDisplayMode(.inline)
            }
            .sheet(isPresented: $showDrive) {
                NavigationStack {
                    DriveView(link: link)
                        .overlay(alignment: .topTrailing) { PoseOverlay(tracker: pose).padding(8) }
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { link.stop(); showDrive = false } } }
                }
            }
            .sheet(isPresented: $showSelfTest) { SelfTestContainer(link: link, tracker: pose) }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                pose.start()
            }
            .onChange(of: phase) { _, new in
                if new == .active {
                    pose.start()
                } else {
                    link.stop()
                    pose.pause()
                    // The speech permission dialog can briefly make the scene inactive.
                    if new == .background || findBar.state != .starting {
                        findBar.stop(speakConfirmation: false)
                    }
                }
            }
        }
    }
}
