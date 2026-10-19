import Foundation
import Testing
@testable import TrainCore

/// ActivityKit decodes content-state with a default JSONDecoder: dates are
/// seconds since 2001-01-01 (`.deferredToDate`), keys are the property names.
@Suite struct ContentStateEncodingTests {
    // 2026-05-07 21:46:40 UTC, as seconds since 2001 and since 1970
    let train = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let since1970 = 800_000_000 + 978_307_200

    func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try ContentState.encoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    var full: ContentState {
        ContentState(
            train: train, trip: "091200_R..N", isLive: true, terminal: "Forest Hills",
            following: [train.addingTimeInterval(300), train.addingTimeInterval(600.5)],
            notice: "Delays", updated: train.addingTimeInterval(-240),
            route: "R", followingRoutes: ["R", "N"]
        )
    }

    @Test func encodesTheAppsPropertyNamesAndDatesAsSecondsSince2001() throws {
        let json = try object(full)
        #expect(Set(json.keys) == ["train", "trip", "isLive", "terminal", "following", "notice", "updated",
                                   "route", "followingRoutes"])
        #expect(json["train"] as? Double == 800_000_000)
        #expect(json["updated"] as? Double == 799_999_760)
        #expect(json["following"] as? [Double] == [800_000_300, 800_000_600.5])
        #expect(json["trip"] as? String == "091200_R..N")
        #expect(json["isLive"] as? Bool == true)
        #expect(json["terminal"] as? String == "Forest Hills")
        #expect(json["notice"] as? String == "Delays")
        #expect(json["route"] as? String == "R")
        #expect(json["followingRoutes"] as? [String] == ["R", "N"])
    }

    @Test func leavesOutNilOptionalsAsSynthesizedCodableDoes() throws {
        var state = full
        state.terminal = nil
        state.notice = nil
        state.route = nil
        state.followingRoutes = nil
        let json = try object(state)
        #expect(Set(json.keys) == ["train", "trip", "isLive", "following", "updated"])
    }

    /// What the app's own `TrainActivityAttributes.ContentState` decodes from,
    /// written by hand: this must keep decoding, and encode back the same.
    @Test func roundTripsThePinnedFormat() throws {
        let pinned = """
            {"train":800000000,"trip":"091200_R..N","isLive":true,"terminal":"Forest Hills",\
            "following":[800000300,800000600.5],"notice":"Delays","updated":799999760,\
            "route":"R","followingRoutes":["R","N"]}
            """
        let decoded = try JSONDecoder().decode(ContentState.self, from: Data(pinned.utf8))
        #expect(decoded == full)
        let reencoded = try JSONSerialization.jsonObject(with: ContentState.encoder().encode(decoded)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(pinned.utf8)) as? NSDictionary
        #expect(reencoded == original)
    }

    @Test func pushPayloadHasUnixTimesOutsideAndActivityKitTimesInside() throws {
        let state = full
        let push = Push(token: "ab", environment: .sandbox, event: .update, state: state, priority: 10,
                        timestamp: train.addingTimeInterval(-240), staleDate: ActivityState.staleDate(for: state))
        let json = try object(APNSPusher.notification(for: push, topic: APNSConfig.defaultTopic))
        let aps = try #require(json["aps"] as? [String: Any])
        #expect(aps["event"] as? String == "update")
        #expect(aps["timestamp"] as? Int == since1970 - 240)
        #expect(aps["stale-date"] as? Int == since1970 + 120)
        #expect(aps["dismissal-date"] == nil)
        let contentState = try #require(aps["content-state"] as? [String: Any])
        #expect(contentState["train"] as? Double == 800_000_000)
    }

    @Test func endPayloadDismissesNow() throws {
        let now = train.addingTimeInterval(1000)
        let push = Push(token: "ab", environment: .production, event: .end, state: full, priority: 10,
                        timestamp: now, dismissalDate: now)
        let aps = try #require(try object(APNSPusher.notification(for: push, topic: "t"))["aps"] as? [String: Any])
        #expect(aps["event"] as? String == "end")
        #expect(aps["dismissal-date"] as? Int == since1970 + 1000)
        #expect(aps["stale-date"] == nil)
        #expect(aps["content-state"] != nil)
    }
}
