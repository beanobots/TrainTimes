import SwiftUI

/// The app is where you choose the station, lines and direction the widget shows.
@main
struct RTrainApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // Opening the app is one of the few times a countdown can get new times
            if phase == .active {
                Task { await TrainActivityController.refresh() }
            }
        }
    }
}
