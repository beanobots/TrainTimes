import Foundation

/// Makes the `Timetable` the app falls back on from the MTA's GTFS: its trips running on each
/// service day from yesterday's to a week from today (yesterday's, for its trips after
/// midnight), with each trip's stop times made into a pattern shared with every trip that calls
/// at the same stops the same time apart.
enum TimetableBuilder {
    /// The MTA's supplemented subway GTFS: the timetable with the next 7 days' planned work,
    /// updated through the day.
    static let source = URL(string: "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_supplemented.zip")!

    /// The GTFS files it reads.
    static let files = ["trips.txt", "stop_times.txt", "calendar.txt", "calendar_dates.txt"]

    /// The service days it covers: yesterday's, today's and the next seven.
    static let daysBefore = 1
    static let daysAfter = 7

    static let newYork = TimeZone(identifier: "America/New_York")!

    struct Problem: Error, CustomStringConvertible {
        let description: String
    }

    /// Downloads `source`, unzips it into a temporary folder and builds from it.
    static func download(from source: URL = source, now: Date = .now) async throws -> Timetable {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("timetable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        let (zip, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Problem(description: "timetable: \(source) answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        // A minute or so of waiting on unzip and reading
        return try await Concurrency.offPool {
            try unzip(zip, into: folder)
            return try build(from: folder, now: now)
        }
    }

    /// The `files` from `zip`, with macOS's unzip.
    static func unzip(_ zip: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zip.path, "-d", folder.path] + files
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Problem(description: "timetable: unzip exited with \(process.terminationStatus)")
        }
    }

    /// Builds from the GTFS files in `folder`, for the service days around `now`'s (New York's).
    static func build(from folder: URL, now: Date = .now) throws -> Timetable {
        let file = { (name: String) in folder.appendingPathComponent(name) }
        let days = serviceDays(around: now)
        let calendar = try ServiceCalendar(calendar: file("calendar.txt"), dates: file("calendar_dates.txt"))

        // Each trip's route, and the days it runs on (indexes into `days`)
        var tripRoutes: [String: String] = [:]
        var tripDays: [String: [Int]] = [:]
        var running: [String: [Int]] = [:]
        try CSV.rows(in: file("trips.txt"), columns: ["trip_id", "route_id", "service_id"]) { row in
            let service = row[2]
            let on = running[service] ?? {
                let on = days.indices.filter { calendar.runs(service, on: days[$0].date) }
                running[service] = on
                return on
            }()
            guard !on.isEmpty else { return }
            tripRoutes[row[0]] = row[1]
            tripDays[row[0]] = on
        }

        // Their stop times
        var stopIndex: [String: UInt16] = [:]
        var stops: [String] = []
        var stopTimes: [String: [(sequence: Int, stop: UInt16, arrives: Int, departs: Int)]] = [:]
        let columns = ["trip_id", "stop_id", "arrival_time", "departure_time", "stop_sequence"]
        try CSV.rows(in: file("stop_times.txt"), columns: columns) { row in
            guard tripDays[row[0]] != nil, let arrives = seconds(row[2]), let sequence = Int(row[4]) else { return }
            let id = row[1]
            let stop = try stopIndex[id] ?? {
                guard stops.count < Int(UInt16.max) else { throw Timetable.Problem.tooBig }
                stopIndex[id] = UInt16(stops.count)
                stops.append(id)
                return UInt16(stops.count - 1)
            }()
            stopTimes[row[0], default: []].append((sequence, stop, arrives, seconds(row[3]) ?? arrives))
        }

        // Patterns, and when each one's trips start
        var routeIndex: [String: UInt8] = [:]
        var routes: [String] = []
        var patternIndex: [Timetable.Pattern: Int] = [:]
        var patterns: [Timetable.Pattern] = []
        var starts: [[UInt32]] = []
        let base = days[0].start
        for (trip, unsorted) in stopTimes {
            guard let route = tripRoutes[trip], let on = tripDays[trip] else { continue }
            let calls = unsorted.sorted { $0.sequence < $1.sequence }
            let first = calls[0].arrives
            // Not a trip whose times go backwards or don't fit, a mistake in the GTFS
            let offsets = calls.map { $0.arrives - first }
            guard zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }), let last = calls.last,
                  last.arrives - first <= Int(UInt16.max), last.departs - first <= Int(UInt16.max) else { continue }
            let tripStarts = on.map { days[$0].start.timeIntervalSince(base) + TimeInterval(first) }
            guard tripStarts.allSatisfy({ (0...TimeInterval(UInt32.max)).contains($0) }) else { continue }
            let routeNumber = try routeIndex[route] ?? {
                guard routes.count < Int(UInt8.max) else { throw Timetable.Problem.tooBig }
                routeIndex[route] = UInt8(routes.count)
                routes.append(route)
                return UInt8(routes.count - 1)
            }()
            let pattern = Timetable.Pattern(route: routeNumber, calls: zip(calls, offsets).map { call, offset in
                Timetable.Call(stop: call.stop, arrives: UInt16(offset),
                               waits: UInt8(clamping: max(0, call.departs - call.arrives)))
            })
            let index = patternIndex[pattern] ?? {
                patternIndex[pattern] = patterns.count
                patterns.append(pattern)
                starts.append([])
                return patterns.count - 1
            }()
            starts[index] += tripStarts.map { UInt32($0) }
        }
        guard !patterns.isEmpty else { throw Problem(description: "timetable: no trips run on \(days.map(\.date))") }
        return Timetable(made: now, base: base, stops: stops, routes: routes, patterns: patterns, starts: starts)
    }

    /// A service day: its date ("20261022", as GTFS has them) and when its times count from.
    struct ServiceDay {
        let date: String
        let start: Date
    }

    /// From yesterday's to a week from today's, in New York. A day's times count from noon less
    /// 12 hours (GTFS's rule, so they're right on days the clocks change).
    static func serviceDays(around now: Date) -> [ServiceDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        return (-daysBefore...daysAfter).compactMap { offset in
            var noon = today
            noon.hour = 12
            guard let todayNoon = calendar.date(from: noon),
                  let dayNoon = calendar.date(byAdding: .day, value: offset, to: todayNoon) else { return nil }
            let day = calendar.dateComponents([.year, .month, .day], from: dayNoon)
            let date = String(format: "%04d%02d%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
            return ServiceDay(date: date, start: dayNoon.addingTimeInterval(-12 * 60 * 60))
        }
    }

    /// "25:03:30" as seconds; times past midnight run past 24:00.
    static func seconds(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// Which services run on which dates: calendar.txt's weekdays between its dates, with
    /// calendar_dates.txt's exceptions (1 added, 2 removed).
    struct ServiceCalendar {
        private var weekly: [String: (days: [Bool], from: String, to: String)] = [:]
        private var exceptions: [String: [String: Bool]] = [:]

        init(calendar: URL, dates: URL) throws {
            let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            try CSV.rows(in: calendar, columns: ["service_id", "start_date", "end_date"] + weekdays) { row in
                weekly[row[0]] = (row[3...].map { $0 == "1" }, row[1], row[2])
            }
            try CSV.rows(in: dates, columns: ["service_id", "date", "exception_type"]) { row in
                exceptions[row[0], default: [:]][row[1]] = row[2] == "1"
            }
        }

        /// Whether `service` runs on `date` ("20261022").
        func runs(_ service: String, on date: String) -> Bool {
            if let exception = exceptions[service]?[date] { return exception }
            guard let weekly = weekly[service], weekly.from <= date, date <= weekly.to,
                  let weekday = Self.weekday(of: date) else { return false }
            return weekly.days[weekday]
        }

        /// 0 for Sunday, as calendar.txt's columns from `sunday`.
        static func weekday(of date: String) -> Int? {
            guard date.count == 8, let year = Int(date.prefix(4)), let month = Int(date.dropFirst(4).prefix(2)),
                  let day = Int(date.suffix(2)) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
            else { return nil }
            return calendar.component(.weekday, from: noon) - 1
        }
    }
}

/// Reads GTFS files: CSV with a header, fields in double quotes allowed.
enum CSV {
    /// Calls `body` with each row of the file at `url`, as just the `columns` named, in that order
    /// (empty if a row is short). Throws if the header lacks one.
    static func rows(in url: URL, columns: [String], _ body: ([String]) throws -> Void) throws {
        try rows(in: Data(contentsOf: url), columns: columns, body)
    }

    static func rows(in data: Data, columns: [String], _ body: ([String]) throws -> Void) throws {
        var indexes: [Int]?
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var bytes = buffer[...]
            // Any byte-order mark
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
            try lines(in: bytes) { fields in
                guard let indexes else {
                    let header = fields.map { $0.trimmingCharacters(in: .whitespaces) }
                    indexes = try columns.map { name in
                        guard let index = header.firstIndex(of: name) else {
                            throw TimetableBuilder.Problem(description: "timetable: no \(name) column")
                        }
                        return index
                    }
                    return
                }
                guard fields != [""] else { return }
                try body(indexes.map { $0 < fields.count ? fields[$0] : "" })
            }
        }
        guard indexes != nil else { throw TimetableBuilder.Problem(description: "timetable: an empty file") }
    }

    /// Each line's fields.
    private static func lines(in bytes: Slice<UnsafeRawBufferPointer>, _ body: ([String]) throws -> Void) throws {
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var index = bytes.startIndex
        let finishField = {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            if quoted {
                if byte == UInt8(ascii: "\"") {
                    // A doubled quote is one
                    if index < bytes.endIndex, bytes[index] == UInt8(ascii: "\"") {
                        field.append(byte)
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(byte)
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                quoted = true
            case UInt8(ascii: ","):
                finishField()
            case UInt8(ascii: "\n"):
                finishField()
                try body(row)
                row.removeAll(keepingCapacity: true)
            case UInt8(ascii: "\r"):
                break
            default:
                field.append(byte)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            finishField()
            try body(row)
        }
    }
}
