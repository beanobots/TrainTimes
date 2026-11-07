import Foundation

// A change from a train to a bus (`Change.buses`): each train's ways on get the first bus it
// can catch at each bus's stop, after the walk there, from Bus Time. Not the push server's: it
// builds `Change.swift` and `TrainService.swift` but not Bus Time.

extension TrainService {
    /// `board` with each connection's ways by bus added, among its trains' by when each leaves
    /// the change; unchanged without buses, or if Bus Time can't be reached.
    static func addingBuses(to board: Board, change: Change, now: Date = .now) async -> Board {
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
