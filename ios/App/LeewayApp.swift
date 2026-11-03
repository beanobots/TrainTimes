import SwiftUI

/// The app, where you set up widgets (station, lines, direction).
@main
struct LeewayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    /// Seconds after coming back before work nothing on screen waits for.
    private static let backgroundWorkDelay: Double = 3

    init() {
        // Marks the log's launch, and takes MetricKit's crash and hang reports, sending them
        // for anyone sharing diagnostics
        Diagnostics.shared.start()
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
        // The bundled maps' data decoded now, off the main thread, rather than by the first map
        // to draw it, holding up its screen. Each is decoded once whoever's first. Not when iOS
        // launches the app in the background (a walk's location, a refresh, a push token), with
        // no map to draw
        Task { @MainActor in
            guard UIApplication.shared.applicationState != .background else { return }
            Task.detached(priority: .userInitiated) {
                _ = StationDirectory.all.count
                _ = EquipmentDirectory.all.count
                _ = TrackShapes.byRoute.count
                _ = TrackShapes.byBusLine.count
                _ = TrackShapes.busStops.count
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            AppTabs()
                // DEMO HOOK: remove with WalkDemos.swift
                #if DEBUG
                .task {
                    await WalkDemos.watch()
                }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // One of the few chances a countdown has to get new times
            if phase == .active {
                // Off the train by now if it's due where you get off, as the Lock Screen said
                ActiveWalk.shared.session?.resume()
                Task { await TrainActivityController.refresh() }
                ActivityPush.resume()
                // The timetable to fall back on, if it's a day old, and reports the server couldn't
                // take before: a few seconds on, after the times on screen and the countdown's,
                // not all at once with them on a weak connection
                Task(priority: .utility) {
                    try? await Task.sleep(for: .seconds(Self.backgroundWorkDelay))
                    await TimetableStore.refresh()
                    await Diagnostics.sendPending()
                }
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

/// Told when the app's quit: swiped away in the app switcher while running, as it is following
/// a walk. iOS closing it for memory says nothing, and the walk carries on when it's relaunched.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillTerminate(_ application: UIApplication) {
        MainActor.assumeIsolated { ActiveWalk.shared.quit() }
    }
}
