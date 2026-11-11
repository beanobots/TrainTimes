import CoreLocation
import Foundation
import Testing
@testable import Leeway

/// Lets the main actor's queued tasks (a location delegate's hop back to it) run.
@MainActor
private func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

// MARK: - A walk restored after iOS closed the app

/// Saved walks that are old, corrupt, past their time, or of stations gone.
@MainActor
@Suite(.serialized)
struct WalkRestoreAdversarialTests {
    static let key = "walkSession"

    /// Runs `body` with `data` saved as the walk, then puts back what was there.
    static func withSaved(_ data: Data?, _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let kept = defaults.data(forKey: key)
        defaults.set(data, forKey: key)
        defer { defaults.set(kept, forKey: key) }
        try body()
    }

    static func encoded(_ saved: WalkSession.Saved) throws -> Data { try JSONEncoder().encode(saved) }

    /// Bytes that aren't a walk read as none, not a crash.
    @Test func garbageIsNoWalk() {
        Self.withSaved(Data([0xFF, 0x00, 0x7B, 0x22])) {
            #expect(WalkSession.Saved.load() == nil)
        }
        Self.withSaved(Data("{}".utf8)) {
            #expect(WalkSession.Saved.load() == nil)
        }
    }

    /// A walk saved by an older version without a field now needed reads as none.
    @Test func oldDataMissingAFieldIsNoWalk() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Self.encoded(WalkSavedTests.saved())) as? [String: Any])
        object["onLockScreen"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WalkSession.Saved.self, from: old) }
        Self.withSaved(old) { #expect(WalkSession.Saved.load() == nil) }
    }

    /// A stage this version doesn't know reads as none.
    @Test func unknownStageIsNoWalk() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Self.encoded(WalkSavedTests.saved())) as? [String: Any])
        object["stage"] = "teleporting"
        let data = try JSONSerialization.data(withJSONObject: object)
        Self.withSaved(data) { #expect(WalkSession.Saved.load() == nil) }
    }

    /// Restoring a corrupt walk clears it and starts nothing.
    @Test func restoreClearsCorrupt() {
        guard ActiveWalk.shared.session == nil else { return }
        Self.withSaved(Data("not json".utf8)) {
            ActiveWalk.shared.restore()
            #expect(ActiveWalk.shared.session == nil)
            #expect(UserDefaults.standard.data(forKey: Self.key) == nil)
        }
    }

    /// A walk begun longer ago than its countdown lasts isn't carried on, and is cleared.
    @Test func restoreClearsExpired() throws {
        guard ActiveWalk.shared.session == nil else { return }
        let started = Date.now.addingTimeInterval(-TrainActivityController.walkLifetime - 60)
        try Self.withSaved(Self.encoded(WalkSavedTests.saved(started: started))) {
            ActiveWalk.shared.restore()
            #expect(ActiveWalk.shared.session == nil)
            #expect(UserDefaults.standard.data(forKey: Self.key) == nil)
        }
    }

    /// A walk to a station no longer in the app's list is cleared, not restored half-made.
    @Test func restoreClearsStationGone() throws {
        guard ActiveWalk.shared.session == nil else { return }
        var saved = try WalkSavedTests.saved()
        saved.destinationID = "NOPE"
        try Self.withSaved(Self.encoded(saved)) {
            ActiveWalk.shared.restore()
            #expect(ActiveWalk.shared.session == nil)
            #expect(UserDefaults.standard.data(forKey: Self.key) == nil)
        }
    }

    /// A trip saved without its walks, or a save with neither trip nor walk, makes no session.
    @Test func halfSavedMakesNoSession() throws {
        var noWalks = try WalkSavedTests.saved()
        noWalks.walks = nil
        #expect(WalkSession(saved: noWalks) == nil)
        let nothing = WalkSession.Saved(endName: "Nowhere", endLatitude: 40.7, endLongitude: -74, started: .now,
                                        stage: .toTrain, arrivals: [:], onLockScreen: true)
        #expect(WalkSession(saved: nothing) == nil)
    }

    /// A save that says it's arrived (never written so, but old data might be) has no walk to show.
    @Test func arrivedSaveHasNothingToShow() throws {
        let session = try #require(WalkSession(saved: try WalkSavedTests.saved(stage: .arrived)))
        #expect(session.walk == nil)
        #expect(session.nextStep == nil)
        #expect(session.liveState == nil)
        #expect(session.pathLeft.isEmpty)
    }
}

// MARK: - Odd walks and times

/// Walks with nothing in them, no time, and distances that aren't numbers.
@MainActor
struct WalkSessionAdversarialTests {
    /// A walk with no steps has no instruction and nothing for the Lock Screen.
    @Test func emptyWalk() {
        let session = WalkSession(walk: Walk(steps: [], seconds: 0, meters: 0), endName: "Here", end: WalkFixture.end)
        #expect(session.nextStep == nil)
        #expect(session.laterSteps.isEmpty)
        #expect(session.thenStep == nil)
        #expect(session.lightNote == nil)
        #expect(session.liveState == nil)
        #expect(session.secondsLeft == 0)
        #expect(session.pathLeft.isEmpty)
    }

    /// A walk with no time from Apple Maps is timed at the usual pace, not infinitely long.
    @Test func zeroSecondWalkUsesTheUsualPace() {
        let walk = Walk(steps: [WalkFixture.left], seconds: 0, meters: 133)
        let session = WalkSession(walk: walk, endName: "Here", end: WalkFixture.end)
        #expect(session.secondsLeft.isFinite)
        #expect(abs(session.secondsLeft - 100) < 0.01)
    }

    /// With no trains yet, none to catch nor missed.
    @Test func noTrainsYet() throws {
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.left))
        #expect(session.catchable(now: .now) == nil)
        #expect(session.missed(now: .now).isEmpty)
        #expect(session.trainArrives == nil)
        #expect(session.arrives == nil)
    }

    /// Only trains gone already: none to catch, and none counted as missed.
    @Test func allTrainsGone() throws {
        let now = Fixtures.date("2026-11-10 08:00")
        let trains = [WalkFixture.train(leaves: now.addingTimeInterval(-300)), WalkFixture.train(leaves: now.addingTimeInterval(-60))]
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: WalkFixture.left), trains: trains)
        #expect(session.catchable(now: now) == nil)
        #expect(session.missed(now: now).isEmpty)
    }

    /// Distances that aren't numbers, or are huge or below zero, give some text, not a crash.
    @Test func oddTurnDistances() {
        for metric in [false, true] {
            #expect(!WalkSession.turnDistance(.nan, metric: metric).isEmpty)
            #expect(!WalkSession.turnDistance(.infinity, metric: metric).isEmpty)
            #expect(!WalkSession.turnDistance(1e12, metric: metric).isEmpty)
            #expect(!WalkSession.turnDistance(-5, metric: metric).isEmpty)
        }
        #expect(WalkSession.turnDistance(0, metric: false) == "10 ft")
    }

    /// A crossing step with no way over has no street to name and no middle.
    @Test func crossingWithoutItsWayOver() throws {
        let step = Walk.Step(turn: .cross, instruction: "Cross the street", meters: 0, points: [WalkFixture.p(0, 0)],
                             light: .unsignalledWide, crossing: nil)
        let session = try WalkFixture.session(toTrain: WalkFixture.walk(first: step))
        #expect(session.instruction(of: step) == "Cross the street")
        #expect(session.lightNote == "No light and wide crossing - watch for cars")
    }
}

// MARK: - Places that aren't walks

/// The bundled walking graph and sidewalks asked about places outside the city, in the water, or not places at all.
struct WalkDataAdversarialTests {
    static let parkSlope = Walk.Point(lat: 40.6731, lon: -73.9860)

    /// NaN or infinite coordinates are no graph, not a crash counting their tiles.
    @Test func notANumberIsNoGraph() async {
        for bad in [Walk.Point(lat: .nan, lon: -73.98), Walk.Point(lat: 40.67, lon: .infinity)] {
            let result = await WalkGraphStore.shared.walk(from: bad, to: Self.parkSlope, options: WalkRouter.Options())
            #expect(result == .failure(.noGraph))
        }
    }

    /// CoreLocation's invalid coordinate (-180, -180) is no graph, not the box of tiles round most of the world.
    @Test func invalidCoordinateIsNoGraph() async {
        let invalid = Walk.Point(kCLLocationCoordinate2DInvalid)
        let result = await WalkGraphStore.long.walk(from: invalid, to: Self.parkSlope, options: WalkRouter.Options())
        #expect(result == .failure(.noGraph))
    }

    /// Walking from Los Angeles is too far to route.
    @Test func acrossTheCountryIsTooFar() async {
        let losAngeles = Walk.Point(lat: 34.05, lon: -118.24)
        let result = await WalkGraphStore.long.walk(from: losAngeles, to: Self.parkSlope, options: WalkRouter.Options())
        #expect(result == .failure(.tooFar))
    }

    /// From the middle of the Hudson, or out at sea, there's no walk.
    @Test func inTheWaterIsNoWalk() async {
        for water in [Walk.Point(lat: 40.7600, lon: -74.0120), Walk.Point(lat: 40.45, lon: -73.80)] {
            let result = await WalkGraphStore.store(from: water, to: Self.parkSlope)
                .walk(from: water, to: Self.parkSlope, options: WalkRouter.Options())
            #expect((try? result.get()) == nil, "\(water)")
        }
    }

    /// A walk from where you are to where you are, inside a building ~12 m from the sidewalk, is
    /// out to the street and back (~31 m), not round the block (200 m and more), and no crash.
    @Test func walkToWhereYouAre() async {
        #expect(await SidewalkStore.shared.isIndoors(Self.parkSlope))
        let result = await WalkGraphStore.shared.walk(from: Self.parkSlope, to: Self.parkSlope, options: WalkRouter.Options())
        if case let .success(walk) = result { #expect(walk.meters <= 60) }
    }

    /// Apple Maps' or the graph's walk from a place that isn't one throws rather than crashing.
    @Test func directionsFromNowhereThrow() async {
        let nyc = CLLocationCoordinate2D(latitude: 40.6731, longitude: -73.9860)
        for bad in [CLLocationCoordinate2D(latitude: .nan, longitude: -73.98), kCLLocationCoordinate2DInvalid,
                    CLLocationCoordinate2D(latitude: 40.67, longitude: -.infinity)] {
            await #expect(throws: (any Error).self) { try await WalkingDirections.walk(from: bad, to: nyc) }
            await #expect(throws: (any Error).self) { try await WalkingDirections.walk(from: nyc, to: bad) }
        }
    }

    /// Sidewalk questions about non-places, other cities and the water are all no.
    @Test func sidewalksOfNowhere() async {
        let west = Walk.Point(lat: 40.6715, lon: -73.98797)
        for bad in [Walk.Point(lat: .nan, lon: .nan), Walk.Point(lat: .infinity, lon: -73.98),
                    Walk.Point(lat: 34.05, lon: -118.24), Walk.Point(lat: 40.7600, lon: -74.0120)] {
            #expect(await !SidewalkStore.shared.isIndoors(bad), "\(bad)")
            #expect(await !SidewalkStore.shared.differentSidewalks(bad, west), "\(bad)")
            #expect(await !SidewalkStore.shared.differentSidewalks(west, bad), "\(bad)")
        }
    }

    /// Fitting a walk with no path and no ends gives nothing to fit.
    @Test func fitNothing() async {
        let fitted = await SidewalkStore.shared.fit(Walk(steps: [], seconds: 0, meters: 0), from: nil, to: nil)
        #expect(fitted == nil)
    }

    /// Fitting a walk off in Los Angeles finds no sidewalks to put it on.
    @Test func fitElsewhere() async {
        let la = Walk.Point(lat: 34.05, lon: -118.24), there = Walk.Point(lat: 34.051, lon: -118.24)
        let walk = Walk(steps: [Walk.Step(turn: .arrive, instruction: "Arrive", meters: 111, points: [la, there])],
                        seconds: 80, meters: 111)
        let fitted = await SidewalkStore.shared.fit(walk, from: la, to: there)
        #expect(fitted == nil || fitted?.meters == walk.meters)
    }
}

// MARK: - Bad fixes on the train

/// Station fixes on the ride that are rough, invalid, far off, or going backwards.
@MainActor
struct RideTrackerAdversarialTests {
    static func fix(_ coordinate: CLLocationCoordinate2D, accuracy: Double, at time: Date) -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: time)
    }

    /// A fix good only to over a kilometre, or marked invalid, changes nothing.
    @Test func roughAndInvalidFixesIgnored() async throws {
        let ride = try await RideTrackerTests.tracker()
        let before = RideTrackerTests.starts(ride)
        let time = RideTrackerTests.boarded.addingTimeInterval(30)
        ride.check(Self.fix(ride.stops[2].coordinate, accuracy: 1_500, at: time), for: 2)
        ride.check(Self.fix(ride.stops[3].coordinate, accuracy: -1, at: time), for: 3)
        #expect(RideTrackerTests.starts(ride) == before)
        ride.locate(Self.fix(ride.stops[2].coordinate, accuracy: 2_000, at: time))
        ride.locate(Self.fix(ride.stops[2].coordinate, accuracy: -1, at: time))
        #expect(RideTrackerTests.starts(ride) == before)
    }

    /// A fix that's jumped a kilometre off the line, or out of the city, changes nothing.
    @Test func farOffFixesIgnored() async throws {
        let ride = try await RideTrackerTests.tracker()
        let before = RideTrackerTests.starts(ride)
        let time = RideTrackerTests.boarded.addingTimeInterval(120)
        let stop = ride.stops[2].coordinate
        let jumped = CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude + 0.012)
        for place in [jumped, CLLocationCoordinate2D(latitude: 34.05, longitude: -118.24),
                      CLLocationCoordinate2D(latitude: 40.7600, longitude: -74.0120)] {
            ride.check(Self.fix(place, accuracy: 10, at: time), for: 2)
            ride.locate(Self.fix(place, accuracy: 10, at: time))
        }
        #expect(RideTrackerTests.starts(ride) == before)
    }

    /// A fix that isn't a number changes nothing, and doesn't crash.
    @Test func notANumberFixIgnored() async throws {
        let ride = try await RideTrackerTests.tracker()
        let before = RideTrackerTests.starts(ride)
        let nan = CLLocationCoordinate2D(latitude: .nan, longitude: .nan)
        ride.check(Self.fix(nan, accuracy: 10, at: RideTrackerTests.boarded), for: 1)
        ride.locate(Self.fix(nan, accuracy: 10, at: RideTrackerTests.boarded))
        #expect(RideTrackerTests.starts(ride) == before)
        #expect(ride.place(at: RideTrackerTests.boarded.addingTimeInterval(60)) != nil)
    }

    /// A fix at a station already passed doesn't take the train back to it.
    @Test func neverBackwards() async throws {
        let ride = try await RideTrackerTests.tracker()
        try #require(ride.stops.count >= 4)
        let later = RideTrackerTests.boarded.addingTimeInterval(240)
        ride.check(Self.fix(ride.stops[3].coordinate, accuracy: 20, at: later), for: 3)
        let afterFix = RideTrackerTests.starts(ride)
        ride.check(Self.fix(ride.stops[1].coordinate, accuracy: 20, at: later.addingTimeInterval(30)), for: 1)
        #expect(RideTrackerTests.starts(ride) == afterFix)
    }

    /// Long after it's due, it's held at the end, not run off the track.
    @Test func heldAtTheEnd() async throws {
        let ride = try await RideTrackerTests.tracker()
        let last = try #require(ride.stops.last)
        #expect(ride.place(at: .distantFuture)?.description == "At \(last.name)")
    }

    /// The feed's position for a station off the ride is ignored.
    @Test func feedPositionOffTheRide() async throws {
        let ride = try await RideTrackerTests.tracker()
        let now = RideTrackerTests.boarded.addingTimeInterval(-60)
        let before = ride.place(at: RideTrackerTests.boarded.addingTimeInterval(90))
        ride.update(live: Arrival(route: "R", time: now, stop: "R28N", lastStop: "G08N", isLive: true, trip: "ride",
                                  position: Arrival.Position(stop: "101N", isStopped: true)), arrives: nil)
        #expect(ride.place(at: RideTrackerTests.boarded.addingTimeInterval(90)) == before)
    }

    /// A refresh with nothing new leaves its times as they were.
    @Test func emptyRefreshKeepsTimes() async throws {
        let ride = try await RideTrackerTests.tracker()
        let before = RideTrackerTests.starts(ride)
        ride.update(live: nil, arrives: nil)
        #expect(RideTrackerTests.starts(ride) == before)
    }

    /// A train at a stop the app doesn't know has no stops to show, and no crash.
    @Test func unknownStop() async throws {
        let courtSt = try #require(StationDirectory.station(id: "R28"))
        let train = Arrival(route: "ZZ", time: RideTrackerTests.boarded, stop: "XX99N", lastStop: "XX00N", isLive: false)
        let ride = RideTracker(train: train, to: courtSt, live: nil, arrives: nil)
        await ride.build()
        #expect(ride.stops.allSatisfy { StationDirectory.station(forStop: $0.id) != nil })
        _ = ride.place(at: RideTrackerTests.boarded)
        _ = ride.nextCheck(after: .distantPast)
    }
}

// MARK: - Nearby's location

/// Nearby's location as its delegate is told of fixes, failures and Pretend Location, with no
/// location manager started.
@MainActor
@Suite(.serialized)
struct NearbyLocationAdversarialTests {
    static let timesSquare = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 40.758, longitude: -73.9855),
                                        altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 5, timestamp: .now)

    /// A fix becomes Nearby's location.
    @Test func fixTaken() async {
        let nearby = NearbyLocation()
        nearby.locationManager(CLLocationManager(), didUpdateLocations: [Self.timesSquare])
        await settle()
        #expect(nearby.location?.coordinate.latitude == 40.758)
        #expect(!nearby.failed)
    }

    /// A fix CoreLocation marks invalid (negative accuracy) doesn't replace a good one.
    @Test func invalidFixIgnored() async {
        let nearby = NearbyLocation()
        nearby.locationManager(CLLocationManager(), didUpdateLocations: [Self.timesSquare])
        await settle()
        let invalid = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), altitude: 0,
                                 horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: .now)
        nearby.locationManager(CLLocationManager(), didUpdateLocations: [invalid])
        await settle()
        #expect(nearby.location?.coordinate.latitude == 40.758)
        // The last good one of a batch, past an invalid one at its end
        nearby.locationManager(CLLocationManager(), didUpdateLocations: [Self.timesSquare, invalid])
        await settle()
        #expect(nearby.location?.coordinate.latitude == 40.758)
    }

    /// An empty batch changes nothing.
    @Test func emptyBatchIgnored() async {
        let nearby = NearbyLocation()
        nearby.locationManager(CLLocationManager(), didUpdateLocations: [])
        await settle()
        #expect(nearby.location == nil)
    }

    /// A failure with no fix yet says so; with an earlier fix, that's kept and it hasn't failed.
    @Test func failureOnlyWithoutAFix() async {
        let fresh = NearbyLocation()
        fresh.locationManager(CLLocationManager(), didFailWithError: CLError(.locationUnknown))
        await settle()
        #expect(fresh.failed)
        let located = NearbyLocation()
        located.locationManager(CLLocationManager(), didUpdateLocations: [Self.timesSquare])
        await settle()
        located.locationManager(CLLocationManager(), didFailWithError: CLError(.denied))
        await settle()
        #expect(!located.failed)
        #expect(located.location != nil)
    }

    /// While pretending, real fixes are ignored; and a ride's station check gets the pretend spot
    /// without starting a location manager.
    @Test func pretendLocationWins() async {
        let pretend = CLLocationCoordinate2D(latitude: 40.6838, longitude: -73.9788)
        PretendLocation.shared.set(pretend, name: "Test")
        defer { PretendLocation.shared.set(nil) }
        let nearby = NearbyLocation()
        nearby.locationManager(CLLocationManager(), didUpdateLocations: [Self.timesSquare])
        await settle()
        #expect(nearby.location == nil)
        let fix = await RideTracker.fix(within: 1)
        #expect(fix?.coordinate.latitude == pretend.latitude)
        #expect(fix?.coordinate.longitude == pretend.longitude)
    }
}

// MARK: - Spoken text

/// Text to be said that's empty, odd, huge or not English.
struct SpokenTextAdversarialTests {
    /// Nothing to say is nothing said.
    @Test func empty() {
        #expect(SpokenText.spoken("") == "")
        #expect(SpokenText.spoken("   ") == "")
        #expect(SpokenText.tokens(of: "").isEmpty)
    }

    /// Only punctuation comes out as one pause, not doubled.
    @Test func onlyPunctuation() {
        #expect(SpokenText.spoken(",,,") == ",")
        #expect(SpokenText.spoken(" · · ") == ".")
    }

    /// Numbers too big for an Int, or as big as one, don't crash.
    @Test func hugeNumbers() {
        #expect(SpokenText.spoken("99999999999999999999999 ft").hasSuffix("feet"))
        #expect(!SpokenText.spoken("\(Int.max) St").isEmpty)
        #expect(!SpokenText.ordinal(Int.max).isEmpty)
        #expect(!SpokenText.ordinal(-3).isEmpty)
    }

    /// A clock time that isn't one stays as written.
    @Test func notATime() {
        #expect(SpokenText.spoken("25:99") == "25:99")
        #expect(SpokenText.spoken("8:5") == "8:5")
    }

    /// Emoji, accents and other scripts pass through.
    @Test func unicode() {
        #expect(SpokenText.spoken("🚇 Café São Paulo 東京") == "🚇 Café São Paulo 東京")
    }

    /// A very long instruction is said whole.
    @Test func longText() {
        let text = Array(repeating: "Take a right onto W 43rd St", count: 500).joined(separator: ", ")
        let spoken = SpokenText.spoken(text)
        #expect(spoken.components(separatedBy: "West forty-third Street").count == 501)
    }

    /// Phrases of odd text: no spaces is one phrase, pauses alone are their own.
    @Test func oddPhrases() {
        #expect(VoiceStyle.phrases(of: "abc,def.ghi") == ["abc,def.ghi"])
        #expect(VoiceStyle.phrases(of: "   ").isEmpty)
    }
}

// MARK: - Turn map

/// The turn map with nothing much to frame.
struct TurnMapAdversarialTests {
    /// No path: no heading, and the closest zoom.
    @Test func emptyPath() {
        let turn = WalkFixture.p(0, 0)
        #expect(TurnMap.heading(into: turn, along: []) == nil)
        let scene = TurnMap.Scene(path: [], turn: turn, heading: 0, end: turn, endsAtStairs: true)
        #expect(abs(TurnMap.metresPerPoint(for: scene) - 60.0 / 78) < 1e-9)
    }

    /// You 50 km off (a GPS jump), it zooms out no further than its farthest.
    @Test func gpsJumpCapsTheZoom() {
        let turn = WalkFixture.p(0, 0)
        for heading in [0.0, 45, 90, 180, 270, 359] {
            let scene = TurnMap.Scene(path: [WalkFixture.p(50_000, -50_000), turn], turn: turn, heading: heading,
                                      end: turn, endsAtStairs: false)
            #expect(TurnMap.metresPerPoint(for: scene) == 2, "\(heading)")
        }
    }
}

// MARK: - Bad fixes while walking, through the session's seam

/// The live walk fed GPS that jumps, is rough or invalid, goes backwards, freezes, or comes after End.
@MainActor
@Suite(.serialized)
struct WalkSessionLocationAdversarialTests {
    /// GPS jumping a kilometre off and back, one fix at a time, never re-routes.
    @Test func kilometreJumpsDontReroute() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        let original = session.walk
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(-50, 280, from: o))
            await harness.fix(WalkFixture.p(1_000, 250, from: o))
            await harness.fix(WalkFixture.p(-50, 270, from: o))
            await harness.fix(WalkFixture.p(0, -1_000, from: o))
            // A jump past the station's end of the walk doesn't skip you on to the way down
            #expect(harness.session.nextStep?.instruction == "Take a left onto 9th St")
            await harness.fix(WalkFixture.p(-50, 260, from: o))
            await WalkHarness.settle(400)
            #expect(harness.session.walk == original)
            #expect(harness.session.stage == .toTrain)
            #expect(harness.session.isFollowing)
        }
    }

    /// A fix good only to 1.5 km, off the path, isn't counted as going another way.
    @Test func roughFixesDontReroute() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        let original = session.walk
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(10, 250, from: o), accuracy: 1_500)
            await harness.fix(WalkFixture.p(12, 245, from: o), accuracy: 1_500)
            await harness.fix(WalkFixture.p(14, 240, from: o), accuracy: 1_500)
            await WalkHarness.settle(400)
            #expect(harness.session.walk == original)
            #expect(harness.session.stage == .toTrain)
        }
    }

    /// Fixes marked invalid (negative accuracy) off the path don't re-route.
    @Test func invalidFixesDontReroute() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        let original = session.walk
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(10, 250, from: o), accuracy: -1)
            await harness.fix(WalkFixture.p(12, 245, from: o), accuracy: -1)
            await WalkHarness.settle(400)
            #expect(harness.session.walk == original)
        }
    }

    /// GPS dropping you two steps back doesn't take the instruction back to the first.
    @Test func walkingBackwardsKeepsTheStep() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(0, 75, from: o))
            let ahead = try #require(harness.session.nextStep)
            #expect(ahead.turn == .stairsDown)
            await harness.fix(WalkFixture.p(-50, 250, from: o))
            #expect(harness.session.nextStep?.instruction != "Take a left onto 9th St")
            // A few metres back on the same step stays on it
            await harness.fix(WalkFixture.p(0, 90, from: o))
            #expect(harness.session.nextStep == ahead)
        }
    }

    /// The same fix over and over, standing still on the path, changes nothing.
    @Test func frozenLocation() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        let original = session.walk
        try await WalkHarness.run({ session }) { harness in
            for _ in 0..<10 { await harness.fix(WalkFixture.p(-50, 250, from: o)) }
            #expect(harness.session.walk == original)
            #expect(harness.session.stage == .toTrain)
            #expect(harness.session.nextStep?.instruction == "Take a left onto 9th St")
            #expect(harness.alerts == 0)
        }
    }

    /// A fix that isn't a number doesn't crash or move you on; a real one after still gets you there.
    @Test func notANumberFix() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(Walk.Point(lat: .nan, lon: .nan))
            #expect(harness.session.stage == .toTrain)
            await harness.fix(o)
            #expect(harness.session.stage == .atStation)
        }
    }

    /// Fixes on the other sidewalk too rough to tell which, or broken by one, don't move the walk over.
    @Test func roughOtherSidewalkFixesDontMoveIt() async throws {
        let session = WalkFixture.sidewalkWalk()
        let original = session.walk
        try await WalkHarness.run({ session }) { harness in
            for t in [0.3, 0.6, 0.9] { await harness.fix(WalkFixture.northSide(t), accuracy: 15) }
            await harness.fix(WalkFixture.northSide(1.0))
            await harness.fix(WalkFixture.northSide(1.1))
            await harness.fix(WalkFixture.northSide(1.2), accuracy: 15)
            await harness.fix(WalkFixture.northSide(1.3))
            await WalkHarness.settle(400)
            #expect(harness.session.walk == original)
        }
    }

    /// After End, a fix already on its way is ignored, and location's stopped.
    @Test func fixAfterEnd() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            let follower = try #require(harness.walking)
            harness.session.stop()
            #expect(follower.stopped)
            #expect(!harness.session.isFollowing)
            follower.moved(WalkFixture.location(o))
            await WalkHarness.settle()
            #expect(harness.session.stage == .toTrain)
        }
    }

    /// Precise Location turned off mid-walk, then on again, is followed as it changes.
    @Test func permissionDowngradeMidWalk() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            await harness.fix(WalkFixture.p(-50, 280, from: o))
            harness.walking?.approximate(true)
            #expect(harness.session.isApproximate)
            // Rough fixes meanwhile, a few hundred metres out, don't re-route nor end it
            await harness.fix(WalkFixture.p(200, 250, from: o), accuracy: 500)
            await harness.fix(WalkFixture.p(-250, 250, from: o), accuracy: 500)
            #expect(harness.session.stage == .toTrain)
            #expect(harness.session.isFollowing)
            harness.walking?.approximate(false)
            #expect(!harness.session.isApproximate)
        }
    }

    /// One bad fix 1.2 km up the line, seconds after being by the station, sooner than a train
    /// could get there, doesn't board you: you're still walking to it, followed as before.
    @Test func oneJumpUpTheLineDoesntBoard() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            let now = Date.now
            await harness.fix(WalkFixture.p(0, 100, from: o), at: now.addingTimeInterval(-5))
            await harness.fix(WalkFixture.p(0, 1_300, from: o), at: now)
            await WalkHarness.settle(800)
            #expect(harness.session.stage == .toTrain)
            #expect(harness.session.isFollowing)
            #expect(!harness.session.isKeptAwake)
        }
    }

    /// The same fix up the line two minutes after being by the station, as a train could make it,
    /// does board you: on the train, location coarse.
    @Test func plausibleFixUpTheLineBoards() async throws {
        let (session, o) = try WalkFixture.walkingIn()
        try await WalkHarness.run({ session }) { harness in
            let now = Date.now
            await harness.fix(WalkFixture.p(0, 100, from: o), at: now.addingTimeInterval(-120))
            await harness.fix(WalkFixture.p(0, 1_300, from: o), at: now)
            #expect(await harness.eventually { harness.session.stage == .riding })
            #expect(!harness.session.isFollowing)
            #expect(harness.session.isKeptAwake)
        }
    }

    /// The fastest a fix up the line may have come from the station: a subway train's top speed.
    @Test func fastestTrainIsTheLimit() {
        #expect(WalkSession.fastestTrain == 25)
    }
}
