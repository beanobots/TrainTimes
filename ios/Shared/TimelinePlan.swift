import Foundation

/// How the Next train and Transfers widgets plan their timelines, apart from
/// fetching the times and drawing them (RTrainWidget.swift's `Provider`), so
/// the push server's tests can check it, as nothing in the app can.
enum TimelinePlan {
    /// How many of the trains to catch get entries of their own.
    static let trainsAhead = 10
    /// How long after the times were fetched the maps go by where the feed
    /// said the trains were; after that, by when they're due at each stop.
    static let positionLife: TimeInterval = 60
    /// How old saved times can be for a widget to redraw with them rather
    /// than fetch its own.
    static let reuseWindow: TimeInterval = 30

    /// When the entries after the one for `now` come: as the time to leave for
    /// each of the next `trainsAhead` of `toCatch` (soonest first) passes, and
    /// the last moment to leave for it, as a train held at the platform can
    /// still be caught until it leaves; so the widget moves on to the next
    /// train without going back to the network. With `everyMinute`, for the
    /// medium and large widgets' minutes to go and maps, also a minute apart,
    /// up to the last time to leave or for an hour. Soonest first, all after `now`.
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

    /// After the last entry's date, the widget knows of no train of `toCatch` to show.
    static func runsOut(_ toCatch: [Arrival], selection: Selection) -> Date? {
        toCatch.prefix(trainsAhead).map(selection.lastLeaveTime(for:)).max()
    }

    /// `trains`, fetched at `fetched`, as the entry at `date` shows them: those
    /// still to catch. Only the maps show a train's stops, and only the next
    /// train's; the timeline holds many entries, in the widget's little memory,
    /// so no other train keeps them. With `keepsStops`, as on the medium and
    /// large widgets, the next one keeps them with the map off too, as their
    /// map button swaps to them before the widget reloads. After a minute,
    /// where the feed said each train was goes, and the maps go by when it's
    /// due at each stop.
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

    /// The same for the connections of a widget with a change: only the
    /// first's trains keep their stops, and only with `keepsStops`.
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

    /// When the widget reloads: `reloadInterval` after its times were
    /// `fetched`, as they may be ones another widget fetched a while ago.
    /// Without new ones, it goes by when the try for them `failed` (nil for
    /// now), so a tap that redraws the widget after doesn't put the next try
    /// off: 2 minutes after it, or showing `old` ones instead, fetched then,
    /// as long after as they were old, up to `reloadInterval`, as the MTA can
    /// be out of reach for a whole ride underground, and a widget's reloads
    /// are budgeted by the day. Sooner if its entries run out of trains first,
    /// rather than say there are none, or as commuting hours start or end
    /// (`switches`), for the other train; and never within a minute. Times
    /// fetched after `now`, before the clock was set back, are old; a try
    /// that failed then is taken to have failed now.
    static func reload(now: Date, fetched: Date?, old: Date? = nil, failed: Date? = nil, runsOut: Date?,
                       switches: Date?) -> Date {
        let tried = min(failed ?? now, now)
        let retry = old.map { min(reloadInterval(at: tried), max(2 * 60, tried.timeIntervalSince($0))) } ?? 2 * 60
        var reload = fetched.map { $0 > now ? now : $0.addingTimeInterval(reloadInterval(at: now)) }
            ?? tried.addingTimeInterval(retry)
        if let runsOut { reload = min(reload, runsOut) }
        if let switches { reload = min(reload, switches) }
        return max(reload, now.addingTimeInterval(60))
    }

    /// How long to wait for new times: 5 minutes, about as often as iOS
    /// reloads a widget, from 6 am to 11 pm in New York; 15 overnight. A
    /// widget's reloads are budgeted by the day, so fewer at night leaves
    /// more for the day.
    static func reloadInterval(at date: Date) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let hour = calendar.component(.hour, from: date)
        return (6..<23).contains(hour) ? 5 * 60 : 15 * 60
    }

    /// Whether a widget redraws with times saved at `saved` rather than
    /// fetching its own: ones fetched in the last 30 seconds, by another
    /// widget or the countdown; or, after a tap on the map or walk button or
    /// the alert banner in the last 30 seconds (`toggled`), which changes only
    /// how the widget looks, ones of any age while any of their trains is
    /// still to catch. Never ones from before the widget's ↻ (`refreshed`).
    /// Times after `now`, saved before the clock was set back, are old.
    static func reuses(saved: Date, refreshed: Date?, toggled: Date?, anyToCatch: () -> Bool, now: Date) -> Bool {
        guard saved > refreshed ?? .distantPast else { return false }
        if saved.isWithin(reuseWindow, before: now) { return true }
        let tapped = toggled?.isWithin(reuseWindow, before: now) ?? false
        return tapped && anyToCatch()
    }
}
