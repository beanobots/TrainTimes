import Foundation
import Testing
@testable import TrainCore

/// `AlertsFeed` reading the MTA's alerts feed (GTFS-realtime as JSON) and
/// picking out a train's alerts.
@Suite struct AlertsFeedTests {
    /// An active_period from `start` to `end`, in minutes from now; nil leaves either out.
    func period(_ start: Double?, _ end: Double?) -> String {
        let seconds = { (minutes: Double) in String(Int(now.addingTimeInterval(minutes * 60).timeIntervalSince1970)) }
        let fields = [start.map { "\"start\":\(seconds($0))" }, end.map { "\"end\":\(seconds($0))" }].compactMap { $0 }
        return "{\(fields.joined(separator: ","))}"
    }

    /// An entity with an alert, in effect from an hour ago for two hours unless `periods` says otherwise.
    func alert(_ id: String, type: String = "Delays", header: String = "[R] trains are delayed.",
               informed: String = #"{"agency_id":"MTASBWY","route_id":"R"}"#, periods: [String]? = nil) -> String {
        let periods = periods ?? [period(-60, 60)]
        return """
            {"id":"\(id)","alert":{"active_period":[\(periods.joined(separator: ","))],
            "informed_entity":[\(informed)],
            "header_text":{"translation":[{"text":"\(header)","language":"en"},{"text":"<p>\(header)</p>","language":"en-html"}]},
            "description_text":{"translation":[{"text":"Expect longer waits.","language":"en"}]},
            "transit_realtime.mercury_alert":{"alert_type":"\(type)",
            "human_readable_active_period":{"translation":[{"text":"Until further notice","language":"en"}]}}}}
            """
    }

    func feed(_ entities: [String]) -> Data {
        Data(#"{"header":{"gtfs_realtime_version":"1.0"},"entity":[\#(entities.joined(separator: ","))]}"#.utf8)
    }

    func ids(for selection: Selection = prospect, in entities: [String], at time: Date = now) throws -> [String] {
        let entries = try AlertsFeed.entries(in: feed(entities), now: now)
        return AlertsFeed.alerts(for: selection, in: entries, now: time).map(\.id).sorted()
    }

    @Test func keepsWhatsInEffectNowOrWithinTheHour() throws {
        let entities = [
            alert("now"),
            alert("soon", periods: [period(30, 90)]),
            alert("later", periods: [period(120, 180)]),
            alert("over", periods: [period(-120, -60)]),
            alert("endsAtZero", periods: [#"{"start":0,"end":0}"#]),
            alert("noEnd", periods: [period(-60, nil)]),
            alert("noStart", periods: [period(nil, 60)]),
            alert("always", periods: []),
            alert("again", periods: [period(-180, -120), period(-10, 10)]),
            #"{"id":"notAnAlert"}"#,
        ]
        #expect(try ids(in: entities) == ["again", "always", "endsAtZero", "noEnd", "noStart", "now"])
        // Kept for later in the hour, when it's in effect
        #expect(try ids(in: entities, at: now.addingTimeInterval(45 * 60)).contains("soon"))
    }

    @Test func onlyThoseForTheTrainsLinesStationAndDirection() throws {
        let entities = [
            alert("line"),
            alert("otherLine", informed: #"{"route_id":"N"}"#),
            alert("station", informed: #"{"route_id":"R","stop_id":"R34"}"#),
            alert("platform", informed: #"{"route_id":"R","stop_id":"R34N"}"#),
            alert("otherPlatform", informed: #"{"route_id":"R","stop_id":"R34S"}"#),
            alert("otherStation", informed: #"{"route_id":"R","stop_id":"R33"}"#),
            // direction_id 0 is north
            alert("north", informed: #"{"route_id":"R","direction_id":0}"#),
            alert("south", informed: #"{"route_id":"R","direction_id":1}"#),
            alert("noLine", informed: #"{"agency_id":"MTASBWY","stop_id":"R34"}"#),
            alert("oneOfThem", informed: #"{"route_id":"N"},{"route_id":"R","stop_id":"R34N"}"#),
        ]
        #expect(try ids(in: entities) == ["line", "north", "oneOfThem", "platform", "station"])

        let lexington = Selection(stationID: "640", routes: ["6"], direction: .south)
        #expect(try ids(for: lexington, in: [alert("express", informed: #"{"route_id":"6X"}"#)]) == ["express"])
    }

    @Test func mostImportantFirst() throws {
        let entities = [
            alert("1", type: "Station Notice"),
            alert("2", type: "Planned - Stops Skipped"),
            alert("3", type: "Delays"),
            alert("4", type: "Suspended"),
            alert("5", type: "Extra Service"),
        ]
        let entries = try AlertsFeed.entries(in: feed(entities), now: now)
        // No trains at all before slow ones
        #expect(AlertsFeed.alerts(for: prospect, in: entries, now: now).map(\.kind)
            == [.suspended, .delays, .serviceChange, .notice, .notice])
    }

    @Test func kindsFromTheMTAsTypes() {
        #expect(AlertsFeed.kind(of: "Delays") == .delays)
        #expect(AlertsFeed.kind(of: "Severe Delays") == .delays)
        #expect(AlertsFeed.kind(of: "Part Suspended") == .suspended)
        #expect(AlertsFeed.kind(of: "Planned - Part Suspended") == .suspended)
        #expect(AlertsFeed.kind(of: "Planned - Reroute") == .serviceChange)
        #expect(AlertsFeed.kind(of: "Station Notice") == .notice)
        #expect(AlertsFeed.kind(of: "Special Schedule") == .notice)
    }

    @Test func itsWords() throws {
        let header = "[R] trains are running with delays [accessibility icon]"
        let entries = try AlertsFeed.entries(in: feed([alert("1", header: header)]), now: now)
        let alert = try #require(AlertsFeed.alerts(for: prospect, in: entries, now: now).first)
        #expect(alert.type == "Delays")
        #expect(alert.header == "R trains are running with delays")
        #expect(alert.markedHeader == "[R] trains are running with delays")
        #expect(alert.details == "Expect longer waits.")
        #expect(alert.period == "Until further notice")
        #expect(alert.brief?.routes == ["R"])

        let notice = try AlertsFeed.entries(in: feed([self.alert("2", type: "Station Notice")]), now: now)
        #expect(AlertsFeed.alerts(for: prospect, in: notice, now: now).first?.brief == nil)
    }

    @Test func theSameWordsWorkedOutAhead() throws {
        let header = "[N][R] trains are running with delays [accessibility icon]"
        let entries = try AlertsFeed.entries(in: feed([alert("1", header: header), alert("2", type: "Station Notice")]), now: now)
        let prepared = AlertsFeed.prepared(entries)
        #expect(AlertsFeed.alerts(for: prospect, in: prepared, now: now) == AlertsFeed.alerts(for: prospect, in: entries, now: now))
        #expect(AlertsFeed.alerts(for: prospect, in: prepared, now: now).map(\.header)
                == ["N and R trains are running with delays", "R trains are delayed."])
    }

    @Test func notTheFeedItWas() {
        #expect(throws: DecodingError.self) { try AlertsFeed.entries(in: Data(#"{"entity":{}}"#.utf8), now: now) }
    }
}
