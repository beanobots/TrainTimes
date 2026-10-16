import SwiftUI
import UIKit

/// The app's three tabs, in a Liquid Glass tab bar on iOS 26: Live, for your
/// favorites' trains and those near you; Widgets, to set widgets up; and Settings.
struct AppTabs: View {
    private enum AppTab: Hashable { case live, widgets, settings }

    @State private var store = WidgetStore()
    @State private var favorites = FavoritesStore()
    @State private var settings = SettingsStore()
    @State private var tab = AppTab.live
    /// A train whose alerts show in full, after "More ›" on a widget.
    @State private var alertsTrain: AlertsSheet.Train?

    var body: some View {
        TabView(selection: $tab) {
            LiveView()
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
        // A widget's "More ›": the alerts of its train, which can be other than
        // the default's. Here so it opens whichever tab is showing.
        .onOpenURL { url in
            guard let selection = Selection(alertsURL: url) else { return }
            let train = AlertsSheet.Train(selection: selection)
            // A sheet already up, such as the train picker or these alerts,
            // would keep this one from showing, so it goes first
            let root = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
                .first
            if let root, root.presentedViewController != nil {
                root.dismiss(animated: true) { alertsTrain = train }
            } else {
                alertsTrain = train
            }
        }
    }
}

#Preview {
    AppTabs()
}
