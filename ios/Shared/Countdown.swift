import Foundation

/// The Lock Screen countdown's `TrainActivityAttributes.ContentState`, posted by the app via
/// ActivityKit and by the push server (server/, which links this file) via APNs. ActivityKit
/// decodes it with a plain `JSONDecoder`: keys are property names, dates are seconds since
/// 2001-01-01.
///
/// Must decode what older apps and older or newer servers send: new properties must be optional,
/// and none may be renamed or change type.
struct CountdownState: Codable, Hashable, Sendable {
    /// When the train reaches the platform.
    var train: Date
    /// Feed trip id, so a refresh follows the same train.
    var trip: String
    var isLive: Bool
    var terminal: String?
    /// The next couple of trains after it.
    var following: [Date]
    /// E.g. "Delays", "Elevator out".
    var notice: String?
    /// When the times were fetched.
    var updated: Date
    /// May be another line running on yours; nil from countdowns started before other lines'
    /// trains were shown.
    var route: String? = nil
    /// The lines of `following`.
    var followingRoutes: [String]? = nil
    /// Settings › Mark live/scheduled times when posted. The countdown reads Settings when drawn;
    /// these only make a settings change post a different state, so iOS redraws. Nil from the
    /// push server and older apps.
    var marksLiveTimes: Bool? = nil
    var marksScheduledTimes: Bool? = nil
}

extension CountdownState {
    /// How long a countdown runs from when it starts, moving on to the next train each time one
    /// is due; then the app, or the push server, ends it. (iOS's own limit is 8 hours.)
    static let lifetime: TimeInterval = 30 * 60

    /// How much earlier than the last target a train can be and still count as it: the same
    /// train under a new trip id, or one without an id whose time moved up a little.
    static let leeway: TimeInterval = 60

    /// Stale when the train is due, so iOS redraws and it moves on (`movedOn(at:)`).
    var staleDate: Date { train }

    /// Whether widgets for its train show the same as with `other`: they take its trains'
    /// times, lines and liveness (`CountdownSync`), however little they move, but not its notice.
    func hasSameTrains(as other: CountdownState) -> Bool {
        train == other.train && trip == other.trip && route == other.route && isLive == other.isLive
            && following == other.following && followingRoutes == other.followingRoutes
    }

    /// The countdown for `selection` from `trains`; `notice` is an alert label. On start (`trip`
    /// nil), targets the first train you can reach as it arrives. After that, the train with
    /// `trip` while it's coming, then the first due at or after `last` (the previous target), as
    /// the countdown moves on by itself. The walk isn't subtracted again since you've set off.
    /// With nothing known of that train, the first reachable one.
    ///
    /// Times are platform arrivals, not departures of held trains. So it never starts on a train
    /// you'd only catch while it's held: it would move on as that train arrived, with you still
    /// walking.
    init?(for selection: Selection, trains: [Arrival], notice: String?, now: Date,
          following trip: String?, after last: Date?) {
        let upcoming = trains.filter { $0.time > now }
        let reachable = selection.firstReachable(upcoming, now: now)
        let target: Arrival?
        if let trip {
            // A trip without an id can only be matched by time
            let same = trip.isEmpty ? nil : upcoming.first { $0.trip == trip }
            let next = last.flatMap { last in upcoming.first { $0.time >= last.addingTimeInterval(-Self.leeway) } }
            target = same ?? next ?? reachable
        } else {
            target = reachable
        }
        guard let target else { return nil }
        let following = upcoming.filter { $0.time > target.time }.prefix(2)
        self.init(
            train: target.time,
            trip: target.trip,
            isLive: target.isLive,
            terminal: target.terminal,
            following: following.map(\.time),
            notice: notice,
            updated: now,
            route: target.route,
            followingRoutes: following.map(\.route)
        )
    }

    /// As above, from `board`, with the notice `selection` and `settings` ask for.
    init?(for selection: Selection, board: Board, settings: AppSettings, now: Date,
          following trip: String?, after last: Date?) {
        self.init(for: selection, trains: board.trains, notice: board.notice(for: selection, settings: settings)?.label,
                  now: now, following: trip, after: last)
    }

    /// Updates the running countdown from `board`: the same train while it's coming, then the
    /// next. With no trains, keeps the last one and says so, or names the service alert (not an
    /// elevator outage, which would otherwise take priority).
    func refreshed(for selection: Selection, board: Board, settings: AppSettings, now: Date) -> CountdownState {
        if let state = CountdownState(for: selection, board: board, settings: settings, now: now,
                                      following: trip, after: train) {
            return state
        }
        let alert = board.notice(includingElevators: false, includingAlerts: selection.serviceAlerts,
                                 kinds: settings.alertKinds)
        var state = self
        state.following = []
        state.followingRoutes = []
        state.notice = alert?.label ?? "No trains predicted"
        state.updated = now
        return state
    }

    /// Once the train has gone, retargets to the first following train still to come (or returns
    /// self if none). iOS redraws at `staleDate`, so this moves on without the app, but only once
    /// until the app updates it. A following train's trip and terminal are unknown; it's live if
    /// this one was.
    func movedOn(at now: Date) -> CountdownState {
        guard train <= now, let index = following.firstIndex(where: { $0 > now }) else { return self }
        var state = self
        state.train = following[index]
        state.trip = ""
        state.terminal = nil
        if let routes = followingRoutes, index < routes.count { state.route = routes[index] }
        state.following = Array(following.dropFirst(index + 1))
        state.followingRoutes = followingRoutes.map { Array($0.dropFirst(index + 1)) }
        return state
    }
}
