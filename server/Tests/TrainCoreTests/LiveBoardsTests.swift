import Foundation
import Testing
@testable import TrainCore

/// The push server's boards, made from the feeds as `Poller.liveBoards` reads
/// them, once for every countdown.
@Suite struct LiveBoardsTests {
    /// Canal St, toward uptown: its elevators go only to the 6's platforms.
    let canal6 = Selection(stationID: "R23", routes: ["6"], direction: .north, elevatorAlerts: true)
    let canalR = Selection(stationID: "R23", routes: ["R"], direction: .north, elevatorAlerts: true)

    /// The alerts feed with a delay on each of `routes`, all along the line.
    func alerts(_ routes: [String]) throws -> [AlertsFeed.Entry] {
        let entities = routes.map { route in
            #"{"id":"\#(route)","alert":{"informed_entity":[{"route_id":"\#(route)"}],"#
                + #""header_text":{"translation":[{"text":"\#(route) trains are delayed.","language":"en"}]},"#
                + #""transit_realtime.mercury_alert":{"alert_type":"Delays"}}}"#
        }
        let feed = #"{"entity":[\#(entities.joined(separator: ","))]}"#
        return try AlertsFeed.entries(in: Data(feed.utf8), now: now)
    }

    /// The outages feed with each of `equipment` out.
    func outages(_ equipment: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: equipment.map { ["equipment": $0, "isupcomingoutage": "N"] })
    }

    func boards(_ selections: [Selection], trains: [Selection: [Arrival]], alerts: [AlertsFeed.Entry]? = nil,
                outages: Data? = nil) -> [Selection: Board] {
        let byTrain = Dictionary(trains.map { ($0.key.trainID, $0.value) }, uniquingKeysWith: { a, _ in a })
        return Poller.boards(for: selections, trains: byTrain, alerts: alerts, outages: outages, now: now)
    }

    @Test func oneForEachSelectionWhoseTrainsCame() {
        let trains = [arrival(2, trip: "a"), arrival(6, trip: "b")]
        let boards = boards([prospect, canal6, prospect], trains: [prospect: trains])
        #expect(Array(boards.keys) == [prospect])
        #expect(boards[prospect]?.trains == trains)
    }

    @Test func eachHasItsOwnLinesAlertsOrNilWithoutThem() throws {
        let both = [prospect, canal6]
        let trains: [Selection: [Arrival]] = [prospect: [], canal6: []]
        let boards = boards(both, trains: trains, alerts: try alerts(["R", "6", "Q"]))
        #expect(boards[prospect]?.alerts?.map(\.id) == ["R"])
        #expect(boards[canal6]?.alerts?.map(\.id) == ["6"])
        // Couldn't be had, which isn't the same as none
        let without = self.boards(both, trains: trains)
        #expect(without.count == 2)
        #expect(without.values.allSatisfy { $0.alerts == nil })
    }

    @Test func outagesOnlyForThoseThatMentionElevators() throws {
        let canal6South = Selection(stationID: "R23", routes: ["6"], direction: .south, elevatorAlerts: true)
        var withElevators = prospect
        withElevators.elevatorAlerts = true
        let all = [prospect, withElevators, canal6, canal6South, canalR]
        let trains = Dictionary(all.map { ($0, [Arrival]()) }, uniquingKeysWith: { a, _ in a })
        let boards = boards(all, trains: trains, outages: try outages(["EL324", "EL325", "EL218"]))
        #expect(boards[prospect]?.outages == nil)
        // Prospect Av has only stairs
        #expect(boards[withElevators]?.outages?.isEmpty == true)
        // Both ways on the 6 get its platforms' elevators; the R, none of them
        #expect(boards[canal6]?.outages?.map(\.id).sorted() == ["EL324", "EL325"])
        #expect(boards[canal6South]?.outages?.map(\.id).sorted() == ["EL324", "EL325"])
        #expect(boards[canalR]?.outages?.isEmpty == true)

        // Without the feed, those with elevators can't say; no elevator serves the R's platform
        let without = self.boards(all, trains: trains)
        #expect(without[withElevators]?.outages?.isEmpty == true)
        #expect(without[canal6]?.outages == nil)
        #expect(without[canalR]?.outages?.isEmpty == true)
    }
}
