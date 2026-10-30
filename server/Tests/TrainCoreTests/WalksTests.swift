import CoreLocation
import Foundation
import Testing
@testable import TrainCore

/// The walks at either end of a trip: which entrance to go in by and which exit to leave by
/// (`StationWays`), the way down and up there, and each turn on the way (`Walk.Turn`).
@Suite struct WalksTests {
    func train(from origin: String, _ routes: [String], _ direction: Direction) -> Selection {
        Selection(stationID: origin, routes: routes, direction: direction)
    }

    /// Where to come out at `destination` off `selection`'s train, toward `end`.
    func leaving(_ selection: Selection, at destination: String, toward end: CLLocation) throws -> StationWays.Way? {
        StationWays.leaving(selection, change: nil, at: try #require(StationDirectory.station(id: destination)), toward: end)
    }

    // MARK: Turns

    @Test func aTurnIsNamedByHowFarItGoesRound() {
        #expect(Walk.Turn(from: 0, to: 90) == .right)
        #expect(Walk.Turn(from: 0, to: 270) == .left)
        #expect(Walk.Turn(from: 0, to: 30) == .slightRight)
        #expect(Walk.Turn(from: 355, to: 10) == .straight)
        #expect(Walk.Turn(from: 10, to: 210) == .sharpLeft)
        #expect(Walk.Turn(from: 90, to: 268) == .uTurn)
    }

    /// Apple Maps' words win over the angles where they say which way, as Broadway's slant
    /// makes going straight on across 42 St look like a right.
    @Test func theInstructionSaysWhichWay() {
        #expect(Walk.Turn.right.said(in: "Cross W 42nd St and continue straight") == .straight)
        #expect(Walk.Turn.slightRight.said(in: "Take a left onto Flatbush Ave") == .slightLeft)
        #expect(Walk.Turn.straight.said(in: "Take a right onto W 43rd St") == .right)
        #expect(Walk.Turn.sharpLeft.said(in: "Take a left") == .sharpLeft)
        #expect(Walk.Turn.left.said(in: "Head toward 4th Ave") == .left)
        // Only whole words say which way, not a street's name
        #expect(Walk.Turn.slightLeft.said(in: "Continue onto Brighton Beach Ave") == .straight)
        #expect(Walk.Turn.right.said(in: "Take a right onto Lefferts Blvd") == .right)
    }

    /// Up 4 Av to 7 St, then right along it.
    @Test func aStepsTurnIsFromTheWayThePathCameIn() {
        let up = [Walk.Point(lat: 40.6700, lon: -73.9880), Walk.Point(lat: 40.6710, lon: -73.9880),
                  Walk.Point(lat: 40.67100001, lon: -73.9880)]
        let along = [Walk.Point(lat: 40.6710, lon: -73.9880), Walk.Point(lat: 40.6710, lon: -73.9860)]
        #expect(Walk.turn(from: up, onto: along) == .right)
        #expect(Walk.turn(from: along.reversed(), onto: Array(up.reversed())) == .left)
        #expect(Walk.turn(from: [], onto: along) == .straight)
    }

    // MARK: Following a walk

    /// West along 7 St from near 5 Av, left down 4 Av to 9 St, then down the stairs: each step's
    /// instruction at the end of its path, as Apple Maps gives them.
    var parkSlope: Walk {
        let fifth = Walk.Point(lat: 40.6725, lon: -73.9840)
        let fourth = Walk.Point(lat: 40.6725, lon: -73.9880)
        let ninth = Walk.Point(lat: 40.6705, lon: -73.9880)
        return Walk(steps: [
            Walk.Step(turn: .left, instruction: "Take a left onto 4th Ave", meters: 337, points: [fifth, fourth]),
            Walk.Step(turn: .stairsDown, instruction: "Down the stairs", meters: 222, points: [fourth, ninth]),
        ], seconds: 420, meters: 559)
    }

    @Test func progressIsAlongTheStepYoureOn() throws {
        let walk = parkSlope
        // A third of the way along 7 St, a little off it
        let start = try #require(walk.progress(at: Walk.Point(lat: 40.67252, lon: -73.98533)))
        #expect(start.step == 0)
        #expect(abs(start.toTurn - 225) < 10)
        #expect(abs(start.left - 447) < 15)
        #expect(start.offPath < 5)
        // Halfway down 4 Av: the next turn's the stairs
        let down = try #require(walk.progress(at: Walk.Point(lat: 40.6715, lon: -73.9880), after: start.step))
        #expect(down.step == 1)
        #expect(abs(down.toTurn - 111) < 5)
        #expect(down.toTurn == down.left)
        // A block east of 4 Av and south of 7 St, 110 m from either
        let lost = try #require(walk.progress(at: Walk.Point(lat: 40.6715, lon: -73.9856)))
        #expect(lost.offPath > 100)
    }

    /// What's left to walk is drawn from where you are, part way along a step.
    @Test func thePathLeftStartsWhereYouAre() throws {
        let walk = parkSlope
        let left = walk.path(last: 300)
        #expect(left.count == 3)
        let start = try #require(left.first)
        // 78 m of 7 St to go, then all of 4 Av
        #expect(abs(start.metres(to: Walk.Point(lat: 40.6725, lon: -73.9880)) - 78) < 2)
        #expect(walk.path(last: 10_000).count == 3)
    }

    @Test func distancesAreInFeetThenMiles() {
        #expect(Walk.distance(76, metric: false) == "250 ft")
        #expect(Walk.distance(9, metric: false) == "30 ft")
        #expect(Walk.distance(480, metric: false) == "0.3 mi")
        #expect(Walk.distance(204, metric: true) == "200 m")
    }

    // MARK: Ways in and out

    /// Downtown from 23 St on the 6, the stairs are on Park Av's west side, so from the east side
    /// it's across the avenue, not down the nearer stairs to the Uptown side.
    @Test func theWayInIsToYourTrainsSide() throws {
        let east = CLLocation(latitude: 40.7398, longitude: -73.9852)
        let downtown = try #require(StationWays.boarding(train(from: "634", ["6"], .south), from: east))
        #expect(downtown.entrance.side == .south)
        #expect(downtown.down.detail == "Downtown-bound only")
        let uptown = try #require(StationWays.boarding(train(from: "634", ["6"], .north), from: east))
        #expect(uptown.entrance.side == .north)
        #expect(uptown.entrance.corner?.hasSuffix("E") != false)
    }

    @Test func theWayDownAndUpSayWhere() throws {
        let corner = CLLocation(latitude: 40.67055, longitude: -73.98880)
        let ninth = try #require(StationWays.boarding(train(from: "R33", ["R"], .north), from: corner))
        #expect(ninth.down.instruction == "Down the stairs at the NW corner of 4 Av & 9 St")
        // Its sides are joined, so the stairs aren't just for one
        #expect(ninth.down.detail == nil)
        #expect(ninth.down.turn == .stairsDown)
        let out = try #require(try leaving(train(from: "R16", ["R"], .south), at: "R33", toward: corner))
        #expect(out.up.instruction == "Up the stairs to the NW corner of 4 Av & 9 St")
    }

    /// Flushing-Main St's escalators by Main St & Roosevelt Av only go in.
    @Test func noWayOutIsByAnEntryOnlyEscalator() throws {
        let corner = CLLocation(latitude: 40.75997, longitude: -73.82860)
        let out = try #require(try leaving(train(from: "702", ["7"], .north), at: "701", toward: corner))
        #expect(out.entrance.entryOnly != true)
        let into = try #require(StationWays.boarding(train(from: "701", ["7"], .south), from: corner))
        #expect(into.entrance.entryOnly == true)
    }

    /// Off the R at Times Sq-42 St for W 43 St, out by the station's 42 St stairs, though they're
    /// listed under the 1 2 3; the R's own are at 40 St.
    @Test func theWayOutCanBeByAnotherPlatformsStairs() throws {
        let townHall = CLLocation(latitude: 40.7559, longitude: -73.9846)
        let out = try #require(try leaving(train(from: "R33", ["R"], .north), at: "R16", toward: townHall))
        #expect(out.entrance.streets?.contains("40 St") != true)
        #expect(out.location.distance(from: townHall) < 250)
        // Off the north end of the R's platform: the front of a train going north
        #expect(out.entrance.along == nil)
        #expect(out.part == .front)
    }

    /// Off a train to Brooklyn at 1 Av on the L, Avenue A's stairs are by its front.
    @Test func theWayOutSaysWhereToRide() throws {
        let avenueA = CLLocation(latitude: 40.7303, longitude: -73.9805)
        let out = try #require(try leaving(train(from: "L05", ["L"], .south), at: "L06", toward: avenueA))
        #expect(out.part == .front)
    }

    // MARK: The Lock Screen

    /// On the train, the app asleep: once it's due where you get off, the countdown says what
    /// to do next by itself, iOS redrawing it then (`staleDate`).
    @Test func onTheTrainTheWayUpShowsOnceItsDue() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let walk = WalkState(phase: .riding, symbol: "tram.fill", distance: "On the train",
                             instruction: "Get off at Times Sq-42 St", getOff: now.addingTimeInterval(600),
                             endName: "The Town Hall", next: "Up the stairs to the NE corner of Broadway & 41 St",
                             nextSymbol: "stairs", nextNote: "Tap for the turns to The Town Hall")
        let state = CountdownState(train: now.addingTimeInterval(-60), trip: "R", isLive: true, terminal: nil,
                                   following: [], notice: nil, updated: now, walk: walk)
        #expect(state.staleDate == now.addingTimeInterval(600))
        #expect(state.movedOn(at: now).walk == walk)
        let off = try #require(state.movedOn(at: now.addingTimeInterval(601)).walk)
        #expect(off.phase == .off)
        #expect(off.instruction == "Up the stairs to the NE corner of Broadway & 41 St")
        #expect(off.symbol == "stairs")
        #expect(off.detail == "Tap for the turns to The Town Hall")
    }

    /// Walking to the train, it's stale when the train is, as any countdown.
    @Test func walkingToTheTrainIsStaleWithTheTrain() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let walk = WalkState(phase: .toTrain, symbol: "arrow.up", distance: "250 ft", instruction: "Head north",
                             endName: "The Town Hall")
        let state = CountdownState(train: now.addingTimeInterval(300), trip: "R", isLive: true, terminal: nil,
                                   following: [], notice: nil, updated: now, walk: walk)
        #expect(state.staleDate == now.addingTimeInterval(300))
        #expect(state.movedOn(at: now.addingTimeInterval(400)).walk == walk)
    }
}
