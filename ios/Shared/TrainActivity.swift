import ActivityKit
import AppIntents
import Foundation
import WidgetKit

/// A countdown to one train on the Lock Screen and in the Dynamic Island.
///
/// iOS keeps these encoded while the countdown runs, across updates of the
/// app, so like `ContentState` they must keep decoding what older versions
/// wrote: a property added here has to be optional.
struct TrainActivityAttributes: ActivityAttributes {
    /// Shared with the push server, which sends it too.
    typealias ContentState = CountdownState

    var selection: Selection
    var stationName: String
    var heading: String
}

// Starting and updating Live Activities is only allowed in the app itself, so
// iOS runs these in the app; in the widget they're only there for the buttons.

/// The ↻ on the widgets and the countdown: new times for both. iOS reloads
/// a widget tapped, after this, and no other; the countdown's redraws the
/// widgets, which it doesn't belong to.
struct RefreshIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Refresh train times"
    static let isDiscoverable = false

    /// The `TrainEntry.widgetID` of the widget tapped; nil on the countdown.
    @Parameter(title: "Widget")
    var widgetID: String?

    init() {}

    init(widgetID: String?) {
        self.widgetID = widgetID
    }

    func perform() async throws -> some IntentResult {
        #if APP
        if let widgetID { SharedStore.recordTap(\.refreshed, for: widgetID) }
        await TrainActivityController.refresh()
        if widgetID == nil { WidgetCenter.shared.reloadAllTimelines() }
        #endif
        return .result()
    }
}

/// A widget's ↻ while no countdown is running: new times for that widget
/// alone, which iOS reloads after this. It runs in the widget, which answers
/// sooner than the app, which iOS would first have to start.
struct RefreshWidgetsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh the widgets"
    static let isDiscoverable = false

    /// A `TrainEntry.widgetID`; empty for Trains near you, which always fetches.
    @Parameter(title: "Widget", default: "")
    var widgetID: String

    init() {}

    init(widgetID: String) {
        self.widgetID = widgetID
    }

    func perform() async throws -> some IntentResult {
        if !widgetID.isEmpty { SharedStore.recordTap(\.refreshed, for: widgetID) }
        return .result()
    }
}

// iOS reloads only the widget tapped, and the map and the alert are kept by
// widget, so these leave the others as they are.

/// The medium and large widgets' map button: shows where the next train is,
/// or the later trains again.
struct ToggleMapIntent: AppIntent {
    static let title: LocalizedStringResource = "Show where the train is"
    static let isDiscoverable = false

    /// A `TrainEntry.widgetID`.
    @Parameter(title: "Widget", default: "")
    var widgetID: String

    /// A `Selection.trainID`.
    @Parameter(title: "Train")
    var trainID: String

    init() {}

    init(selection: Selection, widgetID: String) {
        self.widgetID = widgetID
        trainID = selection.trainID
    }

    func perform() async throws -> some IntentResult {
        SharedStore.toggleMap(for: trainID, in: widgetID)
        SharedStore.recordTap(\.toggled, for: widgetID)
        return .result()
    }
}

/// A home screen widget's alert banner: shows the alert in full, or the times
/// again.
struct ToggleAlertIntent: AppIntent {
    static let title: LocalizedStringResource = "Show the alert"
    static let isDiscoverable = false

    /// A `TrainEntry.widgetID`.
    @Parameter(title: "Widget", default: "")
    var widgetID: String

    /// A `Selection.alertID`.
    @Parameter(title: "Train")
    var trainID: String

    init() {}

    init(selection: Selection, widgetID: String) {
        self.widgetID = widgetID
        trainID = selection.alertID
    }

    func perform() async throws -> some IntentResult {
        SharedStore.toggleAlert(for: trainID, in: widgetID)
        SharedStore.recordTap(\.toggled, for: widgetID)
        return .result()
    }
}

/// A widget's walk button: starts the countdown to that widget's train, or
/// stops it if it's that widget's.
struct ToggleCountdownIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "I'm on my way"
    static let isDiscoverable = false

    /// A `TrainEntry.widgetID`.
    @Parameter(title: "Widget", default: "")
    var widgetID: String

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

    init(selection: Selection, widgetID: String) {
        self.widgetID = widgetID
        trainID = selection.trainID
        walkMinutes = selection.walkMinutes
        elevatorAlerts = selection.elevatorAlerts
        serviceAlerts = selection.serviceAlerts
    }

    func perform() async throws -> some IntentResult {
        #if APP
        SharedStore.recordTap(\.toggled, for: widgetID)
        if var selection = StopEntity(id: trainID)?.selection(basedOn: SharedStore.load()) {
            selection.walkMinutes = walkMinutes
            selection.elevatorAlerts = elevatorAlerts
            selection.serviceAlerts = serviceAlerts
            try await TrainActivityController.toggle(for: selection, widgetID: widgetID)
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
