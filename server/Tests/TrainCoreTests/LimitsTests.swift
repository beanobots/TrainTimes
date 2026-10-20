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
        // Asking uses up nothing; recording does
        #expect(await limiter.allows("ip", now: day))
        #expect(await limiter.allows("ip", now: day))
        await limiter.record("ip", now: day)
        #expect(await limiter.allows("ip", now: day))
        await limiter.record("ip", now: day)
        #expect(await !limiter.allows("ip", now: day.addingTimeInterval(3600)))
        #expect(await limiter.allows("other", now: day))
        #expect(await limiter.allows("ip", now: day.addingTimeInterval(86400)))
        #expect(await limiter.tracked == 0)
        // Until the next midnight UTC
        #expect(DailyLimiter.secondsUntilReset(now: day) == 86300)
        #expect(DailyLimiter.secondsUntilReset(now: day.addingTimeInterval(86299.5)) == 1)
        #expect(DailyLimiter.secondsUntilReset(now: day.addingTimeInterval(-100)) == 86400)
    }

    @Test func dailyLimitRefusesNewClientsWhenTrackingTooMany() async {
        let limiter = DailyLimiter(limit: 2, maxTracked: 3)
        for client in ["a", "b", "c"] { await limiter.record(client, now: now) }
        #expect(await !limiter.allows("d", now: now))
        // Those it knows keep their share
        #expect(await limiter.allows("a", now: now))
        // And a new day starts afresh
        #expect(await limiter.allows("d", now: now.addingTimeInterval(86400)))
    }

    @Test func challengesAreSingleUseExpireAndAreCapped() async throws {
        let store = ChallengeStore(limit: 2, perClient: 10)
        let first = try #require(await store.issue(for: "a", now: now).value)
        let second = try #require(await store.issue(for: "b", now: now).value)
        #expect(first != second)
        #expect(first.count == 43)
        #expect(await store.issue(for: "c", now: now) == .full)
        #expect(await store.consume(first, now: now))
        #expect(await !store.consume(first, now: now))
        #expect(await store.issue(for: "c", now: now).value != nil)
        // Expired: refused, and it no longer counts
        #expect(await !store.consume(second, now: now.addingTimeInterval(301)))
        _ = await store.issue(for: "c", now: now.addingTimeInterval(400))
        #expect(await store.outstanding == 1)
    }

    @Test func eachClientHasItsOwnShareOfChallenges() async throws {
        let store = ChallengeStore(limit: 100, perClient: 2)
        let first = try #require(await store.issue(for: "a", now: now).value)
        #expect(await store.issue(for: "a", now: now.addingTimeInterval(10)).value != nil)
        // Not until its first expires
        #expect(await store.issue(for: "a", now: now.addingTimeInterval(20)) == .clientFull(retryAfter: 280))
        // Others aren't held up
        #expect(await store.issue(for: "b", now: now.addingTimeInterval(20)).value != nil)
        // Using one makes room, as does its expiring
        #expect(await store.consume(first, now: now.addingTimeInterval(20)))
        #expect(await store.issue(for: "a", now: now.addingTimeInterval(20)).value != nil)
        #expect(await store.issue(for: "a", now: now.addingTimeInterval(20)) == .clientFull(retryAfter: 290))
        #expect(await store.issue(for: "a", now: now.addingTimeInterval(310)).value != nil)
        // Clients with none outstanding are forgotten
        _ = await store.issue(for: "c", now: now.addingTimeInterval(700))
        #expect(await store.outstanding == 1)
        #expect(await store.clientCount == 1)
    }

    @Test func usedChallengesDontPileUp() async throws {
        let store = ChallengeStore(limit: 10, perClient: 10)
        // Each used as soon as it's issued, all within their 5 minutes
        for i in 0..<10_000 {
            let at = now.addingTimeInterval(Double(i) / 100)
            let challenge = try #require(await store.issue(for: "a", now: at).value)
            #expect(await store.consume(challenge, now: at))
        }
        #expect(await store.outstanding == 0)
        #expect(await store.queued <= 2 * 1024 + 1)
        // Those still outstanding are kept, and still expire
        let kept = try #require(await store.issue(for: "a", now: now.addingTimeInterval(100)).value)
        for i in 0..<3000 {
            let at = now.addingTimeInterval(100 + Double(i) / 100)
            let challenge = try #require(await store.issue(for: "b", now: at).value)
            #expect(await store.consume(challenge, now: at))
        }
        #expect(await store.queued <= 2 * 1024 + 1)
        #expect(await store.consume(kept, now: now.addingTimeInterval(200)))
    }

    @Test func trustsCFConnectingIPOnlyFromLoopback() throws {
        let local = try SocketAddress(ipAddress: "127.0.0.1", port: 50000)
        let local6 = try SocketAddress(ipAddress: "::1", port: 50000)
        let remote = try SocketAddress(ipAddress: "198.51.100.7", port: 50000)
        #expect(ClientIP.resolve(peer: local, connectingIP: "203.0.113.9") == "203.0.113.9")
        #expect(ClientIP.resolve(peer: local6, connectingIP: "2001:DB8::1") == "2001:db8:0:0::/64")
        #expect(ClientIP.resolve(peer: remote, connectingIP: "203.0.113.9") == "198.51.100.7")
        #expect(ClientIP.resolve(peer: local, connectingIP: nil) == "127.0.0.1")
        #expect(ClientIP.resolve(peer: local, connectingIP: "evil\nheader") == "127.0.0.1")
        #expect(ClientIP.resolve(peer: nil, connectingIP: "203.0.113.9") == "unknown")
    }

    @Test func countsAnIPv6AddressByItsSlash64() throws {
        #expect(ClientIP.key("2001:db8:1:2::1") == "2001:db8:1:2::/64")
        #expect(ClientIP.key("2001:db8:1:2:aaaa:bbbb:cccc:dddd") == "2001:db8:1:2::/64")
        #expect(ClientIP.key("2001:0db8:0001:0002:0000:0000:0000:0009") == "2001:db8:1:2::/64")
        #expect(ClientIP.key("2001:db8:1:3::1") == "2001:db8:1:3::/64")
        #expect(ClientIP.key("::1") == "0:0:0:0::/64")
        // IPv4 as it is, and an IPv4-mapped address as its IPv4 one
        #expect(ClientIP.key("203.0.113.9") == "203.0.113.9")
        #expect(ClientIP.key("::ffff:203.0.113.9") == "203.0.113.9")
        #expect(ClientIP.key("::ffff:cb00:7109") == "203.0.113.9")
        #expect(ClientIP.key("abc") == "abc")
        // The peer's own address too
        let peer = try SocketAddress(ipAddress: "2001:db8:5:6::7", port: 50000)
        #expect(ClientIP.resolve(peer: peer, connectingIP: nil) == "2001:db8:5:6::/64")
    }

    @Test func redactsConsistentlyWithoutRevealing() {
        #expect(Redact.id("203.0.113.9") == Redact.id("203.0.113.9"))
        #expect(Redact.id("203.0.113.9") != Redact.id("203.0.113.10"))
        #expect(!Redact.id("203.0.113.9").contains("203"))
        #expect(Redact.id("x").count == 11)
    }
}

extension ChallengeStore.Issued {
    /// The challenge, if one was issued.
    var value: String? {
        if case .challenge(let challenge) = self { return challenge }
        return nil
    }
}
