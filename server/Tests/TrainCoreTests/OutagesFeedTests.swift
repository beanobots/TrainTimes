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

    @Test func aRowThatCantBeReadIsLeftOut() throws {
        var withoutEquipment = row("EL101", start: "06/16/2026 08:30:00 AM")
        withoutEquipment["equipment"] = nil
        let rows: [Any] = [
            row("EL100", start: "06/15/2026 08:30:00 AM"),
            withoutEquipment,
            ["equipment": 101, "outagedate": "06/16/2026 08:30:00 AM"] as [String: Any],
            "EL101",
            NSNull(),
            row("ES200", start: "06/17/2026 08:30:00 AM"),
        ]
        let outages = try OutagesFeed.outages(atComplex: "30", in: try JSONSerialization.data(withJSONObject: rows),
                                              equipment: equipment)
        #expect(outages.map(\.id) == ["EL10006/15/2026 08:30:00 AM", "ES20006/17/2026 08:30:00 AM"])
    }

    @Test func eachHasTheStopsItServes() throws {
        var equipment = self.equipment
        equipment["EL100"]?.stops = ["R34"]
        let outages = try OutagesFeed.outages(atComplex: "30", in: try JSONSerialization.data(withJSONObject: [
            row("EL100", start: "06/15/2026 08:30:00 AM"),
            row("EL101", start: "06/16/2026 08:30:00 AM"),
        ]), equipment: equipment)
        #expect(outages.map(\.stops) == [["R34"], nil])
    }

    @Test func anEquipmentListFromBeforeStopsStillLoads() throws {
        let json = #"{"EL100": {"complex": "30", "elevator": true, "ada": true, "serving": "Street to platform", "#
            + #""alternative": ""}, "EL218": {"complex": "602", "elevator": true, "ada": true, "#
            + #""serving": "Mezzanine to L platform", "alternative": "", "stops": ["L03", "R20"]}}"#
        let machines = try JSONDecoder().decode([String: EquipmentDirectory.Machine].self, from: Data(json.utf8))
        #expect(machines["EL100"]?.stops == nil)
        #expect(machines["EL218"]?.stops == ["L03", "R20"])
        // The one built into the app has them
        #expect(EquipmentDirectory.all["EL218"]?.stops == ["L03", "R20"])
    }

    @Test func oneWhoseStopsArentKnownMightServeAnyPlatform() {
        let canal = Selection(stationID: "R23", routes: ["R", "6"], direction: .north).platforms
        #expect(Set(canal.map(\.id)) == ["639", "R23"])
        var outage = Outage(id: "EL324", isElevator: true, isAccessibilityElevator: true, serving: "Street to platform",
                            reason: "Repair", start: nil, estimatedReturn: nil, isPlanned: false, alternative: "")
        #expect(outage.serves(anyOf: canal))
        outage.stops = []
        #expect(outage.serves(anyOf: canal))
        outage.stops = ["639"]
        #expect(outage.serves(anyOf: canal))
        #expect(outage.serves(anyOf: canal.filter { $0.id == "639" }))
        #expect(!outage.serves(anyOf: canal.filter { $0.id == "R23" }))
        #expect(!outage.serves(anyOf: []))
    }

    /// The feed with a current outage of each of `equipment`, a day apart.
    func feed(_ equipment: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: equipment.enumerated().map { day, equipment in
            row(equipment, start: "06/1\(day)/2026 08:30:00 AM")
        })
    }

    @Test func aSelectionGetsOnlyThoseThatServeItsLinesPlatforms() throws {
        // At Canal St, EL324 and EL325 go only to the 6's platforms; at 14
        // St-Union Sq, EL218 goes to the L's and EL219 the N Q R W's (the MTA
        // gives both for each)
        let data = try feed(["EL324", "EL325", "EL218", "EL219"])
        func outages(_ stationID: String, _ routes: [String]) -> [String]? {
            TrainService.outages(for: Selection(stationID: stationID, routes: routes, direction: .north), in: data)?
                .map { String($0.id.prefix(5)) }
        }
        #expect(outages("R23", ["R"]) == [])
        #expect(outages("R23", ["6"]) == ["EL324", "EL325"])
        #expect(outages("R23", ["R", "6"]) == ["EL324", "EL325"])
        #expect(outages("R20", ["L"]) == ["EL218", "EL219"])
        #expect(outages("R20", ["R"]) == ["EL218", "EL219"])
        #expect(outages("R20", ["4"]) == [])
    }

    @Test func noneToFetchAtAStationWithoutElevatorsOrEscalators() {
        // Prospect Av has only stairs, so without the feed there are still none
        #expect(!EquipmentDirectory.hasEquipment(atComplex: prospect.station?.complex ?? ""))
        #expect(TrainService.outages(for: prospect, in: nil) == [])
        // Where there are some, the feed is needed
        #expect(TrainService.outages(for: Selection(stationID: "R23", routes: ["R"], direction: .north), in: nil) == nil)
    }
}
