import Foundation

/// A service alert from the MTA: delays, planned work, skipped stops, station notices.
struct ServiceAlert: Identifiable, Hashable, Sendable {
    /// How much it matters to someone waiting for a train, most first.
    enum Kind: Int, Comparable, Sendable {
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
    }

    let id: String
    let kind: Kind
    /// The MTA's own type, e.g. "Planned - Stops Skipped".
    let type: String
    let header: String
    let details: String
    /// When it applies, in the MTA's words, e.g. "Nov 2 - 5, Mon to Thu, 9:45 PM to 11:30 PM".
    let period: String?
}

enum AlertsFeed {
    /// All subway alerts, current and planned. About 1 MB, but sent gzipped (about 80 KB).
    static let url = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts.json")!

    /// The alerts in effect at `now` that affect `selection`'s lines at their
    /// platforms and direction, most important first.
    static func alerts(for selection: Selection, in data: Data, now: Date = Date()) throws -> [ServiceAlert] {
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        let time = now.timeIntervalSince1970
        let direction = selection.direction == .north ? 0 : 1
        // An alert names a platform by its id, or by its id plus N or S
        let stops = Set(selection.platforms.map(\.id) + selection.stopIDs)
        let alerts: [ServiceAlert] = feed.entity.compactMap { entity in
            guard let alert = entity.alert else { return nil }
            let periods = alert.active_period ?? []
            let isActive = periods.isEmpty || periods.contains { period in
                (period.start ?? 0) <= time && (period.end.map { $0 == 0 || $0 > time } ?? true)
            }
            let applies = (alert.informed_entity ?? []).contains { informed in
                guard let route = informed.route_id, selection.routes.contains(Lines.normalized(route)) else { return false }
                if let stop = informed.stop_id, !stops.contains(stop) { return false }
                if let informedDirection = informed.direction_id, informedDirection != direction { return false }
                return true
            }
            guard isActive, applies else { return nil }
            let type = alert.mercury?.alert_type ?? ""
            return ServiceAlert(
                id: entity.id,
                kind: kind(of: type),
                type: type,
                header: readable(alert.header_text?.english ?? ""),
                details: readable(alert.description_text?.english ?? ""),
                period: alert.mercury?.human_readable_active_period?.english
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

    /// The MTA writes lines as "[R]" and icons as "[airplane icon]".
    static func readable(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([A-Z0-9]{1,3})\]"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\[[a-z ]+ icon\]"#, with: "", options: .regularExpression)
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
    private struct Period: Decodable {
        let start: Double?
        let end: Double?
    }
    private struct Informed: Decodable {
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
