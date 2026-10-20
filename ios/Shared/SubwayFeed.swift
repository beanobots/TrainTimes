import Foundation

/// One train's predicted arrival at a stop.
struct Arrival: Codable, Hashable, Sendable {
    /// A real-time route id, with express versions folded in ("6X" is "6").
    let route: String
    let time: Date
    /// When it's due to leave, where that's later than `time`: it waits at the
    /// platform. Nil when it leaves as it gets there.
    var departure: Date? = nil
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

    /// When it leaves the stop, so until when it can still be caught there.
    var leaves: Date { max(departure ?? time, time) }
    /// Whether its trip ends at this stop, so it doesn't leave from here.
    var endsHere: Bool { stop == lastStop }

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
    /// How old a feed can be and still be gone by: the MTA makes each one anew
    /// about every 30 seconds, and this allows for one that's late. One older
    /// than this has stopped updating. Its age goes by the newest of the feeds
    /// fetched with it rather than by this device's clock, which may be fast.
    static let staleAfter: TimeInterval = 3 * 60
    /// How fast this device's clock can be without every feed going out of
    /// date. A feed with no newer one to go by, or a set of them that have all
    /// stopped updating, goes out of date only this much later.
    static let clockAllowance: TimeInterval = 7 * 60

    /// Whether a feed made at `made` has stopped updating: it's more than
    /// `staleAfter` older than `newest`, the newest of the feeds fetched with
    /// it (or than `now`, where that's earlier), or more than `staleAfter` and
    /// `clockAllowance` older than `now`.
    static func isStale(made: Date, newest: Date?, now: Date) -> Bool {
        let newest = min(newest ?? now, now)
        return newest.timeIntervalSince(made) > staleAfter
            || now.timeIntervalSince(made) > staleAfter + clockAllowance
    }

    /// When the newest of `feeds` was made, for the others' age to go by; nil
    /// when none of them says.
    static func newest(_ feeds: [Data]) -> Date? {
        feeds.compactMap { made($0) }.max()
    }

    /// When a feed says it was made; nil when it doesn't say or can't be read.
    static func made(_ data: Data) -> Date? {
        let reader = ProtobufReader(data)
        var time: UInt64 = 0
        try? reader.fields(until: reader.count) { field in
            guard field == 1 else { return false } // FeedMessage.header
            time = try timestamp(reader)
            return true
        }
        return time != 0 ? Date(timeIntervalSince1970: TimeInterval(time)) : nil
    }

    /// Decodes just enough of a GTFS-realtime feed (gtfs.org/realtime) to list,
    /// for every trip that stops at one of `stopIDs`, its route, arrival time
    /// (and departure time, if later), which of them it stops at, the stops
    /// before it, its last stop, whether a train is assigned to it and where
    /// that train is, so the widget needs no protobuf library. A feed that has
    /// stopped updating (`isStale`, where `newest` is when the newest of the
    /// feeds fetched with it was made) throws `FeedError.stale`.
    static func arrivals(at stopIDs: Set<String>, in data: Data, newest: Date? = nil,
                         now: Date = Date()) throws -> [Arrival] {
        let reader = ProtobufReader(data)
        var arrivals: [Arrival] = []
        var positions: [String: Arrival.Position] = [:]
        try reader.fields(until: reader.count) { field in
            switch field {
            case 1: // FeedMessage.header
                let made = try timestamp(reader)
                // 0 is a feed that doesn't say when it was made
                if made != 0, isStale(made: Date(timeIntervalSince1970: TimeInterval(made)), newest: newest, now: now) {
                    throw FeedError.stale
                }
            case 2: // FeedMessage.entity
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
            default:
                return false
            }
            return true
        }
        // A trip's position comes in an entity of its own
        for index in arrivals.indices {
            arrivals[index].position = positions[arrivals[index].trip]
        }
        return arrivals.sorted { $0.time < $1.time }
    }

    /// For each trip of `routes` that calls at one of `stopIDs`, the stops it
    /// lists after that one, in order: where its train goes on to.
    static func stops(after stopIDs: Set<String>, on routes: Set<String>, in data: Data) throws -> [[String]] {
        let reader = ProtobufReader(data)
        var lists: [[String]] = []
        try reader.fields(until: reader.count) { field in
            guard field == 2 else { return false } // FeedMessage.entity
            try reader.message { field in
                guard field == 3 else { return false } // FeedEntity.trip_update
                let trip = try tripStops(reader)
                if routes.contains(Lines.normalized(trip.route)), let at = trip.stops.firstIndex(where: stopIDs.contains) {
                    lists.append(Array(trip.stops[(at + 1)...]))
                }
                return true
            }
            return true
        }
        return lists
    }

    /// A trip's route and every stop it lists, in order.
    private static func tripStops(_ reader: ProtobufReader) throws -> (route: String, stops: [String]) {
        var route = ""
        var stops: [String] = []
        try reader.message { field in
            switch field {
            case 1: // TripUpdate.trip
                try reader.message { field in
                    guard field == 5 else { return false } // TripDescriptor.route_id
                    route = try reader.string()
                    return true
                }
            case 2: // TripUpdate.stop_time_update
                try reader.message { field in
                    guard field == 4 else { return false } // stop_id
                    stops.append(try reader.string())
                    return true
                }
            default:
                return false
            }
            return true
        }
        return (route, stops)
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
        /// Where in `stops` the trip calls at one of `stopIDs`, and when it
        /// leaves there if that's later than it gets there
        var matches: [(at: Int, departure: UInt64?)] = []
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
                    matches.append((at: stops.count, departure: departure > due ? departure : nil))
                }
                stops.append(Arrival.Stop(id: stop, time: Date(timeIntervalSince1970: TimeInterval(due))))
            default:
                return false
            }
            return true
        }
        guard let lastStop else { return [] }
        return matches.map { match in
            Arrival(
                route: Lines.normalized(route),
                time: stops[match.at].time,
                departure: match.departure.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                stop: stops[match.at].id,
                lastStop: lastStop,
                isLive: isLive,
                trip: trip,
                approach: Array(stops[...match.at])
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

    /// FeedHeader.timestamp: when the feed was made, in seconds since 1970;
    /// 0 when it doesn't say, or says a time outside `plausibleTimes`.
    private static func timestamp(_ reader: ProtobufReader) throws -> UInt64 {
        var time: UInt64 = 0
        try reader.message { field in
            guard field == 3 else { return false }
            time = try reader.varint()
            return true
        }
        return plausibleTimes.contains(time) ? time : 0
    }

    /// StopTimeEvent.time; 0, as for none, when it's outside `plausibleTimes`.
    private static func eventTime(_ reader: ProtobufReader) throws -> UInt64 {
        var time: UInt64 = 0
        try reader.message { field in
            guard field == 2 else { return false }
            time = try reader.varint()
            return true
        }
        return plausibleTimes.contains(time) ? time : 0
    }

    /// The times a feed can mean, from 2000 to 2100, in seconds since 1970.
    /// One outside them is taken as none: a negative one, say, which reads as
    /// one far in the future.
    private static let plausibleTimes: ClosedRange<UInt64> = 946_684_800...4_102_444_800
}

enum FeedError: Error {
    case malformed
    /// Made too long ago to go by (`SubwayFeed.isStale`).
    case stale
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
