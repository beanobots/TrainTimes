import SwiftUI

/// The app is where you set up the widgets: each one's station, lines and direction.
@main
struct RTrainApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppTabs()
        }
        .onChange(of: scenePhase) { _, phase in
            // Opening the app is one of the few times a countdown can get new times
            if phase == .active {
                Task { await TrainActivityController.refresh() }
            }
        }
    }
}
