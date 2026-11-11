import CoreLocation
import Foundation
import Testing
@testable import Leeway

/// Nearby's line grid: its tiles worked out once for their inputs (`NearbyLineGrid.TilesMemo`),
/// as they were in its body each time, from the saved weekday feeds at 4 Av-9 St.
@MainActor
struct NearbyLineGridTests {
    /// 4 Av-9 St and the stations round it, a bus stop still being found and a dock, with their
    /// trains as the feeds had them.
    private static func inputs() async -> (stations: [NearbyGridPlace], stops: [NearbyGridPlace],
                                           docks: [NearbyGridPlace], trains: [String: [Arrival]], now: Date) {
        let here = CLLocation(latitude: 40.6705, longitude: -73.9888)
        let near = Nearby.stations(near: here, limit: 3)
        let stations = near.map {
            NearbyGridPlace(id: "s" + $0.id, name: $0.station.name, distance: .walk($0.walkMinutes), kind: .station($0.station))
        }
        let stops = [NearbyGridPlace(id: "b1", name: "9 St & 4 Av", distance: .walk(1),
                                     kind: .stop(nil, lines: ["B61", "B103", "b61"], stale: false))]
        let dock = CitiBike.Dock(id: "d1", name: "4 Av & 9 St", lat: 40.67, lon: -73.99, bikes: 3, eBikes: 1, docks: 9,
                                 renting: true, returning: true)
        let docks = [NearbyGridPlace(id: "dd1", name: dock.name, distance: .walk(2), kind: .dock(dock))]
        let now = FeedFixtures.capturedAt
        let (trains, _) = await withNetwork(FeedFixtures.respond) {
            await TrainService.trains(for: near.flatMap(\.station.lineSelections), includingOtherLines: false, now: now)
        }
        return (stations, stops, docks, trains, now)
    }

    /// Everything a tile shows or opens, to compare two lists of them.
    private static func described(_ tiles: [NearbyLineGrid.Tile]) -> [String] {
        tiles.map { "\($0.id) \($0.first) \($0.place.id) \(String(describing: $0.ways))" }
    }

    @Test func tilesAsBefore() async throws {
        let input = await Self.inputs()
        let tiles = NearbyLineGrid.tiles(stations: input.stations, stops: input.stops, docks: input.docks, picked: nil,
                                         trains: input.trains, now: input.now)
        // Each line once, at the nearest station it stops at: the F, G and R at 4 Av-9 St first
        let first = try #require(input.stations.first)
        #expect(tiles.prefix(3).map(\.line) == ["F", "G", "R"])
        #expect(tiles.prefix(3).allSatisfy { $0.place.id == first.id })
        #expect(tiles.filter(\.first).map(\.place.id) == Array(Set(tiles.map(\.place.id))).sorted { a, b in
            tiles.firstIndex { $0.place.id == a }! < tiles.firstIndex { $0.place.id == b }!
        })
        #expect(Set(tiles.map(\.id)).count == tiles.count)
        // Its buses each once whatever their case, and the dock last
        #expect(tiles.filter(\.isBus).map(\.line) == ["B61", "B103"])
        #expect(tiles.last?.id == "dd1")
        // Trains with times, from the feeds
        #expect(tiles.contains { if case .trains(let ways) = $0.ways { !ways.isEmpty } else { false } })
    }

    /// The same inputs: the tiles kept, not worked out again. Any input changed: worked out again,
    /// the same as from scratch.
    @Test func memoKeepsOnlyForTheSameInputs() async {
        let input = await Self.inputs()
        let memo = NearbyLineGrid.TilesMemo()
        var made = 0
        func tiles(picked: String?, now: Date, trains: [String: [Arrival]]? = nil) -> [NearbyLineGrid.Tile] {
            let trains = trains ?? input.trains
            let key = NearbyLineGrid.TilesMemo.Key(stations: input.stations, stops: input.stops, docks: input.docks,
                                                   picked: picked, trains: trains, now: now)
            return memo.tiles(for: key) {
                made += 1
                return NearbyLineGrid.tiles(stations: input.stations, stops: input.stops, docks: input.docks,
                                            picked: picked, trains: trains, now: now)
            }
        }
        let fresh = { (picked: String?, now: Date, trains: [String: [Arrival]]) in
            Self.described(NearbyLineGrid.tiles(stations: input.stations, stops: input.stops, docks: input.docks,
                                                picked: picked, trains: trains, now: now))
        }
        let a = tiles(picked: nil, now: input.now)
        let b = tiles(picked: nil, now: input.now)
        #expect(made == 1)
        #expect(Self.described(a) == Self.described(b))
        #expect(Self.described(a) == fresh(nil, input.now, input.trains))
        // A tick of the minutes
        let later = input.now.addingTimeInterval(10 * 60)
        #expect(Self.described(tiles(picked: nil, now: later)) == fresh(nil, later, input.trains))
        #expect(made == 2)
        // A place tapped on the map
        let picked = input.stations.last?.id
        #expect(Self.described(tiles(picked: picked, now: later)) == fresh(picked, later, input.trains))
        #expect(made == 3)
        // New trains
        let none: [String: [Arrival]] = [:]
        #expect(Self.described(tiles(picked: picked, now: later, trains: none)) == fresh(picked, later, none))
        #expect(made == 4)
    }

    /// What VoiceOver says for each tile, one element: its line, place and walk, then every way's
    /// next as the tile shows it.
    @Test func spokenAsShown() async throws {
        let input = await Self.inputs()
        let tiles = NearbyLineGrid.tiles(stations: input.stations, stops: input.stops, docks: input.docks, picked: nil,
                                         trains: input.trains, now: input.now)
        let f = try #require(tiles.first)
        #expect(NearbyLineTile.spokenLabel(f) == "F train at 4 Av-9 St, 1 min walk")
        guard case .trains(let ways) = f.ways else { Issue.record("Not a train tile"); return }
        let times = NearbyLineTile.spokenTimes(f, now: input.now, failed: [])
        #expect(times.components(separatedBy: "; ").count == ways.count)
        #expect(ways.allSatisfy { times.contains($0.label + ", ") })
        // A stop still being found, and one whose times couldn't be had
        let finding = try #require(tiles.first { $0.isBus })
        #expect(NearbyLineTile.spokenLabel(finding) == "B61 bus at 9 St & 4 Av, 1 min walk")
        #expect(NearbyLineTile.spokenTimes(finding, now: input.now, failed: []) == "Loading")
        let stale = NearbyLineGrid.Tile(line: "B61", place: finding.place, ways: .buses(nil, stale: true))
        #expect(NearbyLineTile.spokenTimes(stale, now: input.now, failed: []) == "Bus times aren't available")
        // A way with no bus coming says "None", as shown, not "No trains"
        let stop = BusStop(id: "308209", name: "4 AV/9 ST", latitude: 40.67, longitude: -73.99, direction: "N")
        let bus = BusArrival(line: "B61", destination: "Bay Ridge", expected: input.now.addingTimeInterval(300))
        let ways2 = [NearbyBusPick.Way(stop: stop, destination: "Downtown Bklyn", arrivals: [bus]),
                     NearbyBusPick.Way(stop: stop, destination: "Bay Ridge", arrivals: [])]
        let buses = NearbyLineGrid.Tile(line: "B61", place: finding.place, ways: .buses(ways2, stale: false))
        #expect(NearbyLineTile.spokenTimes(buses, now: input.now, failed: []) == "Downtown Bklyn, 5 minutes; Bay Ridge, None")
        // A dock: its bikes of each kind and open docks
        let dock = try #require(tiles.last)
        #expect(NearbyLineTile.spokenLabel(dock) == "Citi Bike dock at 4 Av & 9 St, 2 min walk")
        #expect(NearbyLineTile.spokenTimes(dock, now: input.now, failed: []) == "3 bikes, 1 e-bike, 9 open docks")
    }
}
