import Foundation
import Testing
@testable import TrainCore

/// What the widgets, the countdown, Siri and the alerts sheet say of a board's
/// alerts and elevators out (`Notice`), made one way for all of them.
@Suite struct NoticeTests {
    func outage(_ id: String, planned: Bool = false, accessible: Bool = true) -> Outage {
        Outage(id: id, isElevator: true, isAccessibilityElevator: accessible, serving: "Street to \(id) platform",
               reason: "", start: nil, estimatedReturn: nil, isPlanned: planned, alternative: "")
    }

    let delays = ServiceAlert(id: "1", kind: .delays, type: "Delays", header: "R trains are delayed", details: "",
                              period: nil, brief: AlertBrief(header: "[R] trains are delayed"),
                              markedHeader: "[R] trains are delayed")

    @Test func theElevatorsOutAreThoseSomeoneNeedsThatAreOutNow() throws {
        let board = Board(trains: [], alerts: nil, outages: [
            outage("a"), outage("planned", planned: true), outage("escalator", accessible: false), outage("c"),
        ])
        #expect(board.elevatorsOut.map(\.id) == ["a", "c"])
        #expect(Board(trains: [], alerts: nil, outages: nil).elevatorsOut.isEmpty)
        let notice = try #require(board.notice(includingElevators: true))
        #expect(notice == Notice(kind: .elevator, label: "2 elevators out", text: "Street to a platform", others: 0))
        #expect(Notice(elevatorsOut: []) == nil)
        #expect(Notice(elevatorsOut: [outage("a")])?.label == "Elevator out")
    }

    @Test func anAlertIsMentionedWithItsBriefAndMarkedHeadline() {
        let notice = Notice(delays)
        #expect(notice.kind == .alert(.delays))
        #expect(notice.label == "Delays")
        #expect(notice.text == "R trains are delayed")
        #expect(notice.others == 0)
        #expect(notice.brief == delays.brief)
        #expect(notice.markedText == "[R] trains are delayed")
        // As the board mentions it: after an elevator out, or alone
        let board = Board(trains: [], alerts: [delays], outages: [outage("a")])
        #expect(board.notice(includingElevators: true)
                == Notice(kind: .elevator, label: "Elevator out", text: "Street to a platform", others: 1))
        #expect(board.notice(includingElevators: false) == Notice(delays))
        #expect(board.notice(includingElevators: false, kinds: [.notice]) == nil)
    }

    @Test func nextTrainDoesntMentionALineChangedTo() {
        // Changing from the R to the D at Atlantic Av, while there's no D there
        let noD = ServiceAlert(id: "2", kind: .suspended, type: "Planned - Part Suspended",
                               header: "No D between 59 St-Columbus Circle and Atlantic Av-Barclays Ctr", details: "",
                               period: nil, brief: nil, markedHeader: "No [D] between 59 St-Columbus Circle and Atlantic Av-Barclays Ctr")
        let board = Board(trains: [], alerts: [noD], outages: [], ownAlerts: [])
        #expect(board.notice(includingElevators: false)?.label == "Suspended")
        #expect(board.withoutChange.notice(includingElevators: false) == nil)
        // The R's own still are
        let both = Board(trains: [], alerts: [noD, delays], outages: [], ownAlerts: [delays])
        #expect(both.withoutChange.notice(includingElevators: false) == Notice(delays))
    }

    @Test func aNoticesKindByItsLabel() {
        for kind in ServiceAlert.Kind.allCases {
            #expect(Notice.Kind(label: kind.label) == .alert(kind))
            #expect(Notice.Kind.alert(kind).label == kind.label)
        }
        #expect(Notice.Kind(label: "Elevator out") == .elevator)
        #expect(Notice.Kind(label: "3 elevators out") == .elevator)
        #expect(Notice.Kind.elevator.label == "Elevator out")
        // The countdown's own, and what no notice is called
        #expect(Notice.Kind(label: ActivityState.noTrains) == nil)
        #expect(Notice.Kind(label: "1 elevators out") == nil)
        #expect(Notice.Kind(label: "elevators out") == nil)
        #expect(Notice.Kind(label: "") == nil)
    }

    @Test func alertsAreWantedOnlyWhereTheyCanBeMentioned() {
        var settings = AppSettings()
        #expect(prospect.mentionsAlerts(with: settings))
        var quiet = prospect
        quiet.serviceAlerts = false
        #expect(!quiet.mentionsAlerts(with: settings))
        settings.alertKinds = []
        #expect(!prospect.mentionsAlerts(with: settings))
        // Where they can't be, the notice never names one
        #expect(fixtureBoard().notice(for: quiet, settings: AppSettings()) == nil)
        #expect(fixtureBoard().notice(for: prospect, settings: settings) == nil)
    }
}
