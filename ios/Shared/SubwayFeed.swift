import Foundation

/// One train's predicted arrival at a stop.
struct Arrival: Codable, Hashable, Sendable {
    /// A real-time route id, with express versions folded in ("6X" is "6").
    let route: String
    let time: Date
    /// Where it stops at the station: its platform's id plus N or S, e.g. "R31N".
    let stop: String
    /// The last stop of the trip, whose station is where the train ends up.
    let lastStop: String
    /// True when a real train is running this trip, so the time is a live
    /// prediction. False when the MTA hasn't assigned a train to it yet, so
    /// the time is still the timetable's.
    let isLive: Bool
    /// The trip's id in the feed, so a countdown can follow one train as its time changes.
    var trip: String = ""
    /// The stops the trip still lists, up to and including this one: first the
    /// one it's at or heading for (sometimes the one it just left), or, before
    /// it sets off, where it starts.
    var approach: [Stop] = []
    /// Where the feed says the train is; nil when it doesn't say.
    var position: Position? = nil

    var terminal: String? { StationDirectory.terminalName(forStop: lastStop) }
    var lineLabel: String { LineStyle.of(route).label }

    struct Stop: Codable, Hashable, Sendable {
        /// A platform's id plus N or S, e.g. "R34N".
        let id: String
        /// When the train is due there.
        let time: Date

        var name: String { StationDirectory.shortName(forStop: id) ?? id }
    }

    /// The feed's vehicle position for the trip.
    struct Position: Codable, Hashable, Sendable {
        /// The stop it's at, or on its way to.
        let stop: String
        let isStopped: Bool
    }

    /// Where the train is along `approach`.
    enum Place: Hashable, Sendable {
        /// It hasn't set off from the first stop.
        case starting
        /// Stopped at this stop.
        case at(Int)
        /// On its way to this stop, from the one before it.
        case approaching(Int)
    }

    /// Nil when the feed doesn't list its stops.
    func place(now: Date) -> Place? {
        guard !approach.isEmpty else { return nil }
        if !isLive { return .starting }
        if let position, let index = approach.firstIndex(where: { $0.id == position.stop }) {
            return position.isStopped ? .at(index) : .approaching(index)
        }
        // Without a position, the first stop it isn't due at yet
        return .approaching(approach.firstIndex { $0.time > now } ?? approach.count - 1)
    }
}

enum SubwayFeed {
    /// Decodes just enough of a GTFS-realtime feed (gtfs.org/realtime) to list,
    /// for every trip that stops at one of `stopIDs`, its route, arrival time,
    /// which of them it stops at, the stops before it, its last stop, whether a
    /// train is assigned to it and where that train is, so the widget needs no
    /// protobuf library.
    static func arrivals(at stopIDs: Set<String>, in data: Data) throws -> [Arrival] {
        let reader = ProtobufReader(data)
        var arrivals: [Arrival] = []
        var positions: [String: Arrival.Position] = [:]
        try reader.fields(until: reader.count) { field in
            guard field == 2 else { return false } // FeedMessage.entity
            try reader.message { field in
                switch field {
                case 3: // FeedEntity.trip_update
                    arrivals += try tripUpdate(reader, at: stopIDs)
                case 4: // FeedEntity.vehicle
                    if let vehicle = try vehiclePosition(reader) { positions[vehicle.trip] = vehicle.position }
                default:
                    return false
                }
                return true
            }
            return true
        }
        // A trip's position comes in an entity of its own
        for index in arrivals.indices {
            arrivals[index].position = positions[arrivals[index].trip]
        }
        return arrivals.sorted { $0.time < $1.time }
    }

    /// The trip's arrival at each of `stopIDs` it stops at: the Live tab asks
    /// about several stations at once, and one trip can call at more than one.
    private static func tripUpdate(_ reader: ProtobufReader, at stopIDs: Set<String>) throws -> [Arrival] {
        var route = ""
        var isLive = false
        var trip = ""
        /// The stops it has a time for
        var stops: [Arrival.Stop] = []
        /// Where it ends, whether or not there's a time for it
        var lastStop: String?
        /// Where in `stops` the trip calls at one of `stopIDs`
        var matches: [Int] = []
        try reader.message { field in
            switch field {
            case 1: // TripUpdate.trip
                try reader.message { field in
                    switch field {
                    case 1: trip = try reader.string() // TripDescriptor.trip_id
                    case 5: route = try reader.string() // TripDescriptor.route_id
                    case 1001: // the MTA's extension to TripDescriptor
                        try reader.message { field in
                            guard field == 2 else { return false } // is_assigned
                            isLive = try reader.varint() == 1
                            return true
                        }
                    default: return false
                    }
                    return true
                }
            case 2: // TripUpdate.stop_time_update
                var stop = ""
                var arrival: UInt64 = 0
                var departure: UInt64 = 0
                try reader.message { field in
                    switch field {
                    case 4: stop = try reader.string()
                    case 2: arrival = try eventTime(reader)
                    case 3: departure = try eventTime(reader)
                    default: return false
                    }
                    return true
                }
                lastStop = stop
                // Without a time, it would be due in 1970
                let due = arrival != 0 ? arrival : departure
                guard due != 0 else { return true }
                if stopIDs.contains(stop) {
                    matches.append(stops.count)
                }
                stops.append(Arrival.Stop(id: stop, time: Date(timeIntervalSince1970: TimeInterval(due))))
            default:
                return false
            }
            return true
        }
        guard let lastStop else { return [] }
        return matches.map { at in
            Arrival(
                route: Lines.normalized(route),
                time: stops[at].time,
                stop: stops[at].id,
                lastStop: lastStop,
                isLive: isLive,
                trip: trip,
                approach: Array(stops[...at])
            )
        }
    }

    /// The trip a VehiclePosition is for, and the stop it's at or on its way to.
    private static func vehiclePosition(_ reader: ProtobufReader) throws -> (trip: String, position: Arrival.Position)? {
        var trip = ""
        var stop = ""
        // IN_TRANSIT_TO, which the feed leaves out as protobuf's default
        var status: UInt64 = 2
        try reader.message { field in
            switch field {
            case 1: // VehiclePosition.trip
                try reader.message { field in
                    guard field == 1 else { return false } // TripDescriptor.trip_id
                    trip = try reader.string()
                    return true
                }
            case 4: status = try reader.varint() // VehiclePosition.current_status
            case 7: stop = try reader.string() // VehiclePosition.stop_id
            default: return false
            }
            return true
        }
        guard !trip.isEmpty, !stop.isEmpty else { return nil }
        // 1 is STOPPED_AT; 0 INCOMING_AT and 2 IN_TRANSIT_TO are both on the way
        return (trip, Arrival.Position(stop: stop, isStopped: status == 1))
    }

    /// StopTimeEvent.time
    private static func eventTime(_ reader: ProtobufReader) throws -> UInt64 {
        var time: UInt64 = 0
        try reader.message { field in
            guard field == 2 else { return false }
            time = try reader.varint()
            return true
        }
        return time
    }
}

enum FeedError: Error {
    case malformed
}

/// Reads protobuf wire format: varints, strings and nested messages.
private final class ProtobufReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var count: Int { bytes.count }

    func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < bytes.count, shift < 64 else { throw FeedError.malformed }
            let byte = bytes[position]
            position += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    func string() throws -> String {
        let end = try lengthDelimitedEnd()
        defer { position = end }
        return String(decoding: bytes[position..<end], as: UTF8.self)
    }

    /// Reads one nested message, passing each field number to `handle`, which
    /// reads the field and returns true, or returns false to have it skipped.
    func message(_ handle: (Int) throws -> Bool) throws {
        try fields(until: try lengthDelimitedEnd(), handle)
    }

    func fields(until end: Int, _ handle: (Int) throws -> Bool) throws {
        while position < end {
            let key = try varint()
            if try !handle(Int(key >> 3)) { try skip(wireType: key & 7) }
        }
        guard position == end else { throw FeedError.malformed }
    }

    private func skip(wireType: UInt64) throws {
        switch wireType {
        case 0: _ = try varint()
        case 1: position += 8
        case 2: position = try lengthDelimitedEnd()
        case 5: position += 4
        default: throw FeedError.malformed
        }
        guard position <= bytes.count else { throw FeedError.malformed }
    }

    private func lengthDelimitedEnd() throws -> Int {
        let length = try varint()
        guard length <= UInt64(bytes.count - position) else { throw FeedError.malformed }
        return position + Int(length)
    }
}
