import Foundation

/// One row of the Logs tab's readable view: a countdown from its registration
/// on, a run of quiet passes, or a single line said plainly.
struct LogEvent: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case lifecycle, quiet, countdown, ended, registration, drop, error, other
    }

    /// A countdown's train and what was pushed to it.
    struct Countdown: Equatable, Sendable {
        /// "R34:N:R"
        var trainID: String
        var routes: [String]
        /// "36 St · to Manhattan", or the train's id when the station isn't known.
        var place: String
        var environment: String?
        var key: String?
        var pushes: [Push] = []
        var ended: Date?
    }

    /// One "push …" line, which the server writes only with LOG_PUSHES=1.
    struct Push: Equatable, Sendable {
        var date: Date?
        /// "in 7m25s", "1m05s ago"
        var train: String
        /// The next train's line, which can differ from the countdown's.
        var route: String?
        var notice: String?
    }

    /// The id of its first line, unless another event has it.
    var id: Int
    var kind: Kind
    var date: Date?
    /// Its last line's date: when a quiet run ended so far.
    var endDate: Date?
    var title: String
    var detail: String?
    /// A push token's prefix, "8020cd5a".
    var token: String?
    var countdown: Countdown?
    /// For a quiet run.
    var passes = 0
    /// The lines it was made from, for searching and copying.
    var texts: [String]

    var isProblem: Bool { kind == .error }
}

extension LogEvent {
    /// `lines`, oldest first, as events in the same order. `stations` names a
    /// train's stop and direction.
    static func group(_ lines: [LogLine], stations: [String: StationName] = StationName.installed) -> [LogEvent] {
        var events: [LogEvent] = []
        /// A token's countdown still running, by its index in `events`.
        var open: [String: Int] = [:]
        /// The quiet run being added to.
        var quiet: Int?

        func close(_ index: Int, at date: Date?, reason: String, text: String, id: Int) {
            events[index].countdown?.ended = date
            let start = events[index].date
            let ran = date.flatMap { end in start.map { Self.span(end.timeIntervalSince($0)) } }
            events.append(LogEvent(id: id, kind: .ended, date: date, title: "Countdown ended",
                                   detail: [reason, ran.map { "ran \($0)" }].compactMap(\.self).joined(separator: " · "),
                                   token: events[index].token, texts: [text]))
        }

        for line in lines {
            let message = line.message
            if let stats = line.pass {
                if stats.countdowns == 0 {
                    // Nothing's registered: whatever was running has ended without a line of its own
                    for index in open.values.sorted() {
                        close(index, at: line.date, reason: "Ended by the server", text: line.text, id: line.id)
                    }
                    open = [:]
                } else if stats.ended > 0, open.count == 1, let only = open.first {
                    // With several running, which one ended isn't known until they all have
                    close(only.value, at: line.date, reason: "Ended by the server", text: line.text, id: line.id)
                    open = [:]
                }
                if stats.countdowns == 0, stats.pushes == 0, stats.failed == 0 {
                    let index: Int
                    if let quiet {
                        index = quiet
                        events[index].passes += 1
                        events[index].endDate = line.date
                        events[index].texts.append(line.text)
                    } else {
                        events.append(LogEvent(id: line.id, kind: .quiet, date: line.date, endDate: line.date,
                                               title: "", passes: 1, texts: [line.text]))
                        index = events.count - 1
                        quiet = index
                    }
                    events[index].title = Self.quietTitle(events[index])
                    events[index].detail = Self.quietDetail(events[index], keys: stats.keys)
                } else {
                    quiet = nil
                }
                continue
            }
            quiet = nil
            let words = message.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

            if message.hasPrefix("due: ") {
                // Part of the countdowns' pushes, which their own lines show
                continue
            } else if message.hasPrefix("register "), words.count >= 4 {
                let token = Self.token(words[1])
                let trainID = words[3]
                let key = words.count >= 6 && words[4] == "key" ? words[5] : nil
                if let index = open[token], events[index].countdown?.trainID == trainID {
                    events[index].texts.append(line.text)
                    continue
                }
                let countdown = Countdown(trainID: trainID, routes: Self.routes(of: trainID),
                                          place: Self.place(of: trainID, stations: stations),
                                          environment: words[2], key: key)
                events.append(LogEvent(id: line.id, kind: .countdown, date: line.date, title: countdown.place,
                                       token: token, countdown: countdown, texts: [line.text]))
                open[token] = events.count - 1
            } else if message.hasPrefix("push "), words.count >= 2 {
                let token = Self.token(words[1])
                let index: Int
                if let known = open[token] {
                    index = known
                } else {
                    // Registered before the log's start
                    events.append(LogEvent(id: line.id, kind: .countdown, date: line.date, title: "Countdown",
                                           token: token, countdown: Countdown(trainID: "", routes: [], place: "Countdown"),
                                           texts: []))
                    index = events.count - 1
                    open[token] = index
                }
                events[index].countdown?.pushes.append(Self.push(message, date: line.date))
                events[index].texts.append(line.text)
            } else if message.hasPrefix("drop "), words.count >= 2 {
                let token = Self.token(String(words[1].dropLast(words[1].hasSuffix(":") ? 1 : 0)))
                let reason = Self.sentence(Self.after(": ", in: message) ?? "")
                if let index = open[token] {
                    close(index, at: line.date, reason: reason, text: line.text, id: line.id)
                    open[token] = nil
                } else {
                    events.append(LogEvent(id: line.id, kind: .drop, date: line.date, title: "Dropped", detail: reason,
                                           token: token, texts: [line.text]))
                }
            } else if message.hasPrefix("attest: new key ") {
                events.append(LogEvent(id: line.id, kind: .registration, date: line.date, title: "New attest key",
                                       detail: String(message.dropFirst("attest: new key ".count)), texts: [line.text]))
            } else if message.hasPrefix("purged ") {
                events.append(LogEvent(id: line.id, kind: .drop, date: line.date, title: "Purged attest keys",
                                       detail: Self.sentence(String(message.dropFirst("purged ".count))),
                                       texts: [line.text]))
            } else if message.hasPrefix("listening ") {
                events.append(LogEvent(id: line.id, kind: .lifecycle, date: line.date, title: "Server started",
                                       detail: Self.sentence(message), texts: [line.text]))
            } else if message.hasPrefix("start: ") {
                let counts = String(message.dropFirst("start: ".count))
                if let last = events.indices.last, events[last].title == "Server started", events[last].texts.count == 1 {
                    // Follows its "listening on …" line
                    events[last].detail = [events[last].detail, counts].compactMap(\.self).joined(separator: " · ")
                    events[last].texts.append(line.text)
                } else {
                    events.append(LogEvent(id: line.id, kind: .lifecycle, date: line.date, title: "Server started",
                                           detail: counts, texts: [line.text]))
                }
            } else if message == "stop" {
                events.append(LogEvent(id: line.id, kind: .lifecycle, date: line.date, title: "Server stopped",
                                       texts: [line.text]))
            } else if line.kind == .error {
                events.append(Self.error(line))
            } else if message.hasPrefix("send-test "), words.count >= 2 {
                events.append(LogEvent(id: line.id, kind: .other, date: line.date, title: "Test push sent",
                                       token: Self.token(words[1]), texts: [line.text]))
            } else if message.hasPrefix("forget widget token of "), words.count >= 5 {
                events.append(LogEvent(id: line.id, kind: .drop, date: line.date, title: "Widget token forgotten",
                                       detail: Self.after(": ", in: message), token: Self.token(words[4]),
                                       texts: [line.text]))
            } else {
                events.append(LogEvent(id: line.id, kind: .other, date: line.date, title: Self.sentence(message),
                                       texts: [line.text]))
            }
        }
        // One pass can end countdowns and start a quiet run: the later events get ids no line has
        var seen = Set<Int>()
        for index in events.indices where !seen.insert(events[index].id).inserted {
            events[index].id = -(index + 1)
        }
        return events
    }

    /// An "error: …" line, its title saying what failed.
    private static func error(_ line: LogLine) -> LogEvent {
        let message = String(line.message.dropFirst("error: ".count))
        let words = message.split(separator: " ").map(String.init)
        var event = LogEvent(id: line.id, kind: .error, date: line.date, title: "Error", detail: Self.sentence(message),
                             texts: [line.text])
        // "push 3f9a1c0e… (production) failed: APNs 400 BadDeviceToken"
        for (prefix, title) in [("push ", "Push failed"), ("end ", "Couldn't end a countdown")]
        where message.hasPrefix(prefix) && message.contains(" failed: ") && words.count >= 3 {
            event.title = title
            event.token = Self.token(words[1])
            let environment = words[2].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            event.detail = [Self.after(" failed: ", in: message), environment].compactMap(\.self).joined(separator: " · ")
            return event
        }
        if message.hasPrefix("send-test "), words.count >= 2 {
            event.title = "Test push failed"
            event.token = Self.token(words[1])
            event.detail = Self.after(": ", in: message)
        } else if message.hasPrefix("widget reload for "), words.count >= 4 {
            event.title = "Widget reload failed"
            event.token = Self.token(words[3])
            event.detail = Self.after(" failed: ", in: message)
        } else if message.hasPrefix("pass took ") {
            // "pass took 34.2 s, over POLL_SECONDS: skipping 1 tick"
            let parts = message.split(separator: ", ", maxSplits: 1).map(String.init)
            event.title = Self.sentence(parts[0])
            event.detail = parts.count > 1 ? Self.sentence(parts[1]) : nil
        } else if message.hasPrefix("no feeds for ") {
            event.title = "Feeds missing"
        }
        return event
    }

    /// "push 8020cd5a… p10 train in 7m25s (N) notice "Delays""
    private static func push(_ message: String, date: Date?) -> Push {
        var push = Push(date: date, train: "")
        guard let train = message.range(of: " train ") else { return push }
        var rest = message[train.upperBound...]
        if let open = rest.range(of: " (") {
            push.train = String(rest[..<open.lowerBound])
            rest = rest[open.upperBound...]
            if let close = rest.firstIndex(of: ")") {
                let route = String(rest[..<close])
                push.route = route == "?" ? nil : route
                rest = rest[rest.index(after: close)...]
            }
        } else {
            push.train = String(rest)
            rest = ""
        }
        if let notice = rest.range(of: " notice \"") {
            push.notice = String(rest[notice.upperBound...].dropLast(rest.hasSuffix("\"") ? 1 : 0))
        }
        return push
    }

    private static func quietTitle(_ event: LogEvent) -> String {
        guard let start = event.date, let end = event.endDate, end.timeIntervalSince(start) >= 60 else { return "Quiet" }
        return "Quiet for \(span(end.timeIntervalSince(start)))"
    }

    private static func quietDetail(_ event: LogEvent, keys: Int?) -> String {
        let passes = event.passes == 1 ? "1 pass" : "\(event.passes) passes"
        let keyCount = keys.map { $0 == 1 ? "1 attest key" : "\($0) attest keys" }
        return ["\(passes), nothing to push", keyCount].compactMap(\.self).joined(separator: " · ")
    }

    /// "2h 42m", "6m 20s", "29s".
    static func span(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(rest)s" }
        return "\(rest)s"
    }

    /// "8020cd5a…" as "8020cd5a".
    private static func token(_ word: String) -> String {
        word.hasSuffix("…") ? String(word.dropLast()) : word
    }

    /// "R34:N:N,R" as ["N", "R"].
    private static func routes(of trainID: String) -> [String] {
        let parts = trainID.split(separator: ":")
        guard parts.count == 3 else { return [] }
        return parts[2].split(separator: ",").map(String.init)
    }

    /// "R34:N:R" as "36 St · to Manhattan".
    static func place(of trainID: String, stations: [String: StationName]) -> String {
        let parts = trainID.split(separator: ":").map(String.init)
        guard parts.count == 3 else { return trainID }
        let direction = parts[1]
        guard let station = stations[parts[0]] else {
            return "\(parts[0]) · \(direction == "N" ? "northbound" : direction == "S" ? "southbound" : direction)"
        }
        let toward = direction == "N" ? station.north : direction == "S" ? station.south : nil
        return [station.name, toward.map { "to \($0)" }].compactMap(\.self).joined(separator: " · ")
    }

    private static func after(_ separator: String, in text: String) -> String? {
        text.range(of: separator).map { String(text[$0.upperBound...]) }
    }

    /// "deleted by the app" as "Deleted by the app".
    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// A station's name and the way each direction goes, from the server's stations.json.
struct StationName: Decodable, Equatable, Sendable {
    let name: String
    let north: String?
    let south: String?

    /// From the installed server's resources; empty when they can't be read.
    static let installed: [String: StationName] = {
        let path = "\(Server.prefix)/TrainTimesServer_TrainResources.bundle/Contents/Resources/stations.json"
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return decode(data)
    }()

    static func decode(_ data: Data) -> [String: StationName] {
        struct Entry: Decodable {
            let id: String
            let name: String
            let north: String?
            let south: String?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.id, StationName(name: $0.name, north: $0.north, south: $0.south)) },
                          uniquingKeysWith: { first, _ in first })
    }
}
