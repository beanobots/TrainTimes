import os

/// Intervals for timing widget taps in Instruments (os_signpost, "Widget" category): a tap's
/// intent, the reload after it, the fetch for times, and the first load of the station list.
enum Signposts {
    static let widget = OSSignposter(subsystem: "com.rtrainwidget.app", category: "Widget")

    /// Times `work` as an interval named `name`.
    static func interval<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let state = widget.beginInterval(name, id: widget.makeSignpostID())
        defer { widget.endInterval(name, state) }
        return try await work()
    }

    /// As `interval`, for work that doesn't wait.
    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = widget.beginInterval(name, id: widget.makeSignpostID())
        defer { widget.endInterval(name, state) }
        return try work()
    }
}
