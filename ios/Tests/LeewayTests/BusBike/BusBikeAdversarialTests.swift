import CoreLocation
import Foundation
import Testing
@testable import Leeway

// Buses, Citi Bike and Nearby given bad data, bad places and no network.

/// Counts the requests a `withNetwork` answer has seen, to answer the first differently.
private final class Asks: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// A place in the Atlantic, a little apart for each test: Bus Time's answers are kept by URL.
private func sea(_ index: Int) -> BusRide.Place {
    BusRide.Place(name: "Sea \(index)", latitude: 40.45 + Double(index) * 0.0007, longitude: -73.70)
}

/// Runs `body`, then puts back the App Group's saved Citi Bike dock places, which a load of
/// Citi Bike's feed here would otherwise leave as the test's few docks for a day.
private func keepingDockPlaces<T>(_ body: () async throws -> T) async rethrows -> T {
    let file = SharedStore.url(named: "Library/Caches/citibike-docks.json")
    let saved = file.flatMap { try? Data(contentsOf: $0) }
    defer {
        if let file {
            if let saved { try? saved.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
        }
    }
    return try await body()
}

// MARK: - Bus Time answers

struct BusTimesAdversarialTests {
    let now = Fixtures.date("2026-11-10 08:15")
    let stop = BusStop(id: "999001", name: "NOWHERE/NOWHERE", latitude: 40.45, longitude: -73.70)

    /// An empty 200, a 500 and JSON missing its fields all come to nothing (and no stop at sea by the timetable).
    @Test(arguments: [TestNetwork.Answer.ok(Data()), .status(500), .ok(Data(#"{"stop":{}}"#.utf8)),
                      .ok(Data(#"{"stop":{"id":"1","name":"A","latitude":40,"longitude":-73},"arrivals":"soon"}"#.utf8))])
    func badAnswersGiveNothing(answer: TestNetwork.Answer) async {
        // Failures aren't kept, so the same place for each
        let place = sea(6)
        let now = now
        let (times, made) = await withNetwork({ _ in answer }) {
            await BusTimes.arrivals(line: "B63", at: place, now: now)
        }
        #expect(times == nil)
        #expect(made.count == 1)
    }

    /// No signal: nothing, rather than a hang or a crash.
    @Test func offlineGivesNothing() async {
        let place = sea(1)
        let now = now
        let (times, _) = await withNetwork { await BusTimes.arrivals(line: "B63", at: place, now: now) }
        #expect(times == nil)
    }

    /// Five thousand buses, duplicates and buses with no time: gone and timeless ones dropped, the rest in order.
    @Test func hugeAndDuplicateBuses() async throws {
        let now = now
        var arrivals = (0..<5_000).map { testBus("B63", Double($0 % 120) - 10, after: now) }
        arrivals += [BusArrival(line: "B63"), BusArrival(line: "B63"), testBus("B63", 5, after: now), testBus("B63", 5, after: now)]
        let data = try JSONEncoder().encode(BusStopTimes(stop: stop, arrivals: arrivals))
        let place = sea(2)
        let (times, _) = await withNetwork({ _ in .ok(data) }) {
            await BusTimes.arrivals(line: "B63", at: place, now: now)
        }
        let kept = try #require(times?.arrivals)
        #expect(kept.allSatisfy { ($0.time ?? .distantPast) > now })
        // Each minute's bus once, however many times it was listed
        #expect(kept.count == 109)
        #expect(zip(kept, kept.dropFirst()).allSatisfy { $0.time! <= $1.time! })
        // Each line still once on Nearby's grid
        let picks = NearbyBusPick.lines(at: [(stop, kept)], date: now)
        #expect(picks.map(\.line) == ["B63"] && picks[0].ways[0].arrivals.count == 3)
    }

    /// Asked for one stop's lines, answers from another stop (an unknown code) are left out.
    @Test func unknownStopLeftOut() async throws {
        let data = try JSONEncoder().encode(BusStopTimes(stop: stop, arrivals: [testBus("B63", 4, after: now)]))
        let place = sea(3)
        let now = now
        let (times, _) = await withNetwork({ _ in .ok(data) }) {
            await BusTimes.arrivals(lines: ["B63"], at: place, onlyAt: "not-a-stop", now: now)
        }
        #expect(times == nil)
        #expect(await BusTimes.arrivals(lines: [], at: place, now: now) == nil)
    }

    /// A failure isn't kept: asked again, it's asked of the server again.
    @Test func failureNotKept() async throws {
        let data = try JSONEncoder().encode(BusStopTimes(stop: stop, arrivals: [testBus("B63", 4, after: now)]))
        let asks = Asks()
        let place = sea(4)
        let now = now
        let ((first, second), made) = await withNetwork({ _ in asks.next() == 1 ? nil : .ok(data) }) {
            (await BusTimes.arrivals(line: "B63", at: place, now: now), await BusTimes.arrivals(line: "B63", at: place, now: now))
        }
        #expect(first == nil && second?.arrivals.count == 1)
        #expect(made.count == 2)
    }

    /// The same stop and line asked twice at once is asked of the server once.
    @Test func sameAskSharedOnce() async throws {
        let data = try JSONEncoder().encode(BusStopTimes(stop: stop, arrivals: [testBus("B63", 4, after: now)]))
        let place = sea(5)
        let now = now
        let (both, made) = await withNetwork({ _ in .ok(data, delay: .milliseconds(300)) }) {
            async let a = BusTimes.arrivals(line: "B63", at: place, now: now)
            async let b = BusTimes.arrivals(line: "B63", at: place, now: now)
            return await (a, b)
        }
        #expect(both.0 == both.1 && both.0 != nil)
        #expect(made.count == 1)
    }

    /// Nearby's buses: no stops, or places with none, are no places; a refusal is none either way.
    @Test func nearbyEmptyAndRefused() async {
        let empty = Data(#"{"ways":[],"places":[[],[]]}"#.utf8)
        let (none, _) = await withNetwork({ _ in .ok(empty) }) {
            await NearbyBuses.places(near: BusBikePlaces.atlantic)
        }
        #expect(none == [])
        let (refused, _) = await withNetwork({ _ in .status(404) }) {
            await NearbyBuses.places(near: BusBikePlaces.atlantic)
        }
        #expect((refused ?? []).isEmpty)
        let old = Data(#"{"ways":[]}"#.utf8)
        let (older, _) = await withNetwork({ _ in .ok(old) }) { await NearbyBuses.places(near: BusBikePlaces.albany) }
        #expect(older == [])
    }
}

// MARK: - Bus data off the edges

struct BusDataAdversarialTests {
    let now = Fixtures.date("2026-11-10 08:15")

    /// Unknown lines and stop codes have nothing ahead; no walk, or the sea, no buses near.
    @Test func unknownLinesAndStops() {
        #expect(BusRoutes.ahead(on: "B63", from: "no-such-stop", toward: nil).isEmpty)
        #expect(BusRoutes.ahead(on: "ZZ999", from: "306619", toward: "PIER").isEmpty)
        #expect(BusRoutes.ways(of: "").isEmpty)
        #expect(BusRoutes.nearby(BusBikePlaces.parkSlopeNorth, walkMinutes: 0).isEmpty)
        #expect(BusRoutes.nearby(BusBikePlaces.atlantic, walkMinutes: 30).isEmpty)
        #expect(BusRoutes.nearby(BusBikePlaces.albany, walkMinutes: 30).isEmpty)
        #expect(BusNetwork.stopByID["no-such-stop"] == nil)
    }

    /// No bus lines drawn at sea, nor a side for a stop there.
    @Test func noLinesAtSea() {
        #expect(NearbyLines.busLines(near: BusBikePlaces.atlantic.coordinate, within: 400).isEmpty)
        #expect(NearbyLines.nearestStopsLines(near: BusBikePlaces.atlantic).isEmpty)
        #expect(BusSides.none.way(at: BusBikePlaces.parkSlopeNorth.coordinate, lines: ["B63"]) == nil)
        let sides = BusSides(ways: BusNetwork.ways(of: ["B63"]))
        #expect(sides.way(at: BusBikePlaces.atlantic.coordinate, lines: ["B63"]) == nil)
    }

    /// No path for a line that isn't, nor from a place to itself.
    @Test func noPaths() {
        let here = BusBikePlaces.parkSlopeNorth.coordinate
        #expect(BusNetwork.path(of: "ZZ999", from: here, to: BusBikePlaces.parkSlopeSouth.coordinate) == nil)
        #expect(BusNetwork.path(of: "B63", from: here, to: here) == nil)
        #expect(BusNetwork.ways(of: []).isEmpty)
    }

    /// Odd names: a bare mark or nothing stays as it is.
    @Test func oddNames() {
        #expect(BusNames.label("+") == "+")
        #expect(BusNames.label("SBS") == "SBS")
        #expect(BusNames.label("") == "")
        #expect(BusNames.readable("") == "")
        #expect(!BusNames.isSBS(""))
        #expect(BusRoutes.key("") == "")
        #expect(BusNames.destination("SELECT BUS SERVICE") == "Select Bus Service")
    }

    /// Garbage for an intent's parameter, or a way that isn't, is nothing.
    @Test func badPicks() {
        #expect(NearbyBusPick(encoded: "garbage") == nil)
        #expect(NearbyBusPlace(encoded: "") == nil)
        let pick = NearbyBusPick(line: "B63", ways: [])
        #expect(pick.shown(way: 0, both: true) == nil && pick.shown(way: -1, both: false) == nil)
        #expect(NearbyBusPlace(ways: [], meters: 0).name == "")
    }

    /// Buses all gone, or with no time at all, make no lines.
    @Test func noLinesFromGoneBuses() {
        let stop = BusStop(id: "1", name: "A", latitude: 40.7, longitude: -73.9)
        let gone = [testBus("B63", -1, after: now), testBus("B63", 0, after: now), BusArrival(line: "B67")]
        #expect(NearbyBusPick.lines(at: [(stop, gone)], date: now).isEmpty)
        #expect(NearbyBusPick.lines(at: [], date: now).isEmpty)
    }

    /// The home stop picker with nothing due, a way that isn't, or no lines.
    @Test func homeStopPickerEdges() {
        let stop = BusStop(id: "1", name: "5 AV/9 ST", latitude: 40.7, longitude: -73.9)
        let place = NearbyBusPlace(ways: [.init(stop: stop, destination: nil, arrivals: [])], meters: 50)
        #expect(place.detail(place.ways[0], index: 0, lines: ["B63"], now: now) == "This side")
        #expect(place.going(place.ways[0], lines: ["B63"]) == "5 Av & 9 St")
        #expect(place.ways(for: ["B63"]).count == 1)
        #expect(place.choice(lines: ["B63"], way: 3, of: place.ways, both: true) == nil)
        #expect(place.choice(lines: [], way: 0, of: place.ways, both: false) == nil)
        let alone = place.choice(lines: ["B63"], way: 0, of: place.ways, both: true)
        #expect(alone?.bothWays == false && alone?.otherStop == nil)
    }

    /// A bus that's left before you're at the stop counts the 5-minute wait, in time and ranking.
    @Test func busAlreadyGone() throws {
        let place = BusRide.Place(name: "A", latitude: 40.669453, longitude: -73.986015)
        var ride = BusRide(line: "B63", from: place, to: place, seconds: 300)
        ride.leaves = now.addingTimeInterval(-60)
        let trip = BusTrip(bus: ride, busFirst: true)
        #expect(try #require(trip.arrival(from: place.location, to: place.location, at: now, timetable: nil))
            == now.addingTimeInterval(BusTrip.wait + 300))
        #expect(abs(trip.penalty(from: place.location, to: place.location, at: now, timetable: nil) - BusTrip.wait) < 0.001)
    }

    /// A bus with a train but no timetable to time it isn't timed.
    @Test func busAndTrainWithoutTimetable() {
        let place = BusRide.Place(name: "A", latitude: 40.669453, longitude: -73.986015)
        let train = SharedTrip.Option(selection: Selection(stationID: "R31", routes: ["R"], direction: .north),
                                      change: nil, destinationID: "R20")
        let trip = BusTrip(bus: BusRide(line: "B63", from: place, to: place), train: train, busFirst: true)
        #expect(trip.arrival(from: place.location, to: place.location, at: now, timetable: nil) == nil)
        #expect(trip.minutes(from: place.location, to: place.location, at: now, timetable: nil) == nil)
    }

    /// Train to bus with no bus catchable (gone, timeless, or none): no bus way, and no bus as the connection.
    @Test func noCatchableBus() {
        let stop = BusStop(id: "1", name: "A", latitude: 40.7, longitude: -73.9)
        let leg = BusLeg(line: "B63", stop: stop, walkMinutes: 5)
        let arrival = Arrival(route: "R", time: now.addingTimeInterval(600), stop: "R31N", lastStop: "R01N", isLive: true)
        let connection = Connection(first: arrival, arrival: arrival, next: nil)
        let buses = [testBus("B63", 12, after: now), BusArrival(line: "B63")]
        let changed = TrainService.addingBuses([(leg: leg, arrivals: buses), (leg: leg, arrivals: [])], to: connection)
        #expect(changed.next == nil)
        #expect(changed.ways?.isEmpty ?? true)
    }

    /// Bus to train with fewer train lists than changes, none catchable, or no changes at all.
    @Test func busToTrainEdges() {
        let stop = BusStop(id: "1", name: "A", latitude: 40.7, longitude: -73.9)
        let change = BusChange(stop: stop, minutes: 5, walkMinutes: 2,
                               selection: Selection(stationID: "R31", routes: ["R"], direction: .north))
        let choice = BusChoice(line: "B63", stop: stop, changes: [change, change])
        let bus = [testBus("B63", 3, after: now)]
        let early = Arrival(route: "R", time: now.addingTimeInterval(60), stop: "R31N", lastStop: "R01N", isLive: true)
        let connections = choice.connections(buses: bus, trains: [[early]], at: now)
        #expect(connections.count == 1 && connections[0].next == nil && connections[0].ways == [])
        #expect(choice.connections(buses: bus, trains: [], at: now).first?.next == nil)
        let plain = BusChoice(line: "B63", stop: stop)
        #expect(plain.connections(buses: bus, trains: [[early]], at: now).isEmpty && plain.trainChange == nil)
    }
}

// MARK: - The bus timetable, bad

@Suite(.serialized) struct BusScheduleAdversarialTests {
    let morning = Fixtures.date("2026-11-10 08:15")

    /// At sea, or for a line the timetable hasn't, no buses.
    @Test func noStopNoLine() async throws {
        let (atSea, noLine, places) = try await withBusTimetable(ParkSlopeTimetable.timetable) {
            (BusSchedule.times(line: "B63", at: sea(9), now: morning),
             BusSchedule.times(line: "ZZ9", at: BusBikePlaces.place("A", BusBikePlaces.parkSlopeNorth), now: morning),
             BusSchedule.places(near: BusBikePlaces.atlantic, now: morning))
        }
        #expect(atSea == nil && noLine == nil && places == [])
    }

    /// A timetable whose places don't match its stops is read as having none: no buses, no crash.
    @Test func placesMismatched() async throws {
        let base = ParkSlopeTimetable.base
        let timetable = Timetable(
            made: base, base: base, stops: ["S1", "S2"], routes: ["B63\tPIER 6"],
            patterns: [.init(route: 0, calls: [.init(stop: 0, arrives: 0, waits: 0), .init(stop: 1, arrives: 60, waits: 0)])],
            starts: [[15_000]], places: [.init(latitude: 40.669453, longitude: -73.986015, name: "5 AV/9 ST")])
        let here = BusBikePlaces.place("A", BusBikePlaces.parkSlopeNorth)
        let (times, places) = try await withBusTimetable(timetable) {
            (BusSchedule.times(line: "B63", at: here, now: morning), BusSchedule.places(near: BusBikePlaces.parkSlopeNorth, now: morning))
        }
        #expect(times == nil && places == nil)
    }
}

// MARK: - Citi Bike feeds

struct CitiBikeAdversarialTests {
    /// The push server's docks with negative counts never offer bikes or docks below none.
    @Test func negativeCountsFromServer() async throws {
        let body = #"{"docks":[{"id":"n1","name":"Bad","lat":40.7,"lon":-73.99,"bikes":-4,"eBikes":-1,"docks":-7,"renting":true,"returning":true}]}"#
        let (docks, _) = await withNetwork({ $0.url?.path == "/docks" ? .ok(Data(body.utf8)) : nil }) {
            await CitiBike.docks(near: CLLocation(latitude: 40.7, longitude: -73.99))
        }
        let dock = try #require(docks?.first)
        #expect(dock.available(.bike) == 0 && dock.available(.eBike) == 0 && dock.free == 0)
        #expect(BikeKinds.both.count(at: dock) == 0)
        #expect(!CitiBike.Has.either.admits(dock))
        let trip = BikeTrip(kind: .bike, pickup: dock, dropoff: dock, path: [], rideMinutes: 5, bikeFirst: true, minutes: 9)
        #expect(trip.bikes == 0 && trip.docks == 0 && trip.isShort)
    }

    /// No docks near is none, not "can't say".
    @Test func zeroDocksNear() async {
        let (docks, _) = await withNetwork({ _ in .ok(Data(#"{"docks":[]}"#.utf8)) }) {
            await CitiBike.docks(near: BusBikePlaces.atlantic)
        }
        #expect(docks == [])
        #expect(NearbyDock.nearest(to: BusBikePlaces.atlantic, among: []).isEmpty)
        #expect(NearbyDock.nearest(to: BusBikePlaces.atlantic, among: [testDock("a", 40.7, -73.99)]).isEmpty)
        #expect(NearbyDock.nearest(to: BusBikePlaces.timesSquare, among: [testDock("a", 40.7581, -73.9855)], limit: 0).isEmpty)
    }

    /// The server's answer unreadable, and Citi Bike's own feed unreachable: none far from any dock.
    @Test func malformedServerFallsBack() async {
        let body = Data(#"{"docks":[{"id":"x"}]}"#.utf8)
        let (docks, made) = await withNetwork({ $0.url?.path == "/docks" ? .ok(body) : nil }) {
            await keepingDockPlaces { await CitiBike.docks(near: BusBikePlaces.albany) }
        }
        #expect((docks ?? []).isEmpty)
        #expect(made.first?.url.path == "/docks")
    }

    /// Citi Bike's own feed with bad counts, a dock not installed, and one with no place: each
    /// dock's counts never below none, nor more classic bikes for a negative e-bike count.
    @Test func gbfsFeedBadCounts() async throws {
        let information = #"""
        {"data":{"stations":[
          {"station_id":"t-neg","name":"Neg","lat":40.75,"lon":-73.99},
          {"station_id":"t-over","name":"Over","lat":40.751,"lon":-73.99},
          {"station_id":"t-off","name":"Off","lat":40.752,"lon":-73.99},
          {"station_id":"t-null","name":"Null","lat":40.753,"lon":-73.99},
          {"station_id":"t-huge","name":"Huge","lat":40.754,"lon":-73.99},
          {"station_id":"t-stale","name":"Stale","lat":40.755,"lon":-73.99}]}}
        """#
        let status = #"""
        {"data":{"stations":[
          {"station_id":"t-neg","num_bikes_available":5,"num_ebikes_available":-3,"num_docks_available":-2,"is_installed":1,"is_renting":1,"is_returning":1,"last_reported":0},
          {"station_id":"t-over","num_bikes_available":2,"num_ebikes_available":7,"num_docks_available":1,"is_installed":1,"is_renting":1,"is_returning":1},
          {"station_id":"t-off","num_bikes_available":9,"num_ebikes_available":0,"num_docks_available":9,"is_installed":0},
          {"station_id":"t-null"},
          {"station_id":"t-ghost","num_bikes_available":3,"is_installed":1},
          {"station_id":"t-huge","num_bikes_available":2147483647,"num_ebikes_available":0,"num_docks_available":2147483647,"is_installed":1,"is_renting":1,"is_returning":1},
          {"station_id":"t-stale","num_bikes_available":8,"num_ebikes_available":2,"num_docks_available":5,"is_installed":1,"is_renting":1,"is_returning":1,"last_reported":STALE}]}}
        """#.replacingOccurrences(of: "STALE", with: String(Int(Date.now.timeIntervalSince1970) - 31 * 60))
        let (docks, made) = await withNetwork({ request in
            guard let path = request.url?.path else { return nil }
            if path.hasSuffix("station_information.json") { return .ok(Data(information.utf8)) }
            if path.hasSuffix("station_status.json") { return .ok(Data(status.utf8)) }
            return nil
        }) {
            await keepingDockPlaces { await CitiBike.docks() }
        }
        let all = try #require(docks)
        #expect(all.allSatisfy { $0.available(.bike) >= 0 && $0.available(.eBike) >= 0 && $0.free >= 0 })
        // Only where this load read our feed whole: the store keeps a minute's counts and a day's places
        guard made.contains(where: { $0.url.path.hasSuffix("station_information.json") }) else { return }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let negative = try #require(byID["t-neg"])
        #expect(negative.bikes == 5 && negative.eBikes == 0 && negative.docks == 0)
        let over = try #require(byID["t-over"])
        #expect(over.bikes == 0 && over.eBikes == 7)
        #expect(byID["t-off"] == nil && byID["t-ghost"] == nil)
        let null = try #require(byID["t-null"])
        #expect(null.available(.bike) == 0 && null.free == 0)
        #expect(byID["t-huge"]?.available(.bike) == Int(Int32.max))
        let stale = try #require(byID["t-stale"])
        #expect(!stale.renting && !stale.returning && stale.available(.bike) == 0 && stale.free == 0)
    }

    /// A ride from the sea finds no dock at the start, and asks Apple Maps nothing.
    @Test func noDockAtStart() async {
        let status = #"{"data":{"stations":[{"station_id":"s1","num_bikes_available":9,"num_ebikes_available":1,"num_docks_available":9,"is_installed":1,"is_renting":1,"is_returning":1}]}}"#
        let information = #"{"data":{"stations":[{"station_id":"s1","name":"Midtown","lat":40.758,"lon":-73.9855}]}}"#
        let (planned, _) = await withNetwork({ request in
            let path = request.url?.path ?? ""
            return path.hasSuffix("station_status.json") ? .ok(Data(status.utf8))
                : path.hasSuffix("station_information.json") ? .ok(Data(information.utf8)) : nil
        }) {
            await keepingDockPlaces {
                await BikePlanner.planned(from: BusBikePlaces.atlantic, to: BusBikePlaces.timesSquare, kind: .bike,
                                          subway: false, walkRange: 1200, at: Fixtures.date("2026-11-10 08:15"))
            }
        }
        #expect(planned.trips.isEmpty)
        #expect(planned.none == .noDock(atStart: true))
    }
}

// MARK: - Bike lanes, bad paths

struct BikeLanesAdversarialTests {
    /// Nothing, one point, the same point twice, or not-a-number: too short to say, no crash.
    @Test func tooShortToSay() {
        let point = Walk.Point(lat: 40.75, lon: -73.99)
        #expect(BikeLanes.protectedShare(of: []) == nil)
        #expect(BikeLanes.protectedShare(of: [point]) == nil)
        #expect(BikeLanes.protectedShare(of: [point, point]) == nil)
        #expect(BikeLanes.protectedShare(of: [point, Walk.Point(lat: .nan, lon: .nan)]) == nil)
    }

    /// A ride at sea is on no lane.
    @Test func atSeaNoLane() {
        let path = [Walk.Point(lat: 40.45, lon: -73.70), Walk.Point(lat: 40.451, lon: -73.70)]
        #expect(BikeLanes.protectedShare(of: path) == 0)
    }

    /// The pill for odd shares: none for not-a-number or below 0, at most 100%.
    @Test func oddShares() {
        #expect(BikeTripRow.protectedPercent(of: .nan) == nil)
        #expect(BikeTripRow.protectedPercent(of: -0.3) == nil)
        #expect(BikeTripRow.protectedPercent(of: 1.7) == 100)
    }

    /// Your own bike between two places at sea, no subway: no trip, nothing asked.
    @Test func ownBikeAtSea() async {
        let planned = await BikePlanner.plannedOwn(from: BusBikePlaces.atlantic,
                                                   to: CLLocation(latitude: 40.452, longitude: -73.70), endName: "Sea",
                                                   kind: .eBike, carry: .none, subway: false, walkRange: 800,
                                                   at: Fixtures.date("2026-11-10 08:15"))
        #expect(planned.trips.isEmpty && planned.none == nil)
    }
}

// MARK: - Nearby at the city's edges

struct NearbyEdgeTests {
    /// Hoboken: Manhattan's stations are near as the crow flies but no walk, so none listed.
    @Test func newJerseyNoStations() throws {
        #expect(Nearby.stations(near: BusBikePlaces.hoboken).isEmpty)
        let nearest = try #require(Nearby.nearest(to: BusBikePlaces.hoboken))
        #expect(nearest.meters > 1_000 && nearest.meters < 5_000)
    }

    /// Staten Island by the Verrazzano: only its own stations, none across the Narrows in Bay Ridge.
    @Test func statenIslandOnlyItsOwn() {
        let near = Nearby.stations(near: BusBikePlaces.fortWadsworth, limit: 20)
        #expect(!near.isEmpty)
        #expect(near.allSatisfy { $0.station.borough == "Staten Island" })
    }

    /// At sea or upstate, no stations listed; the nearest is still said, however far.
    @Test func farAwayNoStations() throws {
        #expect(Nearby.stations(near: BusBikePlaces.atlantic).isEmpty)
        #expect(Nearby.stations(near: BusBikePlaces.albany).isEmpty)
        #expect(try #require(Nearby.nearest(to: BusBikePlaces.albany)).meters > 100_000)
        #expect(Nearby.stations(near: BusBikePlaces.timesSquare, among: []).isEmpty)
        #expect(Nearby.stations(near: BusBikePlaces.timesSquare, limit: 0).isEmpty)
    }

    /// Islands with no walk off them: none from Rikers to Manhattan.
    @Test func noWalkOffRikers() {
        let rikers = CLLocation(latitude: 40.7900, longitude: -73.8850)
        #expect(WalkReach.land(at: rikers.coordinate) == .rikers)
        #expect(WalkReach.meters(from: rikers, to: BusBikePlaces.timesSquare) == nil)
        #expect(Nearby.stations(near: rikers).isEmpty)
    }
}


// MARK: - Docks gone quiet, buses listed twice

struct StaleDocksAdversarialTests {
    /// Silent over half an hour, a dock is out of service; under it, or not said, as it was.
    @Test func staleDockOutOfService() {
        let now = Fixtures.date("2026-11-10 08:15")
        let seconds = Int(now.timeIntervalSince1970)
        var dock = testDock("1", 40.7, -74, bikes: 6, eBikes: 2, docks: 9)
        #expect(dock.checked(at: now) == dock)
        dock.lastReported = seconds - 31 * 60
        let stale = dock.checked(at: now)
        #expect(!stale.renting && !stale.returning && stale.available(.bike) == 0 && stale.free == 0)
        #expect(!CitiBike.Has.service.admits(stale))
        dock.lastReported = seconds - 29 * 60
        #expect(dock.checked(at: now).renting)
        // 0 is GBFS's "not said"; a report from the future isn't stale
        dock.lastReported = 0
        #expect(dock.checked(at: now).renting)
        dock.lastReported = seconds + 3_600
        #expect(dock.checked(at: now).renting)
    }

    /// The push server's docks with when each last reported: one silent too long is out of
    /// service; an answer without it (an older server) reads as before.
    @Test func servedStaleDocks() async throws {
        let old = Int(Date.now.timeIntervalSince1970) - 45 * 60
        let fresh = Int(Date.now.timeIntervalSince1970) - 60
        let body = """
        {"docks":[
         {"id":"s1","name":"Old","lat":40.7,"lon":-73.99,"bikes":5,"eBikes":1,"docks":4,"renting":true,"returning":true,"lastReported":\(old)},
         {"id":"s2","name":"Fresh","lat":40.7,"lon":-73.99,"bikes":5,"eBikes":1,"docks":4,"renting":true,"returning":true,"lastReported":\(fresh)},
         {"id":"s3","name":"Older server","lat":40.7,"lon":-73.99,"bikes":5,"eBikes":1,"docks":4,"renting":true,"returning":true}]}
        """
        let (docks, _) = await withNetwork({ $0.url?.path == "/docks" ? .ok(Data(body.utf8)) : nil }) {
            await CitiBike.docks(near: CLLocation(latitude: 40.7, longitude: -73.99))
        }
        let byID = Dictionary(uniqueKeysWithValues: try #require(docks).map { ($0.id, $0) })
        #expect(byID["s1"]?.renting == false && byID["s1"]?.available(.bike) == 0 && byID["s1"]?.lastReported == old)
        #expect(byID["s2"]?.available(.bike) == 5)
        #expect(byID["s3"]?.available(.bike) == 5 && byID["s3"]?.lastReported == nil)
    }
}

struct DuplicateBusTests {
    let now = Fixtures.date("2026-11-10 08:15")

    /// The same bus listed twice, seconds apart, or under a line's two names, is listed once.
    @Test func repeatsDropped() {
        let bus = testBus("Q6", 4, after: now, to: "JAMAICA")
        var near = bus
        near.expected = bus.expected?.addingTimeInterval(4)
        let padded = BusArrival(line: "Q06", destination: "JAMAICA", expected: bus.expected)
        #expect(BusArrival.withoutRepeats([bus, near, padded]) == [bus])
    }

    /// Different buses stay: another way, another line, seconds further apart, or live beside scheduled.
    @Test func differentBusesKept() {
        let bus = testBus("Q6", 4, after: now, to: "JAMAICA")
        var later = bus
        later.expected = bus.expected?.addingTimeInterval(6)
        let otherWay = testBus("Q6", 4, after: now, to: "JFK")
        let otherLine = testBus("Q7", 4, after: now, to: "JAMAICA")
        let scheduled = testBus("Q6", 4, after: now, live: false, to: "JAMAICA")
        let all = [bus, otherWay, otherLine, scheduled, later]
        #expect(BusArrival.withoutRepeats(all) == all)
        let timeless = [BusArrival(line: "Q6"), BusArrival(line: "Q6")]
        #expect(BusArrival.withoutRepeats(timeless) == timeless)
    }

    /// A line asked under two names at once comes back once, merged.
    @Test func mergedLinesOnce() async throws {
        let stop = BusStop(id: "999002", name: "SEA", latitude: 40.46, longitude: -73.70)
        let data = try JSONEncoder().encode(BusStopTimes(stop: stop, arrivals: [testBus("Q6", 3, after: now, to: "JAMAICA"),
                                                                              testBus("Q6", 9, after: now, to: "JAMAICA")]))
        let place = BusRide.Place(name: "Sea", latitude: 40.4612, longitude: -73.7012)
        let now = now
        let (times, made) = await withNetwork({ _ in .ok(data) }) {
            await BusTimes.arrivals(lines: ["Q6", "Q06"], at: place, now: now)
        }
        #expect(made.count == 2)
        #expect(times?.arrivals.count == 2)
    }
}
