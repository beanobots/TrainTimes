import Crypto
import Foundation
import NIOCore

/// A token bucket per client: `burst` requests at once, refilled at
/// `perMinute`. Kept in memory only.
actor RateLimiter {
    private let rate: Double
    private let burst: Double
    private let maxTracked: Int
    private var buckets: [String: (tokens: Double, updated: Date)] = [:]

    init(perMinute: Double, burst: Double, maxTracked: Int = 200_000) {
        rate = perMinute / 60
        self.burst = max(1, burst)
        self.maxTracked = maxTracked
    }

    /// Takes a token for `client`, or says it has none left.
    func allow(_ client: String, now: Date = .now) -> Bool {
        var bucket = buckets[client] ?? (burst, now)
        bucket.tokens = min(burst, bucket.tokens + max(0, now.timeIntervalSince(bucket.updated)) * rate)
        bucket.updated = now
        guard bucket.tokens >= 1 else {
            buckets[client] = bucket
            return false
        }
        bucket.tokens -= 1
        if buckets[client] == nil, buckets.count >= maxTracked { prune(now: now) }
        buckets[client] = bucket
        return true
    }

    var tracked: Int { buckets.count }

    /// Forgets the buckets that have refilled, which are as good as new; if
    /// that isn't enough (a flood of addresses), all of them.
    private func prune(now: Date) {
        buckets = buckets.filter { $0.value.tokens + now.timeIntervalSince($0.value.updated) * rate < burst }
        if buckets.count >= maxTracked { buckets.removeAll() }
    }
}

/// Counts per client per UTC day, such as attest keys made from one address.
actor DailyLimiter {
    private let limit: Int
    private var day: Int = -1
    private var counts: [String: Int] = [:]

    init(limit: Int) { self.limit = limit }

    func take(_ client: String, now: Date = .now) -> Bool {
        let today = Int(now.timeIntervalSince1970 / 86400)
        if today != day {
            day = today
            counts.removeAll()
        }
        guard counts[client, default: 0] < limit else { return false }
        counts[client, default: 0] += 1
        return true
    }
}

/// Single-use challenges for App Attest, kept in memory for 5 minutes.
actor ChallengeStore {
    static let lifetime: TimeInterval = 5 * 60

    enum Issued: Equatable {
        case challenge(String)
        /// The client has `perClient` outstanding; the first of them expires in this many seconds.
        case clientFull(retryAfter: Int)
        /// `limit` are outstanding in all.
        case full
    }

    private let limit: Int
    private let perClient: Int
    private var expiries: [String: (client: String, expires: Date)] = [:]
    /// When each client's outstanding challenges expire.
    private var clients: [String: [Date]] = [:]
    /// In the order issued, so the expired ones come off the front.
    private var queue: [(challenge: String, expires: Date)] = []
    private var head = 0

    init(limit: Int, perClient: Int) {
        self.limit = limit
        self.perClient = perClient
    }

    /// A new challenge for `client`, unless it already has `perClient`
    /// outstanding or `limit` are outstanding in all.
    func issue(for client: String, now: Date = .now) -> Issued {
        purge(now: now)
        if let mine = clients[client], mine.count >= perClient, let first = mine.min() {
            return .clientFull(retryAfter: max(1, Int(first.timeIntervalSince(now).rounded(.up))))
        }
        guard expiries.count < limit else { return .full }
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let challenge = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let expires = now.addingTimeInterval(Self.lifetime)
        expiries[challenge] = (client, expires)
        clients[client, default: []].append(expires)
        queue.append((challenge, expires))
        return .challenge(challenge)
    }

    /// Whether `challenge` was issued, hasn't expired and hasn't been used;
    /// either way, it can't be used again.
    func consume(_ challenge: String, now: Date = .now) -> Bool {
        guard let entry = expiries.removeValue(forKey: challenge) else { return false }
        release(entry)
        return entry.expires > now
    }

    var outstanding: Int { expiries.count }

    /// How many clients have challenges outstanding.
    var clientCount: Int { clients.count }

    private func release(_ entry: (client: String, expires: Date)) {
        guard var mine = clients[entry.client], let index = mine.firstIndex(of: entry.expires) else { return }
        mine.remove(at: index)
        clients[entry.client] = mine.isEmpty ? nil : mine
    }

    private func purge(now: Date) {
        while head < queue.count, queue[head].expires <= now {
            if let entry = expiries.removeValue(forKey: queue[head].challenge) { release(entry) }
            head += 1
        }
        if head > 1024, head * 2 > queue.count {
            queue.removeFirst(head)
            head = 0
        }
    }
}

enum ClientIP {
    /// The client, as the limits count it: cloudflared's `CF-Connecting-IP`
    /// when the request came from cloudflared on this machine, otherwise the
    /// peer's own address, either as `key(_:)` gives it.
    static func resolve(peer: SocketAddress?, connectingIP: String?) -> String {
        if let peer, isLoopback(peer), let header = connectingIP?.trimmingCharacters(in: .whitespaces),
           (1...45).contains(header.utf8.count),
           header.utf8.allSatisfy({ isHexDigit($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: ":") }) {
            return key(header.lowercased())
        }
        return peer?.ipAddress.map(key) ?? "unknown"
    }

    /// An IPv6 address's /64, as "2001:db8:0:0::/64": a host is commonly given
    /// a whole /64, so could otherwise use a new address for every request.
    /// An IPv4 address as it is, and an IPv4-mapped IPv6 one as its IPv4 address.
    static func key(_ address: String) -> String {
        guard case .v6(let v6)? = try? SocketAddress(ipAddress: address, port: 0) else { return address }
        let bytes = withUnsafeBytes(of: v6.address.sin6_addr) { Array($0) }
        if bytes[..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return bytes[12...].map { String($0) }.joined(separator: ".")
        }
        let groups = stride(from: 0, to: 8, by: 2).map { String(UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]), radix: 16) }
        return groups.joined(separator: ":") + "::/64"
    }

    static func isLoopback(_ address: SocketAddress) -> Bool {
        guard let ip = address.ipAddress else { return false }
        return ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("::ffff:127.")
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }
}

/// For logs: IPs and key IDs become a short keyed hash, the same within a run
/// and meaningless outside it.
enum Redact {
    private static let key = SymmetricKey(size: .bits256)

    static func id(_ value: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)
        return "#" + mac.prefix(5).map { String(format: "%02x", $0) }.joined()
    }
}
