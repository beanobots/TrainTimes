import SwiftUI
import UIKit

/// The app's tabs (Liquid Glass bar on iOS 26): Nearby (trains at nearby stations), Navigate
/// (A to B, for Transit Directions), Routes (widget setup), and Settings.
struct AppTabs: View {
    private enum AppTab: Hashable { case newTrip, live, widgets, settings }

    @State private var store = WidgetStore()
    @State private var settings = SettingsStore()
    /// Navigate, or Nearby when the app was put away on it within the last 10 minutes.
    @State private var tab = AppTabs.nearbyKept ? AppTab.live : AppTab.newTrip
    /// Set by the Nearby widget's "allow location" link, for the Nearby tab to act on.
    @State private var allowingLocation = false
    /// Counts taps on the Nearby tab, picked or already showing, for it to come back to you.
    @State private var nearbyTaps = 0
    /// Which way you last turned Nearby's or Navigate's map, when not Settings' way: shared, so
    /// the other tab's map shows turned the same.
    @State private var keptHeading: Double?
    /// When the Settings tab was last tapped, picked or already showing: 5 in under 2 seconds
    /// shows (or hides again) its secret Prototyping card, for this run of the app only.
    @State private var settingsTaps: [Date] = []
    @State private var showsPrototyping = false
    /// New Trip's picked trip, for its Show on Widget.
    @State private var tripShowing = TripShowing()
    /// A station tapped in Spotlight, set by `OpenStationIntent`.
    @State private var opening = StationOpening.shared
    /// That station, as its picker shows it.
    @State private var openStation: Station?
    /// New Trip's Go: the walk under way, over everything.
    @State private var walk = ActiveWalk.shared
    /// First-run setup's been through or skipped, or wasn't needed: set up before it came.
    @AppStorage(Self.firstRunDoneKey) private var firstRunDone = false
    /// Where `firstRunDone` is kept, for Settings' setup again too.
    static let firstRunDoneKey = "firstRunDone"
    @State private var settingUp = false
    /// A visitor's stay is over: whether to clear their hotel and sights.
    @State private var stayOver = false
    @Environment(\.scenePhase) private var scenePhase
    /// When the app was last put away on Nearby; cleared when put away on any other tab.
    private static let nearbyLeftKey = "nearbyLeftAt"
    /// How long Nearby is kept as the tab the app opens on.
    private static let nearbyKeptFor: TimeInterval = 10 * 60

    var body: some View {
        TabView(selection: Binding(get: { tab }, set: { picked in
            if picked == .live { nearbyTaps += 1 }
            if picked == .settings { tapSettings() }
            tab = picked
        })) {
            Tab("Nearby", systemImage: "circle.inset.filled", value: AppTab.live) {
                LiveView(allowingLocation: $allowingLocation, keptHeading: $keptHeading, recenterRequests: nearbyTaps)
            }
            Tab("Navigate", systemImage: "location.fill", value: AppTab.newTrip) {
                NewTripView(showing: tripShowing, startHeading: $keptHeading)
            }
            Tab("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", value: AppTab.widgets) {
                WidgetsView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView(showsPrototyping: showsPrototyping)
            }
        }
        // Shrinks out of the way while scrolling down Nearby's stations
        .tabBarMinimizeBehavior(.onScrollDown)
        .sensoryFeedback(.success, trigger: showsPrototyping)
        .fullScreenCover(isPresented: $settingUp) {
            FirstRunView {
                store.startFirstRoute(train: settings.defaultTrain, bus: settings.settings.defaultBus)
                firstRunDone = true
                settingUp = false
            }
        }
        // Settings' Run Setup Again clears it: show setup again, which forgets the saved places
        // (and a visit's hotel and sights) as it finishes (`FirstRunAnswers.save`), not now, so
        // the app quit part way through still has them
        .onChange(of: firstRunDone) { _, done in
            guard !done else { return }
            settingUp = true
        }
        .alert("Trip Over?", isPresented: $stayOver) {
            Button("Clear Hotel and Sights", role: .destructive) { VisitStay.clear() }
            Button("Keep Them", role: .cancel) { VisitStay.forget() }
        } message: {
            Text("Your stay's ended. Leeway can forget your hotel and the sights you saved for it.")
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active, !settingUp, VisitStay.isOver { stayOver = true }
            // Settings' Citi Bike kinds, for the widgets; setup may have just set them
            if phase == .active { settings.shareBikeKinds() }
            // Put away on Nearby: back to it within 10 minutes, Navigate after
            if phase == .background {
                if tab == .live {
                    UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.nearbyLeftKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.nearbyLeftKey)
                }
            } else if phase == .active, UserDefaults.standard.object(forKey: Self.nearbyLeftKey) != nil {
                // Back from being put away on it this run (a launch picked its tab already)
                if tab == .live, !Self.nearbyKept, walk.session == nil { tab = .newTrip }
                UserDefaults.standard.removeObject(forKey: Self.nearbyLeftKey)
            }
        }
        .sheet(item: $openStation) { station in
            StationWidgetPicker(station: station)
        }
        // Only End or Done takes it down (`ActiveWalk.end()`), as a cover can't be swiped away
        .fullScreenCover(item: $walk.session) { session in
            WalkingView(session: session) { walk.end() }
        }
        // Under a walk, New Trip, where it came from: Done goes back there, even with the walk
        // restored on a relaunch
        .onChange(of: walk.session != nil, initial: true) { _, walking in
            if walking { tab = .newTrip }
            // Its map's drawn upright: turned back if on its side, and kept so till it's over
            Sideways.lockUpright(walking)
        }
        // Also when the tap launched the app, so it was set before this appeared
        // The bus home stop from Spotlight: Nearby opens it
        .onChange(of: opening.busStop != nil, initial: true) { _, opening in
            if opening { afterSheets { tab = .live } }
        }
        // A Saved Route's button on a widget: Navigate, which plans it. Dropped under a walk or
        // first-run setup, rather than planned later when no longer wanted
        .onChange(of: opening.route != nil, initial: true) { _, opening in
            guard opening else { return }
            guard walk.session == nil, !settingUp else {
                self.opening.route = nil
                return
            }
            afterSheets { tab = .newTrip }
        }
        .onChange(of: opening.station, initial: true) { _, station in
            guard let station else { return }
            opening.station = nil
            afterSheets { openStation = station }
        }
        .environment(store)
        .environment(settings)
        // Start the kept store, not one from a discarded view instance
        .onAppear {
            store.start()
            startFirstRun()
        }
        // The Nearby widget's "allow location" link, handled here so it works from any tab
        .onOpenURL { url in
            guard url == Nearby.allowURL else { return }
            afterSheets {
                tab = .live
                allowingLocation = true
            }
        }
    }

    /// The app was put away on Nearby less than 10 minutes ago.
    private static var nearbyKept: Bool {
        let left = UserDefaults.standard.double(forKey: nearbyLeftKey)
        return left > 0 && Date.now.timeIntervalSince1970 - left < nearbyKeptFor
    }

    /// Counts a Settings tab tap; the fifth within 2 seconds of the first shows or hides
    /// Prototyping, and starts the count again.
    private func tapSettings() {
        let now = Date.now
        settingsTaps = settingsTaps.filter { now.timeIntervalSince($0) < 2 } + [now]
        guard settingsTaps.count >= 5 else { return }
        settingsTaps = []
        withAnimation(.smooth(duration: 0.3)) { showsPrototyping.toggle() }
    }

    /// Shows first-run setup on a new install; not to anyone with a home station or a saved
    /// place already, from before it came.
    private func startFirstRun() {
        guard !firstRunDone else { return }
        if settings.settings.defaultTrain != nil || settings.settings.defaultBus != nil || !SavedPlaces.shared.isEmpty {
            firstRunDone = true
        } else {
            // Already up at launch, not sliding up over the tabs: its splash is the first thing seen
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { settingUp = true }
        }
    }

    /// Runs `show` after dismissing any presented sheet (e.g. the train picker), which would
    /// otherwise block it. Not under a walk or first-run setup, whose covers only End, Done or
    /// finishing take down: dismissed, they'd leave the walk running with no way to end it.
    private func afterSheets(_ show: @escaping () -> Void) {
        guard walk.session == nil, !settingUp else { return }
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
        if let root, root.presentedViewController != nil {
            root.dismiss(animated: true, completion: show)
        } else {
            show()
        }
    }
}

#Preview {
    AppTabs()
}
