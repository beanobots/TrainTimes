import Foundation
import Testing
@testable import TrainCore

/// A train of lines that run opposite ways on their platform: the M with the J
/// and Z from Myrtle Av to Delancey St-Essex St, whose ways the MTA names for
/// the J, and the G with the A and C at Hoyt-Schermerhorn Sts. The feeds give
/// a trip one N or S all along its line, so toward Manhattan from Marcy Av the
/// J and Z are S and the M N.
@Suite struct OppositeWaysTests {
    /// The J, Z and M at Marcy Av toward Manhattan, as the train picker's
    /// "Manhattan" for all three has always saved them.
    let jzm = Selection(stationID: "M16", routes: ["J", "Z", "M"], direction: .south)
    let jzURL = Lines.feedURLs(sharingTracksWith: ["J"]).own[0]
    let mURL = Lines.feedURLs(sharingTracksWith: ["M"]).own[0]

    /// The J and Z feed as it was one evening, with a Z added: trains both ways at Marcy Av.
    var jzFeed: Data {
        GTFSFeed.feed([
            GTFSFeed.trip("076950_J..S12R", route: "J", stops: [FeedStop("M16S", at: 1), FeedStop("M18S", at: 5),
                                                                 FeedStop("M23S", arrival: 14)]),
            GTFSFeed.trip("079600_J..N45R", route: "J", stops: [FeedStop("M16N", at: 2), FeedStop("M11N", at: 7),
                                                                 FeedStop("G05N", arrival: 30)]),
            GTFSFeed.trip("077100_Z..S", route: "Z", stops: [FeedStop("M16S", at: 3), FeedStop("M23S", arrival: 16)]),
            GTFSFeed.trip("077750_J..S12R", route: "J", stops: [FeedStop("M16S", at: 6), FeedStop("M23S", arrival: 19)]),
        ])
    }

    /// The B D F M feed of the same evening: Ms both ways at Marcy Av.
    var mFeed: Data {
        GTFSFeed.feed([
            GTFSFeed.trip("074700_M..S24R", route: "M", stops: [FeedStop("M18S", at: 1), FeedStop("M16S", at: 4.3),
                                                                 FeedStop("M01S", arrival: 25)]),
            GTFSFeed.trip("079450_M..N24R", route: "M", stops: [FeedStop("M16N", at: 4.5), FeedStop("M18N", at: 8),
                                                                 FeedStop("G08N", arrival: 50)]),
            GTFSFeed.trip("080250_M..N24R", route: "M", stops: [FeedStop("M16N", at: 8.2), FeedStop("G08N", arrival: 54)]),
        ])
    }

    /// `selection`'s trains from the two feeds, as a board finds them.
    func trains(for selection: Selection) throws -> [Arrival] {
        let arrivals = try TrainService.arrivals(at: Set(selection.stopIDs), own: [jzFeed, mFeed], others: [], now: now)
        return TrainService.trains(for: selection, in: arrivals, now: now)
    }

    @Test func allOfAPlatformsLinesGoTheWayTheyreNamed() throws {
        #expect(jzm.heading == "Manhattan")
        #expect(jzm.direction(of: "J") == .south)
        #expect(jzm.direction(of: "M") == .north)
        #expect(jzm.stopIDs == ["M16S", "M16N"])
        // Every Manhattan-bound train of the three, and no other
        let trains = try trains(for: jzm)
        #expect(trains.map(\.trip) == ["076950_J..S12R", "077100_Z..S", "079450_M..N24R", "077750_J..S12R",
                                       "080250_M..N24R"])
        #expect(trains.allSatisfy { jzm.heading(of: $0) == "Manhattan" })
        // And the other way, toward Jamaica and Middle Village
        var away = jzm
        away.direction = .north
        #expect(away.heading == "Jamaica - Middle Village")
        #expect(try self.trains(for: away).map(\.trip) == ["079600_J..N45R", "074700_M..S24R"])

        // At Hoyt-Schermerhorn Sts, the A and C toward Manhattan and the G toward Church Av, S
        let acg = Selection(stationID: "A42", routes: ["A", "C", "G"], direction: .north)
        #expect(acg.heading == "Manhattan - Church Av")
        #expect(acg.stopIDs == ["A42N", "A42S"])
        #expect(acg.direction(of: "G") == .south)
    }

    @Test func eachLineOnItsOwnKeepsItsWay() throws {
        // The M alone goes by its own N or S, as it always has
        let m = Selection(stationID: "M16", routes: ["M"], direction: .north)
        #expect(m.heading == "Manhattan")
        #expect(m.stopIDs == ["M16N"])
        #expect(try trains(for: m).map(\.trip) == ["079450_M..N24R", "080250_M..N24R"])
        // So do the J and Z without it
        let jz = Selection(stationID: "M16", routes: ["J", "Z"], direction: .south)
        #expect(jz.heading == "Manhattan")
        #expect(jz.stopIDs == ["M16S"])
        #expect(try trains(for: jz).map(\.trip) == ["076950_J..S12R", "077100_Z..S", "077750_J..S12R"])
        // And the G at Hoyt-Schermerhorn Sts
        let g = Selection(stationID: "A42", routes: ["G"], direction: .south)
        #expect(g.heading == "Manhattan - Church Av")
        #expect(g.stopIDs == ["A42S"])
    }

    @Test func aTrainOfTheOtherLineGoingTheOtherWayIsntShown() {
        func train(_ route: String, at stop: String) -> Arrival {
            Arrival(route: route, time: now, stop: stop, lastStop: "M23S", isLive: true)
        }
        #expect(jzm.shows(train("J", at: "M16S")))
        #expect(jzm.shows(train("M", at: "M16N")))
        #expect(!jzm.shows(train("J", at: "M16N")))
        #expect(!jzm.shows(train("M", at: "M16S")))
        // Another line's train running on theirs goes by the J's way
        #expect(jzm.shows(train("F", at: "M16S")))
        #expect(!jzm.shows(train("F", at: "M16N")))
    }

    @Test func theServerFindsThemOnceForEveryCountdown() throws {
        let m = Selection(stationID: "M16", routes: ["M"], direction: .north)
        let selections = [jzm, m]
        let stops = Set(selections.flatMap(\.stopIDs))
        let feeds = TrainService.arrivals(at: stops, in: [jzURL: jzFeed, mURL: mFeed], now: now)
        let trains = TrainService.trains(for: selections, in: feeds, now: now)
        #expect(trains[jzm.trainID]?.map(\.trip) == ["076950_J..S12R", "077100_Z..S", "079450_M..N24R",
                                                     "077750_J..S12R", "080250_M..N24R"])
        #expect(trains[m.trainID]?.map(\.trip) == ["079450_M..N24R", "080250_M..N24R"])

        // And the countdown goes from one Manhattan-bound train to the next, whatever its line
        let state = try #require(CountdownState(for: jzm, trains: trains[jzm.trainID] ?? [], notice: nil, now: now,
                                                following: nil, after: nil))
        #expect(state.trip == "076950_J..S12R")
        #expect(state.terminal == "Broad St")
        #expect(state.followingRoutes == ["Z", "M"])
        let next = try #require(CountdownState(for: jzm, trains: trains[jzm.trainID] ?? [], notice: nil,
                                               now: now.addingTimeInterval(3.5 * 60), following: nil, after: nil))
        #expect(next.trip == "079450_M..N24R")
        #expect(next.terminal == "Forest Hills")
    }

    @Test func aChoiceSavedBeforeStillMeansWhatItSaid() throws {
        // As the app saved it when the picker named all three "Manhattan"
        let json = #"{"stationID":"M16","routes":["J","Z","M"],"direction":"S","elevatorAlerts":false,"#
            + #""serviceAlerts":true,"walkMinutes":0}"#
        let saved = try JSONDecoder().decode(Selection.self, from: Data(json.utf8))
        #expect(saved == jzm)
        #expect(saved.trainID == "M16:S:J,Z,M")
        #expect(saved.heading == "Manhattan")
        #expect(saved.stopIDs == ["M16S", "M16N"])
    }

    @Test func eachLinesAlertsGoByItsOwnWay() throws {
        func entity(_ id: String, route: String, stop: String? = nil, direction: Int? = nil) -> [String: Any] {
            var informed: [String: Any] = ["agency_id": "MTASBWY", "route_id": route]
            if let stop { informed["stop_id"] = stop }
            if let direction { informed["direction_id"] = direction }
            return ["id": id, "alert": [
                "informed_entity": [informed],
                "header_text": ["translation": [["text": "\(route) trains are delayed.", "language": "en"]]],
                "transit_realtime.mercury_alert": ["alert_type": "Delays"],
            ] as [String: Any]]
        }
        let entries = try AlertsFeed.entries(in: JSONSerialization.data(withJSONObject: ["entity": [
            entity("M uptown", route: "M", direction: 0),
            entity("M to Middle Village", route: "M", direction: 1),
            entity("M at Marcy Av uptown", route: "M", stop: "M16N"),
            entity("M at Marcy Av to Middle Village", route: "M", stop: "M16S"),
            entity("J to Broad St", route: "J", direction: 1),
            entity("J at Marcy Av to Jamaica", route: "J", stop: "M16N"),
            entity("J at Marcy Av", route: "J", stop: "M16"),
        ]]), now: now)
        let alerts = AlertsFeed.alerts(for: jzm, in: entries, now: now)
        #expect(Set(alerts.map(\.id)) == ["M uptown", "M at Marcy Av uptown", "J to Broad St", "J at Marcy Av"])
    }
}
