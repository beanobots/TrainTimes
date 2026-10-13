import ActivityKit
import AppIntents
import Foundation

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

/// The countdown's refresh button. iOS runs it in the app, which fetches new times.
struct RefreshCountdownIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Refresh train countdown"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        // Starting and updating Live Activities is only allowed in the app itself
        #if APP
        await TrainActivityController.refresh()
        #endif
        return .result()
    }
}
