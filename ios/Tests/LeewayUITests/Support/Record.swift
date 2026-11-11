import Foundation

/// What the app wrote to its record file (`UITestRecord`): its requests, location manager calls,
/// moves to and from the background and CPU time, each with the real time it was.
struct Record {
    struct Entry {
        let fields: [String: Any]
        var kind: String { fields["kind"] as? String ?? "" }
        var at: Date { Date(timeIntervalSince1970: fields["at"] as? Double ?? 0) }
        subscript(_ key: String) -> Any? { fields[key] }
        func string(_ key: String) -> String { fields[key] as? String ?? "" }
    }

    let entries: [Entry]

    init(_ url: URL) {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        entries = text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]).map(Entry.init)
        }
    }

    private init(entries: [Entry]) {
        self.entries = entries
    }

    /// Only those from `start` (inclusive) to `end`.
    func between(_ start: Date, _ end: Date = .distantFuture) -> Record {
        Record(entries: entries.filter { $0.at >= start && $0.at < end })
    }

    var requests: [Entry] { entries.filter { $0.kind == "request" } }
    var locationCalls: [Entry] { entries.filter { $0.kind == "location" } }

    /// When the app last went to the background, and came back after.
    func phase(_ name: String) -> [Date] {
        entries.filter { $0.kind == "phase" && $0.string("phase") == name }.map(\.at)
    }

    /// A request's endpoint: its host and path, and for the push server's `/feeds` the feed's
    /// name ("api.dctp.dev/feeds nyct/gtfs-g").
    static func endpoint(_ entry: Entry) -> String {
        let base = entry.string("host") + entry.string("path")
        guard entry.string("path") == "/feeds",
              let name = URLComponents(string: entry.string("url"))?.queryItems?.first(where: { $0.name == "name" })?.value
        else { return base }
        return base + " " + name
    }

    /// Requests counted by endpoint.
    var byEndpoint: [String: Int] {
        requests.reduce(into: [:]) { counts, entry in counts[Self.endpoint(entry), default: 0] += 1 }
    }

    /// The counts, one endpoint a line, most first.
    var summary: String {
        byEndpoint.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.value)\t\($0.key)" }
            .joined(separator: "\n")
    }

    /// CPU seconds used between the first and last samples, and the real seconds between them.
    var cpu: (used: Double, over: Double)? {
        let samples = entries.filter { $0.kind == "cpu" }
        guard let first = samples.first, let last = samples.last, last.at > first.at,
              let a = first["seconds"] as? Double, let b = last["seconds"] as? Double else { return nil }
        return (b - a, last.at.timeIntervalSince(first.at))
    }

    /// Main-thread hitches (`UITestFrames`): ms late per second shown, the worst frame's ms
    /// late, and the seconds counted.
    var hitches: (ratio: Double, worstMs: Double, seconds: Double)? {
        let windows = entries.filter { $0.kind == "frames" }
        let span = windows.compactMap { $0["spanMs"] as? Double }.reduce(0, +)
        guard span > 0 else { return nil }
        let late = windows.compactMap { $0["lateMs"] as? Double }.reduce(0, +)
        let worst = windows.compactMap { $0["worstMs"] as? Double }.max() ?? 0
        return (late / (span / 1000), worst, span / 1000)
    }
}
