import Foundation

/// Timeline planning for the Next train and Transfers widgets, separate from fetching and drawing
/// (RTrainWidget.swift's `Provider`) so the push server's tests can check it.
enum TimelinePlan {
    /// How many trains to catch get their own entries.
    static let trainsAhead = 10
    /// How long after fetching the maps use the feed's train positions; after that, due times.
    static let positionLife: TimeInterval = 60
    /// Max age of saved times a widget redraws with instead of fetching.
    static let reuseWindow: TimeInterval = 30
    /// As `reuseWindow`, for a trip just started on Transit Directions: the times fetched as its
    /// journeys showed, which its card's tap drew at once, so the board matches what that drew.
    static let quickTripReuseWindow: TimeInterval = 5 * 60
    /// On a first draw with no saved times, how long to wait for other lines' trains, alerts and
    /// outages after the widget's own times arrive; the rest come at the next reload.
    static let firstDrawWait: TimeInterval = 1
    /// As `firstDrawWait`, with saved times: longer, as nothing waits to draw, but not as long
    /// as a slow feed takes, as the widget extension draws one widget at a time.
    static let extrasWait: TimeInterval = 5

    /// Entry dates after `now`, sorted: each of the next `trainsAhead` trains' leave time and last
    /// leave time (a held train can be caught until it leaves), so the widget moves on without
    /// fetching. With `everyMinute` (medium/large widgets' minutes and maps), also every minute
    /// until the last leave time, at most an hour.
    static func dates(after now: Date, toCatch: [Arrival], selection: Selection, everyMinute: Bool) -> [Date] {
        let trains = toCatch.prefix(trainsAhead)
        let leaveTimes = trains.map(selection.leaveTime(for:))
        var dates = Set(leaveTimes + trains.map(selection.lastLeaveTime(for:)))
        if everyMinute, let lastLeave = leaveTimes.last {
            let end = min(lastLeave, now.addingTimeInterval(60 * 60))
            var minute = now.addingTimeInterval(60)
            while minute < end {
                dates.insert(minute)
                minute.addTimeInterval(60)
            }
        }
        return dates.filter { $0 > now }.sorted()
    }

    /// When the widget runs out of trains in `toCatch` to show.
    static func runsOut(_ toCatch: [Arrival], selection: Selection) -> Date? {
        toCatch.prefix(trainsAhead).map(selection.lastLeaveTime(for:)).max()
    }

    /// The catchable `trains` for the entry at `date`. Stops are stripped to save the widget's
    /// limited memory, except the next train's with `keepsStops` (medium/large widgets, whose map
    /// button shows them before a reload). Positions are dropped after `positionLife`.
    static func trains(_ trains: [Arrival], at date: Date, selection: Selection, fetched: Date,
                       keepsStops: Bool) -> [Arrival] {
        let positionStale = !fetched.isWithin(positionLife, before: date)
        return selection.catchable(trains, now: date).enumerated().map { index, train in
            var train = train
            if !keepsStops || index > 0 { train.approach = [] }
            if positionStale { train.position = nil }
            return train
        }
    }

    /// As `trains(...)`, for a widget with a change.
    static func connections(_ connections: [Connection], at date: Date, selection: Selection, fetched: Date,
                            keepsStops: Bool) -> [Connection] {
        let positionStale = !fetched.isWithin(positionLife, before: date)
        return selection.catchable(connections, now: date).enumerated().map { index, connection in
            var connection = connection
            if !keepsStops || index > 0 {
                connection.first.approach = []
                connection.arrival.approach = []
                connection.next?.approach = []
            }
            if positionStale {
                connection.first.position = nil
                connection.arrival.position = nil
                connection.next?.position = nil
            }
            return connection
        }
    }

    /// For when the MTA can't be reached: the saved `trains` still to catch, then the
    /// timetable's after the last of them (theirs is the better guess until then); just the
    /// timetable's if none is.
    static func filling(_ trains: [Arrival], from timetable: [Arrival], selection: Selection, now: Date) -> [Arrival] {
        let saved = selection.catchable(trains, now: now)
        guard let last = saved.map(\.time).max() else { return timetable }
        return saved + timetable.filter { $0.time > last }
    }

    /// As `filling(_:from:selection:now:)`, for a widget with a change, by the trains that get there.
    static func filling(_ connections: [Connection], from timetable: [Connection], selection: Selection,
                        now: Date) -> [Connection] {
        let saved = selection.catchable(connections, now: now)
        guard let last = saved.map(\.first.time).max() else { return timetable }
        return saved + timetable.filter { $0.first.time > last }
    }

    /// When to reload: `reloadInterval` after `fetched` (which may be another widget's older
    /// fetch). Without new times, timed from the `failed` attempt (nil for now) so a later redraw
    /// doesn't postpone it: 2 minutes later, or when showing `old` times, as long as they were old,
    /// capped at `reloadInterval` (the MTA can be unreachable for a whole ride underground, and
    /// reloads are budgeted daily). Sooner if entries run out of trains (`runsOut`) or commuting
    /// hours switch (`switches`); immediately if not `complete` (see `firstDrawWait`); never
    /// within a minute. Times or failures after `now` (clock set back) count as now.
    static func reload(now: Date, fetched: Date?, old: Date? = nil, failed: Date? = nil, runsOut: Date?,
                       switches: Date?, complete: Bool = true) -> Date {
        let tried = min(failed ?? now, now)
        let retry = old.map { min(reloadInterval(at: tried), max(2 * 60, tried.timeIntervalSince($0))) } ?? 2 * 60
        var reload = fetched.map { $0 > now ? now : $0.addingTimeInterval(reloadInterval(at: now)) }
            ?? tried.addingTimeInterval(retry)
        if let runsOut { reload = min(reload, runsOut) }
        if let switches { reload = min(reload, switches) }
        if !complete { reload = now }
        return max(reload, now.addingTimeInterval(60))
    }

    /// 5 minutes (about iOS's widget reload rate) from 6 am to 11 pm New York time; 15 overnight
    /// to save the daily reload budget for daytime.
    static func reloadInterval(at date: Date) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let hour = calendar.component(.hour, from: date)
        return (6..<23).contains(hour) ? 5 * 60 : 15 * 60
    }

    /// Whether to redraw with times saved at `saved` instead of fetching: if saved within
    /// `reuseWindow` (by another widget or the countdown), or of any age with a train still to
    /// catch after a recent toggle tap (`toggled`; it only changes the look), or when another
    /// widget for the train had it reload to show the times it had just saved (`synced` soon
    /// after `saved`), however late iOS gets to it, up to a `reloadInterval` after: fetching
    /// instead would have it show others, and have that widget reload in turn. Never if older
    /// than the last ↻ (`refreshed`). Times after `now` (clock set back) are old.
    static func reuses(saved: Date, refreshed: Date?, toggled: Date?, synced: Date? = nil, anyToCatch: () -> Bool,
                       now: Date) -> Bool {
        guard saved > refreshed ?? .distantPast else { return false }
        if saved.isWithin(reuseWindow, before: now) { return true }
        let tapped = toggled?.isWithin(reuseWindow, before: now) ?? false
        let sharing = synced.map { saved.isWithin(reuseWindow, before: $0) && $0.isWithin(reloadInterval(at: now), before: now) }
            ?? false
        return (tapped || sharing) && anyToCatch()
    }
}
