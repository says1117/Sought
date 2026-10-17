import SwiftUI

@main
struct RecallApp: App {
    @StateObject private var link = DriveLink()
    @StateObject private var pose = PoseTracker()
    @StateObject private var findBar = RecallApp.makeFindBar()
    @Environment(\.scenePhase) private var phase
    @State private var showSelfTest = false
    @State private var showTeach = false
    @State private var showDrive = false

    /// Planner = Gemini when a key is configured, offline keywords otherwise. The executor is a logging
    /// stand-in until the coordinator exists. Robot is treated as stationary until motion state is wired in.
    @MainActor
    private static func makeFindBar() -> FindBarViewModel {
        let talk = PushToTalk(recognizer: AppleSpeechRecognizer(), isStationary: { true })
        return FindBarViewModel(planner: FallbackPlanner.make(), executor: LoggingToolExecutor(),
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
                                Button("Teach (waypoints, map)") { showTeach = true }
                                Button("Self-test") { showSelfTest = true }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "wrench.and.screwdriver")
                                    Text("Fallback tools")
                                }
                                .font(.headline)
                            }
                            .accessibilityLabel("Fallback tools")
                            .accessibilityHint("Manual drive, Teach, and self-test")
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
            .sheet(isPresented: $showTeach) { TeachContainer(link: link, tracker: pose) }
            .sheet(isPresented: $showSelfTest) { SelfTestContainer(link: link, tracker: pose) }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                pose.start()
            }
            .onChange(of: phase) { _, new in
                if new != .active { link.stop(); pose.pause(); findBar.robotMoved() } else { pose.start() }
            }
        }
    }
}
