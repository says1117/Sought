import SwiftUI

@main
struct CompanionApp: App {
    @StateObject private var model = CompanionModel()
    var body: some Scene {
        WindowGroup { ContentView(model: model).onAppear { model.start() } }
    }
}
