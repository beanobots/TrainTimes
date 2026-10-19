import APNSCore
import Foundation
import Testing
@testable import TrainCore

@Suite struct PusherTests {
    @Test func dropsOnlyTokensAPNsSaysAreGone() throws {
        let gone: [(Int, APNSError.ErrorReason)] = [
            (410, .unregistered), (410, .expiredToken), (400, .badDeviceToken), (400, .deviceTokenNotForTopic),
        ]
        for (status, reason) in gone {
            #expect(APNSPusher.result(status: status, reason: reason) == .invalidToken("\(status) \(reason.reason)"))
        }
        // The server's own problems, or APNs's, aren't the token's
        let kept: [(Int, APNSError.ErrorReason?)] = [
            (400, .topicDisallowed), (400, .badTopic), (403, .expiredProviderToken), (403, .invalidProviderToken),
            (429, .tooManyRequests), (500, .internalServerError), (503, .serviceUnavailable), (500, nil),
            (500, .unregistered),
        ]
        for (status, reason) in kept {
            #expect(APNSPusher.result(status: status, reason: reason)
                == .failed("APNs \(status) \(reason?.reason ?? "no reason given")"))
        }
        // As APNSwift reads APNs's answer
        let response = try JSONDecoder().decode(APNSErrorResponse.self, from: Data(#"{"reason":"DeviceTokenNotForTopic"}"#.utf8))
        let error = APNSError(responseStatus: 400, apnsResponse: response)
        #expect(APNSPusher.result(status: error.responseStatus, reason: error.reason) == .invalidToken("400 DeviceTokenNotForTopic"))
    }

    func push(event: Push.Event = .update, at timestamp: Date, staleDate: Date?) -> Push {
        Push(token: "ab", environment: .production, event: event, state: state(train: 4), priority: 10,
             timestamp: timestamp, staleDate: staleDate, dismissalDate: event == .end ? timestamp : nil)
    }

    @Test func expiresOnceStaleButNotWithinFiveMinutes() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func expiration(_ push: Push) -> Int? { APNSPusher.notification(for: push, topic: "t").expiration.expiration }
        #expect(expiration(push(at: at, staleDate: at + 1200)) == 1_800_001_200)
        #expect(expiration(push(at: at, staleDate: at + 60)) == 1_800_000_300)
        #expect(expiration(push(at: at, staleDate: at - 60)) == 1_800_000_300)
        // An end has no stale date: an hour
        #expect(expiration(push(event: .end, at: at, staleDate: nil)) == 1_800_003_600)
    }

    @Test func timesOutOfRangeDontCrash() throws {
        // A malformed feed's time, read as 2^64 seconds since 1970, as a countdown's train
        let far = Date(timeIntervalSince1970: 0x1p64)
        let notification = APNSPusher.notification(for: push(at: now, staleDate: far), topic: "t")
        #expect(notification.expiration.expiration == .max)
        #expect(notification.staleDate == .max)
        let end = APNSPusher.notification(for: push(event: .end, at: far, staleDate: nil), topic: "t")
        #expect(end.expiration.expiration == .max)
        let aps = try #require(try JSONSerialization.jsonObject(with: ContentState.encoder().encode(end)) as? [String: Any])["aps"]
        #expect((aps as? [String: Any])?["dismissal-date"] as? Int == .max)
    }
}
