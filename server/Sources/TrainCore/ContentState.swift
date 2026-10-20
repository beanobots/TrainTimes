import Foundation

/// The countdown's content state: the app's own type (Shared/Countdown.swift,
/// its `TrainActivityAttributes.ContentState`), so the JSON a plain
/// `JSONEncoder` makes of it is what ActivityKit decodes on the phone. Dates
/// are encoded `.deferredToDate`: seconds since 2001-01-01, as a number.
typealias ContentState = CountdownState

extension CountdownState {
    /// The encoder for content-state, as ActivityKit expects it. Its defaults
    /// are the point: `.deferredToDate`, and no key conversion.
    static func encoder() -> JSONEncoder { JSONEncoder() }
}
