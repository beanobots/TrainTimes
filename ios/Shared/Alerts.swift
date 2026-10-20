import Foundation

/// A service alert from the MTA: delays, planned work, skipped stops, station notices.
struct ServiceAlert: Identifiable, Hashable, Sendable {
    /// Compared by how much it matters to someone waiting for a train, most
    /// first; declared in the order Settings lists them. The numbers are how
    /// Settings saves a choice of kinds, and how the app sends it to the
    /// server, so each kind keeps its own.
    enum Kind: Int, Codable, Comparable, CaseIterable, Sendable {
        case delays = 0, suspended = 1, serviceChange = 2, notice = 3

        /// No trains at your station before slow ones, then changes, then notices.
        private var priority: Int {
            switch self {
            case .suspended: 0
            case .delays: 1
            case .serviceChange: 2
            case .notice: 3
            }
        }

        static func < (a: Kind, b: Kind) -> Bool { a.priority < b.priority }

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
            case .suspended: "Suspensions, planned or not"
            case .serviceChange: "Service changes and other planned work"
            case .notice: "Station notices and extra service"
            }
        }
    }

    /// A choice of kinds as Settings saves it and the app sends it to the
    /// server, their numbers: `[0, 1, 2, 3]`. A number this build doesn't know,
    /// a kind added since, is left out rather than losing the rest.
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

        // A place before "-bound" doesn't start with a word like the "Some" of
        // "Some Manhattan-bound", and "Downtown Brooklyn" is a place, not a way
        if header.localizedCaseInsensitiveContains("both directions") {
            direction = "Both directions"
        } else if let match = header.firstMatch(of: #/\b(?:(?!(?:Some|Most|All|Many|Several|Few|No|The)\b)[A-Z0-9][\w./]*(?:[ -][A-Z0-9][\w./]*)*-bound|[Nn]orthbound|[Ss]outhbound|[Uu]ptown|[Dd]owntown(?! Brooklyn))\b/#) {
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
        /// Where else riders are affected: stations before skipped, rerouted or
        /// suspended stops, whose trains are changed further along.
        fileprivate let affected: [Informed]
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

    /// The alerts in effect at `now` that affect `selection`'s lines at their
    /// platforms and direction, most important first: those about there, and
    /// those whose trains from there are changed further along.
    static func alerts(for selection: Selection, in entries: [Entry], now: Date = Date()) -> [ServiceAlert] {
        let time = now.timeIntervalSince1970
        let platforms = selection.platforms.map(\.id)
        func matches(_ informed: Informed) -> Bool {
            guard let route = informed.route_id.map(Lines.normalized), selection.routes.contains(route) else { return false }
            // Each line going its own way: toward Manhattan from Marcy Av, the J is S and the M N
            let direction = selection.direction(of: route)
            // An alert names a platform by its id, or by its id plus N or S
            if let stop = informed.stop_id, !platforms.contains(where: { stop == $0 || stop == $0 + direction.rawValue }) {
                return false
            }
            if let informedDirection = informed.direction_id, informedDirection != (direction == .north ? 0 : 1) { return false }
            return true
        }
        let alerts: [ServiceAlert] = entries.compactMap { entry in
            let isHere = entry.informed.contains(where: matches)
            guard isHere || entry.affected.contains(where: matches), entry.isActive(from: time, to: time) else { return nil }
            var kind = kind(of: entry.type)
            // Suspended further along, trains still run from here
            if !isHere, kind == .suspended { kind = .serviceChange }
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
            Lines.joined(run.output.matches(of: #/\[([A-Z0-9]{1,3})\]/#).map { String($0.1) })
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
    private struct Feed: Decodable { let entity: [Lenient<Entity>] }
    /// Nil where it can't be read, so one entity or station the MTA gets wrong doesn't lose the rest.
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
