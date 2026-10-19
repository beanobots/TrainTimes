import Foundation

/// A service alert from the MTA: delays, planned work, skipped stops, station notices.
struct ServiceAlert: Identifiable, Hashable, Sendable {
    /// How much it matters to someone waiting for a train, most first.
    enum Kind: Int, Codable, Comparable, CaseIterable, Sendable {
        case delays, suspended, serviceChange, notice

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        /// A word or two for the widget.
        var label: String {
            switch self {
            case .delays: "Delays"
            case .suspended: "Suspended"
            case .serviceChange: "Service change"
            case .notice: "Notice"
            }
        }

        /// What Settings calls this kind, and what it covers.
        var settingsLabel: String {
            switch self {
            case .delays: "Delays"
            case .suspended: "Suspensions"
            case .serviceChange: "Service changes and planned work"
            case .notice: "Station notices and extra service"
            }
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
    /// For delays, the headline cut to what fits a banner.
    var brief: AlertBrief? = nil
    /// The headline with its lines still written "[R]", to show them as bullets.
    var markedHeader: String? = nil
}

/// A delay's headline cut short: the lines it names, and which way they're
/// delayed. "[2][5] trains are running with delays in both directions after
/// we addressed a signal problem near 3 Av/149 St." is 2, 5, "Both directions".
struct AlertBrief: Codable, Hashable, Sendable {
    /// Real-time route ids, in the order the headline names them.
    let routes: [String]
    /// "Both directions", "Manhattan-bound", "Uptown"; nil when the headline doesn't say.
    let direction: String?

    /// Nil when the headline names no lines, as then there's nothing to show
    /// but its words. Wants the MTA's own text, which writes lines as "[R]".
    init?(header: String) {
        // The lines are those named before "train" or "trains", so not those of a "take the [N] instead"
        let subject = header.firstRange(of: #/\btrains?\b/#.ignoresCase()).map { header[..<$0.lowerBound] } ?? header[...]
        var routes: [String] = []
        for match in subject.matches(of: #/\[([A-Z0-9]{1,3})\]/#) {
            let route = Lines.normalized(String(match.1))
            if !routes.contains(route) { routes.append(route) }
        }
        guard !routes.isEmpty else { return nil }
        self.routes = routes

        if header.localizedCaseInsensitiveContains("both directions") {
            direction = "Both directions"
        } else if let match = header.firstMatch(of: #/\b(?:[A-Z0-9][\w./]*(?:[ -][A-Z0-9][\w./]*)*-bound|[Nn]orthbound|[Ss]outhbound|[Uu]ptown|[Dd]owntown)\b/#) {
            let words = String(match.0)
            direction = words.prefix(1).uppercased() + words.dropFirst()
        } else {
            direction = nil
        }
    }
}

enum AlertsFeed {
    /// All subway alerts, current and planned. About 1 MB, but sent gzipped (about 80 KB).
    static let url = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts.json")!

    /// An alert from the feed, with only what `alerts(for:in:now:)` needs: the
    /// feed decoded once serves every train that asks about the same time.
    struct Entry: Sendable {
        fileprivate let id: String
        fileprivate let periods: [Period]
        fileprivate let informed: [Informed]
        fileprivate let type: String
        fileprivate let header: String
        fileprivate let details: String
        fileprivate let period: String?

        /// Whether it's in effect at some moment from `start` to `end`.
        fileprivate func isActive(from start: TimeInterval, to end: TimeInterval) -> Bool {
            periods.isEmpty || periods.contains { period in
                (period.start ?? 0) <= end && (period.end.map { $0 == 0 || $0 > start } ?? true)
            }
        }
    }

    /// The feed's alerts that are in effect now or will be within the hour.
    /// Most of the feed is planned work for later on, which isn't kept.
    static func entries(in data: Data, now: Date = Date()) throws -> [Entry] {
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        let time = now.timeIntervalSince1970
        return feed.entity.compactMap { entity in
            guard let alert = entity.alert else { return nil }
            let entry = Entry(
                id: entity.id,
                periods: alert.active_period ?? [],
                informed: alert.informed_entity ?? [],
                type: alert.mercury?.alert_type ?? "",
                header: alert.header_text?.english ?? "",
                details: alert.description_text?.english ?? "",
                period: alert.mercury?.human_readable_active_period?.english
            )
            return entry.isActive(from: time, to: time + 60 * 60) ? entry : nil
        }
    }

    /// The alerts in effect at `now` that affect `selection`'s lines at their
    /// platforms and direction, most important first.
    static func alerts(for selection: Selection, in entries: [Entry], now: Date = Date()) -> [ServiceAlert] {
        let time = now.timeIntervalSince1970
        let direction = selection.direction == .north ? 0 : 1
        // An alert names a platform by its id, or by its id plus N or S
        let stops = Set(selection.platforms.map(\.id) + selection.stopIDs)
        let alerts: [ServiceAlert] = entries.compactMap { entry in
            let applies = entry.informed.contains { informed in
                guard let route = informed.route_id, selection.routes.contains(Lines.normalized(route)) else { return false }
                if let stop = informed.stop_id, !stops.contains(stop) { return false }
                if let informedDirection = informed.direction_id, informedDirection != direction { return false }
                return true
            }
            guard applies, entry.isActive(from: time, to: time) else { return nil }
            let kind = kind(of: entry.type)
            return ServiceAlert(
                id: entry.id,
                kind: kind,
                type: entry.type,
                header: readable(entry.header),
                details: readable(entry.details),
                period: entry.period,
                brief: kind == .delays ? AlertBrief(header: entry.header) : nil,
                markedHeader: marked(entry.header)
            )
        }
        return alerts.sorted { $0.kind < $1.kind }
    }

    static func kind(of type: String) -> ServiceAlert.Kind {
        let type = type.lowercased()
        if type.contains("delay") { return .delays }
        if type.contains("suspend") { return .suspended }
        if type.contains("notice") || type.contains("extra service") || type.contains("special schedule") { return .notice }
        return .serviceChange
    }

    /// The MTA writes lines as "[R]" and icons as "[airplane icon]". Lines side
    /// by side, as in "[2][5] trains", become "2 and 5 trains", not "25 trains".
    static func readable(_ text: String) -> String {
        text.replacing(#/\[[A-Z0-9]{1,3}\](?:\s*\[[A-Z0-9]{1,3}\])*/#) { run in
            let lines = run.output.matches(of: #/\[([A-Z0-9]{1,3})\]/#).map { String($0.1) }
            guard let last = lines.last, lines.count > 1 else { return lines.joined() }
            return lines.dropLast().joined(separator: ", ") + " and " + last
        }
            .replacingOccurrences(of: #"\s*\[[a-z ]+ icon\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// As `readable`, but with the lines left as "[R]", for drawing as bullets.
    static func marked(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\[[a-z ]+ icon\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The feed is GTFS-realtime written as JSON, with the MTA's "mercury" additions.
    private struct Feed: Decodable { let entity: [Entity] }
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
        let translation: [Translation]
        var english: String? { translation.first { $0.language == "en" }?.text ?? translation.first?.text }
    }
    private struct Translation: Decodable {
        let text: String
        let language: String?
    }
    private struct Mercury: Decodable {
        let alert_type: String?
        let human_readable_active_period: Translated?
    }
}
