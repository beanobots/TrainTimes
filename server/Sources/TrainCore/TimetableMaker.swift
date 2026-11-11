import Crypto
import Foundation
import ServiceLifecycle

/// A timetable the app falls back on (`Timetable`), as `GET /timetable` or `GET /bus-timetable`
/// serves it: encoded, with an ETag so a phone with the current one downloads nothing.
actor TimetableCopy {
    private(set) var data: Data?
    private(set) var etag: String?
    private(set) var made: Date?

    /// `data` and its `etag` read together, so a `set` between two reads can't pair one
    /// timetable with another's ETag (which a phone would then keep until the next).
    var current: (data: Data, etag: String)? {
        guard let data, let etag else { return nil }
        return (data, etag)
    }

    func set(_ data: Data, made: Date) {
        self.data = data
        self.made = made
        etag = "\"" + SHA256.hash(data: data).hex.prefix(32) + "\""
    }
}

/// Builds a timetable once a day (`TimetableBuilder`), at `hour`:`minute` New York time, and
/// keeps it in `DATA_DIR/<file>` so a restart serves it at once. A build that fails is tried
/// again an hour later, while the last one is still served: it covers a week. The server runs
/// three: the subway's week (`timetable.bin`), its month (`timetable-30.bin`) and the buses'
/// week (`bus-timetable.bin`), each logged under its `name`.
final class TimetableMaker: Service {
    typealias Build = @Sendable (Date) async throws -> Timetable

    private let copy: TimetableCopy
    private let file: URL
    private let name: String
    private let hour: Int
    private let minute: Int
    private let retry: TimeInterval
    private let build: Build

    init(copy: TimetableCopy, directory: URL, file: String = "timetable.bin", name: String = "timetable",
         hour: Int = 4, minute: Int = 0, retry: TimeInterval = 60 * 60,
         build: @escaping Build = { try await TimetableBuilder.downloadSubway(now: $0) }) {
        self.copy = copy
        self.file = directory.appendingPathComponent(file)
        self.name = name
        self.hour = hour
        self.minute = minute
        self.retry = retry
        self.build = build
    }

    func run() async throws {
        var made = await load()
        while !Task.isCancelled && !Task.isShuttingDownGracefully {
            let due = made.map { Self.nextBuild(after: $0, hour: hour, minute: minute) } ?? .distantPast
            if due <= .now {
                made = await rebuild() ?? made
            }
            let next = made.map { Self.nextBuild(after: $0, hour: hour, minute: minute) } ?? .now
            // A failed build: again after `retry`
            let wake = next > .now ? next : Date.now.addingTimeInterval(retry)
            do {
                try await cancelWhenGracefulShutdown {
                    try await Task.sleep(for: .seconds(max(1, wake.timeIntervalSinceNow)))
                }
            } catch {
                break
            }
        }
    }

    /// The saved timetable, if it's readable; when it was made.
    private func load() async -> Date? {
        guard let data = try? Data(contentsOf: file), let timetable = try? Timetable(data: data) else { return nil }
        await copy.set(data, made: timetable.made)
        Log.info("\(name): loaded the one made \(timetable.made)")
        return timetable.made
    }

    /// Builds, serves and saves a new timetable; when it was made, or nil if it couldn't be. One
    /// that's served but can't be saved still counts as made: a restart builds again.
    func rebuild(now: Date = .now) async -> Date? {
        let started = ContinuousClock.now
        let timetable: Timetable
        let data: Data
        do {
            timetable = try await build(now)
            data = try timetable.encoded()
        } catch {
            Log.error("\(name): \(error)")
            return nil
        }
        await copy.set(data, made: timetable.made)
        let elapsed = ContinuousClock.now - started
        Log.info("\(name): built \(timetable.patterns.count) patterns, "
            + "\(timetable.starts.reduce(0) { $0 + $1.count }) trips, \(data.count / 1024) KB "
            + "in \(elapsed.components.seconds) s")
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            Log.error("\(name): couldn't save it: \(error)")
        }
        return timetable.made
    }

    /// The first `hour`:`minute` in New York after `made`.
    static func nextBuild(after made: Date, hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimetableBuilder.newYork
        return calendar.nextDate(after: made, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
            ?? made.addingTimeInterval(24 * 60 * 60)
    }
}
