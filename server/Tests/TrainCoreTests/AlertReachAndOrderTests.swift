import Foundation
import Testing
@testable import TrainCore

/// A stop an alert names: a line, and maybe a platform and a direction (0 north, 1 south).
private typealias InformedStop = (route: String, stop: String?, direction: Int?)

/// An alert entity as the MTA's feed writes it, in effect all the time.
private func mtaAlertEntity(_ id: String, type: String, header: String, informed: [InformedStop],
                            affected: [InformedStop] = []) -> [String: Any] {
    func selector(_ stop: InformedStop) -> [String: Any] {
        var json: [String: Any] = ["agency_id": "MTASBWY", "route_id": stop.route]
        if let id = stop.stop { json["stop_id"] = id }
        if let direction = stop.direction { json["direction_id"] = direction }
        return json
    }
    var mercury: [String: Any] = ["alert_type": type]
    if !affected.isEmpty { mercury["affected_stations"] = affected.map(selector) }
    let alert: [String: Any] = [
        "informed_entity": informed.map(selector),
        "header_text": ["translation": [["text": header, "language": "en"]]],
        "transit_realtime.mercury_alert": mercury,
    ]
    return ["id": id, "alert": alert]
}

private func mtaAlertEntries(_ entities: [[String: Any]]) throws -> [AlertsFeed.Entry] {
    try AlertsFeed.entries(in: JSONSerialization.data(withJSONObject: ["entity": entities]), now: now)
}

/// `ServiceAlert.Kind`: its order, and the numbers a choice of kinds is saved and sent as.
@Suite struct AlertKindOrderTests {
    @Test func savedNumbersStayTheSame() throws {
        #expect(ServiceAlert.Kind(rawValue: 0) == .delays)
        #expect(ServiceAlert.Kind(rawValue: 1) == .suspended)
        #expect(ServiceAlert.Kind(rawValue: 2) == .serviceChange)
        #expect(ServiceAlert.Kind(rawValue: 3) == .notice)
        let encoded = try JSONEncoder().encode([ServiceAlert.Kind.suspended])
        #expect(String(decoding: encoded, as: UTF8.self) == "[1]")
    }

    @Test func suspensionsFirst() {
        #expect(ServiceAlert.Kind.allCases.sorted() == [.suspended, .delays, .serviceChange, .notice])
    }

    @Test func unknownKindsAreLeftOut() throws {
        let known = try JSONDecoder().decode(ServiceAlert.KnownKinds.self, from: Data("[0, 2, 9]".utf8))
        #expect(known.kinds == [.delays, .serviceChange])
    }

    @Test func registrationKeepsTheKindsItKnows() throws {
        let body: [String: Any] = [
            "token": sampleToken, "environment": "sandbox",
            "selection": try JSONSerialization.jsonObject(with: JSONEncoder().encode(prospect)),
            "trip": "091200_R..N", "alertKinds": [1, 7],
        ]
        let request = try JSONDecoder().decode(RegistrationRequest.self, from: JSONSerialization.data(withJSONObject: body))
        #expect(request.alertKinds?.kinds == [.suspended])
    }
}

/// `AlertsFeed.alerts(for:in:now:)` finding alerts by the MTA's informed and affected stations.
@Suite struct AlertReachTests {
    /// Manhattan-bound R trains skip 25 St to Union St; stations before them are affected.
    func skippedStops() -> [String: Any] {
        mtaAlertEntity("skip", type: "Planned - Stops Skipped",
                       header: "In Brooklyn, Manhattan-bound [R] skips 25 St, Prospect Av, 4 Av-9 St and Union St",
                       informed: [("R", "R35", 0), ("R", "R34", 0), ("R", "R33", 0), ("R", "R32", 0)],
                       affected: [("R", "R45", 0), ("R", "R44", 0), ("R", "R36", 0)])
    }

    @Test func upstreamOfSkippedStops() throws {
        let entries = try mtaAlertEntries([skippedStops()])
        let bayRidge = Selection(stationID: "R45", routes: ["R"], direction: .north)
        #expect(AlertsFeed.alerts(for: bayRidge, in: entries, now: now).map(\.id) == ["skip"])
        #expect(AlertsFeed.alerts(for: prospect, in: entries, now: now).map(\.kind) == [.serviceChange])
        // Only the way the MTA says
        let thirtySixth = Selection(stationID: "R36", routes: ["R"], direction: .south)
        #expect(AlertsFeed.alerts(for: thirtySixth, in: entries, now: now).isEmpty)
    }

    @Test func suspensionFurtherAlongIsAChangeHere() throws {
        let entries = try mtaAlertEntries([
            mtaAlertEntity("part", type: "Planned - Part Suspended",
                           header: "In Queens, no [A] between Rockaway Blvd and Ozone Park-Lefferts Blvd",
                           informed: [("A", "A65", nil), ("A", "A64", nil), ("A", "A63", nil), ("A", "A61", 1)],
                           affected: [("A", "A59", 1), ("A", "A60", 1)]),
        ])
        let rockawayBlvd = Selection(stationID: "A61", routes: ["A"], direction: .south)
        let eightieth = Selection(stationID: "A59", routes: ["A"], direction: .south)
        #expect(AlertsFeed.alerts(for: rockawayBlvd, in: entries, now: now).map(\.kind) == [.suspended])
        #expect(AlertsFeed.alerts(for: eightieth, in: entries, now: now).map(\.kind) == [.serviceChange])
    }

    @Test func suspensionHereOutranksADelayAlongTheLine() throws {
        let entries = try mtaAlertEntries([
            mtaAlertEntity("delay", type: "Delays", header: "[R] trains are running with delays.", informed: [("R", nil, nil)]),
            mtaAlertEntity("suspended", type: "Planned - Part Suspended", header: "No [R] at Prospect Av",
                           informed: [("R", "R34", nil)]),
            skippedStops(),
        ])
        #expect(AlertsFeed.alerts(for: prospect, in: entries, now: now).map(\.id) == ["suspended", "delay", "skip"])
    }
}

/// `AlertsFeed.entries(in:now:)` reading a feed with entities the MTA got wrong.
@Suite struct AlertFeedToleranceTests {
    @Test func oneBadEntityKeepsTheRest() throws {
        var noID = mtaAlertEntity("x", type: "Delays", header: "[R] trains are delayed.", informed: [("R", nil, nil)])
        noID["id"] = nil
        var badPeriod = mtaAlertEntity("badPeriod", type: "Delays", header: "[R] trains are delayed.", informed: [("R", nil, nil)])
        var alert = try #require(badPeriod["alert"] as? [String: Any])
        alert["active_period"] = [["start": "soon"]]
        badPeriod["alert"] = alert
        var noTranslation = mtaAlertEntity("noTranslation", type: "Reroute", header: "", informed: [("R", nil, nil)])
        alert = try #require(noTranslation["alert"] as? [String: Any])
        alert["header_text"] = [String: Any]()
        noTranslation["alert"] = alert
        var noText = mtaAlertEntity("noText", type: "Station Notice", header: "", informed: [("R", nil, nil)])
        alert = try #require(noText["alert"] as? [String: Any])
        alert["header_text"] = ["translation": [["language": "en"]]]
        noText["alert"] = alert

        let entries = try mtaAlertEntries([
            noID, badPeriod, noTranslation, noText,
            mtaAlertEntity("good", type: "Delays", header: "[R] trains are delayed.", informed: [("R", nil, nil)]),
        ])
        let alerts = AlertsFeed.alerts(for: prospect, in: entries, now: now)
        #expect(alerts.map(\.id) == ["good", "noTranslation", "noText"])
        #expect(alerts.first?.header == "R trains are delayed.")
        #expect(alerts.dropFirst().allSatisfy { $0.header.isEmpty })
    }

    @Test func badAffectedStationKeepsTheAlert() throws {
        var skip = mtaAlertEntity("skip", type: "Planned - Stops Skipped", header: "Manhattan-bound [R] skips Prospect Av",
                                  informed: [("R", "R34", 0)])
        var alert = try #require(skip["alert"] as? [String: Any])
        // One station with its direction written as a string, one as it should be
        let affected: [[String: Any]] = [
            ["agency_id": "MTASBWY", "route_id": "R", "stop_id": "R44", "direction_id": "0"],
            ["agency_id": "MTASBWY", "route_id": "R", "stop_id": "R45", "direction_id": 0],
        ]
        let mercury: [String: Any] = ["alert_type": "Planned - Stops Skipped", "affected_stations": affected]
        alert["transit_realtime.mercury_alert"] = mercury
        skip["alert"] = alert

        let entries = try mtaAlertEntries([skip])
        #expect(AlertsFeed.alerts(for: prospect, in: entries, now: now).map(\.id) == ["skip"])
        let bayRidge = Selection(stationID: "R45", routes: ["R"], direction: .north)
        #expect(AlertsFeed.alerts(for: bayRidge, in: entries, now: now).map(\.id) == ["skip"])
        let eightySixth = Selection(stationID: "R44", routes: ["R"], direction: .north)
        #expect(AlertsFeed.alerts(for: eightySixth, in: entries, now: now).isEmpty)
    }
}

/// `AlertBrief(header:)` with the direction words of real headlines, and the Staten Island Railway.
@Suite struct AlertBriefWordingTests {
    @Test func quantifierIsntPartOfThePlace() throws {
        let coneyIsland = try #require(AlertBrief(header: "Some Coney Island-Stillwell Av-bound [N] trains will end at Kings Hwy while we address a switch problem near Coney Island-Stillwell Av."))
        #expect(coneyIsland.routes == ["N"])
        #expect(coneyIsland.direction == "Coney Island-Stillwell Av-bound")
        #expect(AlertBrief(header: "Some Manhattan-bound [D] trains are delayed.")?.direction == "Manhattan-bound")
        #expect(AlertBrief(header: "Most Inwood-bound [A] trains are running with delays.")?.direction == "Inwood-bound")
        #expect(AlertBrief(header: "No Jamaica-bound [E] trains are stopping at Briarwood.")?.direction == "Jamaica-bound")
    }

    @Test func downtownBrooklynIsAPlace() throws {
        let brief = try #require(AlertBrief(header: "[R] trains are running with delays near Downtown Brooklyn."))
        #expect(brief.direction == nil)
        #expect(AlertBrief(header: "Downtown [1] trains are delayed.")?.direction == "Downtown")
    }

    @Test func statenIslandRailway() throws {
        #expect(Lines.normalized("SIR") == "SI")
        let entries = try mtaAlertEntries([
            mtaAlertEntity("leaves", type: "Expect Delays", header: "Fallen leaves may slow [SIR] service", informed: [("SI", nil, nil)]),
        ])
        let arthurKill = Selection(stationID: "S11", routes: ["SI"], direction: .north)
        let alert = try #require(AlertsFeed.alerts(for: arthurKill, in: entries, now: now).first)
        #expect(alert.kind == .delays)
        #expect(alert.brief?.routes == ["SI"])
    }
}

/// `StationDirectory.direction(toward:on:from:)` for a borough: toward the end of the line in it.
@Suite struct BoroughBoundTests {
    @Test func towardTheEndInTheBorough() {
        // From Canal St the J has Manhattan both ways, but only Broad St's end is in it
        #expect(StationDirectory.direction(toward: "Manhattan", on: "J", from: ["M20"]) == .south)
        #expect(StationDirectory.direction(toward: "Queens", on: "J", from: ["M20"]) == .north)
        // From 3 Av the L has Manhattan both ways, but only 8 Av's end is in it
        #expect(StationDirectory.direction(toward: "Manhattan", on: "L", from: ["L05"]) == .north)
    }

    @Test func neitherEndFallsBackToItsStations() {
        // The R ends in Queens and Brooklyn: from Court St, Manhattan is all north
        #expect(StationDirectory.direction(toward: "Manhattan", on: "R", from: ["R28"]) == .north)
        // From Times Sq-42 St, it's both ways
        #expect(StationDirectory.direction(toward: "Manhattan", on: "R", from: ["R16"]) == nil)
    }

    @Test func aManhattanBoundDelayTheOtherWayIsLeftOut() throws {
        let entries = try mtaAlertEntries([
            mtaAlertEntity("late", type: "Delays", header: "Manhattan-bound [J] trains are delayed.", informed: [("J", nil, nil)]),
        ])
        let towardQueens = Selection(stationID: "M20", routes: ["J"], direction: .north)
        let towardBroadSt = Selection(stationID: "M20", routes: ["J"], direction: .south)
        #expect(AlertsFeed.alerts(for: towardQueens, in: entries, now: now).isEmpty)
        #expect(AlertsFeed.alerts(for: towardBroadSt, in: entries, now: now).count == 1)
    }
}

/// A transfer's alerts: the train's, and the changed-to lines' at the change, going their way.
@Suite struct TransferAlertTests {
    /// The R from Prospect Av toward Manhattan, changing to the D or N at Atlantic Av-Barclays Ctr.
    private let prospect = Selection(stationID: "R34", routes: ["R"], direction: .north)
    private let atlantic = Change(stationID: "R31", routes: ["D", "N"])

    private func alerts(_ entities: [[String: Any]]) throws -> [ServiceAlert] {
        AlertsFeed.alerts(for: [prospect] + atlantic.departureSelections(for: prospect),
                          in: try mtaAlertEntries(entities), now: now)
    }

    @Test func changedToLinesGoingTheirWay() throws {
        let shown = try alerts([
            mtaAlertEntity("d", type: "Delays", header: "Manhattan-bound [D] trains are delayed.", informed: [("D", nil, nil)]),
            mtaAlertEntity("n", type: "Delays", header: "Coney Island-bound [N] trains are delayed.", informed: [("N", nil, nil)]),
            mtaAlertEntity("f", type: "Delays", header: "[F] trains are delayed.", informed: [("F", nil, nil)]),
        ])
        #expect(shown.map(\.id) == ["d"])
        #expect(shown.first?.brief?.routes == ["D"])
    }

    @Test func oneAlertForYoursAndTheirsOnceWithBoth() throws {
        let shown = try alerts([
            mtaAlertEntity("nr", type: "Delays", header: "[N][R] trains are running with delays in both directions.",
                           informed: [("N", nil, nil), ("R", nil, nil)]),
        ])
        #expect(shown.count == 1)
        // Your train's line first, then the one you change to
        #expect(shown.first?.brief?.routes == ["R", "N"])
    }
}
