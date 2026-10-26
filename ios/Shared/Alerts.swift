import Foundation

/// A service alert from the MTA: delays, planned work, skipped stops, station notices.
struct ServiceAlert: Identifiable, Hashable, Sendable {
    /// Sorts most important first; declared in Settings order. Raw values are saved by Settings
    /// and sent to the server, so never renumber them.
    enum Kind: Int, Codable, Comparable, CaseIterable, Sendable {
        case delays = 0, suspended = 1, serviceChange = 2, notice = 3

        /// Suspensions, then delays, then changes, then notices.
        private var priority: Int {
            switch self {
            case .suspended: 0
            case .delays: 1
            case .serviceChange: 2
            case .notice: 3
            }
        }

        static func < (a: Kind, b: Kind) -> Bool { a.priority < b.priority }

        /// Short label for the widget.
        var label: String {
            switch self {
            case .delays: "Delays"
            case .suspended: "Suspended"
            case .serviceChange: "Service change"
            case .notice: "Notice"
            }
        }

        /// Settings label, describing what the kind covers.
        var settingsLabel: String {
            switch self {
            case .delays: "Delays"
            case .suspended: "Suspensions, planned or not"
            case .serviceChange: "Service changes and other planned work"
            case .notice: "Station notices and extra service"
            }
        }
    }

    /// A saved set of kinds as raw values, e.g. `[0, 1, 2, 3]`. Unknown values (kinds added
    /// later) are dropped rather than failing the whole decode.
    struct KnownKinds: Decodable, Sendable {
        let kinds: Set<Kind>

        init(from decoder: Decoder) throws {
            kinds = Set(try [Int](from: decoder).compactMap(Kind.init(rawValue:)))
        }
    }

    let id: String
    let kind: Kind
    /// The MTA's own type, e.g. "Planned - Stops Skipped".
    let type: String
    let header: String
    let details: String
    /// When it applies, in the MTA's words, e.g. "Nov 2 - 5, Mon to Thu, 9:45 PM to 11:30 PM".
    let period: String?
    /// For delays, the headline shortened to fit a banner.
    var brief: AlertBrief? = nil
    /// The headline with lines left as "[R]", for drawing as bullets.
    var markedHeader: String? = nil
}

/// A headline reduced to its lines, direction and any lines to take instead: "[2][5] trains are
/// running with delays in both directions..." becomes 2, 5, "Both directions"; "No [W] between…
/// - take the [N] instead" becomes W, take the N.
struct AlertBrief: Codable, Hashable, Sendable {
    /// Real-time route ids, in the order the headline names them.
    let routes: [String]
    /// "Both directions", "Manhattan-bound", "Uptown"; nil when the headline doesn't say.
    let direction: String?
    /// Lines the headline says to take instead: the A in "[C] service ends early - take the [A]
    /// instead". Nil from older saves.
    var alternatives: [String]? = nil

    /// Nil when the headline names no lines. Takes the MTA's raw text, with lines as "[R]".
    init?(header: String) {
        // Only lines before "train(s)" or "take the", so not the [N] in "take the [N] instead"
        let take = header.firstRange(of: Self.take)
        let before = take.map { header[..<$0.lowerBound] } ?? header[...]
        let subject = before.firstRange(of: #/\btrains?\b/#.ignoresCase()).map { before[..<$0.lowerBound] } ?? before
        let routes = Self.lines(in: subject)
        guard !routes.isEmpty else { return nil }
        self.routes = routes
        direction = Self.direction(in: header)
        alternatives = take.map { Self.lines(in: header[$0.upperBound...]).filter { !routes.contains($0) } }
    }

    /// For a headline naming no lines: the alert's own (`only(_:)` adds them), any direction and
    /// any lines to take instead.
    init(routes: [String], direction: String?, alternatives: [String]? = nil) {
        self.routes = routes
        self.direction = direction
        self.alternatives = alternatives
    }

    /// "take the" or "Take the", before the lines to take instead.
    /// Computed, as a `Regex` isn't `Sendable`.
    private static var take: Regex<Substring> { #/\btake the\b/#.ignoresCase() }

    /// The lines `text` names as "[R]", each once, in order.
    private static func lines(in text: Substring) -> [String] {
        var routes: [String] = []
        for match in text.matches(of: #/\[([A-Z0-9]{1,3})\]/#) {
            let route = Lines.normalized(String(match.1))
            if !routes.contains(route) { routes.append(route) }
        }
        return routes
    }

    /// The lines to take instead in a headline naming none of its own: "No service between… -
    /// take the [N]".
    static func alternatives(in header: String) -> [String]? {
        header.firstRange(of: take).map { lines(in: header[$0.upperBound...]) }
    }

    /// Just `lines`, in the headline's order: a delay to the N and R shows only the R to a widget
    /// tracking the R and W. Lines matched only by the alert's routes, not its headline, go after.
    /// Lines to take instead stay, but not your own.
    func only(_ lines: [String]) -> AlertBrief {
        AlertBrief(routes: routes.filter(lines.contains) + lines.filter { !routes.contains($0) }, direction: direction,
                   alternatives: alternatives?.filter { !lines.contains($0) })
    }

    /// With `other`'s lines after its own, for an alert matched by more than one selection.
    func joined(_ other: AlertBrief) -> AlertBrief {
        let routes = routes + other.routes.filter { !routes.contains($0) }
        return AlertBrief(routes: routes, direction: direction, alternatives: alternatives?.filter { !routes.contains($0) })
    }

    /// The direction a headline names: "Both directions", "Manhattan-bound", "Uptown"; nil when
    /// it doesn't say.
    static func direction(in header: String) -> String? {
        // Skip quantifiers like "Some" before "-bound"; "Downtown Brooklyn" is a place, not a direction
        if header.localizedCaseInsensitiveContains("both directions") {
            return "Both directions"
        } else if let match = header.firstMatch(of: #/\b(?:(?!(?:Some|Most|All|Many|Several|Few|No|The)\b)[A-Z0-9][\w./]*(?:[ -][A-Z0-9][\w./]*)*-bound|[Nn]orthbound|[Ss]outhbound|[Uu]ptown|[Dd]owntown(?! Brooklyn))\b/#) {
            let words = String(match.0)
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        return nil
    }
}

enum AlertsFeed {
    /// All subway alerts, current and planned. About 1 MB, but sent gzipped (about 80 KB).
    static let url = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts.json")!

    /// A feed alert with only what `alerts(for:in:now:)` needs, so one decode serves every
    /// selection.
    struct Entry: Sendable {
        fileprivate let id: String
        fileprivate let periods: [Period]
        fileprivate let informed: [Informed]
        /// Stations before skipped, rerouted or suspended stops, whose trains change further along.
        fileprivate let affected: [Informed]
        fileprivate let type: String
        fileprivate let header: String
        fileprivate let details: String
        fileprivate let period: String?
        /// Precomputed by `prepared(_:)`; nil to compute on each use.
        fileprivate var text: Text? = nil

        /// Header and details via `readable` and `marked`, plus the header's `AlertBrief`.
        fileprivate struct Text: Sendable {
            let header: String
            let details: String
            let markedHeader: String
            let brief: AlertBrief?
            /// The headline's direction, even when it names no lines (so has no `brief`).
            let direction: String?

            init(_ entry: Entry) {
                header = AlertsFeed.readable(entry.header)
                details = AlertsFeed.readable(entry.details)
                markedHeader = AlertsFeed.marked(entry.header)
                brief = AlertBrief(header: entry.header)
                direction = AlertBrief.direction(in: entry.header)
            }
        }

        /// Whether it's in effect at some moment from `start` to `end`.
        fileprivate func isActive(from start: TimeInterval, to end: TimeInterval) -> Bool {
            periods.isEmpty || periods.contains { period in
                (period.start ?? 0) <= end && (period.end.map { $0 == 0 || $0 > start } ?? true)
            }
        }
    }

    /// Alerts in effect now or within the hour; drops the feed's later planned work.
    static func entries(in data: Data, now: Date = Date()) throws -> [Entry] {
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        let time = now.timeIntervalSince1970
        return feed.entity.compactMap(\.value).compactMap { entity in
            guard let alert = entity.alert else { return nil }
            let entry = Entry(
                id: entity.id,
                periods: alert.active_period ?? [],
                informed: alert.informed_entity ?? [],
                affected: alert.mercury?.affected_stations?.compactMap(\.value) ?? [],
                type: alert.mercury?.alert_type ?? "",
                header: alert.header_text?.english ?? "",
                details: alert.description_text?.english ?? "",
                period: alert.mercury?.human_readable_active_period?.english
            )
            return entry.isActive(from: time, to: time + 60 * 60) ? entry : nil
        }
    }

    /// The feed with only the alerts that name one of `routes` (where they are or further along)
    /// and are in effect at some moment from `start` to `end`, for the push server to send a
    /// phone just what it reads (a fraction of the ~1 MB feed, for one with little signal). For
    /// selections of those routes at times in that span, `alerts(for:in:now:)` finds the same in
    /// it as in the whole feed. Everything else in a kept alert is kept as it is.
    static func trimmed(_ data: Data, toRoutes routes: Set<String>, activeFrom start: Date, to end: Date) throws -> Data {
        guard var feed = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = feed["entity"] as? [Any] else { throw FeedError.malformed }
        let (from, to) = (start.timeIntervalSince1970, end.timeIntervalSince1970)
        let number = { (value: Any?) in (value as? NSNumber)?.doubleValue }
        feed["entity"] = entities.filter { entity in
            guard let alert = (entity as? [String: Any])?["alert"] as? [String: Any] else { return false }
            let mercury = alert["transit_realtime.mercury_alert"] as? [String: Any]
            let informed = (alert["informed_entity"] as? [Any] ?? []) + (mercury?["affected_stations"] as? [Any] ?? [])
            let named = informed.contains { informed in
                ((informed as? [String: Any])?["route_id"] as? String).map { routes.contains(Lines.normalized($0)) } ?? false
            }
            // As `Entry.isActive`
            let periods = (alert["active_period"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            let active = periods.isEmpty || periods.contains { period in
                (number(period["start"]) ?? 0) <= to && (number(period["end"]).map { $0 == 0 || $0 > from } ?? true)
            }
            return named && active
        }
        return try JSONSerialization.data(withJSONObject: feed)
    }

    /// Precomputes each entry's text once. For the server, which reuses the same alerts across
    /// thousands of countdowns; the app shows few, so it skips this.
    static func prepared(_ entries: [Entry]) -> [Entry] {
        entries.map { entry in
            var entry = entry
            entry.text = Entry.Text(entry)
            return entry
        }
    }

    /// Alerts in effect at `now` for `selection`'s lines, platforms and direction, most important
    /// first, including ones that change its trains further along.
    static func alerts(for selection: Selection, in entries: [Entry], now: Date = Date()) -> [ServiceAlert] {
        let time = now.timeIntervalSince1970
        let platforms = selection.platforms.map(\.id)
        // Per line, as lines can differ: toward Manhattan from Marcy Av, the J is S and the M is N
        let ways = Dictionary(selection.routes.map { ($0, selection.direction(of: $0)) }, uniquingKeysWith: { first, _ in first })
        let here = Set(platforms)
        let alerts: [ServiceAlert] = entries.compactMap { entry in
            let text = entry.text ?? Entry.Text(entry)
            func matches(_ informed: Informed) -> Bool {
                guard let route = informed.route_id.map(Lines.normalized), let direction = ways[route] else { return false }
                // Stop id is the platform id, optionally plus N or S
                if let stop = informed.stop_id, !platforms.contains(where: { stop == $0 || stop == $0 + direction.rawValue }) {
                    return false
                }
                if let informedDirection = informed.direction_id {
                    if informedDirection != (direction == .north ? 0 : 1) { return false }
                } else if let stated = text.direction,
                          let toward = way(stated: stated, on: route, from: here), toward != direction {
                    // The MTA often leaves out the direction; "Crown Heights-Utica Av-bound" says it
                    return false
                }
                return true
            }
            let matchedHere = entry.informed.filter(matches)
            let isHere = !matchedHere.isEmpty
            let matched = isHere ? matchedHere : entry.affected.filter(matches)
            guard !matched.isEmpty, entry.isActive(from: time, to: time) else { return nil }
            // The tracked lines it's for, in the selection's order, for the banner's bullets
            let lines = Set(matched.compactMap { $0.route_id.map(Lines.normalized) })
            let yours = selection.routes.filter(lines.contains)
            var kind = kind(of: entry.type)
            // Suspended further along: trains still run from here
            if !isHere, kind == .suspended { kind = .serviceChange }
            return ServiceAlert(
                id: entry.id,
                kind: kind,
                type: entry.type,
                header: text.header,
                details: text.details,
                period: entry.period,
                // Every kind, for the widget's banner: its lines among yours, and any direction
                brief: (text.brief ?? AlertBrief(routes: [], direction: text.direction,
                                                 alternatives: AlertBrief.alternatives(in: entry.header))).only(yours),
                markedHeader: text.markedHeader
            )
        }
        return alerts.sorted { $0.kind < $1.kind }
    }

    /// `alerts(for:in:now:)` for each of `selections` (a transfer's train and the lines it changes
    /// to), each alert once: as the most important kind any matched it as, with all their lines.
    static func alerts(for selections: [Selection], in entries: [Entry], now: Date = Date()) -> [ServiceAlert] {
        merged(selections.map { alerts(for: $0, in: entries, now: now) })
    }

    /// Several selections' alerts as one list, each alert once, as `alerts(for:in:now:)` with
    /// several selections; most important first.
    static func merged(_ lists: [[ServiceAlert]]) -> [ServiceAlert] {
        var merged: [ServiceAlert] = []
        for alert in lists.joined() {
            guard let index = merged.firstIndex(where: { $0.id == alert.id }) else {
                merged.append(alert)
                continue
            }
            let earlier = merged[index]
            var kept = alert.kind < earlier.kind ? alert : earlier
            let other = alert.kind < earlier.kind ? earlier : alert
            if let brief = kept.brief, let more = other.brief { kept.brief = brief.joined(more) }
            merged[index] = kept
        }
        return merged.sorted { $0.kind < $1.kind }
    }

    /// The way along `route` from `platforms` that a headline's direction ("Uptown", "Southbound",
    /// "Crown Heights-Utica Av-bound", "Manhattan-bound") names; nil for "Both directions", or
    /// a place it can't place on one side.
    private static func way(stated: String, on route: String, from platforms: Set<String>) -> Direction? {
        switch stated.lowercased() {
        case "uptown", "northbound": return .north
        case "downtown", "southbound": return .south
        default:
            guard stated.hasSuffix("-bound") else { return nil }
            return StationDirectory.direction(toward: String(stated.dropLast("-bound".count)), on: route, from: platforms)
        }
    }

    static func kind(of type: String) -> ServiceAlert.Kind {
        let type = type.lowercased()
        if type.contains("delay") { return .delays }
        if type.contains("suspend") { return .suspended }
        if type.contains("notice") || type.contains("extra service") || type.contains("special schedule") { return .notice }
        return .serviceChange
    }

    /// Rewrites "[R]" lines as plain text and drops "[airplane icon]"s. "[2][5] trains" becomes
    /// "2 and 5 trains", not "25 trains".
    static func readable(_ text: String) -> String {
        text.replacing(#/\[[A-Z0-9]{1,3}\](?:\s*\[[A-Z0-9]{1,3}\])*/#) { run in
            Lines.joined(run.output.matches(of: #/\[([A-Z0-9]{1,3})\]/#).map { String($0.1) })
        }
            .replacingOccurrences(of: #"\s*\[[a-z ]+ icon\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// As `readable`, but leaves lines as "[R]" for drawing as bullets.
    static func marked(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\[[a-z ]+ icon\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // GTFS-realtime as JSON, with the MTA's "mercury" extensions.
    private struct Feed: Decodable { let entity: [Lenient<Entity>] }
    /// Nil when undecodable, so one bad entity or station doesn't lose the rest.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
    private struct Entity: Decodable {
        let id: String
        let alert: Alert?
    }
    private struct Alert: Decodable {
        let active_period: [Period]?
        let informed_entity: [Informed]?
        let header_text: Translated?
        let description_text: Translated?
        let mercury: Mercury?

        enum CodingKeys: String, CodingKey {
            case active_period, informed_entity, header_text, description_text
            case mercury = "transit_realtime.mercury_alert"
        }
    }
    fileprivate struct Period: Decodable, Sendable {
        let start: Double?
        let end: Double?
    }
    fileprivate struct Informed: Decodable, Sendable {
        let route_id: String?
        let stop_id: String?
        /// 0 is north (uptown), 1 is south (downtown).
        let direction_id: Int?
    }
    private struct Translated: Decodable {
        let translation: [Translation]?
        var english: String? {
            let translations = translation ?? []
            return translations.first { $0.language == "en" }?.text ?? translations.first?.text
        }
    }
    private struct Translation: Decodable {
        let text: String?
        let language: String?
    }
    private struct Mercury: Decodable {
        let alert_type: String?
        let human_readable_active_period: Translated?
        let affected_stations: [Lenient<Informed>]?
    }
}
