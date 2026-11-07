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

    /// Seconds to wait for the timetable to download.
    private static let timeout: TimeInterval = 20

    /// How long after a download fails before it's tried again (but for `force`), so every
    /// widget reload and app open doesn't wait out `timeout` on the same failure. Shorter for
    /// the app, opened far less often than widgets reload, so a widget's failure doesn't keep it
    /// from trying for an hour.
    static var retryAfter: TimeInterval { isExtension ? 60 * 60 : 5 * 60 }
    /// Whether this is a widget (or other extension), not the app.
    private static let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
    /// When a download last failed, in the App Group's defaults, so the app and widgets each
    /// know; cleared when one succeeds.
    private static let failedKey = "timetableDownloadFailed"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: SharedStore.groupID) }

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

    /// Downloads a new one if due (or with `force`), and not failed within `retryAfter`. Kept
    /// only if it reads; on failure, the old one stays. Widgets reloading together share one
    /// download. One cut short (cancelled, as when a widget's run ends) isn't a failure.
    static func refresh(force: Bool = false) async {
        if !force {
            guard isDue() else { return }
            if let failed = defaults?.object(forKey: failedKey) as? Date, failed.isWithin(retryAfter, before: .now) { return }
        }
        await downloads.run {
            switch await download() {
            case .downloaded: defaults?.removeObject(forKey: failedKey)
            case .failed: defaults?.set(Date.now, forKey: failedKey)
            case .interrupted: break
            }
        }
    }

    private static let downloads = Downloads()

    /// What came of a download (`download`).
    private enum Outcome {
        /// A new one that reads, or word it's unchanged.
        case downloaded
        case failed
        /// Cancelled before it finished: no word on the server either way.
        case interrupted
    }

    private static func download() async -> Outcome {
        guard let serverURL = ServerRoutes.baseURL, let file, let tagFile else { return .failed }
        var request = URLRequest(url: serverURL.appendingPathComponent("timetable"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if modified(file) != nil, let tag = try? String(contentsOf: tagFile, encoding: .utf8) {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await TrainService.serverSession.data(for: request) }
        catch {
            let cancelled = (error as? URLError)?.code == .cancelled || error is CancellationError || Task.isCancelled
            return cancelled ? .interrupted : .failed
        }
        guard let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 304:
            // Unchanged: checked now. The one read stays, under the file's new date
            let checked = modified(file)
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
            if let checked, let changed = modified(file) { cache.redate(from: checked, to: changed) }
            return .downloaded
        case 200:
            // Read once, to check it, and kept as the one read from the file: a widget hasn't
            // room to read it again alongside, nor to keep the old one while it does (which is
            // read again from the file if this one doesn't read)
            cache.forget()
            guard let timetable = try? Timetable(data: data), (try? data.write(to: file, options: .atomic)) != nil
            else { return .failed }
            if let changed = modified(file) { cache.keep(timetable, changed: changed) }
            if let tag = http.value(forHTTPHeaderField: "ETag") {
                try? tag.write(to: tagFile, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: tagFile)
            }
            return .downloaded
        default:
            return .failed
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
            // Let go of the old one first, so the two aren't held at once while the new one's
            // parsed: several MB, against the widget's memory limit. Still under the lock, so
            // no other reader sees it gone and reads the file too
            read = nil
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
