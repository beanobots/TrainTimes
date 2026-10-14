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
        await TrainActivityController.refresh()
        WidgetCenter.shared.reloadAllTimelines()
        #endif
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

    init() {}

    init(selection: Selection) {
        trainID = selection.trainID
        walkMinutes = selection.walkMinutes
    }

    func perform() async throws -> some IntentResult {
        #if APP
        if var selection = StopEntity(id: trainID)?.selection(basedOn: SharedStore.load()) {
            selection.walkMinutes = walkMinutes
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
