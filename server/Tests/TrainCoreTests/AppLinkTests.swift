import Foundation
import Testing
@testable import TrainCore

/// The app's own links, which the widgets open it with (`AppLink`), as a
/// train's links make and read them.
@Suite struct AppLinkTests {
    @Test func aTrainsLinksAreWrittenAsBefore() {
        #expect(prospect.alertsURL.absoluteString == "traintimes://alerts?station=R34&lines=R&direction=N&elevators=0")
        #expect(prospect.trainURL.absoluteString == "traintimes://train?station=R34&lines=R&direction=N&elevators=0")
        let change = Change(stationID: "R31", routes: ["D", "N"])
        #expect(prospect.transferURL(changingAt: change).absoluteString
                == "traintimes://transfer?station=R34&lines=R&direction=N&elevators=0&walk=0&change=R31&to=D,N&going=N")
    }

    @Test func aTrainsLinksOpenThatTrain() throws {
        let both = Selection(stationID: "R31", routes: ["N", "R"], direction: .south, elevatorAlerts: true)
        #expect(Selection(trainURL: both.trainURL) == both.validated())
        #expect(Selection(alertsURL: both.alertsURL) == both.validated())
        // Each only its own
        #expect(Selection(alertsURL: both.trainURL) == nil)
        #expect(Selection(trainURL: both.alertsURL) == nil)

        var walking = prospect
        walking.walkMinutes = 7
        let opened = try #require(Selection.transfer(from: walking.transferURL(changingAt: Change(stationID: "R31",
                                                                                              routes: ["D", "N"]))))
        #expect(opened.selection.walkMinutes == 7)
        #expect(opened.change.routes == ["D", "N"])
        #expect(Selection.transfer(from: prospect.trainURL) == nil)
    }

    @Test func onlyTheAppsOwnLinksAreRead() throws {
        let other = try #require(URL(string: "https://example.com/train?station=R34&lines=R&direction=N"))
        #expect(AppLink.query(of: other, to: "train") == nil)
        #expect(Selection(trainURL: other) == nil)
        let link = try #require(URL(string: "traintimes://station?id=R33&first=N,Q&id=R34"))
        #expect(AppLink.query(of: link, to: "train") == nil)
        let query = try #require(AppLink.query(of: link, to: "station"))
        // The first of two
        #expect(query["id"] == "R33")
        #expect(query.list("first") == ["N", "Q"])
        #expect(query.list("lines") == nil)
        #expect(query["lines"] == nil)
    }

    @Test func aLinksLists() {
        #expect(AppLink.list(["D", "N", "R"]) == "D,N,R")
        #expect(AppLink.list(["R"]) == "R")
        let url = AppLink.url(to: "station", query: [URLQueryItem(name: "first", value: AppLink.list(["N", "Q"]))])
        #expect(url?.absoluteString == "traintimes://station?first=N,Q")
    }
}
