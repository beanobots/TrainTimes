import Foundation
@testable import TrainCore

/// Prospect Av, R, toward Manhattan (the app's fallback train).
let prospect = Selection(stationID: "R34", routes: ["R"], direction: .north)

let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A train at Prospect Av's Manhattan-bound platform, `minutes` from now.
func arrival(_ minutes: Double, trip: String, route: String = "R", isLive: Bool = true,
             lastStop: String = "G08N") -> Arrival {
    Arrival(route: route, time: now.addingTimeInterval(minutes * 60), stop: "R34N", lastStop: lastStop,
            isLive: isLive, trip: trip)
}

/// Five trains, one already gone, with a service-change alert and an elevator out.
func fixtureBoard() -> Board {
    Board(
        trains: [
            arrival(-1, trip: "gone"),
            arrival(2, trip: "a"),
            arrival(6, trip: "b", isLive: false),
            arrival(9, trip: "c", route: "N", lastStop: "R01N"),
            arrival(15, trip: "d"),
        ],
        alerts: [
            ServiceAlert(id: "1", kind: .serviceChange, type: "Reroute", header: "Some R trains run via the N",
                         details: "", period: nil),
        ],
        outages: [
            Outage(id: "EL1", isElevator: true, isAccessibilityElevator: true, serving: "Street to platform",
                   reason: "Repair", start: nil, estimatedReturn: nil, isPlanned: false, alternative: ""),
        ]
    )
}

func state(train minutes: Double, trip: String = "a", following: [Double] = [6, 9], notice: String? = nil,
           isLive: Bool = true) -> ContentState {
    ContentState(train: now.addingTimeInterval(minutes * 60), trip: trip, isLive: isLive, terminal: "Forest Hills",
                 following: following.map { now.addingTimeInterval($0 * 60) }, notice: notice, updated: now,
                 route: "R", followingRoutes: following.map { _ in "R" })
}

let sampleToken = String(repeating: "ab12", count: 16)
