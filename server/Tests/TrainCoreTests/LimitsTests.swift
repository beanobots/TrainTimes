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

    @Test func takingChecksAndCountsInOneStep() async {
        let limiter = DailyLimiter(limit: 3)
        // Asked all at once, only the limit's worth get one
        let taken = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 { group.addTask { await limiter.take("ip", now: now) } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(taken == 3)
        #expect(await !limiter.allows("ip", now: now))
        #expect(await limiter.take("other", now: now))
        #expect(await limiter.take("ip", now: now.addingTimeInterval(86400)))
        #expect(await !DailyLimiter(limit: 0).take("ip", now: now))
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

    @Test func challengesAreThisServersAndExpire() async throws {
        let store = ChallengeStore()
        let first = store.issue(now: now)
        let second = store.issue(now: now)
        #expect(first != second)
        #expect(first.count == 54)
        // Good for five minutes, as often as asked (a signed request's counter stops a replay)
        #expect(store.isValid(first, now: now))
        #expect(store.isValid(first, now: now.addingTimeInterval(299)))
        #expect(!store.isValid(first, now: now.addingTimeInterval(301)))
        // Another server's (or this one's before a restart), made up, or changed: refused
        #expect(!ChallengeStore().isValid(first, now: now))
        #expect(!store.isValid("made-up", now: now))
        #expect(!store.isValid("", now: now))
        var bytes = Array(first.utf8)
        bytes[30] = bytes[30] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
        #expect(!store.isValid(String(decoding: bytes, as: UTF8.self), now: now))
        #expect(!store.isValid(first + "AA", now: now))
    }

    @Test func aFloodOfChallengesKeepsNothing() async throws {
        let store = ChallengeStore()
        // However many are asked for, from however many addresses, none is refused or kept
        for _ in 0..<20_000 { _ = store.issue(now: now) }
        #expect(store.isValid(store.issue(now: now), now: now))
        #expect(await store.usedCount == 0)
    }

    @Test func anAttestationsChallengeIsUsedOnce() async throws {
        let store = ChallengeStore()
        let challenge = store.issue(now: now)
        #expect(await store.useOnce(challenge, now: now))
        #expect(await !store.useOnce(challenge, now: now.addingTimeInterval(10)))
        #expect(await !store.useOnce("made-up", now: now))
        #expect(await !store.useOnce(store.issue(now: now), now: now.addingTimeInterval(301)))
        // Kept only until they'd have expired
        _ = await store.useOnce(store.issue(now: now.addingTimeInterval(400)), now: now.addingTimeInterval(400))
        #expect(await store.usedCount == 1)
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
