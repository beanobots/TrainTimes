import Foundation

/// An elevator or escalator that's out of service, now or on a planned date.
struct Outage: Identifiable, Hashable, Sendable {
    let id: String
    let isElevator: Bool
    /// Needed for step-free access.
    let isAccessibilityElevator: Bool
    /// E.g. "Street to Manhattan-bound platform".
    let serving: String
    let reason: String
    let start: Date?
    let estimatedReturn: Date?
    let isPlanned: Bool
    /// The MTA's suggested alternative route, for elevators.
    let alternative: String
    /// GTFS stops of the platforms it serves, e.g. ["718", "R09"]; nil when the MTA doesn't say.
    var stops: [String]? = nil

    /// Whether it serves, or might serve, one of `platforms`; unknown stops count as any.
    func serves(anyOf platforms: [Platform]) -> Bool {
        guard let stops, !stops.isEmpty else { return true }
        return platforms.contains { stops.contains($0.id) }
    }
}

/// The elevators and escalators the MTA runs, from equipment.json (built by tools/make_stations.py).
enum EquipmentDirectory {
    struct Machine: Codable, Hashable, Sendable {
        let complex: String
        let elevator: Bool
        let ada: Bool
        let serving: String
        let alternative: String
        /// GTFS stops of the platforms it serves, e.g. ["718", "R09"]; nil in older lists.
        var stops: [String]? = nil
    }

    static let all: [String: Machine] = {
        guard let url = Bundle.main.url(forResource: "equipment", withExtension: "json"),
              let machines = try? load(from: url) else { return [:] }
        return machines
    }()

    static func load(from url: URL) throws -> [String: Machine] {
        try JSONDecoder().decode([String: Machine].self, from: Data(contentsOf: url))
    }

    static func hasEquipment(atComplex complex: String) -> Bool {
        all.values.contains { $0.complex == complex }
    }

    /// Whether any equipment serves, or might serve, one of a station's `platforms`, as in
    /// `Outage.serves(anyOf:)`.
    static func hasEquipment(serving platforms: [Platform]) -> Bool {
        guard let complex = platforms.first?.complex else { return false }
        return all.values.contains { machine in
            guard machine.complex == complex else { return false }
            guard let stops = machine.stops, !stops.isEmpty else { return true }
            return platforms.contains { stops.contains($0.id) }
        }
    }
}

enum OutagesFeed {
    /// Current and planned elevator and escalator outages (about 40 KB).
    static let url = URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fnyct_ene.json")!

    /// Outages at a station complex, current first. Unreadable rows are skipped.
    static func outages(atComplex complex: String, in data: Data, equipment: [String: EquipmentDirectory.Machine] = EquipmentDirectory.all) throws -> [Outage] {
        let rows = try JSONDecoder().decode([MaybeRow].self, from: data).compactMap(\.row)
        let outages: [Outage] = rows.compactMap { row in
            guard let machine = equipment[row.equipment], machine.complex == complex else { return nil }
            return Outage(
                id: row.equipment + (row.outagedate ?? ""),
                isElevator: machine.elevator,
                isAccessibilityElevator: machine.elevator && machine.ada,
                serving: sentence(row.serving ?? machine.serving),
                reason: row.reason ?? "",
                start: date(row.outagedate),
                estimatedReturn: date(row.estimatedreturntoservice),
                isPlanned: row.isupcomingoutage == "Y",
                alternative: machine.alternative,
                stops: machine.stops
            )
        }
        return outages.sorted { a, b in
            if a.isPlanned != b.isPlanned { return !a.isPlanned }
            return (a.start ?? .distantPast) < (b.start ?? .distantPast)
        }
    }

    private struct Row: Decodable {
        let equipment: String
        let serving: String?
        let reason: String?
        let outagedate: String?
        let estimatedreturntoservice: String?
        let isupcomingoutage: String?
    }

    /// Nil for a malformed row.
    private struct MaybeRow: Decodable {
        let row: Row?

        init(from decoder: Decoder) throws {
            row = try? Row(from: decoder)
        }
    }

    /// Some descriptions start in lower case ("mezzanine to 4/5 platform").
    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// E.g. "10/30/2026 10:00:00 PM", New York time.
    private static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return dateFormatter.date(from: text)
    }

    /// Shared across rows to save the widget's limited memory.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "MM/dd/yyyy hh:mm:ss a"
        return formatter
    }()
}
