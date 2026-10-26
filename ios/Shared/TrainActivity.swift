import ActivityKit
import AppIntents
import Foundation
import WidgetKit

/// A countdown to one train on the Lock Screen and in the Dynamic Island.
///
/// iOS keeps these encoded across app updates, so like `ContentState` they must decode what
/// older versions wrote: new properties must be optional.
struct TrainActivityAttributes: ActivityAttributes {
    /// Shared with the push server, which also sends it.
    typealias ContentState = CountdownState

    var selection: Selection
    var stationName: String
    var heading: String
    /// When its `CountdownState.lifetime` is up; nil from countdowns started before they had one.
    var ends: Date? = nil
    /// From a Transfers widget, its change, whose lines' alerts it mentions too; nil otherwise.
    var change: Change? = nil
}

// Only the app may start and update Live Activities, so iOS runs these in the app; the widget
// includes them only for its buttons.

/// The ↻ on widgets and the countdown: refreshes both. iOS reloads only the tapped widget, so
/// a widget's ↻ reloads those with its setup, and the countdown's all Next train and Transfers
/// widgets.
struct RefreshIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Refresh train times"
    static let isDiscoverable = false

    /// The tapped widget's `TrainEntry.widgetID`; nil on the countdown.
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
        if let widgetID {
            await WidgetCenter.shared.reloadWidgets(sharingSetupWith: widgetID)
        } else {
            WidgetCenter.shared.reloadTrainWidgets()
        }
        #endif
        return .result()
    }
}

/// A widget's ↻ when no countdown is running; iOS then reloads that widget, and this the others
/// with its setup. Runs in the widget, which responds faster than launching the app.
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
        if !widgetID.isEmpty {
            SharedStore.recordTap(\.refreshed, for: widgetID)
            await WidgetCenter.shared.reloadWidgets(sharingSetupWith: widgetID)
        }
        return .result()
    }
}

/// A widget's walk button: starts a countdown to its train, or stops it if it's already this
/// widget's.
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

    // This widget's alert settings, not the default train's

    @Parameter(title: "Elevator outages", default: false)
    var elevatorAlerts: Bool

    @Parameter(title: "Service alerts", default: true)
    var serviceAlerts: Bool

    /// On the Transfers widget, the trip that makes the connection, which may not be the next at
    /// your station. Nil for the first train you can catch.
    @Parameter(title: "Trip")
    var trip: String?

    /// On the Transfers widget, its `Change` as JSON, whose lines' alerts the countdown mentions
    /// too. Nil elsewhere.
    @Parameter(title: "Change")
    var change: String?

    init() {}

    init(selection: Selection, widgetID: String, trip: String? = nil, change: Change? = nil) {
        self.widgetID = widgetID
        trainID = selection.trainID
        walkMinutes = selection.walkMinutes
        elevatorAlerts = selection.elevatorAlerts
        serviceAlerts = selection.serviceAlerts
        self.trip = trip
        self.change = change.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    func perform() async throws -> some IntentResult {
        #if APP
        SharedStore.recordTap(\.toggled, for: widgetID)
        if var selection = StopEntity(id: trainID)?.selection(basedOn: SharedStore.defaultTrain) {
            selection.walkMinutes = walkMinutes
            selection.elevatorAlerts = elevatorAlerts
            selection.serviceAlerts = serviceAlerts
            // Only if still a change for this train
            let change = change.flatMap { try? JSONDecoder().decode(Change.self, from: Data($0.utf8)) }?
                .validated(for: selection)
            try await TrainActivityController.toggle(for: selection, change: change, widgetID: widgetID, trip: trip)
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
