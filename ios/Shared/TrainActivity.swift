import ActivityKit
import AppIntents
import Foundation
import WidgetKit

/// A countdown to one train on the Lock Screen and in the Dynamic Island.
struct TrainActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the train reaches the platform.
        var train: Date
        /// Its trip in the feed, so a refresh follows the same train.
        var trip: String
        var isLive: Bool
        var terminal: String?
        /// The next couple of trains after it.
        var following: [Date]
        /// "Delays", "Elevator out", when there's something to know.
        var notice: String?
        var updated: Date
        /// Its line, which can be another one running on yours; nil from countdowns
        /// started before trains of other lines were shown.
        var route: String? = nil
        /// The lines of `following`.
        var followingRoutes: [String]? = nil
    }

    var selection: Selection
    var stationName: String
    var heading: String
}

// Starting and updating Live Activities is only allowed in the app itself, so
// iOS runs these in the app; in the widget they're only there for the buttons.

/// The ↻ on the widgets and the countdown: new times for both.
struct RefreshIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Refresh train times"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if APP
        SharedStore.saveRefreshed(.now)
        await TrainActivityController.refresh()
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        return .result()
    }
}

/// The widgets' ↻ while no countdown is running: new times for the widgets
/// alone. It runs in the widget, which answers sooner than the app, which iOS
/// would first have to start.
struct RefreshWidgetsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh the widgets"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        SharedStore.saveRefreshed(.now)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// The medium widget's map button: shows where the next train is, or the later
/// trains again. It runs in the widget, which reloads once it's done.
struct ToggleMapIntent: AppIntent {
    static let title: LocalizedStringResource = "Show where the train is"
    static let isDiscoverable = false

    /// A `Selection.trainID`.
    @Parameter(title: "Train")
    var trainID: String

    init() {}

    init(selection: Selection) {
        trainID = selection.trainID
    }

    func perform() async throws -> some IntentResult {
        SharedStore.toggleMap(for: trainID)
        SharedStore.saveToggled(.now)
        return .result()
    }
}

/// A home screen widget's alert banner: shows the alert in full, or the times
/// again. It runs in the widget, which reloads once it's done.
struct ToggleAlertIntent: AppIntent {
    static let title: LocalizedStringResource = "Show the alert"
    static let isDiscoverable = false

    /// A `Selection.alertID`.
    @Parameter(title: "Train")
    var trainID: String

    init() {}

    init(selection: Selection) {
        trainID = selection.alertID
    }

    func perform() async throws -> some IntentResult {
        SharedStore.toggleAlert(for: trainID)
        SharedStore.saveToggled(.now)
        return .result()
    }
}

/// A widget's walk button: starts the countdown to that widget's train, or
/// stops it if it's already counting down to that train.
struct ToggleCountdownIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "I'm on my way"
    static let isDiscoverable = false

    /// A `Selection.trainID`.
    @Parameter(title: "Train")
    var trainID: String

    @Parameter(title: "Walking time (minutes)")
    var walkMinutes: Int

    // The widget's own choice of what the countdown mentions, not the default widget's

    @Parameter(title: "Elevator outages", default: false)
    var elevatorAlerts: Bool

    @Parameter(title: "Service alerts", default: true)
    var serviceAlerts: Bool

    init() {}

    init(selection: Selection) {
        trainID = selection.trainID
        walkMinutes = selection.walkMinutes
        elevatorAlerts = selection.elevatorAlerts
        serviceAlerts = selection.serviceAlerts
    }

    func perform() async throws -> some IntentResult {
        #if APP
        SharedStore.saveToggled(.now)
        if var selection = StopEntity(id: trainID)?.selection(basedOn: SharedStore.load()) {
            selection.walkMinutes = walkMinutes
            selection.elevatorAlerts = elevatorAlerts
            selection.serviceAlerts = serviceAlerts
            try await TrainActivityController.toggle(for: selection)
        }
        #endif
        return .result()
    }
}

/// The countdown's own walk button.
struct StopCountdownIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop train countdown"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if APP
        await TrainActivityController.endAll()
        #endif
        return .result()
    }
}
