import Foundation
import Testing
@testable import TrainCore

/// The ways a line goes from a station, as Trains near you and the app's
/// Nearby list show them (`Station.ways(of:trains:now:)`), and the station
/// helpers they share with the rest of the app.
@Suite struct LineWaysTests {
    func station(_ id: String) throws -> Station {
        try #require(StationDirectory.station(id: id))
    }

    /// The `Selection.trainID` of `route` at `station` going `direction`.
    func key(_ route: String, at station: Station, going direction: Direction) -> String {
        Selection(stationID: station.id, routes: [route], direction: direction).trainID
    }

    /// A `route` train at `station` going `direction`, `minutes` from now, that ends up at `lastStop`: at
    /// the line's platform, or for one running on another line's, the station's first.
    func train(_ route: String, at station: Station, going direction: Direction, in minutes: Double = 3,
               to lastStop: String) -> Arrival {
        let platform = station.platforms(serving: [route]).first ?? station.platforms[0]
        let stop = platform.id + direction.rawValue
        return Arrival(route: route, time: now.addingTimeInterval(minutes * 60), stop: stop, lastStop: lastStop,
                       isLive: true, trip: "\(route)\(direction.rawValue)\(minutes)")
    }

    func labels(_ ways: [LineWay?]) -> [String?] {
        ways.map { $0?.label }
    }

    // MARK: Order and names

    @Test func fromOutsideManhattanTheWayThereComesFirst() throws {
        // The 7 at 74 St-Broadway goes to Manhattan southbound
        let jacksonHeights = try station("710")
        let trains = [
            key("7", at: jacksonHeights, going: .north): [train("7", at: jacksonHeights, going: .north, to: "701N")],
            key("7", at: jacksonHeights, going: .south): [train("7", at: jacksonHeights, going: .south, to: "726S")],
        ]
        let ways = jacksonHeights.ways(of: "7", trains: trains, now: now)
        #expect(ways.map { $0?.direction } == [.south, .north])
        #expect(labels(ways) == ["Manhattan", "Queens"])
        // Before any trains come, the same
        #expect(labels(jacksonHeights.ways(of: "7", trains: [:], now: now)) == ["Manhattan", "Queens"])

        // The R at Prospect Av goes there northbound
        let prospectAv = try station("R34")
        let r = prospectAv.ways(of: "R", trains: [
            key("R", at: prospectAv, going: .south): [train("R", at: prospectAv, going: .south, to: "R45S")],
        ], now: now)
        #expect(r.map { $0?.direction } == [.north, .south])
        #expect(labels(r) == ["Manhattan", "Brooklyn"])
    }

    @Test func inManhattanUptownComesFirst() throws {
        // "Uptown & Queens" and "Downtown & Brooklyn"
        let unionSquare = try station("R20")
        let ways = unionSquare.ways(of: "R", trains: [:], now: now)
        #expect(ways.map { $0?.direction } == [.north, .south])
        #expect(labels(ways) == ["Uptown", "Downtown"])
        // Where the lines part, each line's own way: "Broad St (JZ) - Uptown (M)",
        // which is the M's north, as it runs the other way to the J there
        let delancey = try station("M18")
        #expect(labels(delancey.ways(of: "M", trains: [:], now: now)) == ["Uptown", "Brooklyn"])
        #expect(labels(delancey.ways(of: "J", trains: [:], now: now)) == ["Brooklyn", "Broad St"])
    }

    @Test func aLineThatMissesManhattanGoesByWhereItsTrainsEndUp() throws {
        // The G from Classon Av: Queens one way, Brooklyn the other
        let classon = try station("G34")
        let ways = classon.ways(of: "G", trains: [
            key("G", at: classon, going: .north): [train("G", at: classon, going: .north, to: "G22N")],
            key("G", at: classon, going: .south): [train("G", at: classon, going: .south, to: "F27S")],
        ], now: now)
        #expect(ways.map { $0?.direction } == [.north, .south])
        #expect(labels(ways) == ["Queens", "Brooklyn"])
        // Without trains, the same: where the line ends each way
        #expect(labels(classon.ways(of: "G", trains: [:], now: now)) == ["Queens", "Brooklyn"])

        // The Staten Island Railway stays on Staten Island: where its trains end
        let princesBay = try station("S15")
        let sir = princesBay.ways(of: "SI", trains: [
            key("SI", at: princesBay, going: .north): [train("SI", at: princesBay, going: .north, to: "S31N")],
            key("SI", at: princesBay, going: .south): [train("SI", at: princesBay, going: .south, to: "S09S")],
        ], now: now)
        #expect(labels(sir) == ["St George", "Tottenville"])
    }

    @Test func withNoTrainsToGoByAWayIsNamedForWhereTheLineEnds() throws {
        // The G's one way from Court Sq goes to Brooklyn, though the station's in Queens
        let courtSq = try station("G22")
        #expect(labels(courtSq.ways(of: "G", trains: [:], now: now)) == [nil, "Brooklyn"])
        #expect(labels(try station("F27").ways(of: "G", trains: [:], now: now)) == ["Queens", nil])
        // Not the MTA's names at Hoyt-Schermerhorn Sts, which are for the A and C there too
        #expect(labels(try station("A42").ways(of: "G", trains: [:], now: now)) == ["Queens", "Brooklyn"])
        // The J from Flushing Av with none just now toward Jamaica, and the Z, which runs only in rush hours
        let flushing = try station("M12")
        let j = flushing.ways(of: "J", trains: [
            key("J", at: flushing, going: .north): [],
            key("J", at: flushing, going: .south): [train("J", at: flushing, going: .south, to: "M23S")],
        ], now: now)
        #expect(labels(j) == ["Manhattan", "Queens"])
        #expect(labels(try station("J24").ways(of: "Z", trains: [:], now: now)) == ["Manhattan", "Queens"])
    }

    @Test func aLinesOneWayFromWhereItEndsGoesByWhereItsTrainsEndUp() throws {
        // A line that stays in one borough, from either end
        let stGeorge = try station("S31")
        #expect(labels(stGeorge.ways(of: "SI", trains: [:], now: now)) == [nil, "Tottenville"])
        let sir = stGeorge.ways(of: "SI", trains: [
            key("SI", at: stGeorge, going: .south): [train("SI", at: stGeorge, going: .south, to: "S09S")],
        ], now: now)
        #expect(labels(sir) == [nil, "Tottenville"])
        #expect(labels(try station("S09").ways(of: "SI", trains: [:], now: now)) == ["St George", nil])
        #expect(labels(try station("S01").ways(of: "FS", trains: [:], now: now)) == [nil, "Prospect Park"])
        #expect(labels(try station("D26").ways(of: "FS", trains: [:], now: now)) == ["Franklin Av", nil])
        #expect(labels(try station("H15").ways(of: "H", trains: [:], now: now)) == ["Broad Channel", nil])
        // One that leaves the borough goes by the borough it's headed for
        #expect(labels(try station("G22").ways(of: "G", trains: [:], now: now)) == [nil, "Brooklyn"])
    }

    @Test func theRockawayParkShuttleEndsAtBroadChannel() throws {
        // On its own track there, which the feeds call H19 and the station list doesn't have
        let broadChannel = try station("H04")
        #expect(StationDirectory.station(forStop: "H19N")?.id == broadChannel.id)
        let ending = train("H", at: broadChannel, going: .north, to: "H19N")
        #expect(ending.endsHere)
        #expect(ending.terminal == "Broad Channel")
        #expect(Arrival.Stop(id: "H19S", time: now).name == "Broad Channel")
        // So it doesn't leave from there, and the way it ends isn't one
        let north = Selection(stationID: "H04", routes: ["H"], direction: .north)
        #expect(TrainService.trains(for: north, in: [ending], now: now).isEmpty)
        let ways = broadChannel.ways(of: "H", trains: [
            key("H", at: broadChannel, going: .north): [],
            key("H", at: broadChannel, going: .south): [train("H", at: broadChannel, going: .south, to: "H15S")],
        ], now: now)
        #expect(labels(ways) == [nil, "Rockaway Park"])
        // Coming from Rockaway Park, it goes to Broad Channel, not Manhattan
        let beach90 = try station("H12")
        let up = beach90.ways(of: "H", trains: [
            key("H", at: beach90, going: .north): [train("H", at: beach90, going: .north, to: "H19N")],
            key("H", at: beach90, going: .south): [train("H", at: beach90, going: .south, to: "H15S")],
        ], now: now)
        #expect(labels(up) == ["Broad Channel", "Rockaway Park"])
        #expect(labels(beach90.ways(of: "H", trains: [:], now: now)) == ["Broad Channel", "Rockaway Park"])
        // Another of its stops, or another way, isn't where it ends
        #expect(!train("H", at: broadChannel, going: .south, to: "H15S").endsHere)
        #expect(!Arrival(route: "H", time: now, stop: "H04S", lastStop: "H19N", isLive: true).endsHere)
        #expect(!Arrival(route: "R", time: now, stop: "R31N", lastStop: "D24N", isLive: true).endsHere)
    }

    @Test func aLineRunningTheOtherWayToTheStationsNamesGoesByItsOwn() throws {
        // At Marcy Av the MTA names the ways for the J: an M going S is on its way to Middle Village,
        // its part of the J and M's "Jamaica - Middle Village"
        let marcy = try station("M16")
        #expect(marcy.directionLabel(.south, routes: ["J"]) == "Manhattan")
        #expect(marcy.directionLabel(.south, routes: ["M"]) == "Middle Village")
        #expect(marcy.directionLabel(.north, routes: ["M"]) == "Manhattan")
        // With the J, the M goes the way it's named, which for the M is N
        #expect(marcy.directionLabel(.south, routes: ["J", "M"]) == "Manhattan")
        let m = marcy.ways(of: "M", trains: [:], now: now)
        #expect(m.map { $0?.direction } == [.north, .south])
        #expect(labels(m) == ["Manhattan", "Queens"])
        let j = marcy.ways(of: "J", trains: [:], now: now)
        #expect(j.map { $0?.direction } == [.south, .north])
        #expect(labels(j) == ["Manhattan", "Queens"])
        // Each train goes by its own line's
        let both = Selection(stationID: "M16", routes: ["J", "M"], direction: .south)
        #expect(both.heading(of: Arrival(route: "M", time: now, stop: "M16N", lastStop: "G08N", isLive: true))
            == "Manhattan")
        #expect(both.heading(of: Arrival(route: "M", time: now, stop: "M16S", lastStop: "M01S", isLive: true))
            == "Middle Village")
        #expect(both.heading(of: Arrival(route: "J", time: now, stop: "M16S", lastStop: "M23S", isLive: true))
            == "Manhattan")

        // At Hoyt-Schermerhorn Sts they're for the A and C: the G toward Church Av is S. Each line
        // gets its own part of "Manhattan - Church Av" and "Euclid Av & Queens - Court Sq"
        let hoyt = try station("A42")
        #expect(hoyt.directionLabel(.south, routes: ["G"]) == "Church Av")
        #expect(hoyt.directionLabel(.north, routes: ["G"]) == "Court Sq")
        #expect(hoyt.directionLabel(.north, routes: ["A"]) == "Manhattan")
        #expect(hoyt.directionLabel(.north, routes: ["A", "C", "G"]) == "Manhattan - Church Av")

        // Every such line, from the schedule: the M along the Broadway el and the G at Hoyt-Schermerhorn Sts
        let reversed = StationDirectory.platforms.flatMap { platform in
            (platform.reversed ?? []).map { "\($0) at \(platform.id)" }
        }
        #expect(Set(reversed) == ["M at M11", "M at M12", "M at M13", "M at M14", "M at M16", "M at M18", "G at A42"])
    }

    @Test func aWayTheMTADoesntNameIsLeftOut() throws {
        // The 7 starts at Flushing-Main St, going to Manhattan only
        let flushing = try station("701")
        let seven = flushing.ways(of: "7", trains: [:], now: now)
        #expect(seven.map { $0?.direction } == [.south, nil])
        #expect(labels(seven) == ["Manhattan", nil])
        // The G starts at Court Sq; its one way keeps its place, second
        let courtSq = try station("G22")
        let g = courtSq.ways(of: "G", trains: [
            key("G", at: courtSq, going: .south): [train("G", at: courtSq, going: .south, to: "F27S")],
        ], now: now)
        #expect(g.map { $0?.direction } == [nil, .south])
        #expect(labels(g) == [nil, "Brooklyn"])
    }

    @Test func whereTheMTANamesNeitherWayBothAreNamedByTheCompass() {
        // A line lines.json has no ends for, either
        let platform = Platform(id: "X01", name: "Nowhere", short: "Nowhere", borough: "Brooklyn", routes: ["X"],
                                north: "", south: "", lat: 0, lon: 0, complex: "X", ada: 0, adaNotes: "", entrances: [])
        let nowhere = Station(platforms: [platform])
        #expect(nowhere.directions(of: ["X"]) == [.north, .south])
        #expect(labels(nowhere.ways(of: "X", trains: [:], now: now)) == ["Northbound", "Southbound"])
        #expect(nowhere.directionLabel(.south, routes: ["X"]) == "Southbound")
    }

    // MARK: Trains

    @Test func eachWayHasItsLinesOwnTrainsStillToLeave() throws {
        let prospectAv = try station("R34")
        let gone = train("R", at: prospectAv, going: .north, in: -1, to: "G08N")
        let next = train("R", at: prospectAv, going: .north, in: 4, to: "G08N")
        let rerouted = train("N", at: prospectAv, going: .north, in: 2, to: "R01N")
        let ways = prospectAv.ways(of: "R", trains: [key("R", at: prospectAv, going: .north): [gone, rerouted, next]],
                                   now: now)
        #expect(ways[0]?.trains == [next])
        #expect(ways[0]?.selection == Selection(stationID: "R34", routes: ["R"], direction: .north))
        // None fetched for the other way: not known, which isn't none
        #expect(ways[1]?.trains == nil)
        #expect(ways[1]?.selection.trainID == key("R", at: prospectAv, going: .south))
    }

    @Test func everyLineBothWays() throws {
        let atlantic = try station("R31")
        let selections = atlantic.lineSelections
        #expect(selections.count == atlantic.routes.count * 2)
        #expect(Array(selections.prefix(2)) == [
            Selection(stationID: atlantic.id, routes: [atlantic.routes[0]], direction: .north),
            Selection(stationID: atlantic.id, routes: [atlantic.routes[0]], direction: .south),
        ])
        #expect(Set(selections.flatMap(\.routes)) == Set(atlantic.routes))
    }

    // MARK: Station helpers

    @Test func theWaysTheMTANamesForALine() throws {
        #expect(try station("G22").directions(of: ["G"]) == [.south])
        #expect(try station("R34").directions(of: ["R"]) == [.north, .south])
        // The C ends at 168 St, but the A goes on, so the way is named
        #expect(try station("A09").directions(of: ["C"]) == [.north, .south])
    }

    @Test func theWaysALineGoesOnFrom() throws {
        // As the train picker offers them: not where the line ends, though others go on
        #expect(try station("A09").onwardDirections(of: ["C"]) == [.south])
        #expect(try station("A09").onwardDirections(of: ["A", "C"]) == [.north, .south])
        let forestHills = try station("G08")
        #expect(forestHills.onwardDirections(of: ["R"]) == [.south])
        #expect(forestHills.onwardDirections(of: ["M", "R"]) == [.south])
        #expect(forestHills.onwardDirections(of: ["E", "R"]) == [.north, .south])
        #expect(try station("H04").onwardDirections(of: ["H"]) == [.south])
        #expect(try station("250").onwardDirections(of: ["4"]) == [.north])
        #expect(try station("640").onwardDirections(of: ["6"]) == [.north])
        // A way the MTA doesn't name was never one
        #expect(try station("G22").onwardDirections(of: ["G"]) == [.south])
        // Where every way ends, as on a made-up line, both
        let platform = Platform(id: "X01", name: "Nowhere", short: "Nowhere", borough: "Brooklyn", routes: ["X"],
                                north: "", south: "", lat: 0, lon: 0, complex: "X", ada: 0, adaNotes: "", entrances: [])
        #expect(Station(platforms: [platform]).onwardDirections(of: ["X"]) == [.north, .south])

        // Only these: one line at its end by day where another goes on, by its platform
        let ends = StationDirectory.all.flatMap { station in
            station.routes.flatMap { route in
                station.directions(of: [route]).filter { !station.onwardDirections(of: [route]).contains($0) }
                    .map { "\(route) \($0.rawValue) at \(station.platforms(serving: [route])[0].id)" }
            }
        }
        #expect(Set(ends) == [
            "C N at A09", "B N at D03", "B S at D40", "6 S at 640", "G S at F27", "4 S at 250",
            "C S at A55", "M N at G08", "R N at G08", "FS S at D26", "W S at R27",
        ])
    }

    @Test func aLineThatNeverGetsToManhattanIsntHeadedThere() throws {
        // The Rockaway Park Shuttle's north from Beach 90 St, which the MTA names for the A, goes to Broad Channel
        for id in ["H12", "H13", "H14", "H15"] {
            let h = Selection(stationID: id, routes: ["H"], direction: .north)
            #expect(h.heading == "Broad Channel")
            #expect(h.caption == "Rockaway Park Shuttle Broad Channel")
        }
        #expect(Selection(stationID: "H12", routes: ["A", "H"], direction: .north).heading == "Manhattan or Broad Channel")
        // and from Broad Channel, where it ends, it goes nowhere north
        let broadChannel = try station("H04")
        #expect(broadChannel.directions(of: ["H"]) == [.south])
        #expect(broadChannel.directions(of: ["A", "H"]) == [.north, .south])
        #expect(Selection(stationID: "H04", routes: ["H"], direction: .north).heading == "Northbound")
        #expect(Selection(stationID: "H04", routes: ["A"], direction: .north).heading == "Manhattan")
        // The G's north from Church Av, which the MTA names for the F, goes to Court Sq
        let g = Selection(stationID: "F27", routes: ["G"], direction: .north)
        #expect(g.heading == "Court Sq")
        #expect(g.caption == "G Court Sq")
        #expect(Selection(stationID: "F27", routes: ["F"], direction: .north).heading == "Manhattan")
        // A name for several lines keeps only the parts this line goes to
        #expect(Selection(stationID: "F20", routes: ["G"], direction: .north).heading == "Queens")
        #expect(Selection(stationID: "F20", routes: ["G"], direction: .south).heading == "Church Av")
        #expect(Selection(stationID: "F20", routes: ["F"], direction: .north).heading == "Manhattan - Queens")
        #expect(Selection(stationID: "F20", routes: ["F"], direction: .south).heading == "Church Av - Coney Island")
        // Together, the F's name covers the G's
        #expect(Selection(stationID: "F20", routes: ["F", "G"], direction: .north).heading == "Manhattan - Queens")
        #expect(Selection(stationID: "R36", routes: ["R"], direction: .south).heading == "Bay Ridge")
        #expect(Selection(stationID: "R36", routes: ["D"], direction: .south).heading == "Coney Island")
        #expect(Selection(stationID: "A28", routes: ["C"], direction: .north).heading == "Uptown")
        #expect(Selection(stationID: "A28", routes: ["E"], direction: .north).heading == "Uptown - Queens")
        // A part joined by "&" stays only if the line goes to all of it
        #expect(Selection(stationID: "D17", routes: ["B"], direction: .north).heading == "Uptown & The Bronx")
        #expect(Selection(stationID: "D17", routes: ["F"], direction: .north).heading == "Queens")
        // Parts that together name one stop stay together
        #expect(Selection(stationID: "723", routes: ["7"], direction: .south).heading == "34 St - Hudson Yards")
        #expect(Selection(stationID: "R04", routes: ["N"], direction: .north).heading == "Astoria - Ditmars Blvd")
        #expect(Selection(stationID: "L08", routes: ["L"], direction: .south).heading == "Canarsie - Rockaway Parkway")
        // A place inside a stop's name, an area's plural, and another spelling of a stop
        #expect(Selection(stationID: "423", routes: ["4"], direction: .south).heading == "Utica")
        #expect(Selection(stationID: "A40", routes: ["A"], direction: .south).heading == "Euclid - Lefferts - Rockaways")
        #expect(Selection(stationID: "A40", routes: ["C"], direction: .south).heading == "Euclid")
        #expect(Selection(stationID: "416", routes: ["5"], direction: .north).heading == "Eastchester Dyre Av")
        #expect(Selection(stationID: "416", routes: ["4"], direction: .north).heading == "Woodlawn")
        // A borough with any of the line's stops that way, though both its ends are in it
        #expect(Selection(stationID: "B08", routes: ["M"], direction: .north).heading == "Uptown - Queens")
        #expect(Selection(stationID: "B08", routes: ["Q"], direction: .north).heading == "Uptown")
        // Of an "&" part, the places the line goes to, when no other part is wholly its
        #expect(Selection(stationID: "A42", routes: ["C"], direction: .south).heading == "Euclid Av")
        // With no part the line's, its end that way
        #expect(Selection(stationID: "235", routes: ["4"], direction: .south).heading == "Crown Hts")
        #expect(Selection(stationID: "R30", routes: ["B"], direction: .south).heading == "Brighton Beach")
        // Names that say where the line goes, without " - ", stay as the MTA has them
        #expect(Selection(stationID: "D26", routes: ["FS"], direction: .north).heading == "Manhattan & Franklin Av")

        // Changing to the G there from an F toward Manhattan, it's not your way
        let f = Selection(stationID: "F29", routes: ["F"], direction: .north)
        let toG = Change(stationID: "F27", routes: ["G"])
        #expect(toG.suggestedDirection(for: f) == .north)
        #expect(toG.heading(for: f) == "Court Sq")
        #expect(!toG.goesYourWay(from: f))
        // From the shuttle to the A at Broad Channel, Manhattan is still the way it came from Rockaway Park
        let h = Selection(stationID: "H12", routes: ["H"], direction: .north)
        let toA = Change(stationID: "H04", routes: ["A"])
        #expect(toA.suggestedDirection(for: h) == .north)
        #expect(toA.heading(for: h) == "Manhattan")
    }

    @Test func aStopsStation() throws {
        let atlantic = try station("R31")
        #expect(StationDirectory.station(forStop: "R31N")?.id == atlantic.id)
        #expect(StationDirectory.station(forStop: "235S")?.id == atlantic.id)
        // A platform's own id too
        #expect(StationDirectory.station(forStop: "R34")?.id == "R34")
        #expect(StationDirectory.station(forStop: "XYZN") == nil)
    }

    @Test func theCompassNamesWhereTheMTAGivesNone() {
        #expect(Direction.north.compassName == "Northbound")
        #expect(Direction.south.compassName == "Southbound")
        #expect(Station.directionLabel(.north, on: []) == "Northbound")
    }

    @Test func aTrainsTerminalIsItsLastStopsShortName() {
        #expect(arrival(2, trip: "a", lastStop: "G08N").terminal == "Forest Hills")
        #expect(arrival(2, trip: "a", lastStop: "R45N").terminal == StationDirectory.shortName(forStop: "R45N"))
    }
}
