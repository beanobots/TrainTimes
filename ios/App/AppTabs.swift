import SwiftUI
import UIKit

/// The app's three tabs, in a Liquid Glass tab bar on iOS 26: Live, for your
/// favorites' trains and those near you; Widgets, to set widgets up; and Settings.
struct AppTabs: View {
    private enum AppTab: Hashable { case live, widgets, settings }

    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WidgetStore()
    @State private var favorites = FavoritesStore()
    @State private var settings = SettingsStore()
    @State private var tab = AppTab.live
    /// A train whose alerts show in full, after "More ›" on a widget.
    @State private var alertsTrain: AlertsSheet.Train?
    /// What a tap on the Nearby widget opens in the Live tab.
    @State private var liveOpening: LiveOpening?

    var body: some View {
        TabView(selection: $tab) {
            LiveView(opening: $liveOpening)
                .tabItem { Label("Live", systemImage: "bolt.fill") }
                .tag(AppTab.live)
            WidgetsView()
                .tabItem { Label("Widgets", systemImage: "app") }
                .tag(AppTab.widgets)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .environment(store)
        .environment(favorites)
        .environment(settings)
        .sheet(item: $alertsTrain) { train in
            AlertsSheet(selection: train.selection)
        }
        // The icon is the default widget's line: when that changes, and each
        // time the app opens, in case it couldn't change before
        .onChange(of: store.defaultWidget.selection.firstRoute) { _, route in
            AppIcon.show(route)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { AppIcon.show(store.defaultWidget.selection.firstRoute) }
        }
        // A widget's "More ›": the alerts of its train, which can be other than
        // the default's. Here so it opens whichever tab is showing. And the
        // Nearby widget: one of its trains, or the stations near you.
        .onOpenURL { url in
            if let selection = Selection(alertsURL: url) {
                let train = AlertsSheet.Train(selection: selection)
                afterSheets { alertsTrain = train }
            } else if let selection = Selection(trainURL: url) {
                afterSheets { showInLive(.train(selection)) }
            } else if url == Nearby.allowURL {
                afterSheets { showInLive(.allowLocation) }
            } else if url == Nearby.url {
                afterSheets { showInLive(.nearby) }
            }
        }
    }

    private func showInLive(_ opening: LiveOpening) {
        tab = .live
        liveOpening = opening
    }

    /// Runs `show` once any sheet that's up, such as the train picker or a
    /// train's alerts, has gone, as it would keep what's next from showing.
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
