import SwiftUI

/// The app, where you set up widgets (station, lines, direction).
@main
struct LeewayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    /// Seconds after coming back before work nothing on screen waits for.
    private static let backgroundWorkDelay: Double = 3

    init() {
        #if DEBUG
        // Hosting unit tests: none of the launch's own work, so what's measured is the tests'
        guard !TestHost.isUnitTesting else { return }
        // UI tests (-UITest): saved feeds, a pretend place and time, no real servers
        UITestLaunch.start()
        #endif
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
        #if DEBUG
        // TEMP: -VoiceTest says some walking instructions at launch, timed in the log (WalkVoice)
        if ProcessInfo.processInfo.arguments.contains("-VoiceTest") {
            Task { @MainActor in await WalkVoice.test() }
        }
        #endif
        // The alternate icons are gone: back to the only one for anyone who'd picked one
        Task { @MainActor in
            if UIApplication.shared.alternateIconName != nil {
                try? await UIApplication.shared.setAlternateIconName(nil)
            }
        }
        // Every station in Spotlight, once per build
        Task(priority: .utility) {
            await SpotlightStation.indexIfNeeded()
            await SpotlightBusStop.indexHome()
        }
        // The bundled maps' data decoded now, off the main thread, rather than by the first map
        // to draw it, holding up its screen. Each is decoded once whoever's first. Not when iOS
        // launches the app in the background (a walk's location, a refresh, a push token), with
        // no map to draw. Started straight away, not after a turn of the main thread, which
        // Nearby's first map would beat: the small ones first, which Nearby waits on, whatever
        // the launch. Then, launched to be seen, the whole subway's lines, which Nearby draws
        // once they're laid out, and the bus routes last, for the stop and route pickers. Asked
        // only now, after a turn of the main thread: in `init`, before its window's scene has
        // connected, the app reads as in the background however it's launched
        Task.detached(priority: .userInitiated) {
            _ = StationDirectory.all.count
            _ = TrackShapes.busStops.count
            guard await UIApplication.shared.applicationState != .background else { return }
            _ = EquipmentDirectory.all.count
            _ = TrackShapes.byRoute.count
            _ = NearbyLines.allTracks.count
            _ = BusNetwork.byLine.count
            _ = BusRoutes.allStops.count
            _ = BusRoutes.stopByCode.count
            _ = BusRoutes.linesAtStop.count
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if TestHost.isUnitTesting { Color.clear } else { AppTabs() }
            #else
            AppTabs()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            guard !TestHost.isUnitTesting else { return }
            #endif
            // One of the few chances a countdown has to get new times
            if phase == .active {
                // Located again if it was stopped while out of sight
                ActiveWalk.shared.session?.seenAgain()
                // Off the train by now if it's due where you get off, as the Lock Screen said
                ActiveWalk.shared.session?.resume()
                // Not those the push server's keeping up
                Task { await TrainActivityController.refresh(pushedLeftAlone: true, retryingPush: false) }
                ActivityPush.resume()
                // The timetable to fall back on, if it's a day old, and reports the server couldn't
                // take before: a few seconds on, after the times on screen and the countdown's,
                // not all at once with them on a weak connection
                Task(priority: .utility) {
                    try? await Task.sleep(for: .seconds(Self.backgroundWorkDelay))
                    await TimetableStore.refreshAll()
                    await Diagnostics.sendPending(retrying: true)
                }
            } else if phase == .background {
                // No location in the background for a walk that's done, or off the Lock Screen
                ActiveWalk.shared.session?.leftUnseen()
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

    /// Upright under a walk, else on its side too (`Sideways`).
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Sideways.orientations }
    }
}
