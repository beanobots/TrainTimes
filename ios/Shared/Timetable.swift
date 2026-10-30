import Foundation

/// The MTA's timetable for every subway line and Staten Island, for when its real-time feeds
/// can't be reached. The push server builds it once a day from the MTA's supplemented GTFS
/// (the timetable with the coming week's planned work), for yesterday's service day through
/// a week from today, and the app keeps the latest it's downloaded (`TimetableStore`).
///
/// Trips that call at the same stops, the same time apart, share a `Pattern`, so each trip is
/// only its pattern and when it starts: the whole subway's week is about 1.3 MB, under 400 KB
/// compressed as sent.
struct Timetable: Sendable {
    /// When the server built it.
    let made: Date
    /// What `Trip.starts` counts from: the first service day's start.
    let base: Date
    /// Platform ids plus N or S ("R31N"), as `Call.stop` indexes them.
    let stops: [String]
    /// Route ids as the GTFS has them ("R", "6X"), as `Pattern.route` indexes them.
    let routes: [String]
    let patterns: [Pattern]
    /// Each pattern's trips' starts (seconds after `base`), soonest first, by pattern.
    let starts: [[UInt32]]

    /// Each stop's calls, as (pattern, call) indexes packed into one (`packed(pattern:call:)`), for
    /// `arrivals(at:from:to:)`: a quarter of the memory of the pairs, which a widget can't spare.
    private let calls: [String: [UInt32]]

    /// How many of a packed call's bits are the call's index: patterns have up to 61 calls, and
    /// some million patterns are left for the pattern's.
    private static let callBits: UInt32 = 12

    /// A pattern and call as one; nil if they don't fit.
    private static func packed(pattern: Int, call: Int) -> UInt32? {
        guard (0..<1 << callBits).contains(call), (0..<1 << (32 - callBits)).contains(pattern) else { return nil }
        return UInt32(pattern) << callBits | UInt32(call)
    }

    private static func unpacked(_ packed: UInt32) -> (pattern: Int, call: Int) {
        (Int(packed >> callBits), Int(packed & (1 << callBits - 1)))
    }

    /// A trip's stop.
    struct Call: Hashable, Sendable {
        /// Index into `stops`.
        let stop: UInt16
        /// Seconds after the trip starts that it gets there.
        let arrives: UInt16
        /// Seconds it waits there.
        let waits: UInt8
    }

    /// Calls shared by trips.
    struct Pattern: Hashable, Sendable {
        /// Index into `routes`.
        let route: UInt8
        let calls: [Call]
    }

    enum Problem: Error {
        case unreadable
        case tooBig
    }

    init(made: Date, base: Date, stops: [String], routes: [String], patterns: [Pattern], starts: [[UInt32]]) {
        self.made = made
        self.base = base
        self.stops = stops
        self.routes = routes
        self.patterns = patterns
        // Sorted already, as read: kept, not copied
        self.starts = starts.map { starts in
            zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 } ? starts : starts.sorted()
        }
        // Counted first, so each stop's array is made the size it needs
        var counts: [String: Int] = [:]
        for pattern in patterns {
            for stop in pattern.calls where Int(stop.stop) < stops.count {
                counts[stops[Int(stop.stop)], default: 0] += 1
            }
        }
        var calls: [String: [UInt32]] = [:]
        calls.reserveCapacity(counts.count)
        for (stop, count) in counts {
            calls[stop] = []
            calls[stop]?.reserveCapacity(count)
        }
        for (index, pattern) in patterns.enumerated() {
            for (call, stop) in pattern.calls.enumerated() where Int(stop.stop) < stops.count {
                // Too many to index (`encoded()` won't write those): left out
                guard let packed = Self.packed(pattern: index, call: call) else { continue }
                calls[stops[Int(stop.stop)], default: []].append(packed)
            }
        }
        self.calls = calls
    }

    /// When its last trip gets to its last stop; after that it has no trains.
    var ends: Date {
        let last = zip(patterns, starts).compactMap { pattern, starts in
            starts.last.map { Int($0) + Int(pattern.calls.last?.arrives ?? 0) }
        }.max() ?? 0
        return base.addingTimeInterval(TimeInterval(last))
    }

    /// Whether it has trains for `date`: it was built for days up to a week on.
    func covers(_ date: Date) -> Bool {
        date >= base && date < ends
    }

    /// The timetable's trains at `stopIDs` that leave from `start` on and get there by `end`, as
    /// the feeds' arrivals (`Arrival.isLive` false, as for the feeds' unassigned trips), in no
    /// particular order. Each one's `approach` starts at the last stop it's due to have reached
    /// by `start`, and its `trip` is the timetable's own, not the feeds'.
    func arrivals(at stopIDs: Set<String>, from start: Date, to end: Date) -> [Arrival] {
        let from = start.timeIntervalSince(base)
        let to = end.timeIntervalSince(base)
        var arrivals: [Arrival] = []
        for stopID in stopIDs {
            for packed in calls[stopID] ?? [] {
                let (index, position) = Self.unpacked(packed)
                let pattern = patterns[index]
                let call = pattern.calls[position]
                let arrives = TimeInterval(call.arrives)
                // The first trip that hasn't left by `start`
                let first = firstTrip(ofPattern: index, leaving: position, after: from)
                for tripStart in self.starts[index][first...] {
                    let offset = TimeInterval(tripStart)
                    guard offset + arrives <= to else { break }
                    arrivals.append(arrival(of: pattern, index: index, call: position, starting: offset,
                                            at: stopID, now: from))
                }
            }
        }
        return arrivals
    }

    /// The calls at `stopID`, as (pattern, call) indexes; for planning trips on it.
    func calls(at stopID: String) -> [(pattern: Int, call: Int)] {
        (calls[stopID] ?? []).map(Self.unpacked)
    }

    /// When (seconds after `base`) the first trip of pattern `index` that leaves its `call`th stop
    /// at or after `time` (also seconds after `base`) starts; nil if none does.
    func firstStart(ofPattern index: Int, leaving call: Int, after time: TimeInterval) -> TimeInterval? {
        let first = firstTrip(ofPattern: index, leaving: call, after: time)
        return first < starts[index].count ? TimeInterval(starts[index][first]) : nil
    }

    /// The index in `starts[index]` of the first trip of pattern `index` that leaves its `call`th
    /// stop at or after `time` (seconds after `base`); its count if none does.
    private func firstTrip(ofPattern index: Int, leaving call: Int, after time: TimeInterval) -> Int {
        let stop = patterns[index].calls[call]
        let leaves = TimeInterval(stop.arrives) + TimeInterval(stop.waits)
        let starts = self.starts[index]
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if TimeInterval(starts[middle]) + leaves < time { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The trip of `pattern` starting `offset` seconds after `base`, at its `call`th stop.
    private func arrival(of pattern: Pattern, index: Int, call position: Int, starting offset: TimeInterval,
                         at stopID: String, now: TimeInterval) -> Arrival {
        let date = { (call: Call) in self.base.addingTimeInterval(offset + TimeInterval(call.arrives)) }
        let call = pattern.calls[position]
        let time = date(call)
        let upTo = pattern.calls[...position]
        // From the last stop it's due to have reached (its first, before it sets off)
        let reached = upTo.lastIndex { offset + TimeInterval($0.arrives) <= now } ?? upTo.startIndex
        var approach: [Arrival.Stop] = []
        for stop in upTo[reached...] {
            let id = stops[Int(stop.stop)]
            // The same stop twice in a row under two ids (H19S, H04S): just the second
            if let previous = approach.last, StationDirectory.isSameStop(previous.id, id) { approach.removeLast() }
            approach.append(Arrival.Stop(id: id, time: date(stop)))
        }
        return Arrival(route: Lines.normalized(routes[Int(pattern.route)]), time: time,
                       departure: call.waits > 0 ? time.addingTimeInterval(TimeInterval(call.waits)) : nil,
                       stop: stopID, lastStop: pattern.calls.last.map { stops[Int($0.stop)] } ?? stopID,
                       isLive: false, trip: "timetable \(index) \(Int(offset))", approach: approach)
    }

    // MARK: The file

    /// "LWTT", for Leeway timetable.
    private static let magic: [UInt8] = [0x4C, 0x57, 0x54, 0x54]
    private static let version: UInt8 = 1

    /// As sent and saved: the format below, zlib-compressed. Throws if it has too many stops,
    /// routes or patterns for the format's sizes, or patterns or calls for `calls`' index.
    func encoded() throws -> Data {
        let longest = patterns.lazy.map(\.calls.count).max() ?? 0
        guard stops.count <= Int(UInt16.max), routes.count <= Int(UInt8.max),
              patterns.count <= 1 << (32 - Self.callBits), longest <= 1 << Self.callBits
        else { throw Problem.tooBig }
        var out = Writer()
        out.bytes(Self.magic)
        out.integer(Self.version)
        out.integer(Int64(made.timeIntervalSince1970.rounded()))
        out.integer(Int64(base.timeIntervalSince1970.rounded()))
        for strings in [stops, routes] {
            out.integer(UInt16(strings.count))
            for string in strings {
                let utf8 = Array(string.utf8.prefix(Int(UInt8.max)))
                out.integer(UInt8(utf8.count))
                out.bytes(utf8)
            }
        }
        out.integer(UInt32(patterns.count))
        for (pattern, starts) in zip(patterns, starts) {
            out.integer(pattern.route)
            out.integer(UInt16(pattern.calls.count))
            for call in pattern.calls {
                out.integer(call.stop)
                out.integer(call.arrives)
                out.integer(call.waits)
            }
            out.integer(UInt32(starts.count))
            for start in starts {
                out.integer(start)
            }
        }
        return try (out.data as NSData).compressed(using: .zlib) as Data
    }

    /// Reads `encoded()`'s output. Throws if it isn't one, or is a version this can't read.
    init(data: Data) throws {
        let raw: Data
        do {
            raw = try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw Problem.unreadable
        }
        self = try raw.withUnsafeBytes { try Self.read(Reader($0)) }
    }

    /// The decompressed format, read where it is rather than copied out first.
    private static func read(_ reader: Reader) throws -> Timetable {
        var reader = reader
        guard try reader.bytes(4).elementsEqual(magic), try reader.integer(UInt8.self) == version else {
            throw Problem.unreadable
        }
        let made = Date(timeIntervalSince1970: TimeInterval(try reader.integer(Int64.self)))
        let base = Date(timeIntervalSince1970: TimeInterval(try reader.integer(Int64.self)))
        var lists: [[String]] = []
        for _ in 0..<2 {
            let count = Int(try reader.integer(UInt16.self))
            var strings: [String] = []
            strings.reserveCapacity(count)
            for _ in 0..<count {
                let length = Int(try reader.integer(UInt8.self))
                strings.append(String(decoding: try reader.bytes(length), as: UTF8.self))
            }
            lists.append(strings)
        }
        let (stops, routes) = (lists[0], lists[1])
        let count = Int(try reader.integer(UInt32.self))
        // More than `calls`' index can hold
        guard count <= 1 << (32 - callBits) else { throw Problem.unreadable }
        var patterns: [Pattern] = []
        var allStarts: [[UInt32]] = []
        patterns.reserveCapacity(min(count, reader.remaining / 7))
        allStarts.reserveCapacity(min(count, reader.remaining / 7))
        for _ in 0..<count {
            let route = try reader.integer(UInt8.self)
            let callCount = Int(try reader.integer(UInt16.self))
            guard callCount <= 1 << callBits else { throw Problem.unreadable }
            var calls: [Call] = []
            calls.reserveCapacity(callCount)
            for _ in 0..<callCount {
                let call = Call(stop: try reader.integer(UInt16.self), arrives: try reader.integer(UInt16.self),
                                waits: try reader.integer(UInt8.self))
                guard Int(call.stop) < stops.count else { throw Problem.unreadable }
                calls.append(call)
            }
            guard Int(route) < routes.count, !calls.isEmpty else { throw Problem.unreadable }
            let startCount = Int(try reader.integer(UInt32.self))
            var starts: [UInt32] = []
            starts.reserveCapacity(min(startCount, reader.remaining / 4))
            for _ in 0..<startCount {
                starts.append(try reader.integer(UInt32.self))
            }
            patterns.append(Pattern(route: route, calls: calls))
            allStarts.append(starts)
        }
        return Timetable(made: made, base: base, stops: stops, routes: routes, patterns: patterns, starts: allStarts)
    }

    /// Little-endian integers and bytes.
    private struct Writer {
        var data = Data()

        mutating func bytes(_ bytes: [UInt8]) {
            data.append(contentsOf: bytes)
        }

        mutating func integer<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
    }

    /// Over the bytes it's given, which mustn't outlive it.
    private struct Reader {
        private let bytes: UnsafeRawBufferPointer
        private var at = 0

        init(_ bytes: UnsafeRawBufferPointer) {
            self.bytes = bytes
        }

        var remaining: Int { bytes.count - at }

        mutating func bytes(_ count: Int) throws -> UnsafeRawBufferPointer {
            guard count <= remaining else { throw Problem.unreadable }
            defer { at += count }
            return UnsafeRawBufferPointer(rebasing: bytes[at..<at + count])
        }

        mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard size <= remaining else { throw Problem.unreadable }
            defer { at += size }
            return T(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: T.self))
        }
    }
}
