import SwiftUI

@main
struct RecallApp: App {
    @StateObject private var link: DriveLink
    @StateObject private var pose: PoseTracker
    @StateObject private var runtime: AppRuntime
    @StateObject private var findBar: FindBarViewModel
    @Environment(\.scenePhase) private var phase
    @State private var showSelfTest = false
    @State private var showTeach = false
    @State private var showDrive = false
    @State private var showRobotTools = false

    init() {
        let link = DriveLink()
        let pose = PoseTracker()
        _link = StateObject(wrappedValue: link)
        _pose = StateObject(wrappedValue: pose)
        let runtime = AppRuntime(link: link, pose: pose)
        _runtime = StateObject(wrappedValue: runtime)
        _findBar = StateObject(wrappedValue: Self.makeFindBar(link: link, runtime: runtime))
    }

    /// Planner = Gemini when a key is configured, offline keywords otherwise. Tool calls run on the real
    /// RobotCoordinator; STOP and speech gating use live DriveLink state.
    @MainActor
    private static func makeFindBar(link: DriveLink, runtime: AppRuntime) -> FindBarViewModel {
        let talk = PushToTalk(recognizer: AppleSpeechRecognizer(), isStationary: {
            link.isRobotStationary
        })
        return FindBarViewModel(planner: FallbackPlanner.make(), executor: runtime.coordinator,
                                speaker: runtime.speaker, talk: talk, context: { runtime.plannerContext() })
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                FindBarView(model: findBar, robotStatus: runtime.statusLine)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("Manual drive") { runtime.beginManualControl("drive"); showDrive = true }
                                Button("Teach (waypoints, map)") { runtime.beginManualControl("teach"); showTeach = true }
                                Button("Robot tools") { runtime.beginManualControl("robot-tools"); showRobotTools = true }
                                Button("Self-test") { runtime.beginManualControl("selftest"); showSelfTest = true }
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
            .sheet(isPresented: $showDrive, onDismiss: { runtime.endManualControl("drive") }) {
                NavigationStack {
                    DriveView(link: link)
                        .overlay(alignment: .topTrailing) { PoseOverlay(tracker: pose).padding(8) }
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { link.stop(); showDrive = false } } }
                }
            }
            .sheet(isPresented: $showTeach, onDismiss: { runtime.endManualControl("teach") }) { TeachContainer(link: link, tracker: pose) }
            .sheet(isPresented: $showRobotTools, onDismiss: { runtime.endManualControl("robot-tools") }) {
                NavigationStack { RobotToolsView(runtime: runtime) { showRobotTools = false } }
            }
            .sheet(isPresented: $showSelfTest, onDismiss: { runtime.endManualControl("selftest") }) { SelfTestContainer(link: link, tracker: pose) }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                startPoseSession()
                runtime.start()
            }
            .onChange(of: phase) { _, new in
                if new == .active {
                    startPoseSession()
                    runtime.start()
                } else {
                    runtime.pause()          // brakes, cancels the coordinator task, stops the heartbeat
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

    private func startPoseSession() {
        let mapAdapter = ARWorldMapAdapter(tracker: pose)
        pose.start(initialWorldMap: mapAdapter.initialWorldMap)
    }
}
