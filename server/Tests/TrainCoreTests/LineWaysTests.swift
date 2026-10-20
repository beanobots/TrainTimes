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
        // Where the lines part, each line's own way: "Broad St (JZ) - Uptown (M)"
        let delancey = try station("M18")
        #expect(labels(delancey.ways(of: "M", trains: [:], now: now)) == ["Brooklyn", "Uptown"])
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
        // Without trains, both would be Brooklyn, so each goes by the MTA's name
        #expect(labels(classon.ways(of: "G", trains: [:], now: now)) == ["Queens", "Church Av"])

        // The Staten Island Railway stays on Staten Island: where its trains end
        let princesBay = try station("S15")
        let sir = princesBay.ways(of: "SI", trains: [
            key("SI", at: princesBay, going: .north): [train("SI", at: princesBay, going: .north, to: "S31N")],
            key("SI", at: princesBay, going: .south): [train("SI", at: princesBay, going: .south, to: "S09S")],
        ], now: now)
        #expect(labels(sir) == ["St George", "Tottenville"])
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
        let platform = Platform(id: "X01", name: "Nowhere", short: "Nowhere", borough: "Brooklyn", routes: ["G"],
                                north: "", south: "", lat: 0, lon: 0, complex: "X", ada: 0, adaNotes: "", entrances: [])
        let nowhere = Station(platforms: [platform])
        #expect(nowhere.directions(of: ["G"]) == [.north, .south])
        #expect(labels(nowhere.ways(of: "G", trains: [:], now: now)) == ["Northbound", "Southbound"])
        #expect(nowhere.directionLabel(.south, routes: ["G"]) == "Southbound")
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
