import SwiftUI

@main
struct RecallApp: App {
    @StateObject private var link = DriveLink()
    @StateObject private var pose = PoseTracker()
    @Environment(\.scenePhase) private var phase
    @State private var showSelfTest = false
    @State private var showTeach = false

    var body: some Scene {
        WindowGroup {
            DriveView(link: link)
                .overlay(alignment: .topTrailing) { PoseOverlay(tracker: pose).padding(8) }
                .overlay(alignment: .topLeading) {
                    Button("Self-test") { showSelfTest = true }.buttonStyle(.bordered).padding(8)
                }
                .overlay(alignment: .bottomTrailing) { FallbackToolsMenu { showTeach = true }.padding(8) }
                .sheet(isPresented: $showTeach) { TeachContainer(link: link, tracker: pose) }
                .sheet(isPresented: $showSelfTest) { SelfTestContainer(link: link, tracker: pose) }
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    startPoseSession()
                }
                .onChange(of: phase) { _, new in
                    if new != .active { link.stop(); pose.pause() } else { startPoseSession() }
                }
        }
    }

    private func startPoseSession() {
        let mapAdapter = ARWorldMapAdapter(tracker: pose)
        pose.start(initialWorldMap: mapAdapter.initialWorldMap)
    }
}
