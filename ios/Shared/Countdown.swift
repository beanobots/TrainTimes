import Foundation

/// What the Lock Screen countdown shows: `TrainActivityAttributes.ContentState`,
/// which the app posts with ActivityKit and the push server (server/, which
/// links this file) sends through APNs. ActivityKit keeps it encoded, and
/// decodes it with a plain `JSONDecoder`: the keys are the property names, and
/// dates are seconds since 2001-01-01, as a number.
///
/// What older versions of the app posted, and what a server deployed before or
/// after the app sends, must keep decoding: a property added here has to be
/// optional, and none can be renamed or change its type.
struct CountdownState: Codable, Hashable, Sendable {
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
    /// When its times were fetched.
    var updated: Date
    /// Its line, which can be another one running on yours; nil from countdowns
    /// started before trains of other lines were shown.
    var route: String? = nil
    /// The lines of `following`.
    var followingRoutes: [String]? = nil
    /// Settings › Mark live times and Mark scheduled times as they were when the
    /// app posted it. The countdown reads Settings as it's drawn; these are
    /// here so that changing them posts a state that isn't the same, which iOS
    /// redraws. Nil from the push server, which doesn't know them, and from
    /// older versions of the app.
    var marksLiveTimes: Bool? = nil
    var marksScheduledTimes: Bool? = nil
}

extension CountdownState {
    /// iOS ends a Live Activity after 8 hours.
    static let lifetime: TimeInterval = 8 * 60 * 60

    /// How much sooner than the train it last counted down to another one can
    /// be and still be taken for it: the same train under a new trip id, or one
    /// without an id, whose time has moved up a little.
    static let leeway: TimeInterval = 60

    /// Out of date as the train is due: iOS redraws the countdown then, and it
    /// moves on to the next train it has (`movedOn(at:)`).
    var staleDate: Date { train }

    /// The countdown for `selection` from `trains`, mentioning `notice`, the
    /// label of an alert. When starting (`trip` nil), it's to the first train
    /// you can catch. After that it's to the train with `trip` while that's
    /// still coming, and once it has gone, to the first train due at or after
    /// `last`, the one it counted down to, as it moves on by itself. You set
    /// off when it started, so the walk isn't taken off again. Before anything
    /// is known of that train, it's the first you can catch.
    ///
    /// Trains go by when they reach the platform, which is what it counts down
    /// to and moves on at, not when one held there leaves.
    init?(for selection: Selection, trains: [Arrival], notice: String?, now: Date,
          following trip: String?, after last: Date?) {
        let upcoming = trains.filter { $0.time > now }
        let catchable = selection.catchable(upcoming, now: now).first
        let target: Arrival?
        if let trip {
            // A trip without an id can't be told from another one, so that goes by its time
            let same = trip.isEmpty ? nil : upcoming.first { $0.trip == trip }
            let next = last.flatMap { last in upcoming.first { $0.time >= last.addingTimeInterval(-Self.leeway) } }
            target = same ?? next ?? catchable
        } else {
            target = catchable
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

    /// The same from `board`, mentioning what it has that `selection` and
    /// `settings` ask for.
    init?(for selection: Selection, board: Board, settings: AppSettings, now: Date,
          following trip: String?, after last: Date?) {
        self.init(for: selection, trains: board.trains, notice: board.notice(for: selection, settings: settings)?.label,
                  now: now, following: trip, after: last)
    }

    /// New times for the running countdown from `board`: the same train while
    /// it's still coming, the next one once it has gone. With no train at all,
    /// it stays on its last one and says so, or names the service alert that's
    /// why: not an elevator out, which the notice would otherwise put first.
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

    /// Once the train has gone, the first of the following trains still to
    /// come, as though it were the one counted down to; or, with none, as it
    /// is. The countdown is out of date as its train is due, and iOS redraws
    /// it then, so it moves on without the app. Only once, though: nothing
    /// redraws it again until the app updates it. A following train's trip
    /// and where it ends aren't known; it's taken to be live if this one was.
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
