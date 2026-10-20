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
        // The M alone goes by its own N or S, as it always has, and another
        // line's train on its track, which is the J's, by its own line's, either
        let m = Selection(stationID: "M16", routes: ["M"], direction: .north)
        #expect(m.heading == "Manhattan")
        #expect(m.stopIDs == ["M16N", "M16S"])
        #expect(try trains(for: m).map(\.trip) == ["079450_M..N24R", "080250_M..N24R"])
        // So do the J and Z without it, though another line's train on their
        // track, which is the M's, can go by either
        let jz = Selection(stationID: "M16", routes: ["J", "Z"], direction: .south)
        #expect(jz.heading == "Manhattan")
        #expect(jz.stopIDs == ["M16S", "M16N"])
        #expect(try trains(for: jz).map(\.trip) == ["076950_J..S12R", "077100_Z..S", "077750_J..S12R"])
        // And the G at Hoyt-Schermerhorn Sts, on a track of its own
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
        // Another line's train running on theirs goes by its own line's way: an
        // F can only come the M's way, so toward Manhattan it's N, as the M is
        #expect(jzm.shows(train("F", at: "M16N")))
        #expect(!jzm.shows(train("F", at: "M16S")))
        #expect(jzm.heading(of: train("F", at: "M16N")) == "Manhattan")

        // With the M alone toward Manhattan, its own trains are N, and so is an
        // F on its track, not one going S, toward Jamaica
        let m = Selection(stationID: "M16", routes: ["M"], direction: .north)
        #expect(m.shows(train("M", at: "M16N")))
        #expect(!m.shows(train("M", at: "M16S")))
        #expect(m.shows(train("F", at: "M16N")))
        #expect(!m.shows(train("F", at: "M16S")))
        #expect(m.heading(of: train("F", at: "M16N")) == m.heading)
        // And toward Middle Village, the other way round
        var away = m
        away.direction = .south
        #expect(away.shows(train("M", at: "M16S")))
        #expect(away.shows(train("F", at: "M16S")))
        #expect(!away.shows(train("F", at: "M16N")))
        // With the J and Z alone, an F on their track goes by its own way too
        let jz = Selection(stationID: "M16", routes: ["J", "Z"], direction: .south)
        #expect(jz.shows(train("F", at: "M16N")))
        #expect(!jz.shows(train("F", at: "M16S")))
        // Uptown from Delancey St-Essex St, with the F chosen too or the M
        // alone, an F that came over the M's Chrystie St connection to the J's
        // platform is N, as the M is, and one going S is Brooklyn-bound
        let fm = Selection(stationID: "M18", routes: ["F", "M"], direction: .north)
        let mAtDelancey = Selection(stationID: "M18", routes: ["M"], direction: .north)
        for uptown in [fm, mAtDelancey] {
            #expect(uptown.shows(train("F", at: "M18N")))
            #expect(!uptown.shows(train("F", at: "M18S")))
            #expect(uptown.heading(of: train("F", at: "M18N")) == "Broad St (JZ) - Uptown (M)")
        }
        // The G alone toward Church Av at Hoyt-Schermerhorn Sts is S, and so is
        // an F running on its own track; an E across the platform on the A and
        // C's isn't running on it, toward Manhattan, N, or Euclid Av, S
        let g = Selection(stationID: "A42", routes: ["G"], direction: .south)
        #expect(g.shows(train("G", at: "A42S")))
        #expect(g.shows(train("F", at: "A42S")))
        #expect(!g.shows(train("E", at: "A42N")))
        #expect(!g.shows(train("E", at: "A42S")))
        #expect(g.heading(of: train("F", at: "A42S")) == g.heading)
        // And toward Court Sq, N
        var court = g
        court.direction = .north
        #expect(court.heading == "Euclid Av & Queens - Court Sq")
        #expect(court.stopIDs == ["A42N"])
        #expect(court.shows(train("F", at: "A42N")))
        #expect(!court.shows(train("E", at: "A42S")))
        #expect(!court.shows(train("E", at: "A42N")))
        #expect(court.heading(of: train("F", at: "A42N")) == court.heading)
        // With the A and C, an E on their track goes by theirs and an F on the
        // G's by the G's: toward Manhattan and Church Av, the E N and the F S
        let acg = Selection(stationID: "A42", routes: ["A", "C", "G"], direction: .north)
        #expect(acg.shows(train("E", at: "A42N")))
        #expect(!acg.shows(train("E", at: "A42S")))
        #expect(acg.shows(train("F", at: "A42S")))
        #expect(!acg.shows(train("F", at: "A42N")))
        #expect(acg.heading(of: train("F", at: "A42S")) == "Manhattan - Church Av")
        // And with the A and C alone, an E but not an F, on the G's track
        let ac = Selection(stationID: "A42", routes: ["A", "C"], direction: .north)
        #expect(ac.stopIDs == ["A42N"])
        #expect(ac.shows(train("E", at: "A42N")))
        #expect(!ac.shows(train("F", at: "A42N")))
        #expect(!ac.shows(train("F", at: "A42S")))
    }

    @Test func aZRunningLocalGoesByTheJsWayAndAnFByTheMs() {
        func train(_ route: String, at stop: String) -> Arrival {
            Arrival(route: route, time: now, stop: stop, lastStop: "M23S", isLive: true)
        }
        // Where the Z doesn't stop, with the M alone toward Manhattan, a Z
        // running local is S, as the J is, and an F N, as the M is
        for stop in ["M12", "M13", "M14"] {
            let m = Selection(stationID: stop, routes: ["M"], direction: .north)
            #expect(m.heading == "Manhattan")
            #expect(m.stopIDs == [stop + "N", stop + "S"])
            #expect(m.shows(train("Z", at: stop + "S")))
            #expect(!m.shows(train("Z", at: stop + "N")))
            #expect(m.shows(train("F", at: stop + "N")))
            #expect(!m.shows(train("F", at: stop + "S")))
            #expect(m.heading(of: train("Z", at: stop + "S")) == "Manhattan")
            #expect(m.heading(of: train("F", at: stop + "N")) == "Manhattan")
            // And toward Middle Village, the other way round
            var away = m
            away.direction = .south
            #expect(away.shows(train("Z", at: stop + "N")))
            #expect(!away.shows(train("Z", at: stop + "S")))
            #expect(away.shows(train("F", at: stop + "S")))
            #expect(!away.shows(train("F", at: stop + "N")))
        }
    }

    @Test func anFOnTheMsWayIsFoundByItsOwnLetter() throws {
        // An F rerouted the M's way, over the Chrystie St connection and the
        // bridge, both ways, and an F on its own line at Delancey St-Essex St
        let mFeed = GTFSFeed.feed([
            GTFSFeed.trip("100000_F..N", route: "F", stops: [FeedStop("M16N", at: 2), FeedStop("M18N", at: 5),
                                                             FeedStop("D21N", arrival: 8)]),
            GTFSFeed.trip("100100_F..S", route: "F", stops: [FeedStop("M18S", at: 3), FeedStop("M16S", at: 6),
                                                             FeedStop("M11S", arrival: 12)]),
            GTFSFeed.trip("100200_M..N24R", route: "M", stops: [FeedStop("M16N", at: 4), FeedStop("M18N", at: 7),
                                                                FeedStop("G08N", arrival: 50)]),
            GTFSFeed.trip("100300_F..N", route: "F", stops: [FeedStop("F15N", at: 1), FeedStop("D21N", arrival: 3)]),
        ])
        func trains(for selection: Selection) throws -> [String] {
            let arrivals = try TrainService.arrivals(at: Set(selection.stopIDs), own: [mFeed], others: [], now: now)
            return TrainService.trains(for: selection, in: arrivals, now: now).map(\.trip)
        }
        // Uptown, the N ones: with the M alone at Marcy Av or Delancey St-Essex
        // St, or with the F too, and not the Brooklyn-bound one
        let marcy = Selection(stationID: "M16", routes: ["M"], direction: .north)
        #expect(try trains(for: marcy) == ["100000_F..N", "100200_M..N24R"])
        let delancey = Selection(stationID: "M18", routes: ["M"], direction: .north)
        #expect(try trains(for: delancey) == ["100000_F..N", "100200_M..N24R"])
        let fm = Selection(stationID: "M18", routes: ["F", "M"], direction: .north)
        #expect(fm.stopIDs == ["F15N", "M18N", "M18S"])
        let uptown = try TrainService.arrivals(at: Set(fm.stopIDs), own: [mFeed], others: [], now: now)
        let found = TrainService.trains(for: fm, in: uptown, now: now)
        #expect(found.map(\.trip) == ["100300_F..N", "100000_F..N", "100200_M..N24R"])
        #expect(found.map { fm.heading(of: $0) }
            == ["Uptown & Queens", "Broad St (JZ) - Uptown (M)", "Broad St (JZ) - Uptown (M)"])
        // And toward Brooklyn, the S one
        var brooklyn = delancey
        brooklyn.direction = .south
        #expect(try trains(for: brooklyn) == ["100100_F..S"])
    }

    @Test func otherLinesTrainsAreFoundOnlyOnTheChosenLinesTrack() throws {
        // Where the M runs the other way, it's on the J's track, going on to the
        // J's next stops; the G at Hoyt-Schermerhorn Sts has its own
        let reversed = StationDirectory.platforms.filter { $0.reversed != nil }
        let sharing = Dictionary(uniqueKeysWithValues: reversed.map { ($0.id, $0.sharesTrack) })
        #expect(sharing == ["M11": true, "M12": true, "M13": true, "M14": true, "M16": true, "M18": true, "A42": false])

        // So with the G alone toward Church Av at Hoyt-Schermerhorn Sts, an F
        // rerouted on to its track is found by the G's letter, S, and an E on
        // the A and C's isn't, toward Manhattan, N, or Euclid Av, S
        let gFeed = GTFSFeed.feed([
            GTFSFeed.trip("100000_G..S", route: "G", stops: [FeedStop("A42S", at: 2), FeedStop("F27S", arrival: 12)]),
            GTFSFeed.trip("100100_G..N", route: "G", stops: [FeedStop("A42N", at: 3), FeedStop("G22N", arrival: 30)]),
        ])
        let otherFeeds = [
            GTFSFeed.feed([
                GTFSFeed.trip("100200_F..S", route: "F", stops: [FeedStop("A42S", at: 4), FeedStop("F20S", at: 5),
                                                                 FeedStop("D43S", arrival: 40)]),
                GTFSFeed.trip("100300_F..N", route: "F", stops: [FeedStop("F20N", at: 4), FeedStop("A42N", at: 6),
                                                                 FeedStop("G22N", arrival: 30)]),
            ]),
            GTFSFeed.feed([
                GTFSFeed.trip("100400_E..N", route: "E", stops: [FeedStop("A42N", at: 5), FeedStop("A41N", at: 7),
                                                                 FeedStop("G05N", arrival: 60)]),
                GTFSFeed.trip("100500_E..S", route: "E", stops: [FeedStop("A41S", at: 6), FeedStop("A42S", at: 8),
                                                                 FeedStop("A55S", arrival: 30)]),
            ]),
        ]
        let church = Selection(stationID: "A42", routes: ["G"], direction: .south)
        let arrivals = try TrainService.arrivals(at: Set(church.stopIDs), own: [gFeed], others: otherFeeds, now: now)
        let trains = TrainService.trains(for: church, in: arrivals, now: now)
        #expect(trains.map(\.trip) == ["100000_G..S", "100200_F..S"])
        #expect(trains.allSatisfy { church.heading(of: $0) == "Manhattan - Church Av" })
        // And toward Court Sq, the F going N, but no E
        var court = church
        court.direction = .north
        let courtArrivals = try TrainService.arrivals(at: Set(court.stopIDs), own: [gFeed], others: otherFeeds, now: now)
        let courtTrains = TrainService.trains(for: court, in: courtArrivals, now: now)
        #expect(courtTrains.map(\.trip) == ["100100_G..N", "100300_F..N"])
    }

    @Test func elsewhereAnotherLinesTrainGoesByTheChosenLinesWay() {
        // Where no line runs the other way, every train goes by the way chosen,
        // and other lines' trains are on the chosen lines' side and track
        let routes = Set(StationDirectory.platforms.flatMap(\.routes)).sorted()
        var odd: [String] = []
        for platform in StationDirectory.platforms where platform.reversed == nil {
            if platform.sharesTrack { odd.append(platform.id) }
            for route in routes {
                for way in Direction.allCases where platform.side(of: route, going: way) != way
                    || platform.direction(way, of: route, with: Array(platform.routes.prefix(1))) != way {
                    odd.append("\(route) at \(platform.id)\(way.rawValue)")
                }
            }
        }
        #expect(odd.isEmpty)
    }

    @Test func aTrainOfAnotherLineOnTheMAloneIsFoundOnItsSide() throws {
        // A Z running local at Flushing Av, where it doesn't usually stop, both ways
        let jzFeed = GTFSFeed.feed([
            GTFSFeed.trip("100000_Z..N", route: "Z", stops: [FeedStop("M12N", at: 2), FeedStop("G05N", arrival: 30)]),
            GTFSFeed.trip("100100_Z..S", route: "Z", stops: [FeedStop("M12S", at: 3), FeedStop("M23S", arrival: 20)]),
        ])
        let mFeed = GTFSFeed.feed([
            GTFSFeed.trip("100300_M..N24R", route: "M", stops: [FeedStop("M12N", at: 6), FeedStop("G08N", arrival: 50)]),
            GTFSFeed.trip("100400_M..S24R", route: "M", stops: [FeedStop("M12S", at: 7), FeedStop("M01S", arrival: 25)]),
        ])
        let toManhattan = Selection(stationID: "M12", routes: ["M"], direction: .north)
        #expect(toManhattan.heading == "Manhattan")
        #expect(toManhattan.stopIDs == ["M12N", "M12S"])
        let feeds = TrainService.arrivals(at: Set(toManhattan.stopIDs), in: [jzURL: jzFeed, mURL: mFeed], now: now)
        let trains = TrainService.trains(for: [toManhattan], in: feeds, now: now)[toManhattan.trainID] ?? []
        #expect(trains.map(\.trip) == ["100100_Z..S", "100300_M..N24R"])
        #expect(trains.allSatisfy { toManhattan.heading(of: $0) == "Manhattan" })

        var away = toManhattan
        away.direction = .south
        #expect(away.heading == "Jamaica - Middle Village")
        let awayFeeds = TrainService.arrivals(at: Set(away.stopIDs), in: [jzURL: jzFeed, mURL: mFeed], now: now)
        #expect(TrainService.trains(for: [away], in: awayFeeds, now: now)[away.trainID]?.map(\.trip)
            == ["100000_Z..N", "100400_M..S24R"])
    }

    @Test func theStopsAfterYoursAreEachLinesWhereTheyPart() throws {
        // Toward Manhattan, the J and Z go on to Broad St, and the M on to Forest Hills
        let jzFeed = GTFSFeed.feed([
            GTFSFeed.trip("076950_J..S12R", route: "J", stops: [
                FeedStop("M16S", at: 1), FeedStop("M18S", at: 5), FeedStop("M19S", at: 6), FeedStop("M20S", at: 8),
                FeedStop("M21S", at: 10), FeedStop("M22S", at: 12), FeedStop("M23S", arrival: 14),
            ]),
        ])
        let mFeed = GTFSFeed.feed([
            GTFSFeed.trip("079450_M..N24R", route: "M", stops: [
                FeedStop("M16N", at: 4.5), FeedStop("M18N", at: 8), FeedStop("D21N", at: 11), FeedStop("D20N", at: 13),
                FeedStop("D19N", at: 15), FeedStop("D18N", at: 16), FeedStop("D17N", at: 18), FeedStop("D16N", at: 20),
                FeedStop("G08N", arrival: 50),
            ]),
        ])
        let names = try TrainService.stations(after: jzm, in: [jzFeed, mFeed]).map(\.name)
        // Each line's in its order: where the J parts from the M at Delancey St-Essex St,
        // its stops just after it, then the M's. Delancey St-Essex St once, and never Marcy Av
        #expect(names.prefix(7) == ["Delancey St-Essex St", "Bowery", "Canal St", "Chambers St", "Fulton St", "Broad St",
                                    "Broadway-Lafayette St"])
        #expect(names.last == "Forest Hills-71 Av")
        #expect(names.filter { $0 == "Delancey St-Essex St" }.count == 1)
        #expect(!names.contains("Marcy Av"))
        #expect(names.count == 13)
        // So a change at Fulton St, which the J and Z go on to, can be picked
        #expect(Change(stationID: "M22", routes: ["A", "C"]).validated(for: jzm)?.routes == ["A", "C"])
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
