import Foundation
@testable import TrainCore

/// Writes protobuf's wire format, for making GTFS-realtime feeds to read.
struct Protobuf {
    private(set) var bytes: [UInt8] = []

    init(_ build: (inout Protobuf) -> Void = { _ in }) {
        build(&self)
    }

    var data: Data { Data(bytes) }

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wireType: 0)
        append(varint: value)
    }

    /// An int32 or int64 field: protobuf writes a negative one in 10 bytes.
    mutating func int(_ field: Int, _ value: Int64) {
        varint(field, UInt64(bitPattern: value))
    }

    mutating func string(_ field: Int, _ text: String) {
        lengthDelimited(field, Array(text.utf8))
    }

    mutating func message(_ field: Int, _ build: (inout Protobuf) -> Void) {
        message(field, Protobuf(build))
    }

    mutating func message(_ field: Int, _ message: Protobuf) {
        lengthDelimited(field, message.bytes)
    }

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        key(field, wireType: 1)
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    mutating func fixed32(_ field: Int, _ value: UInt32) {
        key(field, wireType: 5)
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    /// Bytes as they are, for writing what isn't protobuf.
    mutating func raw(_ more: [UInt8]) {
        bytes += more
    }

    mutating func key(_ field: Int, wireType: UInt64) {
        append(varint: UInt64(field) << 3 | wireType)
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        return bytes + [UInt8(value)]
    }

    private mutating func lengthDelimited(_ field: Int, _ content: [UInt8]) {
        key(field, wireType: 2)
        append(varint: UInt64(content.count))
        bytes += content
    }

    private mutating func append(varint value: UInt64) {
        bytes += Self.varint(value)
    }
}

/// A stop on a trip in a made-up feed, with its times in minutes from `now`.
struct FeedStop {
    var id: String
    var arrival: Double?
    var departure: Double?

    init(_ id: String, arrival: Double? = nil, departure: Double? = nil) {
        self.id = id
        self.arrival = arrival
        self.departure = departure
    }

    /// Arriving and leaving at the same time, as the lettered lines' feeds have it.
    init(_ id: String, at minutes: Double) {
        self.init(id, arrival: minutes, departure: minutes)
    }
}

/// GTFS-realtime feeds written as the MTA writes them, extensions and all.
enum GTFSFeed {
    /// Seconds since 1970, as the feeds give times.
    static func seconds(_ minutes: Double) -> UInt64 {
        UInt64(now.addingTimeInterval(minutes * 60).timeIntervalSince1970)
    }

    /// A FeedMessage made `made` minutes from `now` (nil: not saying when), with `entities`.
    static func feed(made: Double? = 0, _ entities: [Protobuf]) -> Data {
        Protobuf { feed in
            feed.message(1) { header in // FeedMessage.header
                header.string(1, "1.0") // gtfs_realtime_version
                header.varint(2, 0) // incrementality: FULL_DATASET
                if let made { header.varint(3, seconds(made)) } // timestamp
                header.message(1001) { nyct in // NyctFeedHeader
                    nyct.string(1, "1.0")
                    nyct.message(2) { trip in // trip_replacement_period
                        trip.string(1, "R")
                        trip.message(2) { $0.varint(2, seconds(30)) }
                    }
                }
            }
            for entity in entities {
                feed.message(2, entity) // FeedMessage.entity
            }
        }.data
    }

    /// A FeedEntity with the TripUpdate of trip `id`. `assigned` is the MTA's
    /// is_assigned, left out with nil; `delay` is written into each StopTimeEvent.
    static func trip(_ id: String, route: String = "R", assigned: Bool? = true, delay: Int64? = nil,
                     stops: [FeedStop]) -> Protobuf {
        Protobuf { entity in
            entity.string(1, "000001" + id) // FeedEntity.id
            entity.message(3) { update in // FeedEntity.trip_update
                update.message(1) { trip in // TripUpdate.trip
                    trip.string(1, id) // trip_id
                    trip.string(3, "20260509") // start_date
                    trip.string(5, route) // route_id
                    trip.message(1001) { nyct in // NyctTripDescriptor
                        nyct.string(1, "1\(route) 1234+ 95S/G08") // train_id
                        if let assigned { nyct.varint(2, assigned ? 1 : 0) } // is_assigned
                        nyct.varint(3, 1) // direction: NORTH
                    }
                }
                for stop in stops {
                    update.message(2) { stopTime in // TripUpdate.stop_time_update
                        if let arrival = stop.arrival {
                            stopTime.message(2) { event in // arrival
                                if let delay { event.int(1, delay) } // delay
                                event.int(2, Int64(seconds(arrival))) // time
                            }
                        }
                        if let departure = stop.departure {
                            stopTime.message(3) { event in // departure
                                if let delay { event.int(1, delay) }
                                event.int(2, Int64(seconds(departure)))
                            }
                        }
                        stopTime.string(4, stop.id) // stop_id
                        stopTime.message(1001) { nyct in // NyctStopTimeUpdate
                            nyct.string(1, "1") // scheduled_track
                            nyct.string(2, "1") // actual_track
                        }
                    }
                }
            }
        }
    }

    /// A FeedEntity with the VehiclePosition of trip `id`: at or on its way to
    /// `stop`, with `status` its current_status, left out with nil.
    static func vehicle(_ id: String, route: String = "R", at stop: String, status: UInt64?) -> Protobuf {
        Protobuf { entity in
            entity.string(1, "000002" + id) // FeedEntity.id
            entity.message(4) { vehicle in // FeedEntity.vehicle
                vehicle.message(1) { trip in // VehiclePosition.trip
                    trip.string(1, id)
                    trip.string(5, route)
                }
                vehicle.varint(3, 12) // current_stop_sequence
                if let status { vehicle.varint(4, status) } // current_status
                vehicle.varint(5, seconds(-0.5)) // timestamp
                vehicle.string(7, stop) // stop_id
            }
        }
    }
}
