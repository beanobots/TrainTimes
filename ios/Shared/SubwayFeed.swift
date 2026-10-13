import Foundation

/// One train's predicted arrival at a stop.
struct Arrival: Hashable, Sendable {
    /// A real-time route id, with express versions folded in ("6X" is "6").
    let route: String
    let time: Date
    /// The last stop of the trip, whose station is where the train ends up.
    let lastStop: String
    /// True when a real train is running this trip, so the time is a live
    /// prediction. False when the MTA hasn't assigned a train to it yet, so
    /// the time is still the timetable's.
    let isLive: Bool

    var terminal: String? { StationDirectory.terminalName(forStop: lastStop) }
}

enum SubwayFeed {
    /// The trains of `route` due at the platform `stopID` after `now`, soonest first.
    static func upcoming(stopID: String, route: String, from data: Data, now: Date = Date()) throws -> [Arrival] {
        try arrivals(at: stopID, in: data).filter { $0.route == route && $0.time > now }
    }

    /// Decodes just enough of a GTFS-realtime feed (gtfs.org/realtime) to list,
    /// for every trip that stops at `stopID`, its route, arrival time, last
    /// stop and whether a train is assigned to it, so the widget needs no
    /// protobuf library.
    static func arrivals(at stopID: String, in data: Data) throws -> [Arrival] {
        let reader = ProtobufReader(data)
        var arrivals: [Arrival] = []
        try reader.fields(until: reader.count) { field in
            guard field == 2 else { return false } // FeedMessage.entity
            try reader.message { field in
                guard field == 3 else { return false } // FeedEntity.trip_update
                var route = ""
                var time: UInt64 = 0
                var lastStop = ""
                var isLive = false
                try reader.message { field in
                    switch field {
                    case 1: // TripUpdate.trip
                        try reader.message { field in
                            switch field {
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
                        if stop == stopID { time = arrival != 0 ? arrival : departure }
                        lastStop = stop
                    default:
                        return false
                    }
                    return true
                }
                if time != 0 {
                    arrivals.append(Arrival(
                        route: Lines.normalized(route),
                        time: Date(timeIntervalSince1970: TimeInterval(time)),
                        lastStop: lastStop,
                        isLive: isLive
                    ))
                }
                return true
            }
            return true
        }
        return arrivals.sorted { $0.time < $1.time }
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
