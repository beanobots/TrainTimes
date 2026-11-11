import Foundation

/// Makes the `Timetable`s the app falls back on from the MTA's GTFS: their trips running on each
/// service day from yesterday's to a week (or a month) from today (yesterday's, for its trips
/// after midnight), with each trip's stop times made into a pattern shared with every trip that
/// calls at the same stops the same time apart.
enum TimetableBuilder {
    /// The MTA's supplemented subway GTFS: the timetable with the next 7 days' planned work,
    /// updated through the day.
    static let source = URL(string: "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_supplemented.zip")!

    /// The MTA's bus GTFS: one for each borough's buses, and MTA Bus's.
    static let busSources = ["gtfs_b", "gtfs_bx", "gtfs_m", "gtfs_q", "gtfs_si", "gtfs_busco"].map {
        URL(string: "https://rrgtfsfeeds.s3.amazonaws.com/\($0).zip")!
    }

    /// The GTFS files it reads.
    static let files = ["trips.txt", "stop_times.txt", "calendar.txt", "calendar_dates.txt"]

    /// The service days it covers: yesterday's, today's and the next seven (or `days`).
    static let daysBefore = 1
    static let daysAfter = 7

    static let newYork = TimeZone(identifier: "America/New_York")!

    /// What a timetable's of, which decides what its routes are.
    enum Kind: Sendable {
        /// Routes are the GTFS's route ids ("R", "6X").
        case subway
        /// A route for each line each way it goes, its name and headsign with a tab between
        /// ("B63\tBAY RIDGE 95 ST"), and each stop's place, from stops.txt.
        case buses

        /// The GTFS files it reads.
        var files: [String] {
            self == .buses ? TimetableBuilder.files + ["routes.txt", "stops.txt"] : TimetableBuilder.files
        }
    }

    struct Problem: Error, CustomStringConvertible {
        let description: String
    }

    /// The subway's, for the next `days` days; its zip kept in `kept` (`download`).
    static func downloadSubway(days: Int = daysAfter, now: Date = .now, keptIn kept: URL? = nil) async throws -> Timetable {
        try await download(from: [source], kind: .subway, days: days, now: now, keptIn: kept)
    }

    /// The buses', for the next week; their zips kept in `kept` (`download`).
    static func downloadBuses(now: Date = .now, keptIn kept: URL? = nil) async throws -> Timetable {
        try await download(from: busSources, kind: .buses, now: now, keptIn: kept)
    }

    /// Downloads each of `sources`, unzips each into its own temporary folder and builds from
    /// them together. With `kept` (`DATA_DIR/gtfs/`), each zip is kept there with its ETag and
    /// downloaded again only once S3 has another (`GTFSZips`): the buses' six are some 55 MB, and
    /// most days the same as the day before's; the subway's week and month both build from one.
    static func download(from sources: [URL], kind: Kind, days: Int = daysAfter,
                         now: Date = .now, keptIn kept: URL? = nil) async throws -> Timetable {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("timetable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var feeds: [URL] = []
        for (number, source) in sources.enumerated() {
            let feed = folder.appendingPathComponent("\(number)")
            try FileManager.default.createDirectory(at: feed, withIntermediateDirectories: true)
            try await GTFSZips.shared.unzip(source, keptIn: kept, into: feed, files: kind.files)
            feeds.append(feed)
        }
        // A minute or so of reading (the buses' several)
        let folders = feeds
        return try await Concurrency.offPool { try build(from: folders, kind: kind, days: days, now: now) }
    }

    /// `files` from `zip`, with macOS's unzip.
    static func unzip(_ zip: URL, into folder: URL, files: [String] = files) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zip.path, "-d", folder.path] + files
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Problem(description: "timetable: unzip exited with \(process.terminationStatus)")
        }
    }

    /// The subway's, from the GTFS files in `folder`, for the week around `now`'s (New York's).
    static func build(from folder: URL, now: Date = .now) throws -> Timetable {
        try build(from: [folder], kind: .subway, now: now)
    }

    /// Builds from the GTFS files in each of `folders`, for yesterday's service day to `days` after
    /// `now`'s (New York's). Each folder is read in turn, its services and trips its own (two
    /// feeds can have the same ids), and let go of before the next: the buses' stop times are
    /// hundreds of MB. A stop id is the same stop in any of them.
    static func build(from folders: [URL], kind: Kind = .subway, days count: Int = daysAfter,
                      now: Date = .now) throws -> Timetable {
        let days = serviceDays(around: now, days: count)
        let base = days[0].start
        var stopIndex: [String: UInt16] = [:]
        var stops: [String] = []
        var places: [Timetable.Place?] = []
        var routeIndex: [String: UInt16] = [:]
        var routes: [String] = []
        var patternIndex: [Timetable.Pattern: Int] = [:]
        var patterns: [Timetable.Pattern] = []
        var starts: [[UInt32]] = []

        for folder in folders {
            let file = { (name: String) in folder.appendingPathComponent(name) }
            let calendar = try ServiceCalendar(calendar: file("calendar.txt"), dates: file("calendar_dates.txt"))

            // The buses' line names ("B63"), by route id
            var lines: [String: String] = [:]
            if kind == .buses {
                try CSV.rows(in: file("routes.txt"), columns: ["route_id", "route_short_name"]) { row in
                    lines[row[0]] = row[1].isEmpty ? row[0] : BusTime.canonical(row[1])
                }
            }

            // Each trip's route, and the days it runs on (indexes into `days`)
            var tripRoutes: [String: String] = [:]
            var tripDays: [String: [Int]] = [:]
            var running: [String: [Int]] = [:]
            let tripColumns = ["trip_id", "route_id", "service_id"] + (kind == .buses ? ["trip_headsign"] : [])
            try CSV.rows(in: file("trips.txt"), columns: tripColumns) { row in
                let service = row[2]
                let on = running[service] ?? {
                    let on = days.indices.filter { calendar.runs(service, on: days[$0].date) }
                    running[service] = on
                    return on
                }()
                guard !on.isEmpty else { return }
                tripRoutes[row[0]] = kind == .buses ? (lines[row[1]] ?? BusTime.canonical(row[1])) + "\t" + row[3] : row[1]
                tripDays[row[0]] = on
            }

            // Their stop times
            var stopTimes: [String: [(sequence: Int, stop: UInt16, arrives: Int, departs: Int)]] = [:]
            let columns = ["trip_id", "stop_id", "arrival_time", "departure_time", "stop_sequence"]
            try CSV.rows(in: file("stop_times.txt"), columns: columns) { row in
                guard tripDays[row[0]] != nil, let arrives = seconds(row[2]), let sequence = Int(row[4]) else { return }
                let id = row[1]
                let stop = try stopIndex[id] ?? {
                    guard stops.count < Int(UInt16.max) else { throw Timetable.Problem.tooBig }
                    stopIndex[id] = UInt16(stops.count)
                    stops.append(id)
                    places.append(nil)
                    return UInt16(stops.count - 1)
                }()
                stopTimes[row[0], default: []].append((sequence, stop, arrives, seconds(row[3]) ?? arrives))
            }

            // Where the stops it calls at are, those no folder before placed
            if kind == .buses {
                try CSV.rows(in: file("stops.txt"), columns: ["stop_id", "stop_name", "stop_lat", "stop_lon"]) { row in
                    guard let index = stopIndex[row[0]].map(Int.init), places[index] == nil,
                          let latitude = Double(row[2].trimmingCharacters(in: .whitespaces)),
                          let longitude = Double(row[3].trimmingCharacters(in: .whitespaces)) else { return }
                    places[index] = Timetable.Place(latitude: latitude, longitude: longitude, name: row[1])
                }
            }

            // Patterns, and when each one's trips start
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
                    guard routes.count < Int(UInt16.max) else { throw Timetable.Problem.tooBig }
                    routeIndex[route] = UInt16(routes.count)
                    routes.append(route)
                    return UInt16(routes.count - 1)
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
        }
        guard !patterns.isEmpty else { throw Problem(description: "timetable: no trips run on \(days.map(\.date))") }
        // A stop stops.txt left out: nowhere, under its id
        let placed = kind == .buses ? zip(places, stops).map { $0 ?? Timetable.Place(latitude: 0, longitude: 0, name: $1) } : nil
        return Timetable(made: now, base: base, stops: stops, routes: routes, patterns: patterns, starts: starts,
                         places: placed)
    }

    /// A service day: its date ("20261022", as GTFS has them) and when its times count from.
    struct ServiceDay {
        let date: String
        let start: Date
    }

    /// From yesterday's to `days` from today's (a week), in New York. A day's times count from
    /// noon less 12 hours (GTFS's rule, so they're right on days the clocks change).
    static func serviceDays(around now: Date, days: Int = daysAfter) -> [ServiceDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        return (-daysBefore...max(0, days)).compactMap { offset in
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
        // Small enough not to overflow and crash the server on a garbled time; anything else
        // odd is left for the trip's checks to drop it
        guard parts.count == 3, parts.allSatisfy({ (-999_999...999_999).contains($0) }) else { return nil }
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

/// The MTA's GTFS zips, downloaded and unzipped one at a time: the subway's week and month,
/// built together after a restart, would otherwise both write the same kept zip at once.
actor GTFSZips {
    static let shared = GTFSZips()

    /// The last asked for, which the next waits for.
    private var last: Task<Void, any Error>?

    /// `files` from the zip at `source` into `folder`, as `TimetableBuilder.unzip`. With `kept`,
    /// the zip is kept there (`<name>.zip`, its ETag in `<name>.zip.etag`) and asked for with
    /// If-None-Match: a 304 unzips the kept one. One that won't unzip is dropped, so the next
    /// try downloads it again.
    func unzip(_ source: URL, keptIn kept: URL?, into folder: URL, files: [String]) async throws {
        let previous = last
        let task = Task {
            _ = await previous?.result
            try await Self.unzip(source, keptIn: kept, into: folder, files: files)
        }
        last = task
        try await task.value
    }

    private static func unzip(_ source: URL, keptIn kept: URL?, into folder: URL, files: [String]) async throws {
        let manager = FileManager.default
        let zip = kept?.appendingPathComponent(source.lastPathComponent)
        let tag = zip?.appendingPathExtension("etag")
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        if let zip, let tag, manager.fileExists(atPath: zip.path),
           let etag = try? String(contentsOf: tag, encoding: .utf8), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (download, response) = try await URLSession.shared.download(for: request)
        defer { try? manager.removeItem(at: download) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let unzipped: URL
        if status == 304, let zip, request.value(forHTTPHeaderField: "If-None-Match") != nil {
            unzipped = zip
        } else if status == 200 {
            if let kept, let zip, let tag {
                // The tag first, so a zip saved without its own isn't taken for the last one's
                try manager.createDirectory(at: kept, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? manager.removeItem(at: tag)
                try? manager.removeItem(at: zip)
                try manager.moveItem(at: download, to: zip)
                if let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                    try? etag.write(to: tag, atomically: true, encoding: .utf8)
                }
                unzipped = zip
            } else {
                unzipped = download
            }
        } else {
            throw TimetableBuilder.Problem(description: "timetable: \(source) answered \(status)")
        }
        // Unzipped now, as the download goes when this one's done
        do {
            try await Concurrency.offPool { try TimetableBuilder.unzip(unzipped, into: folder, files: files) }
        } catch {
            if let tag, unzipped != download {
                try? manager.removeItem(at: tag)
                try? manager.removeItem(at: unzipped)
            }
            throw error
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
