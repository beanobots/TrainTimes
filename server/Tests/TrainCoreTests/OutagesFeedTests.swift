import Foundation
import Testing
@testable import TrainCore

/// `OutagesFeed` reading the MTA's elevator and escalator outages.
@Suite struct OutagesFeedTests {
    let equipment: [String: EquipmentDirectory.Machine] = [
        "EL100": .init(complex: "30", elevator: true, ada: true, serving: "Street to Manhattan-bound platform",
                       alternative: "Take the R to 4 Av-9 St"),
        "EL101": .init(complex: "30", elevator: true, ada: false, serving: "Mezzanine to platform", alternative: ""),
        "ES200": .init(complex: "30", elevator: false, ada: false, serving: "Street to mezzanine", alternative: ""),
        "EL900": .init(complex: "617", elevator: true, ada: true, serving: "Street to mezzanine", alternative: ""),
    ]

    /// A row of the feed, as the MTA writes it.
    func row(_ equipment: String, serving: String? = nil, start: String?, back: String? = nil,
             planned: Bool = false) -> [String: String] {
        var row = [
            "station": "Prospect Av", "borough": "BKN", "trainno": "R", "equipment": equipment,
            "equipmenttype": equipment.hasPrefix("EL") ? "EL" : "ES", "ADA": "Y", "reason": "Repair",
            "isupcomingoutage": planned ? "Y" : "N", "ismaintenanceoutage": "N",
        ]
        row["serving"] = serving
        row["outagedate"] = start
        row["estimatedreturntoservice"] = back
        return row
    }

    func read(_ rows: [[String: String]]) throws -> [Outage] {
        try OutagesFeed.outages(atComplex: "30", in: try JSONSerialization.data(withJSONObject: rows),
                                equipment: equipment)
    }

    func date(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }

    @Test func theStationsCurrentOnesFirst() throws {
        let outages = try read([
            row("ES200", start: "12/15/2026 08:30:00 AM", back: "12/16/2026 05:00:00 PM", planned: true),
            row("EL100", start: "06/15/2026 08:30:00 AM", back: "06/20/2026 05:00:00 PM"),
            row("EL900", start: "06/01/2026 08:30:00 AM"),
            row("EL101", serving: "mezzanine to Bay Ridge-bound platform", start: "06/10/2026 11:00:00 PM"),
            row("UNKNOWN", start: "06/01/2026 08:30:00 AM"),
        ])
        #expect(outages.map(\.id) == ["EL10106/10/2026 11:00:00 PM", "EL10006/15/2026 08:30:00 AM",
                                      "ES20012/15/2026 08:30:00 AM"])
        #expect(outages.map(\.isPlanned) == [false, false, true])
    }

    @Test func datesAreNewYorkTime() throws {
        let outages = try read([
            row("EL100", start: "06/15/2026 08:30:00 AM", back: "06/20/2026 05:00:00 PM"),
            row("ES200", start: "12/15/2026 08:30:00 AM", back: "", planned: true),
        ])
        #expect(outages.map(\.start) == [date("2026-06-15T12:30:00Z"), date("2026-12-15T13:30:00Z")])
        #expect(outages.map(\.estimatedReturn) == [date("2026-06-20T21:00:00Z"), nil])
    }

    @Test func whatEachOneIs() throws {
        let outages = try read([
            row("EL100", start: "06/15/2026 08:30:00 AM"),
            row("EL101", serving: "mezzanine to Bay Ridge-bound platform", start: "06/16/2026 08:30:00 AM"),
            row("ES200", start: "06/17/2026 08:30:00 AM"),
        ])
        #expect(outages.map(\.isElevator) == [true, true, false])
        #expect(outages.map(\.isAccessibilityElevator) == [true, false, false])
        // The feed's own words, in a sentence, or else the equipment list's
        #expect(outages.map(\.serving) == ["Street to Manhattan-bound platform", "Mezzanine to Bay Ridge-bound platform",
                                           "Street to mezzanine"])
        #expect(outages.map(\.reason) == ["Repair", "Repair", "Repair"])
        #expect(outages.first?.alternative == "Take the R to 4 Av-9 St")
        #expect(outages.first?.estimatedReturn == nil)
    }

    @Test func notTheFeedItWas() {
        #expect(throws: DecodingError.self) {
            try OutagesFeed.outages(atComplex: "30", in: Data(#"{"equipment":"EL100"}"#.utf8), equipment: equipment)
        }
    }
}
