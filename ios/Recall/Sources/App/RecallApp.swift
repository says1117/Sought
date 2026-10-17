import SwiftUI

@main
struct RecallApp: App {
    @StateObject private var link = DriveLink()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            DriveView(link: link)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
                .onChange(of: phase) { _, new in if new != .active { link.stop() } }
        }
    }
}
