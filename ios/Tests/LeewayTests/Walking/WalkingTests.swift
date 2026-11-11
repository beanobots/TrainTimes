import CoreLocation
import Foundation
import MapKit
import Testing
@testable import Leeway

/// Shared pieces for the walking tests: a trip on the R from 4 Av-9 St to Court St, made-up
/// walks laid out in metres from the station's NW stairs, and a walk session with them.
enum WalkFixture {
    /// The R33 NW stairs at 4 Av & 9 St.
    static let origin = Walk.Point(lat: 40.670538, lon: -73.988778)

    /// A point `east` and `north` metres from `origin`.
    static func p(_ east: Double, _ north: Double, from origin: Walk.Point = origin) -> Walk.Point {
        Walk.Point(lat: origin.lat + north / Earth.metresPerDegree,
                   lon: origin.lon + east / (Earth.metresPerDegree * cos(origin.lat * .pi / 180)))
    }

    static func location(_ point: Walk.Point, accuracy: Double = 5, timestamp: Date = .now) -> CLLocation {
        CLLocation(coordinate: point.coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                   timestamp: timestamp)
    }

    static let selection = Selection(stationID: "R33", routes: ["R"], direction: .north)
    static let start = CLLocation(latitude: 40.6731, longitude: -73.9860)
    static let end = CLLocation(latitude: 40.6925, longitude: -73.9900)

    static func trip() throws -> TripPlanner.Trip {
        let courtSt = try #require(StationDirectory.station(id: "R28"))
        return TripPlanner.Trip(selection: selection, change: nil, destination: courtSt)
    }

    /// A walk whose first step is `first`, then a right onto 9th St and the way down.
    static func walk(first: Walk.Step, crossings: [[Walk.Point]]? = nil, lights: [Walk.Light]? = nil) -> Walk {
        let second = Walk.Step(turn: .right, instruction: "Take a right onto 9th St", meters: 80,
                               points: [p(20, 100), p(20, 180)])
        let down = Walk.Step(turn: .stairsDown, instruction: "Down the stairs, NW corner of 4 Av & 9 St",
                             spoken: "Down the stairs at the NW corner of 4 Av & 9 St", meters: 0, points: [p(20, 180)])
        let steps = [first, second, down]
        let meters = steps.map(\.meters).reduce(0, +)
        return Walk(steps: steps, seconds: meters / 1.2, meters: meters, crossings: crossings, lights: lights)
    }

    /// A left onto 4th Ave, 100 m.
    static let left = Walk.Step(turn: .left, instruction: "Take a left onto 4th Ave", meters: 100,
                                points: [p(0, 0), p(0, 100)])

    /// The way over a street, from (0, 100) to (20, 100).
    static let crossing = [p(0, 100), p(20, 100)]

    /// A crossing's own step over `crossing`, at `light`.
    static func cross(_ light: Walk.Light?, instruction: String = "Cross the street") -> Walk.Step {
        Walk.Step(turn: .cross, instruction: instruction, meters: 0, points: crossing, light: light, crossing: crossing)
    }

    static func tripWalks(toTrain: Walk) throws -> WalkingDirections.TripWalks {
        let trip = try trip()
        let boarding = try #require(StationWays.boarding(selection, from: start))
        let leaving = try #require(StationWays.leaving(selection, change: nil, at: trip.destination, toward: end))
        let out = Walk(steps: [leaving.up, Walk.Step(turn: .arrive, instruction: "Arrive", meters: 200,
                                                     points: [Walk.Point(leaving.location.coordinate), Walk.Point(end.coordinate)])],
                       seconds: 160, meters: 200)
        return WalkingDirections.TripWalks(boarding: boarding, toTrain: toTrain, leaving: leaving, fromTrain: out)
    }

    @MainActor
    static func session(toTrain: Walk, stage: WalkSession.Stage = .toTrain, trains: [Arrival] = []) throws -> WalkSession {
        WalkSession(trip: try trip(), walks: try tripWalks(toTrain: toTrain), endName: "Brooklyn Bridge Park", end: end,
                    stage: stage, trains: trains)
    }

    static func train(leaves: Date, trip: String = "R-test") -> Arrival {
        Arrival(route: "R", time: leaves, stop: "R33N", lastStop: "G08N", isLive: true, trip: trip)
    }
}

// MARK: - The live walk

/// The walk session's instructions, warnings, timing and Lock Screen state, without following
/// you (no `start()`, so no location manager).
@MainActor
struct WalkSessionTests {
    /// A crossing's "Cross the street" takes its street's name once the geocoder has it.
    @Test func crossingTakesItsStreetsName() throws {
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.cross(.signal)))
        let step = try #require(session.nextStep)
        #expect(session.instruction(of: step) == "Cross the street")
        session.crossNames[try #require(CrossStreets.middle(of: WalkFixture.crossing))] = "4th Ave"
        #expect(session.instruction(of: step) == "Cross 4th Ave")
    }

    /// A crossing step that already names its street, or a turn, is left as it says.
    @Test func namedCrossingAndTurnsKeepTheirWords() throws {
        let named = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.cross(.signal, instruction: "Cross 5th Ave")))
        named.crossNames[try #require(CrossStreets.middle(of: WalkFixture.crossing))] = "4th Ave"
        #expect(named.instruction(of: try #require(named.nextStep)) == "Cross 5th Ave")
        let turn = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.left))
        #expect(turn.instruction(of: try #require(turn.nextStep)) == "Take a left onto 4th Ave")
    }

    /// A wide crossing with no light warns of cars, on its own step.
    @Test func wideUnsignalledCrossingWarns() throws {
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.cross(.unsignalledWide)))
        #expect(session.lightNote == "No light and wide crossing - watch for cars")
        #expect(session.liveDetail == session.lightNote)
    }

    /// The two levels of no light: a narrow one is tagged but not warned of; a light is neither.
    @Test func narrowUnsignalledAndSignalledDontWarn() throws {
        #expect(Walk.Light.unsignalled.tag == "No light")
        #expect(Walk.Light.unsignalledWide.tag == "No light")
        #expect(Walk.Light.unsignalled.note == nil)
        #expect(Walk.Light.unsignalledWide.note != nil)
        for light in [Walk.Light.unsignalled, .signal, .leading, .exclusive] {
            let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.cross(light)))
            #expect(session.lightNote == nil, "\(light)")
        }
    }

    /// A turn with a wide unlit street straight after warns with that street's name, or "the street".
    @Test func turnThenUnlitCrossingNamesTheStreet() throws {
        var turn = WalkFixture.left
        turn.light = .unsignalledWide
        turn.crossing = WalkFixture.crossing
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: turn))
        #expect(session.lightNote == "Then cross the street · No light and wide crossing - watch for cars")
        session.crossNames[try #require(CrossStreets.middle(of: WalkFixture.crossing))] = "4th Ave"
        #expect(session.lightNote == "Then cross 4th Ave · No light and wide crossing - watch for cars")
    }

    /// Before any fix, the first step is next, and the one after it is the "Then …".
    @Test func firstStepNextUntilFound() throws {
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.left))
        #expect(session.nextStep?.instruction == "Take a left onto 4th Ave")
        #expect(session.laterSteps.count == 2)
        #expect(session.thenStep == "Then take a right onto 9th St")
        #expect(session.liveDetail == "Then take a right onto 9th St")
    }

    /// What's left of the path is the whole walk before any fix, and nothing once on the train.
    @Test func pathLeftByStage() throws {
        let walk = WalkFixture.walk(first: WalkFixture.left)
        #expect(try WalkFixture.session(toTrain: walk).pathLeft == walk.points)
        let riding = try WalkFixture.session(toTrain: walk, stage: .riding)
        #expect(riding.walk == nil)
        #expect(riding.nextStep == nil)
        #expect(riding.pathLeft.isEmpty)
    }

    /// Time left is the walk's own time at its own pace; on the platform a minute after that.
    @Test func onPlatformAfterWalkAndStairs() throws {
        let walk = WalkFixture.walk(first: WalkFixture.left)
        let session = try WalkFixture.session(toTrain: walk)
        let now = Fixtures.date("2026-11-10 08:00")
        #expect(abs(session.secondsLeft - walk.seconds) < 0.001)
        let onPlatform = session.onPlatform(now: now).timeIntervalSince(now)
        #expect(abs(onPlatform - (walk.seconds + WalkSession.downToPlatform)) < 0.001)
        #expect(WalkSession.downToPlatform == 60)
        #expect(WalkSession.outOfBuilding == 2 * 60)
    }

    /// Trains gone before you're down are missed; the first after is the one to catch.
    @Test func catchableAndMissedTrains() throws {
        let now = Fixtures.date("2026-11-10 08:00")
        let walk = WalkFixture.walk(first: WalkFixture.left)
        let ready = now.addingTimeInterval(walk.seconds + WalkSession.downToPlatform)
        let trains = [now.addingTimeInterval(-30), now.addingTimeInterval(60), ready.addingTimeInterval(-1),
                      ready.addingTimeInterval(1), ready.addingTimeInterval(300)].enumerated().map { WalkFixture.train(leaves: $1, trip: "t\($0)") }
        let session = try WalkFixture.session(toTrain: walk, trains: trains)
        #expect(session.missed(now: now).map(\.trip) == ["t1", "t2"])
        #expect(session.catchable(now: now)?.trip == "t3")
    }

    /// At the entrance, on the platform a minute from now; the train due a moment ago is at the station.
    @Test func atStationTimingAndTrainIn() throws {
        let now = Fixtures.date("2026-11-10 08:00")
        let trains = [WalkFixture.train(leaves: now.addingTimeInterval(-5), trip: "in"),
                      WalkFixture.train(leaves: now.addingTimeInterval(240), trip: "next")]
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.left), stage: .atStation, trains: trains)
        #expect(session.onPlatform(now: now) == now.addingTimeInterval(60))
        #expect(session.trainAtStation(now: now)?.trip == "in")
        #expect(session.catchable(now: now)?.trip == "next")
        // Not while still walking to it
        let walking = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.left), trains: trains)
        #expect(walking.trainAtStation(now: now) == nil)
    }

    /// The Lock Screen while walking to the train: the step's instruction, its distance, the step after.
    @Test func lockScreenWalkingToTheTrain() throws {
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.left))
        let live = try #require(session.liveState)
        #expect(live.phase == .toTrain)
        #expect(live.instruction == "Take a left onto 4th Ave")
        #expect(live.distance == WalkSession.turnDistance(100))
        #expect(live.symbol == Walk.Turn.left.systemImage)
        #expect(live.detail == "Then take a right onto 9th St")
        #expect(live.endName == "Brooklyn Bridge Park")
    }

    /// At the entrance the Lock Screen shows the way down, shown short, and which side it's for.
    @Test func lockScreenAtTheEntrance() throws {
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.left), stage: .atStation)
        let walks = try #require(session.walks)
        let live = try #require(session.liveState)
        #expect(live.phase == .atStation)
        #expect(live.distance == "Here")
        #expect(live.instruction == walks.boarding.down.instruction)
        #expect(live.instruction.hasPrefix("Down the stairs, "))
        #expect(live.instruction.contains("corner of 4 Av & 9 St"))
        // Both sides joined at 4 Av-9 St: not "only", just the side
        #expect(live.detail == "Manhattan-bound")
        #expect(session.platformName == "Manhattan-bound")
    }

    /// On the train: get off at Court St, the way up next.
    @Test func lockScreenOnTheTrain() throws {
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.left), stage: .riding)
        #expect(session.rideInstruction == "Get off at Court St")
        #expect(session.isLastTrain)
        #expect(session.currentRoute == "R")
        let live = try #require(session.liveState)
        #expect(live.phase == .riding)
        #expect(live.instruction == "Get off at Court St")
        #expect(live.getOffAt == "Court St")
        #expect(live.next == session.walks?.leaving.up.instruction)
    }

    /// Walking all the way: walked as out from a train, to the end by its name.
    @Test func plainWalkIsAWalkOut() throws {
        let walk = WalkFixture.walk(first: WalkFixture.left)
        let session = WalkSession(walk: walk, endName: "Prospect Park", end: WalkFixture.end)
        #expect(session.stage == .fromTrain)
        #expect(session.trip == nil)
        #expect(session.destinationName == "Prospect Park")
        #expect(session.walk == walk)
        #expect(session.isLastTrain)
        #expect(session.rideInstruction == "Get off at Prospect Park")
        let live = try #require(session.liveState)
        #expect(live.phase == .fromTrain)
        #expect(live.instruction == "Take a left onto 4th Ave")
    }

    /// Off the train the stairs up are "Now", not a distance.
    @Test func wayUpIsNow() throws {
        let up = Walk.Step(turn: .stairsUp, instruction: "Up the stairs, NE corner of Court St & Montague St", meters: 0,
                           points: [WalkFixture.p(0, 0)])
        let walk = Walk(steps: [up, WalkFixture.left], seconds: 90, meters: 100)
        let live = try #require(WalkSession(walk: walk, endName: "Home", end: WalkFixture.end).liveState)
        #expect(live.distance == "Now")
    }

    /// "Faster" names the other trip's lines and station.
    @Test func fasterLabel() throws {
        let faster = WalkSession.Faster(trip: try WalkFixture.trip(), minutesSooner: 4, arrives: .now)
        #expect(faster.label == "R from 4 Av-9 St")
    }

    /// The turn card's distances: feet in fifties near, hundreds past 500 ft, tenths of a mile from 1,000.
    @Test func turnDistanceImperial() {
        #expect(WalkSession.turnDistance(10, metric: false) == "30 ft")
        #expect(WalkSession.turnDistance(100, metric: false) == "350 ft")
        #expect(WalkSession.turnDistance(200, metric: false) == "700 ft")
        #expect(WalkSession.turnDistance(400, metric: false) == "0.2 mi")
    }

    /// Metric: tens of metres near, fifties past 300, kilometres from 1,000.
    @Test func turnDistanceMetric() {
        #expect(WalkSession.turnDistance(123, metric: true) == "120 m")
        #expect(WalkSession.turnDistance(330, metric: true) == "350 m")
        #expect(WalkSession.turnDistance(1_400, metric: true) == "1.4 km")
    }

    /// The stages' saved names, which a walk saved before an update is read back by.
    @Test func stageNamesAreStable() {
        let names: [WalkSession.Stage] = [.toTrain, .atStation, .riding, .changing, .ridingOn, .fromTrain, .arrived]
        #expect(names.map(\.rawValue) == ["toTrain", "atStation", "riding", "changing", "ridingOn", "fromTrain", "arrived"])
    }
}

// MARK: - Saving and restoring

/// A walk saved as iOS closes the app, and made again from it.
@MainActor
struct WalkSavedTests {
    static func saved(stage: WalkSession.Stage = .riding, started: Date = .now) throws -> WalkSession.Saved {
        let walks = try WalkFixture.tripWalks(toTrain: WalkFixture.walk(first: WalkFixture.left))
        return WalkSession.Saved(selection: WalkFixture.selection, change: nil, destinationID: "R28", walks: walks,
                                 plainWalk: nil, endName: "Brooklyn Bridge Park",
                                 endLatitude: WalkFixture.end.coordinate.latitude,
                                 endLongitude: WalkFixture.end.coordinate.longitude,
                                 started: started, stage: stage,
                                 boarded: WalkFixture.train(leaves: Fixtures.date("2026-11-10 08:10"), trip: "boarded"),
                                 boardedOnward: nil, changedAt: nil,
                                 arrivals: ["boarded": Fixtures.date("2026-11-10 08:22")], onLockScreen: false)
    }

    /// Saved and read back, it's the same walk.
    @Test func roundTrips() throws {
        let saved = try Self.saved()
        let back = try JSONDecoder().decode(WalkSession.Saved.self, from: try JSONEncoder().encode(saved))
        #expect(back.selection == saved.selection)
        #expect(back.walks == saved.walks)
        #expect(back.stage == .riding)
        #expect(back.boarded == saved.boarded)
        #expect(back.arrivals == saved.arrivals)
        #expect(back.endLatitude == saved.endLatitude)
        #expect(back.onLockScreen == false)
    }

    /// Made again from what was saved, it carries on at its stage with the train you're on.
    @Test func restoresTheTrainYoureOn() throws {
        let session = try #require(WalkSession(saved: try Self.saved()))
        #expect(session.stage == .riding)
        #expect(session.trip?.destination.id == "R28")
        #expect(session.boarded?.trip == "boarded")
        #expect(session.arrivals["boarded"] == Fixtures.date("2026-11-10 08:22"))
        #expect(session.trainArrives == Fixtures.date("2026-11-10 08:22"))
        #expect(session.onLockScreen == false)
        #expect(session.end.coordinate.latitude == WalkFixture.end.coordinate.latitude)
    }

    /// A walk all the way, saved, comes back as one.
    @Test func restoresAPlainWalk() throws {
        let walk = WalkFixture.walk(first: WalkFixture.left)
        let saved = WalkSession.Saved(plainWalk: walk, endName: "Home", endLatitude: 40.68, endLongitude: -73.98,
                                      started: .now, stage: .fromTrain, arrivals: [:], onLockScreen: true)
        let session = try #require(WalkSession(saved: saved))
        #expect(session.trip == nil)
        #expect(session.walk == walk)
        #expect(session.destinationName == "Home")
    }
}

// MARK: - Walks on the city's data

/// Walks routed on the bundled walking graph, and the bundled sidewalks: offline, no Apple Maps.
struct BundledWalkDataTests {
    static let start = Walk.Point(lat: 40.6731, lon: -73.9860)
    static let ninthSt = Walk.Point(lat: 40.670538, lon: -73.988778)

    /// A few blocks in Park Slope route on the graph, not far round, with every crossing's light.
    @Test func routesAShortWalk() async throws {
        let result = await WalkGraphStore.shared.walk(from: Self.start, to: Self.ninthSt, options: WalkRouter.Options())
        let walk = try result.get()
        let straight = Self.start.metres(to: Self.ninthSt)
        #expect(!walk.steps.isEmpty)
        #expect(walk.meters >= straight * 0.95)
        #expect(walk.meters <= straight * WalkRouting.furthestTimes + WalkRouting.furthestMore)
        #expect(walk.seconds > 0)
        #expect(walk.crossings?.count == walk.lights?.count)
        // It starts and ends by where it was asked
        #expect(try #require(walk.points.first).metres(to: Self.start) < 60)
        #expect(try #require(walk.points.last).metres(to: Self.ninthSt) < 60)
        // A crossing's own step says it's a crossing
        for step in walk.steps where step.turn == .cross {
            #expect(step.instruction.hasPrefix("Cross "), "\(step.instruction)")
        }
    }

    /// Short walks go on the shared store; ones over 3 km on their own, so they don't hold up the short ones.
    @Test func longWalksOnTheirOwnStore() {
        #expect(WalkGraphStore.store(from: Self.start, to: Self.ninthSt) === WalkGraphStore.shared)
        let farOff = Walk.Point(lat: 40.70, lon: -73.99)
        #expect(Self.start.metres(to: farOff) > WalkGraphStore.longWalk)
        #expect(WalkGraphStore.store(from: Self.start, to: farOff) === WalkGraphStore.long)
    }

    /// The walk to the train ends with its way down, shown short and said in full.
    @MainActor
    @Test func walkToTheTrainEndsWithTheWayDown() async throws {
        let start = CLLocation(latitude: Self.start.lat, longitude: Self.start.lon)
        let boarding = try #require(StationWays.boarding(WalkFixture.selection, from: start))
        // Routed on the graph as the app would, so Apple Maps isn't asked
        let options = WalkRouting.options
        let to = Walk.Point(boarding.location.coordinate)
        let routed = try await WalkGraphStore.shared.walk(from: Self.start, to: to, options: options).get()
        try #require(routed.meters <= Self.start.metres(to: to) * WalkRouting.furthestTimes + WalkRouting.furthestMore)
        let walk = try await WalkingDirections.walk(from: start, to: boarding)
        let last = try #require(walk.steps.last)
        #expect(last.turn == .stairsDown)
        #expect(last.instruction == boarding.down.instruction)
        #expect(last.spoken == boarding.down.spoken)
        #expect(last.instruction.hasPrefix("Down the stairs, "))
        #expect(last.spoken?.hasPrefix("Down the stairs at the ") == true)
    }

    /// Where a platform's sides aren't joined (Union St), the way down's said with its train and shown "only".
    @Test func oneSidedEntranceSaysItsTrain() throws {
        let union = Selection(stationID: "R32", routes: ["R"], direction: .north)
        let way = try #require(StationWays.boarding(union, from: CLLocation(latitude: 40.6772, longitude: -73.9828)))
        #expect(way.isOneSide)
        #expect(way.down.detail == "Manhattan-bound only")
        #expect(way.down.instruction.hasPrefix("Down the stairs, "))
        #expect(way.down.spoken?.hasSuffix(" for the Manhattan-bound R train") == true)
        #expect(way.down.instruction.contains("for the") == false)
    }

    /// GPS inside the Empire State Building, or mid-block in Park Slope, is indoors.
    @Test func indoorsInsideABlock() async {
        #expect(await SidewalkStore.shared.isIndoors(Walk.Point(lat: 40.74844, lon: -73.98566)))
        #expect(await SidewalkStore.shared.isIndoors(Walk.Point(lat: 40.6715, lon: -73.9885)))
    }

    /// On the sidewalk, or in the street, isn't indoors.
    @Test func outdoorsOnTheStreet() async {
        #expect(await !SidewalkStore.shared.isIndoors(Walk.Point(lat: 40.6715, lon: -73.98797)))
        #expect(await !SidewalkStore.shared.isIndoors(Walk.Point(lat: 40.6715, lon: -73.98785)))
    }

    /// 4th Ave's two sidewalks are different ones, as the walk moves over to yours.
    @Test func acrossTheAvenueIsAnotherSidewalk() async {
        let west = Walk.Point(lat: 40.6715, lon: -73.98797), east = Walk.Point(lat: 40.6715, lon: -73.98746)
        #expect(await SidewalkStore.shared.differentSidewalks(west, east))
        #expect(await !SidewalkStore.shared.differentSidewalks(west, west))
    }

    /// In the street between them isn't on a sidewalk, so not counted as another.
    @Test func inTheStreetIsntAnotherSidewalk() async {
        let west = Walk.Point(lat: 40.6715, lon: -73.98797), street = Walk.Point(lat: 40.6715, lon: -73.98785)
        #expect(await !SidewalkStore.shared.differentSidewalks(west, street))
    }

    /// The crossing's street from the geocoder's address: house numbers off, a park's name not a street.
    @Test func crossStreetFromAddress() {
        #expect(CrossStreets.street(in: "245–261 6th St, Brooklyn") == "6th St")
        #expect(CrossStreets.street(in: "37-12 82nd St") == "82nd St")
        #expect(CrossStreets.street(in: "12A Main St") == "Main St")
        #expect(CrossStreets.street(in: "5th Ave") == "5th Ave")
        #expect(CrossStreets.street(in: "Broadway, New York") == "Broadway")
        #expect(CrossStreets.street(in: "Strawberry Fields") == nil)
        #expect(CrossStreets.street(in: nil) == nil)
    }

    /// Halfway over a crossing.
    @Test func crossingMiddle() throws {
        let middle = try #require(CrossStreets.middle(of: [Walk.Point(lat: 40, lon: -74), Walk.Point(lat: 40.002, lon: -73.998)]))
        #expect(abs(middle.lat - 40.001) < 1e-9)
        #expect(abs(middle.lon + 73.999) < 1e-9)
        #expect(CrossStreets.middle(of: []) == nil)
    }

    /// Each way of routing gets its own cache value: preference, step-free, and time of night.
    @Test func routingCacheValuesDiffer() {
        var seen: [Int: WalkRouter.Options] = [:]
        for preference in WalkPreference.allCases {
            for stepFree in [false, true] {
                for hour in 0..<24 {
                    var options = WalkRouter.Options()
                    options.preference = preference
                    options.stepFree = stepFree
                    options.time = WalkRouter.Options.Time(hour: hour)
                    let value = WalkRouting.cacheValue(options)
                    if let other = seen[value] {
                        #expect(other == options, "\(value)")
                    }
                    seen[value] = options
                }
            }
        }
        #expect(Set(seen.keys).count == 3 * 2 * 4)
    }

    /// Apple Maps' throttling and the network are said as such; no route is just no trip.
    @Test func mapsTroubleKinds() {
        #expect(MapsTrouble(MKError(.loadingThrottled)) == .busy)
        #expect(MapsTrouble(MKError(.serverFailure)) == .unreachable)
        #expect(MapsTrouble(URLError(.notConnectedToInternet)) == .unreachable)
        let wrapped = NSError(domain: MKErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError])
        #expect(MapsTrouble(wrapped) == .unreachable)
        #expect(MapsTrouble(MKError(.directionsNotFound)) == nil)
    }
}

// MARK: - The train on the map

/// Where the train you're on is shown, by its times and the station fixes, without GPS following.
@MainActor
struct RideTrackerTests {
    nonisolated static let boarded = Fixtures.date("2025-06-02 08:00")
    nonisolated static let rideTime: TimeInterval = 12 * 60

    static func tracker(train time: Date = boarded) async throws -> RideTracker {
        let courtSt = try #require(StationDirectory.station(id: "R28"))
        let train = Arrival(route: "R", time: time, stop: "R33N", lastStop: "G08N", isLive: true, trip: "ride")
        let ride = RideTracker(train: train, to: courtSt, live: nil, arrives: time.addingTimeInterval(rideTime))
        await ride.build()
        try #require(ride.stops.count >= 3, "the R from 4 Av-9 St to Court St has stops between")
        return ride
    }

    static func at(_ stop: RideTracker.Stop, accuracy: Double = 20, time: Date) -> CLLocation {
        CLLocation(coordinate: stop.coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: time)
    }

    static func starts(_ ride: RideTracker) -> [Date] { ride.times().flatMap { [$0.arrives, $0.leaves] } }

    /// Before its stops are found there's nowhere to put it.
    @Test func nothingBeforeBuilt() throws {
        let courtSt = try #require(StationDirectory.station(id: "R28"))
        let ride = RideTracker(train: WalkFixture.train(leaves: Self.boarded), to: courtSt, live: nil, arrives: nil)
        #expect(ride.place() == nil)
        #expect(ride.times().isEmpty)
        #expect(ride.nextCheck() == nil)
        #expect(ride.path.isEmpty)
    }

    /// Its stops run from yours to where you get off, along the line's track.
    @Test func stopsFromYoursToTheEnd() async throws {
        let ride = try await Self.tracker()
        let courtSt = try #require(StationDirectory.station(id: "R28"))
        #expect(ride.stops.first?.id == "R33N")
        #expect(StationDirectory.stops(inComplexOf: courtSt).contains(try #require(ride.stops.last?.id)))
        #expect(ride.path.count >= ride.stops.count - 1)
    }

    /// Its times run forward, from boarding to the countdown's arrival where you get off.
    @Test func timesRunForwardToTheArrival() async throws {
        let ride = try await Self.tracker()
        let times = ride.times()
        #expect(times.first?.arrives == Self.boarded)
        #expect(times.last?.arrives == Self.boarded.addingTimeInterval(Self.rideTime))
        for (index, time) in times.enumerated() {
            #expect(time.arrives <= time.leaves)
            if index > 0 { #expect(times[index - 1].leaves <= time.arrives) }
        }
    }

    /// At your station before it leaves, at the end once it's due there, between stations meanwhile.
    @Test func placeByTimes() async throws {
        let ride = try await Self.tracker()
        #expect(ride.place(at: Self.boarded.addingTimeInterval(-60))?.description == "At \(ride.stops[0].name)")
        let last = try #require(ride.stops.last)
        #expect(ride.place(at: Self.boarded.addingTimeInterval(Self.rideTime + 300))?.description == "At \(last.name)")
        let middle = try #require(ride.place(at: Self.boarded.addingTimeInterval(Self.rideTime / 2)))
        #expect(middle.description.hasPrefix("At ") || middle.description.hasPrefix("Between "))
    }

    /// The feed's train stopped at a station puts it there, just after it came.
    @Test func feedPositionStopped() async throws {
        let ride = try await Self.tracker()
        let stop = ride.stops[2]
        ride.update(live: Arrival(route: "R", time: Self.boarded, stop: "R28N", lastStop: "G08N", isLive: true, trip: "ride",
                                  position: Arrival.Position(stop: stop.id, isStopped: true)), arrives: nil)
        #expect(ride.place(at: Self.boarded.addingTimeInterval(30))?.description == "At \(stop.name)")
    }

    /// The feed's train on its way to a station puts it just short of it.
    @Test func feedPositionMoving() async throws {
        let ride = try await Self.tracker()
        try #require(ride.stops.count >= 4)
        ride.update(live: Arrival(route: "R", time: Self.boarded, stop: "R28N", lastStop: "G08N", isLive: true, trip: "ride",
                                  position: Arrival.Position(stop: ride.stops[3].id, isStopped: false)), arrives: nil)
        #expect(ride.place(at: Self.boarded.addingTimeInterval(30))?.description
                == "Between \(ride.stops[2].name) and \(ride.stops[3].name)")
    }

    /// A station fix moves the train there, it and the stops after timed from it.
    @Test func stationFixMovesTheTimes() async throws {
        let ride = try await Self.tracker()
        let before = ride.times()
        let fixed = Self.boarded.addingTimeInterval(60)
        ride.check(Self.at(ride.stops[2], time: fixed), for: 2)
        let after = ride.times()
        #expect(after[2].arrives.timeIntervalSince(fixed) <= 0.001)
        #expect(fixed.timeIntervalSince(after[2].leaves) <= 0.001)
        // Those before untouched
        #expect(after[0].arrives == before[0].arrives)
        #expect(after[1].arrives == before[1].arrives)
        // Not checked again
        #expect(ride.nextCheck(after: .distantPast).map(\.index) != 2)
    }

    /// A station with no fix is checked once, and the next check is the station after.
    @Test func missedFixMovesOnToTheNextStation() async throws {
        let ride = try await Self.tracker()
        #expect(ride.nextCheck(after: .distantPast)?.index == 1)
        ride.check(nil, for: 1)
        #expect(ride.nextCheck(after: .distantPast)?.index == 2)
        for index in ride.stops.indices { ride.check(nil, for: index) }
        #expect(ride.nextCheck(after: .distantPast) == nil)
    }

    /// Where you got on at a station up the line puts the train there.
    @Test func boardedUpTheLine() async throws {
        let ride = try await Self.tracker()
        let fixed = Self.boarded.addingTimeInterval(200)
        ride.locate(Self.at(ride.stops[2], time: fixed))
        let after = ride.times()
        #expect(after[2].arrives.timeIntervalSince(fixed) <= 0.001)
        #expect(fixed.timeIntervalSince(after[2].leaves) <= 0.001)
    }

    /// Where you got on at your own station leaves it to its times.
    @Test func boardedAtYourOwnStation() async throws {
        let ride = try await Self.tracker()
        let before = Self.starts(ride)
        ride.locate(Self.at(ride.stops[0], time: Self.boarded.addingTimeInterval(-600)))
        #expect(Self.starts(ride) == before)
        #expect(ride.nextCheck(after: .distantPast)?.index == 1)
    }
}

// MARK: - Spoken directions

/// Instructions as they're said, not read.
struct SpokenTextTests {
    /// A street's direction, number and kind, said in full.
    @Test func turnOntoNumberedStreet() {
        #expect(SpokenText.spoken("Take a right onto W 43rd St") == "Take a right onto West forty-third Street")
    }

    /// The way down's corner and crossing, as in the project's example.
    @Test func wayDownCorner() {
        #expect(SpokenText.spoken("Down the stairs at the NW corner of 4 Av & 9 St")
                == "Down the stairs at the northwest corner of fourth Avenue and ninth Street")
    }

    /// Distances in words, and the shown pause after them.
    @Test func distances() {
        #expect(SpokenText.spoken("In 150 ft, take a right") == "In one hundred fifty feet, take a right")
        #expect(SpokenText.spoken("In 0.2 mi, take a left") == "In point two miles, take a left")
        #expect(SpokenText.spoken("1.5 km") == "one point five kilometers")
    }

    /// A station's two names with a pause, not "Avenue dash".
    @Test func stationNames() {
        #expect(SpokenText.spoken("4 Av-9 St") == "fourth Avenue, ninth Street")
        #expect(SpokenText.spoken("Bed-Stuy") == "Bed-Stuy")
    }

    /// St as Saint before a name, Dr as Doctor; else Street and Drive.
    @Test func saintAndDoctor() {
        #expect(SpokenText.spoken("St Marks Pl") == "Saint Marks Place")
        #expect(SpokenText.spoken("Dr Martin Luther King Jr Blvd") == "Doctor Martin Luther King Junior Boulevard")
        #expect(SpokenText.spoken("Riverside Dr") == "Riverside Drive")
    }

    /// Lines' letters and lettered avenues stay letters; a compass point alone is said as one.
    @Test func lettersStayLetters() {
        #expect(SpokenText.spoken("the N train") == "the N train")
        #expect(SpokenText.spoken("Avenue N") == "Avenue N")
        #expect(SpokenText.spoken("Ave J") == "Avenue J")
        #expect(SpokenText.spoken("Head W") == "Head west")
    }

    /// Clock times and minutes.
    @Test func timesAndMinutes() {
        #expect(SpokenText.spoken("8:05 AM") == "eight oh five A M")
        #expect(SpokenText.spoken("8:00") == "eight o'clock")
        #expect(SpokenText.spoken("12:30 pm") == "twelve thirty P M")
        #expect(SpokenText.spoken("3 min") == "three minutes")
        #expect(SpokenText.spoken("1 min") == "one minute")
    }

    /// The light's note after a middle dot is its own sentence; a spaced dash a pause.
    @Test func lightNotePauses() {
        #expect(SpokenText.spoken("Then cross Ocean Pkwy · No light and wide crossing - watch for cars")
                == "Then cross Ocean Parkway. No light and wide crossing, watch for cars")
    }

    /// Words and punctuation, as the doc comment's example has them.
    @Test func tokens() {
        #expect(SpokenText.tokens(of: "4 Av-9 St, 3 min · No light")
                == ["4", "Av", ",", "9", "St", ",", "3", "min", ".", "No", "light"])
    }

    /// Ordinals, regular and not.
    @Test func ordinals() {
        #expect(SpokenText.ordinal(1) == "first")
        #expect(SpokenText.ordinal(2) == "second")
        #expect(SpokenText.ordinal(3) == "third")
        #expect(SpokenText.ordinal(12) == "twelfth")
        #expect(SpokenText.ordinal(20) == "twentieth")
        #expect(SpokenText.ordinal(21) == "twenty-first")
        #expect(SpokenText.ordinal(100) == "one hundredth")
        #expect(SpokenText.ordinal(112) == "one hundred twelfth")
    }

    /// Siri's line and direction: a named one "to", the MTA's compass fallback before.
    @Test func siriTrainNames() {
        #expect(Spoken.describe(line: "R", heading: "Manhattan") == "R to Manhattan")
        #expect(Spoken.describe(line: "R", heading: "Northbound") == "northbound R")
        #expect(Spoken.describe(line: "R", heading: "") == "R")
        #expect(Spoken.trainsPlural(line: "R", heading: "Manhattan") == "R trains to Manhattan")
        #expect(Spoken.trainsPlural(line: "G", heading: "Southbound") == "southbound G trains")
    }
}

// MARK: - The voice

/// How the walking voice is set and cut into phrases: no audio.
@MainActor
@Suite(.serialized)
struct WalkVoiceTests {
    static let keys = [WalkVoice.speaksKey, VoiceStyle.modelKey, VoiceStyle.voiceKey, VoiceStyle.speedKey,
                       VoiceStyle.pauseKey, VoiceStyle.pitchKey, VoiceStyle.deliveryKey]

    /// Runs `body` with the voice's settings cleared, then puts them back.
    static func withClearedSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let kept = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        defer { for (key, value) in zip(keys, kept) { defaults.set(value, forKey: key) } }
        try body()
    }

    /// Spoken directions are on until turned off.
    @Test func speaksByDefault() {
        Self.withClearedSettings {
            #expect(WalkVoice.speaks)
            WalkVoice.speaks = false
            #expect(!WalkVoice.speaks)
        }
    }

    /// Nothing picked, the voice is as shipped: the pack's model and voice, in one go.
    @Test func standardStyle() {
        Self.withClearedSettings {
            #expect(VoiceStyle.current == VoiceStyle.standard)
            #expect(!VoiceStyle.standard.phrased)
            #expect(VoiceStyle.standard.model.file == "kokoro.onnx")
        }
    }

    /// A bigger model picked without its file falls back to the pack's own.
    @Test func missingModelFallsBackToThePacks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var style = VoiceStyle.standard
        style.model = .fp32
        #expect(style.modelFile(in: folder) == "kokoro.onnx")
        try Data().write(to: folder.appending(path: "kokoro-fp32.onnx"))
        #expect(style.modelFile(in: folder) == "kokoro-fp32.onnx")
    }

    /// Pitch, put on as it plays, doesn't make audio made ahead stale; speed does.
    @Test func madeAheadKey() {
        var higher = VoiceStyle.standard
        higher.pitch = 200
        #expect(higher.key == VoiceStyle.standard.key)
        var quicker = VoiceStyle.standard
        quicker.speed = 1.2
        #expect(quicker.key != VoiceStyle.standard.key)
    }

    /// Phrases cut after each pause with a space after it; a decimal point stays.
    @Test func phrases() {
        #expect(VoiceStyle.phrases(of: "In one hundred fifty feet, take a right. Then cross")
                == ["In one hundred fifty feet,", "take a right.", "Then cross"])
        #expect(VoiceStyle.phrases(of: "0.2 miles") == ["0.2 miles"])
        #expect(VoiceStyle.phrases(of: "").isEmpty)
    }

    /// Each delivery's endings and pace.
    @Test func deliveries() {
        func said(_ delivery: VoiceStyle.Delivery, _ phrase: String, last: Bool) -> String {
            let (ending, speed) = delivery.say(phrase, last: last)
            return "\(ending.map(String.init) ?? "-") \(speed)"
        }
        #expect(said(.natural, "In 150 feet,", last: false) == ", 1.0")
        #expect(said(.natural, "take a right", last: true) == "- 1.0")
        #expect(said(.even, "anything", last: false) == ". 1.0")
        #expect(said(.lively, "take a right", last: true) == "! 0.96")
        #expect(said(.lively, "In 150 feet,", last: false) == ", 1.06")
    }
}

// MARK: - The Lock Screen's turn map

/// How the Lock Screen's map of the next turn is framed.
struct TurnMapTests {
    /// The way into a turn is from 30 m back: heading east into it is 90°.
    @Test func headingIntoTheTurn() throws {
        let path = [WalkFixture.p(0, 0), WalkFixture.p(100, 0)]
        let heading = try #require(TurnMap.heading(into: path[1], along: path))
        #expect(abs(heading - 90) < 0.5)
    }

    /// No heading for a turn not on the path, or one you're on top of.
    @Test func noHeadingWhenTooClose() {
        let path = [WalkFixture.p(0, 96), WalkFixture.p(0, 100)]
        #expect(TurnMap.heading(into: path[1], along: path) == nil)
        let elsewhere = WalkFixture.p(500, 500)
        #expect(TurnMap.heading(into: elsewhere, along: path) == nil)
    }

    /// Zoomed in as close as it goes at the turn, and out no further than 320 m top to bottom far from it.
    @Test func zoomBounds() {
        let turn = WalkFixture.p(0, 0)
        let near = TurnMap.Scene(path: [turn], turn: turn, heading: 0, end: turn, endsAtStairs: true)
        #expect(abs(TurnMap.metresPerPoint(for: near) - 60.0 / 78) < 1e-9)
        let you = WalkFixture.p(0, -2_000)
        let far = TurnMap.Scene(path: [you, turn], turn: turn, heading: 0, end: turn, endsAtStairs: false)
        #expect(TurnMap.metresPerPoint(for: far) == 2)
        #expect(abs(TurnMap.showsYouWithin - 2 * WalkState.mapHeight * (0.93 - 0.42)) < 1e-6)
    }
}

// MARK: - Following you, through the session's seam

/// A walk's location as a test has it: told what the session asks of it, and fed made-up fixes
/// through the session's own `moved` and `approximate`.
@MainActor
final class FakeFollower: WalkLocating {
    let coarse: Bool
    let moved: (CLLocation) -> Void
    let approximate: (Bool) -> Void
    private(set) var stopped = false
    private(set) var relaxed = false
    private(set) var idled = false

    init(coarse: Bool, moved: @escaping (CLLocation) -> Void, approximate: @escaping (Bool) -> Void) {
        self.coarse = coarse
        self.moved = moved
        self.approximate = approximate
    }

    func stop() { stopped = true }
    func relax() { relaxed = true }
    func idle() { idled = true }
    func wake() { idled = false }
}

/// A walk session started with fake location, no background session, no rounds of trains, and
/// its buzzes counted.
@MainActor
final class WalkHarness {
    let session: WalkSession
    private(set) var made: [FakeFollower] = []
    private(set) var alerts = 0

    init(_ session: WalkSession) {
        self.session = session
        session.usesBackgroundSession = false
        session.appIsActive = { true }
        session.makeFollower = { [unowned self] coarse, moved, approximate in
            let fake = FakeFollower(coarse: coarse, moved: moved, approximate: approximate)
            made.append(fake)
            return fake
        }
        session.onAlert = { [unowned self] in alerts += 1 }
        session.start(refreshing: false)
    }

    /// The latest best-accuracy follower, stopped or not.
    var walking: FakeFollower? { made.last { !$0.coarse } }
    var coarse: FakeFollower? { made.last { $0.coarse } }

    /// A fix at `point`, as just taken, and the session's tasks from it given a moment.
    func fix(_ point: Walk.Point, accuracy: Double = 5, at time: Date = .now) async {
        walking?.moved(WalkFixture.location(point, accuracy: accuracy, timestamp: time))
        await Self.settle()
    }

    func fix(lat: Double, lon: Double, accuracy: Double = 5) async {
        await fix(Walk.Point(lat: lat, lon: lon), accuracy: accuracy)
    }

    static func settle(_ milliseconds: Int = 60) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Whether `condition` comes true within `seconds`.
    func eventually(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let end = Date.now.addingTimeInterval(seconds)
        while Date.now < end {
            if condition() { return true }
            await Self.settle(50)
        }
        return condition()
    }

    /// Runs `body` with speech off, vibration as by default, and the saved walk put back after,
    /// no request reaching the network; the session stopped at the end.
    static func run(_ make: () throws -> WalkSession, _ body: (WalkHarness) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["walkSession", WalkVoice.speaksKey, WalkSession.vibratesKey]
        let kept = keys.map { defaults.object(forKey: $0) }
        defaults.set(false, forKey: WalkVoice.speaksKey)
        defaults.removeObject(forKey: WalkSession.vibratesKey)
        defer { for (key, value) in zip(keys, kept) { defaults.set(value, forKey: key) } }
        let harness = WalkHarness(try make())
        defer { harness.session.stop() }
        try await withNetwork { try await body(harness) }
    }
}

extension WalkFixture {
    /// Where the walk to the R at 4 Av-9 St goes in, from `start`.
    static func entrance() throws -> Walk.Point {
        Walk.Point(try #require(StationWays.boarding(selection, from: start)).location.coordinate)
    }

    /// A walk to the entrance, `o`: 150 m south, a right, 50 m east, a left, 150 m south and down.
    static func walkIn(to o: Walk.Point) throws -> Walk {
        let down = try #require(StationWays.boarding(selection, from: start)).down
        let steps = [
            Walk.Step(turn: .left, instruction: "Take a left onto 9th St", meters: 150,
                      points: [p(-50, 300, from: o), p(-50, 150, from: o)]),
            Walk.Step(turn: .right, instruction: "Take a right onto 4th Ave", meters: 50,
                      points: [p(-50, 150, from: o), p(0, 150, from: o)]),
            Walk.Step(turn: down.turn, instruction: down.instruction, spoken: down.spoken, meters: 150,
                      points: [p(0, 150, from: o), o]),
        ]
        return Walk(steps: steps, seconds: 350 / 1.3, meters: 350)
    }

    /// A walk to the train by `walkIn(to:)`, and its entrance.
    @MainActor
    static func walkingIn() throws -> (WalkSession, Walk.Point) {
        let o = try entrance()
        return (try session(toTrain: walkIn(to: o)), o)
    }

    /// Along 9th St's south sidewalk between 4th and 5th Ave, 60 m, by the bundled sidewalks.
    static let southSide = (Walk.Point(lat: 40.671052, lon: -73.9868), Walk.Point(lat: 40.670767, lon: -73.9862))
    /// Its north sidewalk, opposite: `t` of the way along the south side's first 20 m.
    static func northSide(_ t: Double) -> Walk.Point {
        Walk.Point(lat: 40.671180 - 0.000095 * t, lon: -73.9868 + 0.0002 * t)
    }

    /// Walking all the way along the south sidewalk, crossings known (none), so it can move over.
    @MainActor
    static func sidewalkWalk() -> WalkSession {
        let (a, b) = southSide
        let walk = Walk(steps: [Walk.Step(turn: .arrive, instruction: "Arrive at the end", meters: 60, points: [a, b])],
                        seconds: 45, meters: 60, crossings: [], lights: [])
        return WalkSession(walk: walk, endName: "The end", end: CLLocation(latitude: b.lat, longitude: b.lon))
    }
}

/// The live walk following you, fed made-up fixes through its seam: no location manager, no blue pill.
@MainActor
@Suite(.serialized)
struct WalkSessionLocationTests {
    /// Go follows you at best accuracy, and Precise Location turned off is noticed.
    @Test func followsAndNoticesApproximate() async throws {
        try await WalkHarness.run({ try WalkFixture.walkingIn().0 }) { harness in
            #expect(harness.session.isFollowing)
            #expect(harness.walking?.coarse == false)
            #expect(!harness.session.isKeptAwake)
            harness.walking?.approximate(true)
            await WalkHarness.settle()
            #expect(harness.session.isApproximate)
            harness.walking?.approximate(false)
            await WalkHarness.settle()
            #expect(!harness.session.isApproximate)
        }
    }

    /// A fix along the walk moves you along it: the next step is the one you're on.
    @Test func fixesMoveYouAlong() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(-25, 150, from: o))
            #expect(harness.session.nextStep?.instruction == "Take a right onto 4th Ave")
            #expect(abs((harness.session.progress?.toTurn ?? 0) - 25) < 1)
        }
    }

    /// One fix off the path isn't another way; the second is, and the walk's routed again from there.
    @Test func offRouteAfterTwoFixes() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        let original = session.walk
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(-50, 280, from: o))
            await harness.fix(WalkFixture.p(10, 250, from: o))
            await WalkHarness.settle(400)
            #expect(harness.session.walk == original)
            await harness.fix(WalkFixture.p(12, 245, from: o))
            #expect(await harness.eventually { harness.session.walk != original })
            #expect(harness.session.walk?.steps.last?.turn == .stairsDown)
            #expect(harness.session.stage == .toTrain)
        }
    }

    /// Three precise fixes on the street's other sidewalk move the walk over to it; two don't.
    @Test func otherSidewalkAfterThreePreciseFixes() async throws {
        let session = WalkFixture.sidewalkWalk()
        let original = session.walk
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.northSide(0.5))
            await harness.fix(WalkFixture.northSide(1))
            await WalkHarness.settle(400)
            #expect(harness.session.walk == original)
            await harness.fix(WalkFixture.northSide(1.5))
            #expect(await harness.eventually { harness.session.walk != original })
            #expect(harness.session.stage == .fromTrain)
        }
    }

    /// At the entrance before the walk's done, you're at the station, and GPS let down to rough fixes.
    @Test func atTheEntranceEarly() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(-50, 280, from: o))
            await harness.fix(o)
            #expect(harness.session.stage == .atStation)
            #expect(harness.session.isFollowing)
            #expect(harness.walking?.relaxed == true)
        }
    }

    /// Fixes up the line, past the station you walked to, put you on the train: location then
    /// coarse, to keep the app awake, and no longer following you.
    @Test func ridingPastTheStation() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            // By the station five minutes ago, as long as the ride up the line takes
            await harness.fix(WalkFixture.p(0, 100, from: o), at: .now.addingTimeInterval(-300))
            // DeKalb Av, two miles up the R
            await harness.fix(lat: 40.690635, lon: -73.981824)
            #expect(await harness.eventually { harness.session.stage == .riding })
            #expect(!harness.session.isFollowing)
            #expect(harness.walking?.stopped == true)
            #expect(harness.session.isKeptAwake)
            #expect(harness.coarse?.coarse == true)
            #expect(harness.coarse?.stopped == false)
            #expect(harness.session.walk == nil)
        }
    }

    /// A fix at the end's station, never having said you were on the train, has you off it and walking out.
    @Test func cameUpAtTheEnd() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(0, 100, from: o), at: .now.addingTimeInterval(-300))
            // Court St
            await harness.fix(lat: 40.6941, lon: -73.991777)
            #expect(await harness.eventually { harness.session.stage == .fromTrain })
            #expect(harness.session.isFollowing)
            #expect(!harness.session.isKeptAwake)
            #expect(harness.walking?.stopped == false)
        }
    }

    /// GPS inside a block setting off adds the way out to the platform time; once out, it's gone for good.
    @Test func indoorsAtTheStart() async throws {
        let o = try WalkFixture.entrance()
        let inside = Walk.Point(lat: 40.6731, lon: -73.9860), sidewalk = Walk.Point(lat: 40.6715, lon: -73.98797)
        let down = try #require(StationWays.boarding(WalkFixture.selection, from: WalkFixture.start)).down
        let walk = Walk(steps: [
            Walk.Step(turn: .left, instruction: "Take a left onto 4th Ave", meters: inside.metres(to: sidewalk),
                      points: [inside, sidewalk]),
            Walk.Step(turn: down.turn, instruction: down.instruction, meters: sidewalk.metres(to: o), points: [sidewalk, o]),
        ], seconds: 300, meters: inside.metres(to: sidewalk) + sidewalk.metres(to: o))
        let session = try WalkFixture.session(toTrain: walk)
        try await WalkHarness.run({ session }) { harness in
            let extra = { () -> TimeInterval in
                let now = Date.now
                return harness.session.onPlatform(now: now).timeIntervalSince(now) - harness.session.secondsLeft
            }
            #expect(abs(extra() - WalkSession.downToPlatform) < 0.01)
            await harness.fix(inside)
            #expect(await harness.eventually { harness.session.isIndoorsAtStart })
            #expect(abs(extra() - (WalkSession.downToPlatform + WalkSession.outOfBuilding)) < 0.01)
            await harness.fix(sidewalk)
            #expect(await harness.eventually { !harness.session.isIndoorsAtStart })
            #expect(abs(extra() - WalkSession.downToPlatform) < 0.01)
            // Back into a building as you pass: not looked for again
            await harness.fix(inside)
            await WalkHarness.settle(300)
            #expect(!harness.session.isIndoorsAtStart)
        }
    }

    /// The turn's buzz comes 20 m before it, once, and not again as the turn's made.
    @Test func turnAlertTwentyMetresBefore() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(-50, 230, from: o))
            #expect(harness.alerts == 0)
            await harness.fix(WalkFixture.p(-50, 175, from: o))
            #expect(harness.alerts == 0)
            await harness.fix(WalkFixture.p(-50, 165, from: o))
            #expect(harness.alerts == 1)
            await harness.fix(WalkFixture.p(-50, 160, from: o))
            #expect(harness.alerts == 1)
            // Round the corner: the new step's shown without a second buzz
            await harness.fix(WalkFixture.p(-25, 150, from: o))
            #expect(harness.session.nextStep?.instruction == "Take a right onto 4th Ave")
            #expect(harness.alerts == 1)
        }
    }

    /// Vibrate During Navigation off: no buzz at the turn.
    @Test func noAlertWithVibrationOff() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            UserDefaults.standard.set(false, forKey: WalkSession.vibratesKey)
            await harness.fix(WalkFixture.p(-50, 230, from: o))
            await harness.fix(WalkFixture.p(-50, 165, from: o))
            #expect(harness.alerts == 0)
        }
    }

    /// There, location stops: no following, nothing kept awake, the saved walk cleared.
    @Test func locationStopsOnArrival() async throws {
        let session = WalkFixture.sidewalkWalk()
        try await WalkHarness.run({ session }) { harness in
            #expect(UserDefaults.standard.data(forKey: "walkSession") != nil)
            await harness.fix(WalkFixture.southSide.1)
            #expect(harness.session.stage == .arrived)
            #expect(!harness.session.isFollowing)
            #expect(!harness.session.isKeptAwake)
            #expect(harness.walking?.stopped == true)
            #expect(UserDefaults.standard.data(forKey: "walkSession") == nil)
        }
    }

    /// In the background with the walk's countdown gone, location stops; opened again, it's back.
    @Test func locationStopsWhenTheCountdownsGone() async throws {
        try await WalkHarness.run({ try WalkFixture.walkingIn().0 }) { harness in
            guard !TrainActivityController.isWalking else { return }
            harness.session.appIsActive = { false }
            harness.session.leftUnseen()
            #expect(!harness.session.isFollowing)
            #expect(harness.walking?.stopped == true)
            harness.session.appIsActive = { true }
            harness.session.seenAgain()
            #expect(harness.session.isFollowing)
            #expect(harness.walking?.stopped == false)
        }
    }

    /// With the app open, the countdown's going doesn't stop location.
    @Test func openAppKeepsFollowing() async throws {
        try await WalkHarness.run({ try WalkFixture.walkingIn().0 }) { harness in
            harness.session.leftUnseen()
            #expect(harness.session.isFollowing)
        }
    }

    /// A re-route's walk to rejoin the way it was going is cached apart from one that isn't.
    @Test func cacheKeyIncludesTheRejoinPath() {
        let start = CLLocationCoordinate2D(latitude: 40.6731, longitude: -73.9860)
        let end = CLLocationCoordinate2D(latitude: 40.670538, longitude: -73.988778)
        let along = [WalkFixture.p(0, 0), WalkFixture.p(0, 100)]
        let plain = WalkingDirections.CacheKey(start, end, routing: 1)
        #expect(plain == WalkingDirections.CacheKey(start, end, along: [], routing: 1))
        #expect(plain != WalkingDirections.CacheKey(start, end, along: along, routing: 1))
        #expect(WalkingDirections.CacheKey(start, end, along: along, routing: 1)
                == WalkingDirections.CacheKey(start, end, along: along, routing: 1))
        #expect(WalkingDirections.CacheKey(start, end, along: along, routing: 1)
                != WalkingDirections.CacheKey(start, end, along: [WalkFixture.p(5, 0), WalkFixture.p(5, 100)], routing: 1))
        // Still to the nearest metre from, and 10 m to
        let nudged = CLLocationCoordinate2D(latitude: 40.6731 + 1e-6, longitude: -73.9860)
        #expect(plain == WalkingDirections.CacheKey(nudged, end, routing: 1))
        #expect(plain != WalkingDirections.CacheKey(start, end, routing: 2))
    }
}
