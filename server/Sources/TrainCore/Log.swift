import Foundation
import ServiceLifecycle

/// One line per event on stdout, which launchd sends to the log file. Never
/// given the API secret or a whole push token.
enum Log {
    static func info(_ message: String) { write("", message) }
    static func error(_ message: String) { write("error: ", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(Date.now.formatted(.iso8601)) \(level)\(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    /// "in 4m30s", "1m05s ago": a train's time, for a log line.
    static func relative(_ date: Date, to now: Date) -> String {
        let seconds = Int(saturating: date.timeIntervalSince(now).rounded())
        let magnitude = seconds.magnitude
        let text = "\(magnitude / 60)m\(String(format: "%02d", Int(magnitude % 60)))s"
        return seconds >= 0 ? "in \(text)" : "\(text) ago"
    }

    /// Points `descriptors` (stdout and stderr) at the file at `path` once it
    /// isn't the one they write to: newsyslog has moved it aside and made a
    /// new one. It's never created here. Says whether they were moved.
    @discardableResult
    static func reopen(_ path: String, onto descriptors: [Int32] = [STDOUT_FILENO, STDERR_FILENO]) -> Bool {
        guard let first = descriptors.first else { return false }
        var named = stat(), current = stat()
        guard stat(path, &named) == 0 else { return false }
        if fstat(first, &current) == 0, current.st_dev == named.st_dev, current.st_ino == named.st_ino {
            return false
        }
        let file = open(path, O_WRONLY | O_APPEND)
        guard file >= 0 else { return false }
        defer { close(file) }
        for descriptor in descriptors {
            guard dup2(file, descriptor) >= 0 else { return false }
        }
        return true
    }
}

/// Moves stdout and stderr to LOG_FILE's new file within a minute of its
/// being rotated, rather than writing to the old one until a restart.
struct LogReopener: Service {
    let path: String

    func run() async throws {
        while !Task.isCancelled && !Task.isShuttingDownGracefully {
            Log.reopen(path)
            do {
                try await cancelWhenGracefulShutdown { try await Task.sleep(for: .seconds(60)) }
            } catch {
                break
            }
        }
    }
}

/// Lines about refused requests, which anyone can cause as often as the rate
/// limit lets them: at most `perMinute` a minute, and as many errors besides,
/// so a flood of the one can't hide the other. How many more there were is
/// logged with the first line of a later minute.
actor RefusalLog {
    /// One kind of line's count this minute.
    private struct Count {
        var written = 0
        var leftOut = 0

        /// Counts a line, and says whether it's within `limit`.
        mutating func admit(_ limit: Int) -> Bool {
            guard written < limit else {
                leftOut += 1
                return false
            }
            written += 1
            return true
        }
    }

    private let perMinute: Int
    private var minute = Date.distantPast
    private var infos = Count()
    private var errors = Count()

    init(perMinute: Int = 20) { self.perMinute = perMinute }

    /// Writes `message` unless this minute's lines are used up. Says whether it did.
    @discardableResult
    func info(_ message: String, now: Date = .now) -> Bool {
        startMinute(of: now)
        guard infos.admit(perMinute) else { return false }
        Log.info(message)
        return true
    }

    /// The same, with this minute's error lines.
    @discardableResult
    func error(_ message: String, now: Date = .now) -> Bool {
        startMinute(of: now)
        guard errors.admit(perMinute) else { return false }
        Log.error(message)
        return true
    }

    private func startMinute(of now: Date) {
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        guard start != minute else { return }
        if infos.leftOut > 0 {
            Log.info("… and \(infos.leftOut) more refused requests in the minute from \(minute.formatted(.iso8601))")
        }
        if errors.leftOut > 0 {
            Log.error("… and \(errors.leftOut) more such errors in the minute from \(minute.formatted(.iso8601))")
        }
        minute = start
        infos = Count()
        errors = Count()
    }
}

extension Int {
    /// `value` without its fraction, as `Int(_:)` makes it, but the nearest
    /// Int rather than a crash when it's out of range, and 0 when it's NaN.
    init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= Double(Int.max) {
            self = .max
        } else if value <= Double(Int.min) {
            self = .min
        } else {
            self = Int(value)
        }
    }
}
