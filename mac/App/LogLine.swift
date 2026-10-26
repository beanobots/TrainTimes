import Foundation

/// The totals of one of the server's passes, from its "pass: …" line.
struct PassStats: Equatable, Sendable {
    var countdowns = 0
    var updates = 0
    var refreshes = 0
    var ended = 0
    var dropped = 0
    var failed = 0
    var withoutFeeds = 0
    /// Only in lines from servers that log it.
    var keys: Int?

    var pushes: Int { updates + refreshes }
}

/// One line of server.log: "2026-10-21T17:37:25Z pass: 3 countdowns, …".
struct LogLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case pass, registration, drop, error, lifecycle, other
    }

    /// Its place in the log, as read.
    let id: Int
    let text: String
    let date: Date?
    /// The text after its date.
    let message: String
    let kind: Kind
    let pass: PassStats?
    /// From a "start: …" line, which counts the attest keys.
    let startKeys: Int?

    init(id: Int, text: String) {
        self.id = id
        self.text = text
        var message = Substring(text)
        if let space = text.firstIndex(of: " "),
           let date = try? Date(String(text[..<space]), strategy: .iso8601) {
            self.date = date
            message = text[text.index(after: space)...]
        } else {
            date = nil
        }
        self.message = String(message)
        if message.hasPrefix("error: ") {
            kind = .error
            pass = nil
        } else if message.hasPrefix("pass: ") {
            kind = .pass
            pass = Self.passStats(message.dropFirst("pass: ".count))
        } else {
            pass = nil
            if message.hasPrefix("register ") || message.hasPrefix("attest: ") {
                kind = .registration
            } else if message.hasPrefix("drop ") || message.hasPrefix("purged ") {
                kind = .drop
            } else if message.hasPrefix("start: ") || message.hasPrefix("listening ") || message == "stop" {
                kind = .lifecycle
            } else {
                kind = .other
            }
        }
        startKeys = message.hasPrefix("start: ") ? Self.counts(in: message.dropFirst("start: ".count))["attest keys"] : nil
    }

    /// "3 countdowns, 1 updates, …, 0 without feeds, 412 attest keys".
    private static func passStats(_ text: Substring) -> PassStats? {
        let counts = counts(in: text)
        guard let countdowns = counts["countdowns"] else { return nil }
        return PassStats(countdowns: countdowns, updates: counts["updates"] ?? 0, refreshes: counts["refreshes"] ?? 0,
                         ended: counts["ended"] ?? 0, dropped: counts["dropped"] ?? 0, failed: counts["failed"] ?? 0,
                         withoutFeeds: counts["without feeds"] ?? 0, keys: counts["attest keys"])
    }

    /// "3 countdowns, 412 attest keys" as ["countdowns": 3, "attest keys": 412].
    private static func counts(in text: Substring) -> [String: Int] {
        var counts: [String: Int] = [:]
        for part in text.split(separator: ", ") {
            guard let space = part.firstIndex(of: " "), let number = Int(part[..<space]) else { continue }
            counts[String(part[part.index(after: space)...])] = number
        }
        return counts
    }
}
