import Foundation

/// One train's predicted arrival at a stop.
struct Arrival: Codable, Hashable, Sendable {
    /// A real-time route id, with express versions folded in ("6X" is "6").
    let route: String
    let time: Date
    /// Departure time if later than `time` (it waits at the platform); else nil.
    var departure: Date? = nil
    /// Platform id plus N or S, e.g. "R31N".
    let stop: String
    /// The trip's last stop.
    let lastStop: String
    /// True if a train is assigned to the trip (live prediction); false if the time is still the
    /// timetable's.
    let isLive: Bool
    /// The feed's trip id, so a countdown can follow one train as its time changes.
    var trip: String = ""
    /// Remaining stops up to and including this one, starting at the current or next stop
    /// (sometimes the one just left), or the origin before it sets off. A stop listed twice in a
    /// row under two ids (H19S then H04S at Broad Channel) appears once, as the second.
    var approach: [Stop] = []
    /// The feed's vehicle position, if any.
    var position: Position? = nil

    /// When it leaves the stop: the last moment to catch it.
    var leaves: Date { max(departure ?? time, time) }
    /// Whether the trip ends here, including at a separately named track of this platform (the
    /// H's at Broad Channel).
    var endsHere: Bool { StationDirectory.isSameStop(stop, lastStop) }

    /// The terminal's name: "Forest Hills" for "G08N".
    var terminal: String? { StationDirectory.shortName(forStop: lastStop) }
    var lineLabel: String { LineStyle.of(route).label }

    struct Stop: Codable, Hashable, Sendable {
        /// Platform id plus N or S, e.g. "R34N".
        let id: String
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
        /// Not yet left the first stop.
        case starting
        case at(Int)
        /// On its way to this stop from the previous one.
        case approaching(Int)
    }

    /// Nil when the feed doesn't list its stops.
    func place(now: Date) -> Place? {
        guard !approach.isEmpty else { return nil }
        if !isLive { return .starting }
        // The position may use a stop's other id, which `approach` drops
        if let position, let index = approach.firstIndex(where: { StationDirectory.isSameStop($0.id, position.stop) }) {
            return position.isStopped ? .at(index) : .approaching(index)
        }
        // No position: the first stop not yet due; if all are due, held at the last
        if let next = approach.firstIndex(where: { $0.time > now }) { return .approaching(next) }
        return .at(approach.count - 1)
    }
}

enum SubwayFeed {
    /// Max feed age before it's considered stopped. The MTA regenerates feeds about every 30 s;
    /// this allows for a late one. Age is measured against the newest feed fetched with it, not
    /// the device clock, which may be fast.
    static let staleAfter: TimeInterval = 3 * 60
    /// How fast the device clock may be. A feed with no newer one to compare to (or a batch that
    /// has all stopped) goes stale only this much later.
    static let clockAllowance: TimeInterval = 7 * 60

    /// Whether a feed made at `made` has stopped updating: over `staleAfter` older than `newest`
    /// (capped at `now`), or over `staleAfter + clockAllowance` older than `now`.
    static func isStale(made: Date, newest: Date?, now: Date) -> Bool {
        let newest = min(newest ?? now, now)
        return newest.timeIntervalSince(made) > staleAfter
            || now.timeIntervalSince(made) > staleAfter + clockAllowance
    }

    /// The newest of `feeds`' timestamps, to measure the others' age by; nil if none has one.
    static func newest(_ feeds: [Data]) -> Date? {
        feeds.compactMap { made($0) }.max()
    }

    /// The feed's header timestamp; nil if missing or unreadable.
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

    /// Minimal GTFS-realtime decoder (gtfs.org/realtime), so the widget needs no protobuf library.
    /// Returns an `Arrival` for each trip stopping at one of `stopIDs`. Throws `FeedError.stale`
    /// if the feed has stopped updating (`isStale`; `newest` is the batch's newest timestamp).
    static func arrivals(at stopIDs: Set<String>, in data: Data, newest: Date? = nil,
                         now: Date = Date()) throws -> [Arrival] {
        let reader = ProtobufReader(data)
        var arrivals: [Arrival] = []
        var positions: [String: Arrival.Position] = [:]
        try reader.fields(until: reader.count) { field in
            switch field {
            case 1: // FeedMessage.header
                let made = try timestamp(reader)
                // 0 means no timestamp
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
        // Positions come in separate entities
        for index in arrivals.indices {
            arrivals[index].position = positions[arrivals[index].trip]
        }
        return arrivals.sorted { $0.time < $1.time }
    }

    /// The feed with only the trips listing one of `stopIDs`, and their vehicle positions, for
    /// the push server to send a phone just what its board reads (a fraction of the feed, for
    /// one with little signal). `arrivals(at:)` with any of `stopIDs` finds the same in it as in
    /// the whole feed. Kept fields are copied byte for byte; the header and any other top-level
    /// fields are kept as they are.
    static func trimmed(_ data: Data, toStops stopIDs: Set<String>) throws -> Data {
        let reader = ProtobufReader(data)
        // Each top-level field's bytes; an entity's with its trip, and whether it's a trip
        // update calling here (kept) or a vehicle (kept if its trip is)
        var parts: [(bytes: Range<Int>, entity: (trip: String, calls: Bool)?)] = []
        var kept: Set<String> = []
        while reader.position < reader.count {
            let start = reader.position
            let key = try reader.varint()
            guard key >> 3 == 2, key & 7 == 2 else { // FeedMessage.entity
                try reader.skip(wireType: key & 7)
                parts.append((start..<reader.position, nil))
                continue
            }
            var trip = ""
            var calls = false
            try reader.message { field in
                switch field {
                case 3: (trip, calls) = try tripCalls(reader, at: stopIDs) // FeedEntity.trip_update
                case 4: trip = try vehicleTrip(reader) // FeedEntity.vehicle
                default: return false
                }
                return true
            }
            if calls { kept.insert(trip) }
            parts.append((start..<reader.position, (trip, calls)))
        }
        var trimmed = Data()
        for part in parts {
            if let entity = part.entity, !entity.calls, entity.trip.isEmpty || !kept.contains(entity.trip) { continue }
            trimmed.append(contentsOf: reader.slice(part.bytes))
        }
        return trimmed
    }

    /// A TripUpdate's trip id, and whether it lists one of `stopIDs`.
    private static func tripCalls(_ reader: ProtobufReader, at stopIDs: Set<String>) throws -> (trip: String, calls: Bool) {
        var trip = ""
        var calls = false
        try reader.message { field in
            switch field {
            case 1: // TripUpdate.trip
                try reader.message { field in
                    guard field == 1 else { return false } // TripDescriptor.trip_id
                    trip = try reader.string()
                    return true
                }
            case 2: // TripUpdate.stop_time_update
                try reader.message { field in
                    guard field == 4 else { return false } // stop_id
                    if stopIDs.contains(try reader.string()) { calls = true }
                    return true
                }
            default:
                return false
            }
            return true
        }
        return (trip, calls)
    }

    /// A VehiclePosition's trip id; empty if it has none.
    private static func vehicleTrip(_ reader: ProtobufReader) throws -> String {
        var trip = ""
        try reader.message { field in
            guard field == 1 else { return false } // VehiclePosition.trip
            try reader.message { field in
                guard field == 1 else { return false } // TripDescriptor.trip_id
                trip = try reader.string()
                return true
            }
            return true
        }
        return trip
    }

    /// For each trip of `routes` calling at one of `stopIDs`, its stops after that one, in order,
    /// each with its ride time from the stop in `stopIDs`: nil where either has no time.
    static func timedStops(after stopIDs: Set<String>, on routes: Set<String>,
                           in data: Data) throws -> [[(id: String, ride: TimeInterval?)]] {
        let reader = ProtobufReader(data)
        var lists: [[(id: String, ride: TimeInterval?)]] = []
        try reader.fields(until: reader.count) { field in
            guard field == 2 else { return false } // FeedMessage.entity
            try reader.message { field in
                guard field == 3 else { return false } // FeedEntity.trip_update
                let trip = try tripStops(reader)
                if routes.contains(Lines.normalized(trip.route)), let at = trip.stops.firstIndex(where: { stopIDs.contains($0.id) }) {
                    let start = trip.stops[at].time
                    lists.append(trip.stops[(at + 1)...].map { stop in
                        (stop.id, start.flatMap { start in stop.time.map { $0.timeIntervalSince(start) } })
                    })
                }
                return true
            }
            return true
        }
        return lists
    }

    /// A trip's route and every stop it lists, in order, with its time if any (arrival, else
    /// departure).
    private static func tripStops(_ reader: ProtobufReader) throws -> (route: String, stops: [(id: String, time: Date?)]) {
        var route = ""
        var stops: [(id: String, time: Date?)] = []
        try reader.message { field in
            switch field {
            case 1: // TripUpdate.trip
                try reader.message { field in
                    guard field == 5 else { return false } // TripDescriptor.route_id
                    route = try reader.string()
                    return true
                }
            case 2: // TripUpdate.stop_time_update
                let (stop, arrival, departure) = try stopTimeUpdate(reader)
                let due = arrival != 0 ? arrival : departure
                stops.append((stop, due == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(due))))
            default:
                return false
            }
            return true
        }
        return (route, stops)
    }

    /// The trip's arrival at each of `stopIDs` (the Nearby tab queries several stations, and a trip
    /// can call at more than one).
    private static func tripUpdate(_ reader: ProtobufReader, at stopIDs: Set<String>) throws -> [Arrival] {
        var route = ""
        var isLive = false
        var trip = ""
        /// Stops with a time
        var stops: [Arrival.Stop] = []
        /// Last stop, with or without a time
        var lastStop: String?
        /// Indexes in `stops` matching `stopIDs`, with the departure if later than arrival
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
                let (stop, arrival, departure) = try stopTimeUpdate(reader)
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
        // Only merge if a stop is listed twice in a row before the last match
        let doubled = matches.last.map { last in
            (0..<last.at).contains { StationDirectory.isSameStop(stops[$0].id, stops[$0 + 1].id) }
        } ?? false
        return matches.map { match in
            Arrival(
                route: Lines.normalized(route),
                time: stops[match.at].time,
                departure: match.departure.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                stop: stops[match.at].id,
                lastStop: lastStop,
                isLive: isLive,
                trip: trip,
                approach: doubled ? once(stops[...match.at]) : Array(stops[...match.at])
            )
        }
    }

    /// A StopTimeUpdate's stop id, and its arrival and departure times (`eventTime`; 0 for none).
    private static func stopTimeUpdate(_ reader: ProtobufReader) throws -> (stop: String, arrival: UInt64, departure: UInt64) {
        var stop = ""
        var arrival: UInt64 = 0
        var departure: UInt64 = 0
        try reader.message { field in
            switch field {
            case 4: stop = try reader.string() // stop_id
            case 2: arrival = try eventTime(reader)
            case 3: departure = try eventTime(reader)
            default: return false
            }
            return true
        }
        return (stop, arrival, departure)
    }

    /// `stops` with consecutive duplicates under another id (H19S, H04S) collapsed to the second,
    /// so maps show it once.
    private static func once(_ stops: ArraySlice<Arrival.Stop>) -> [Arrival.Stop] {
        var kept: [Arrival.Stop] = []
        for stop in stops {
            if let last = kept.last, StationDirectory.isSameStop(last.id, stop.id) { kept.removeLast() }
            kept.append(stop)
        }
        return kept
    }

    /// The trip a VehiclePosition is for, and the stop it's at or on its way to.
    private static func vehiclePosition(_ reader: ProtobufReader) throws -> (trip: String, position: Arrival.Position)? {
        var trip = ""
        var stop = ""
        // IN_TRANSIT_TO, omitted by the feed as protobuf's default
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

    /// FeedHeader.timestamp in Unix seconds; 0 if missing or outside `plausibleTimes`.
    private static func timestamp(_ reader: ProtobufReader) throws -> UInt64 {
        var time: UInt64 = 0
        try reader.message { field in
            guard field == 3 else { return false }
            time = try reader.varint()
            return true
        }
        return plausibleTimes.contains(time) ? time : 0
    }

    /// StopTimeEvent.time; 0 if missing or outside `plausibleTimes`.
    private static func eventTime(_ reader: ProtobufReader) throws -> UInt64 {
        var time: UInt64 = 0
        try reader.message { field in
            guard field == 2 else { return false }
            time = try reader.varint()
            return true
        }
        return plausibleTimes.contains(time) ? time : 0
    }

    /// 2000 to 2100 in Unix seconds. Times outside count as none (e.g. a negative time, which
    /// reads as far future).
    private static let plausibleTimes: ClosedRange<UInt64> = 946_684_800...4_102_444_800
}

enum FeedError: Error {
    case malformed
    /// Too old to trust (`SubwayFeed.isStale`).
    case stale
}

/// Reads protobuf wire format: varints, strings and nested messages.
private final class ProtobufReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var count: Int { bytes.count }

    /// The bytes read in `range`, for copying a field as it is.
    func slice(_ range: Range<Int>) -> ArraySlice<UInt8> { bytes[range] }

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

    /// Reads a nested message, passing each field number to `handle`. It reads the field and
    /// returns true, or returns false to skip it.
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

    func skip(wireType: UInt64) throws {
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
