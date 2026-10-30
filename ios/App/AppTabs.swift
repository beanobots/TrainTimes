import SwiftUI
import UIKit

/// The app's tabs (Liquid Glass bar on iOS 26): New Trip (A to B, for Transit Directions), Nearby
/// (trains at nearby stations), Widgets (setup), and Settings.
struct AppTabs: View {
    private enum AppTab: Hashable { case newTrip, live, widgets, settings }

    @State private var store = WidgetStore()
    @State private var settings = SettingsStore()
    @State private var tab = AppTab.live
    /// Set by the Nearby widget's "allow location" link, for the Nearby tab to act on.
    @State private var allowingLocation = false
    /// New Trip's picked trip, for its Show on Widget.
    @State private var tripShowing = TripShowing()
    /// A station tapped in Spotlight, set by `OpenStationIntent`.
    @State private var opening = StationOpening.shared
    /// That station, as its picker shows it.
    @State private var openStation: Station?
    /// New Trip's Go: the walk under way, over everything.
    @State private var walk = ActiveWalk.shared
    /// First-run setup's been through or skipped, or wasn't needed: set up before it came.
    @AppStorage("firstRunDone") private var firstRunDone = false
    @State private var settingUp = false
    /// A visitor's stay is over: whether to clear their hotel and sights.
    @State private var stayOver = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $tab) {
            Tab("New Trip", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", value: AppTab.newTrip) {
                NewTripView(showing: tripShowing)
            }
            Tab("Nearby", systemImage: "location.fill", value: AppTab.live) {
                LiveView(allowingLocation: $allowingLocation)
            }
            Tab("Widgets", systemImage: "app", value: AppTab.widgets) {
                WidgetsView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        // Shrinks out of the way while scrolling down Nearby's stations
        .tabBarMinimizeBehavior(.onScrollDown)
        .fullScreenCover(isPresented: $settingUp) {
            FirstRunView {
                firstRunDone = true
                settingUp = false
            }
        }
        // Settings' Run Setup Again clears it: show setup again, the saved places (and a visit's
        // hotel and sights) forgotten for it to set afresh
        .onChange(of: firstRunDone) { _, done in
            guard !done else { return }
            VisitStay.clear()
            SavedPlaces.shared.clear()
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
        }
        .sheet(item: $openStation) { station in
            StationWidgetPicker(station: station)
        }
        // Only End or Done takes it down (`ActiveWalk.end()`), as a cover can't be swiped away
        .fullScreenCover(item: $walk.session) { session in
            WalkingView(session: session) { walk.end() }
        }
        // Under a walk, New Trip, where it came from: Done goes back there, even with the walk
        // restored on a relaunch, which opens on Nearby
        .onChange(of: walk.session != nil, initial: true) { _, walking in
            if walking { tab = .newTrip }
        }
        // Also when the tap launched the app, so it was set before this appeared
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

    /// Shows first-run setup on a new install; not to anyone with a home station or a saved
    /// place already, from before it came.
    private func startFirstRun() {
        guard !firstRunDone else { return }
        if settings.settings.defaultTrain != nil || !SavedPlaces.shared.isEmpty {
            firstRunDone = true
        } else {
            settingUp = true
        }
    }

    /// Runs `show` after dismissing any presented sheet (e.g. the train picker), which would
    /// otherwise block it.
    private func afterSheets(_ show: @escaping () -> Void) {
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
