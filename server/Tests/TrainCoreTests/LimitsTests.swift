import Foundation
import NIOCore
import Testing
@testable import TrainCore

@Suite struct LimitsTests {
    @Test func tokenBucketAllowsABurstThenRefills() async {
        let limiter = RateLimiter(perMinute: 30, burst: 30)
        for _ in 0..<30 { #expect(await limiter.allow("a", now: now)) }
        #expect(await !limiter.allow("a", now: now))
        // Someone else has their own bucket
        #expect(await limiter.allow("b", now: now))
        // One token every 2 s
        #expect(await !limiter.allow("a", now: now.addingTimeInterval(1)))
        #expect(await limiter.allow("a", now: now.addingTimeInterval(2)))
        #expect(await !limiter.allow("a", now: now.addingTimeInterval(2)))
        // Refills to the burst, no further
        for _ in 0..<30 { #expect(await limiter.allow("a", now: now.addingTimeInterval(3600))) }
        #expect(await !limiter.allow("a", now: now.addingTimeInterval(3600)))
    }

    @Test func forgetsRefilledBucketsWhenTrackingTooMany() async {
        let limiter = RateLimiter(perMinute: 60, burst: 2, maxTracked: 10)
        for i in 0..<10 { #expect(await limiter.allow("\(i)", now: now)) }
        #expect(await limiter.tracked == 10)
        #expect(await limiter.allow("new", now: now.addingTimeInterval(5)))
        #expect(await limiter.tracked == 1)
    }

    @Test func dailyLimitResetsAtMidnightUTC() async {
        let limiter = DailyLimiter(limit: 2)
        let day = Date(timeIntervalSince1970: 86400 * 20000 + 100)
        #expect(await limiter.take("ip", now: day))
        #expect(await limiter.take("ip", now: day))
        #expect(await !limiter.take("ip", now: day.addingTimeInterval(3600)))
        #expect(await limiter.take("other", now: day))
        #expect(await limiter.take("ip", now: day.addingTimeInterval(86400)))
    }

    @Test func challengesAreSingleUseExpireAndAreCapped() async {
        let store = ChallengeStore(limit: 2)
        let first = await store.issue(now: now)!
        let second = await store.issue(now: now)!
        #expect(first != second)
        #expect(first.count == 43)
        #expect(await store.issue(now: now) == nil)
        #expect(await store.consume(first, now: now))
        #expect(await !store.consume(first, now: now))
        #expect(await store.issue(now: now) != nil)
        // Expired: refused, and it no longer counts
        #expect(await !store.consume(second, now: now.addingTimeInterval(301)))
        _ = await store.issue(now: now.addingTimeInterval(400))
        #expect(await store.outstanding == 1)
    }

    @Test func trustsCFConnectingIPOnlyFromLoopback() throws {
        let local = try SocketAddress(ipAddress: "127.0.0.1", port: 50000)
        let local6 = try SocketAddress(ipAddress: "::1", port: 50000)
        let remote = try SocketAddress(ipAddress: "198.51.100.7", port: 50000)
        #expect(ClientIP.resolve(peer: local, connectingIP: "203.0.113.9") == "203.0.113.9")
        #expect(ClientIP.resolve(peer: local6, connectingIP: "2001:DB8::1") == "2001:db8::1")
        #expect(ClientIP.resolve(peer: remote, connectingIP: "203.0.113.9") == "198.51.100.7")
        #expect(ClientIP.resolve(peer: local, connectingIP: nil) == "127.0.0.1")
        #expect(ClientIP.resolve(peer: local, connectingIP: "evil\nheader") == "127.0.0.1")
        #expect(ClientIP.resolve(peer: nil, connectingIP: "203.0.113.9") == "unknown")
    }

    @Test func redactsConsistentlyWithoutRevealing() {
        #expect(Redact.id("203.0.113.9") == Redact.id("203.0.113.9"))
        #expect(Redact.id("203.0.113.9") != Redact.id("203.0.113.10"))
        #expect(!Redact.id("203.0.113.9").contains("203"))
        #expect(Redact.id("x").count == 11)
    }
}
