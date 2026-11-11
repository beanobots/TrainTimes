import Foundation
import Testing
@testable import TrainCore

/// A countdown's sign-up (`POST /activities`) from a saved route with a big plan: the app sends
/// its change and bus as a countdown keeps them (`forCountdown`), under the server's 4 KB.
struct CountdownSignUpTests {
    /// The app's `PushRegistration` (ios/App/PushServer.swift), as it encodes.
    private struct SignUp: Encodable {
        var token: String
        var environment: String
        var selection: Selection
        var trip: String
        var started: Date?
        var alertKinds: [Int]?
        var state: CountdownState?
        var change: Change?
        var widgetToken: String?
        var bus: BusChoice?
    }

    private let stop = BusStop(id: "308204", name: "5 AV/9 ST", latitude: 40.67, longitude: -73.98, direction: "N")

    /// Eight ways of three rides, each of three places to change.
    private var bigPlan: PlannedTrip {
        let ways = (0..<8).map { way in
            PlannedWay(rides: [
                [PlannedRide(bus: BusLeg(line: "B63", stop: stop, destination: "PIER 6 BKLYN BRIDGE PK via 5 AV",
                                         walkMinutes: way))],
                (0..<3).map { _ in
                    PlannedRide(train: Selection(stationID: "R33", routes: ["R", "N", "D"], direction: .north), walkMinutes: 5,
                                offStop: BusStop(id: "308201", name: "5 AV/7 ST", latitude: 40.67, longitude: -73.98))
                },
                (0..<3).map { _ in
                    PlannedRide(train: Selection(stationID: "D24", routes: ["N", "Q"], direction: .north), walkMinutes: 3,
                                offStationID: "R31")
                },
            ], endStop: stop, endWalk: 4, endStationID: "127")
        }
        return PlannedTrip(ways: ways, destinationID: "127")
    }

    private func signUp(change: Change?, bus: BusChoice?) throws -> Data {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let state = CountdownState(train: now + 300, trip: "123456_R..N", isLive: true, terminal: "Forest Hills-71 Av",
                                   following: [now + 600, now + 900], notice: "Delays", updated: now, route: "R",
                                   followingRoutes: ["R", "N"])
        let request = SignUp(token: String(repeating: "ab", count: 32), environment: "production",
                             selection: Selection(stationID: "R31", routes: ["R"], direction: .north),
                             trip: state.trip, started: now, alertKinds: [0, 1, 2, 3], state: state, change: change,
                             widgetToken: String(repeating: "cd", count: 32), bus: bus)
        return try JSONEncoder().encode(request)
    }

    @Test func aBigPlannedSignUpFitsUnder4KB() throws {
        var change = Change(stationID: "R30", routes: ["Q", "B"], direction: .north,
                            then: Change(stationID: "127", routes: ["GS"], direction: .north))
        change.planned = bigPlan
        // Without stripping, it wouldn't fit
        #expect(try signUp(change: change, bus: nil).count > AppContext.bodyLimit)
        let body = try signUp(change: change.forCountdown, bus: nil)
        #expect(body.count < AppContext.bodyLimit)
        // Still read as a planned change, its second change kept for alerts
        let request = try JSONDecoder().decode(RegistrationRequest.self, from: body)
        #expect(request.change?.planned?.ways.isEmpty == true)
        #expect(request.change?.then?.routes == ["GS"])
        #expect(request.change?.validated(for: request.selection) != nil)
    }

    @Test func aBigPlannedBusSignUpFitsUnder4KB() throws {
        var bus = BusChoice(line: "B63", stop: stop, destination: "PIER 6")
        bus.planned = bigPlan
        bus.changes = (0..<6).map { _ in
            BusChange(stop: stop, minutes: 12, walkMinutes: 3, selection: Selection(stationID: "R30", routes: ["Q"], direction: .north))
        }
        #expect(try signUp(change: nil, bus: bus).count > AppContext.bodyLimit)
        let body = try signUp(change: nil, bus: bus.forCountdown)
        #expect(body.count < AppContext.bodyLimit)
        let request = try JSONDecoder().decode(RegistrationRequest.self, from: body)
        #expect(request.bus?.planned == nil)
        #expect(request.bus?.changes == nil)
        #expect(request.bus?.stop == bus.stop && request.bus?.allLines == bus.allLines)
    }
}
