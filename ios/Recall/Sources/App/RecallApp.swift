import SwiftUI

@main
struct RecallApp: App {
    @StateObject private var link = DriveLink()
    @StateObject private var pose = PoseTracker()
    @Environment(\.scenePhase) private var phase
    @State private var showSelfTest = false

    var body: some Scene {
        WindowGroup {
            DriveView(link: link)
                .overlay(alignment: .topTrailing) { PoseOverlay(tracker: pose).padding(8) }
                .overlay(alignment: .topLeading) {
                    Button("Self-test") { showSelfTest = true }.buttonStyle(.bordered).padding(8)
                }
                .sheet(isPresented: $showSelfTest) { SelfTestContainer(link: link, tracker: pose) }
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    pose.start()
                }
                .onChange(of: phase) { _, new in
                    if new != .active { link.stop(); pose.pause() } else { pose.start() }
                }
        }
    }
}
