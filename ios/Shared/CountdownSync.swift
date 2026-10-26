import Foundation

/// Makes a widget for the running countdown's train show the countdown's arrival times, so the
/// two can't disagree: they'd otherwise come from separate fetches (the widget's own, and the
/// app's or the push server's for the countdown), and the MTA's times move between them. Each
/// widget still works out its own leave times from them with its own walk. Separate from the
/// widget's drawing so the push server's tests can check it.
enum CountdownSync {
    /// How far a board's train can be from one of the countdown's and still be taken for it:
    /// the same train fetched at another time, as its prediction moved.
    static let matchWindow: TimeInterval = 3 * 60

    /// A board's trains brought into line with a countdown; see `aligned(_:to:selection:now:)`.
    struct Alignment: Equatable {
        /// Soonest first.
        var trains: [Arrival]
        /// The board's trains that are the countdown's, by `key(of:)`, and the times it has for them.
        fileprivate var times: [String: Date] = [:]
        /// The board's trains the countdown doesn't have, by `key(of:)`.
        fileprivate var dropped: Set<String> = []

        /// `connections` (a Transfers widget's) as `trains`: each one's first train at the
        /// countdown's time, and its arrival at the change moved as much; those whose first train
        /// was dropped are left out. In their order.
        func connections(_ connections: [Connection]) -> [Connection] {
            connections.compactMap { connection in
                let key = CountdownSync.key(of: connection.first)
                guard !dropped.contains(key) else { return nil }
                guard let time = times[key] else { return connection }
                let delta = time.timeIntervalSince(connection.first.time)
                var connection = connection
                connection.first = connection.first.moved(by: delta)
                connection.arrival = connection.arrival.moved(by: delta)
                return connection
            }
        }
    }

    /// `trains` (a board's for `selection`, the countdown's train) with the countdown's `state`,
    /// moved on at `now` as the Lock Screen draws it. Each of the countdown's trains takes the
    /// place of the board's train that's the same (same trip, else the nearest on the same line
    /// within `matchWindow`), at the countdown's time; one the board doesn't have is added from
    /// what the countdown knows of it. The board's other trains between the countdown's first and
    /// last are left out, as the Lock Screen doesn't have them; those before (which the
    /// countdown skipped, too soon for its walk) and after are kept. Unchanged once the
    /// countdown's trains have all come.
    static func aligned(_ trains: [Arrival], to state: CountdownState, selection: Selection, now: Date) -> Alignment {
        let state = state.movedOn(at: now)
        guard state.train > now else { return Alignment(trains: trains) }
        let routes = state.followingRoutes ?? []
        let targets = [(time: state.train, trip: state.trip, route: state.route, isLive: state.isLive as Bool?)]
            + state.following.enumerated().map { index, time in
                (time: time, trip: "", route: index < routes.count ? routes[index] : nil, isLive: nil)
            }

        var matched: [Int: Int] = [:]
        var added: [Arrival] = []
        for (index, target) in targets.enumerated() {
            let free = trains.indices.filter { matched[$0] == nil }
            let sameTrip = target.trip.isEmpty ? nil : free.first { trains[$0].trip == target.trip }
            let nearest = free
                .filter { (target.route == nil || trains[$0].route == target.route)
                    && abs(trains[$0].time.timeIntervalSince(target.time)) <= matchWindow }
                .min { abs(trains[$0].time.timeIntervalSince(target.time)) < abs(trains[$1].time.timeIntervalSince(target.time)) }
            if let board = sameTrip ?? nearest {
                matched[board] = index
            } else {
                added.append(Arrival(route: target.route ?? selection.firstRoute, time: target.time,
                                     stop: selection.stopIDs.first ?? "", lastStop: "",
                                     isLive: target.isLive ?? state.isLive, trip: target.trip))
            }
        }

        let first = targets[0].time
        let last = targets[targets.count - 1].time
        var alignment = Alignment(trains: added)
        for (board, train) in trains.enumerated() {
            if let index = matched[board] {
                let target = targets[index]
                var moved = train.moved(by: target.time.timeIntervalSince(train.time))
                if let isLive = target.isLive, isLive != moved.isLive { moved = moved.with(isLive: isLive) }
                alignment.trains.append(moved)
                alignment.times[key(of: train)] = target.time
            } else if train.time < first || train.time > last {
                alignment.trains.append(train)
            } else {
                alignment.dropped.insert(key(of: train))
            }
        }
        alignment.trains.sort { $0.time < $1.time }
        return alignment
    }

    /// Identifies a board's train across its trains and connections.
    fileprivate static func key(of train: Arrival) -> String {
        "\(train.route) \(train.trip) \(train.time.timeIntervalSinceReferenceDate)"
    }
}

private extension Arrival {
    /// At `time` plus `delta`, as is its departure if it's held.
    func moved(by delta: TimeInterval) -> Arrival {
        guard delta != 0 else { return self }
        return Arrival(route: route, time: time.addingTimeInterval(delta), departure: departure?.addingTimeInterval(delta),
                       stop: stop, lastStop: lastStop, isLive: isLive, trip: trip, approach: approach, position: position)
    }

    func with(isLive: Bool) -> Arrival {
        Arrival(route: route, time: time, departure: departure, stop: stop, lastStop: lastStop, isLive: isLive,
                trip: trip, approach: approach, position: position)
    }
}
