import Foundation

// A change from a train to a bus (`Change.buses`): each train's ways on get the first bus it
// can catch at each bus's stop, after the walk there, from Bus Time. Not the push server's: it
// builds `Change.swift` and `TrainService.swift` but not Bus Time.

extension TrainService {
    /// `board` with each connection's ways by bus added, among its trains' by when each leaves
    /// the change; unchanged without buses, or if Bus Time can't be reached.
    static func addingBuses(to board: Board, change: Change, now: Date = AppClock.now) async -> Board {
        guard !change.buses.isEmpty else { return board }
        let found = await withTaskGroup(of: (BusLeg, [BusArrival]).self) { group in
            for leg in change.buses {
                group.addTask {
                    let place = BusRide.Place(name: leg.stopName, latitude: leg.stop.latitude, longitude: leg.stop.longitude)
                    return (leg, await BusTimes.arrivals(line: leg.line, at: place, now: now)?.arrivals ?? [])
                }
            }
            var found: [(BusLeg, [BusArrival])] = []
            for await leg in group { found.append(leg) }
            // In the change's order, not as they came back
            return change.buses.compactMap { leg in found.first { $0.0 == leg } }
        }
        var board = board
        board.connections = board.connections.map { Self.addingBuses(found, to: $0) }
        return board
    }

    /// `connection` with a way for each bus in `buses`: the first it can catch, after its walk
    /// from the train.
    static func addingBuses(_ buses: [(leg: BusLeg, arrivals: [BusArrival])], to connection: Connection) -> Connection {
        var connection = connection
        var ways = connection.ways ?? []
        for (leg, arrivals) in buses {
            let walk = TimeInterval(leg.walkMinutes * 60)
            let ready = connection.arrival.time.addingTimeInterval(walk)
            guard let bus = arrivals.first(where: { ($0.time ?? .distantPast) >= ready }), let time = bus.time else { continue }
            // As a train, so the boards time it as one: its line marked a bus's (`BusLeg.route`)
            let ride = Arrival(route: leg.route, time: time, stop: BusLeg.prefix + leg.stop.id, lastStop: "",
                               isLive: bus.isLive)
            var change = connection
            change.next = ride
            change.walk = walk
            change.ways = nil
            change.stationID = nil
            let way = Way(route: leg.route, connection: change, arrival: ride)
            // Before the first way leaving the change later
            let index = ways.firstIndex { ($0.connection?.next?.leaves ?? .distantFuture) > time } ?? ways.endIndex
            ways.insert(way, at: index)
        }
        connection.ways = ways
        // With no train to change to, the bus is the connection
        if connection.next == nil, let first = ways.first(where: { BusLeg.line(of: $0.route) != nil })?.connection {
            connection.next = first.next
            connection.walk = first.walk
        }
        return connection
    }
}

// A change from a bus to a train (`BusChoice.changes`): each bus at your stop is timed to where
// you get off by the timetable's minutes there (Bus Time has no times further on), then the walk,
// and gets the first train it can catch at each change: a train's change board (`Connection`),
// its bus drawn as a line marked a bus's (`BusLeg.route`).

extension BusChoice {
    /// As a train's change for the boards that draw one: at the first change's station, the
    /// others its alternatives. Nil without changes.
    var trainChange: Change? {
        guard let changes, let first = changes.first else { return nil }
        return Change(stationID: first.selection.stationID, routes: first.selection.routes,
                      direction: first.selection.direction, walkMinutes: first.walkMinutes,
                      alternatives: changes.dropFirst().map {
                          Change.Stop(stationID: $0.selection.stationID, routes: $0.selection.routes,
                                      direction: $0.selection.direction)
                      })
    }

    /// Each of `buses` still to come at `date` with its ways on: for each change, the first of
    /// its trains (`trains`, one list per change) it can catch, soonest leaving first.
    func connections(buses: [BusArrival], trains: [[Arrival]], at date: Date) -> [Connection] {
        guard let changes else { return [] }
        return buses.compactMap { bus -> Connection? in
            guard let time = bus.time, time > date else { return nil }
            let route = BusLeg.prefix + line
            let first = Arrival(route: route, time: time, stop: BusLeg.prefix + stop.id, lastStop: "", isLive: bus.isLive)
            var ways: [Way] = []
            for (index, change) in changes.enumerated() where trains.indices.contains(index) {
                let off = time.addingTimeInterval(change.minutes * 60)
                let walk = TimeInterval(change.walkMinutes * 60)
                let arrival = Arrival(route: route, time: off, stop: BusLeg.prefix + change.stop.id, lastStop: "",
                                      isLive: bus.isLive)
                guard let train = trains[index].first(where: { $0.leaves >= off.addingTimeInterval(walk) }) else { continue }
                let connection = Connection(first: first, arrival: arrival, next: train, walk: walk,
                                            stationID: index == 0 ? nil : change.selection.stationID)
                ways.append(Way(route: train.route, connection: connection, arrival: train))
            }
            ways.sort { ($0.arrival?.leaves ?? .distantFuture) < ($1.arrival?.leaves ?? .distantFuture) }
            guard let soonest = ways.first?.connection else {
                return Connection(first: first, arrival: first, next: nil, ways: [])
            }
            var connection = soonest
            connection.stationID = nil
            connection.ways = ways
            return connection
        }
    }
}
