import SwiftUI

/// The app, where you set up widgets (station, lines, direction).
@main
struct RTrainApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Alerts and outages fetched by the widgets, and theirs by them (`TrainService.sharedCache`)
        TrainService.sharedCache = SharedStore.FeedCache()
        // Also when iOS launches the app in the background with a countdown's new push token
        Task { @MainActor in ActivityPush.resume() }
        // The alternate icons are gone: back to the only one for anyone who'd picked one
        Task { @MainActor in
            if UIApplication.shared.alternateIconName != nil {
                try? await UIApplication.shared.setAlternateIconName(nil)
            }
        }
        // Every station in Spotlight, once per build
        Task(priority: .utility) { await SpotlightStation.indexIfNeeded() }
    }

    var body: some Scene {
        WindowGroup {
            AppTabs()
        }
        .onChange(of: scenePhase) { _, phase in
            // One of the few chances a countdown has to get new times
            if phase == .active {
                Task { await TrainActivityController.refresh() }
                ActivityPush.resume()
                // The timetable to fall back on, if it's a day old
                Task { await TimetableStore.refresh() }
            } else if phase == .background {
                // While the push server doesn't have a countdown, refresh it in the background
                ActivityPush.scheduleRefreshIfNeeded()
                TimetableStore.scheduleRefresh()
            }
        }
        .backgroundTask(.appRefresh(ActivityPush.refreshTaskID)) {
            await ActivityPush.backgroundRefresh()
        }
        .backgroundTask(.appRefresh(TimetableStore.refreshTaskID)) {
            await TimetableStore.backgroundRefresh()
        }
    }
}
