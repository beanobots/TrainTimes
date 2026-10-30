import SwiftUI

/// The app, where you set up widgets (station, lines, direction).
@main
struct LeewayApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Alerts and outages fetched by the widgets, and theirs by them (`TrainService.sharedCache`)
        TrainService.sharedCache = SharedStore.FeedCache()
        // Also when iOS launches the app in the background with a countdown's new push token
        Task { @MainActor in ActivityPush.resume() }
        // A tap on the reminder to leave, from first-run setup, starts the countdown
        LeaveReminder.install()
        // A walk from Go that iOS closed the app during: carried on straight away, as iOS asks
        // of an app relaunched in the background for the location it was following
        Task { @MainActor in ActiveWalk.shared.restore() }
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
                // Off the train by now if it's due where you get off, as the Lock Screen said
                ActiveWalk.shared.session?.resume()
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
