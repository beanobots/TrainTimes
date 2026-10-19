import Foundation

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
        let seconds = Int(date.timeIntervalSince(now).rounded())
        let magnitude = abs(seconds)
        let text = "\(magnitude / 60)m\(String(format: "%02d", magnitude % 60))s"
        return seconds >= 0 ? "in \(text)" : "\(text) ago"
    }
}
