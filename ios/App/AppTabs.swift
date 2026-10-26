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
        .sheet(item: $openStation) { station in
            StationWidgetPicker(station: station)
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
        .onAppear { store.start() }
        // The Nearby widget's "allow location" link, handled here so it works from any tab
        .onOpenURL { url in
            guard url == Nearby.allowURL else { return }
            afterSheets {
                tab = .live
                allowingLocation = true
            }
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
