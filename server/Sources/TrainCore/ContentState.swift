import Foundation

/// Mirrors `TrainActivityAttributes.ContentState` in ios/Shared/TrainActivity.swift,
/// which imports ActivityKit and so can't be shared. The property names, types
/// and order are the same, and Codable is synthesized as in the app, so the JSON
/// a plain `JSONEncoder` makes is what ActivityKit decodes on the phone. Dates
/// are encoded `.deferredToDate`: seconds since 2001-01-01, as a number.
///
/// Keep this in step with the app's: a property it adds needs adding here too.
public struct ContentState: Codable, Hashable, Sendable {
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
    /// Its line, which can be another one running on yours.
    var route: String? = nil
    /// The lines of `following`.
    var followingRoutes: [String]? = nil
}

extension ContentState {
    /// The encoder for content-state, as ActivityKit expects it. Its defaults
    /// are the point: `.deferredToDate`, and no key conversion.
    static func encoder() -> JSONEncoder { JSONEncoder() }
}
