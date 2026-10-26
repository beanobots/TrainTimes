import Foundation

/// The timetable to fall back on when the MTA can't be reached (`Timetable`), downloaded from
/// the push server's `GET /timetable` about once a day into the App Group, so the widgets
/// have it too. The app downloads it when opened and in the background; a widget does when
/// it finds it's due.
enum TimetableStore {
    private static let file = SharedStore.url(named: "timetable.bin")
    /// The server's ETag for the downloaded one, so an unchanged one isn't downloaded again.
    private static let tagFile = SharedStore.url(named: "timetable-etag.txt")

    /// How old the downloaded one gets before it's downloaded again: the server builds a new one
    /// each morning.
    static let refreshAfter: TimeInterval = 20 * 60 * 60

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// The downloaded timetable, if it has trains for `now`. Read once, and again only after a
    /// new one's downloaded.
    static func load(now: Date = .now) -> Timetable? {
        guard let file, let changed = modified(file) else { return nil }
        let timetable = cache.timetable(changed: changed) {
            (try? Data(contentsOf: file, options: .mappedIfSafe)).flatMap { try? Timetable(data: $0) }
        }
        return timetable.flatMap { $0.covers(now) ? $0 : nil }
    }

    /// Whether there's none, or it's over `refreshAfter` old (checked, if not changed, then).
    static func isDue(now: Date = .now) -> Bool {
        guard let file, let changed = modified(file) else { return true }
        return !changed.isWithin(refreshAfter, before: now)
    }

    /// Downloads a new one if due (or with `force`). Kept only if it reads; on failure, the old
    /// one stays. Widgets reloading together share one download.
    static func refresh(force: Bool = false) async {
        guard force || isDue() else { return }
        await downloads.run { await download() }
    }

    private static let downloads = Downloads()

    private static func download() async {
        guard let serverURL = ServerRoutes.baseURL, let file, let tagFile else { return }
        var request = URLRequest(url: serverURL.appendingPathComponent("timetable"),
                                 cachePolicy: .reloadIgnoringLocalCacheData)
        if modified(file) != nil, let tag = try? String(contentsOf: tagFile, encoding: .utf8) {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 304:
            // Unchanged: checked now. The one read stays, under the file's new date
            let checked = modified(file)
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
            if let checked, let changed = modified(file) { cache.redate(from: checked, to: changed) }
        case 200:
            // Read once, to check it, and kept as the one read from the file: a widget hasn't
            // room to read it again alongside, nor to keep the old one while it does (which is
            // read again from the file if this one doesn't read)
            cache.forget()
            guard let timetable = try? Timetable(data: data), (try? data.write(to: file, options: .atomic)) != nil
            else { return }
            if let changed = modified(file) { cache.keep(timetable, changed: changed) }
            if let tag = http.value(forHTTPHeaderField: "ETag") {
                try? tag.write(to: tagFile, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: tagFile)
            }
        default:
            break
        }
    }

    private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// The download under way, which others join.
    private actor Downloads {
        private var running: Task<Void, Never>?

        func run(_ download: @escaping @Sendable () async -> Void) async {
            if let running { return await running.value }
            let task = Task { await download() }
            running = task
            await task.value
            running = nil
        }
    }

    private static let cache = Cache()

    /// The timetable read from the file, while the file's unchanged.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var read: (changed: Date, timetable: Timetable?)?

        func timetable(changed: Date, reading: () -> Timetable?) -> Timetable? {
            lock.lock()
            defer { lock.unlock() }
            if let read, read.changed == changed { return read.timetable }
            let timetable = reading()
            read = (changed, timetable)
            return timetable
        }

        /// `timetable`, just written to the file, as if read from it.
        func keep(_ timetable: Timetable, changed: Date) {
            lock.lock()
            defer { lock.unlock() }
            read = (changed, timetable)
        }

        /// The one read from the file changed at `old`, if that's the one kept, as changed at
        /// `new`: the file touched, not rewritten.
        func redate(from old: Date, to new: Date) {
            lock.lock()
            defer { lock.unlock() }
            if let read, read.changed == old { self.read = (new, read.timetable) }
        }

        func forget() {
            lock.lock()
            defer { lock.unlock() }
            read = nil
        }
    }
}
