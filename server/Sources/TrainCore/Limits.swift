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

    /// Takes a token for `client`, or says it has none left. An IPv4 address gets
    /// `ClientIP.ipv4Share` times as many, being shared.
    func allow(_ client: String, now: Date = .now) -> Bool {
        let share = ClientIP.share(of: client)
        let burst = self.burst * share, rate = self.rate * share
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
        buckets = buckets.filter { client, bucket in
            let share = ClientIP.share(of: client)
            return bucket.tokens + now.timeIntervalSince(bucket.updated) * rate * share < burst * share
        }
        if buckets.count >= maxTracked { buckets.removeAll() }
    }
}

/// Counts per client per UTC day, such as attest keys made from one address.
/// Only what's recorded counts, so a request that fails uses up nothing.
actor DailyLimiter {
    private let limit: Int
    private let maxTracked: Int
    /// Clients are addresses (`ClientIP`), an IPv4 one getting `ClientIP.ipv4Share` times
    /// the limit; not for keys, or everyone's.
    private let byAddress: Bool
    private var day: Int = -1
    private var counts: [String: Int] = [:]

    init(limit: Int, maxTracked: Int = 200_000, byAddress: Bool = false) {
        self.limit = limit
        self.maxTracked = maxTracked
        self.byAddress = byAddress
    }

    /// Whether `client` is under the limit today. A client with none yet is
    /// refused too once `maxTracked` others have some (a flood of addresses).
    func allows(_ client: String, now: Date = .now) -> Bool {
        startDay(now)
        let limit = byAddress ? self.limit * Int(ClientIP.share(of: client)) : self.limit
        if let count = counts[client] { return count < limit }
        return limit > 0 && counts.count < maxTracked
    }

    /// Counts one more for `client` today.
    func record(_ client: String, now: Date = .now) {
        startDay(now)
        counts[client, default: 0] += 1
    }

    /// Counts one more for `client` if it's under the limit (`allows`), in the one step, so
    /// requests at the same time can't all get the last one; whether it was.
    func take(_ client: String, now: Date = .now) -> Bool {
        guard allows(client, now: now) else { return false }
        record(client, now: now)
        return true
    }

    /// Gives back one `take` counted for `client` today, for a request that then failed.
    func release(_ client: String, now: Date = .now) {
        startDay(now)
        guard let count = counts[client], count > 0 else { return }
        // None left: no longer tracked, so failed requests from many addresses can't fill
        // `maxTracked` and refuse every new client till midnight
        counts[client] = count == 1 ? nil : count - 1
    }

    var tracked: Int { counts.count }

    /// Whole seconds until the counts start again, at midnight UTC.
    static func secondsUntilReset(now: Date) -> Int {
        let seconds = 86400 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400)
        return max(1, Int(seconds.rounded(.up)))
    }

    private func startDay(_ now: Date) {
        let today = Int(now.timeIntervalSince1970 / 86400)
        if today != day {
            day = today
            counts.removeAll()
        }
    }
}

/// App Attest challenges the server needn't keep: 16 random bytes and when it expires, with a
/// keyed hash of both (HMAC-SHA256 under a key made at start), so only this server's, still in
/// date, pass. As nothing's kept for one issued, no flood of asks from however many addresses
/// can fill anything and refuse everyone else.
///
/// A signed request's challenge needn't be used once: its assertion's counter only goes up, so
/// it can't be sent again. An attestation has no counter, so its challenge is used once
/// (`useOnce`), noted only once the attestation checks out, which takes a real phone, so what's
/// noted stays small. A restart makes a new key: challenges from before are refused, and the
/// app asks for another.
actor ChallengeStore {
    static let lifetime: TimeInterval = 5 * 60
    private static let randomBytes = 16, expiryBytes = 8, macBytes = 16
    static let byteCount = randomBytes + expiryBytes + macBytes

    private let key: SymmetricKey
    /// Attestations' challenges used, with when they expire, until they do.
    private var used: [Data: Date] = [:]

    init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.key = key
    }

    /// A new challenge, good for `lifetime`, base64url without padding (54 characters).
    nonisolated func issue(now: Date = .now) -> String {
        var generator = SystemRandomNumberGenerator()
        var body = Data((0..<Self.randomBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let expires = UInt64(now.addingTimeInterval(Self.lifetime).timeIntervalSince1970.rounded(.up))
        body.append(contentsOf: withUnsafeBytes(of: expires.bigEndian) { Array($0) })
        body.append(contentsOf: HMAC<SHA256>.authenticationCode(for: body, using: key).prefix(Self.macBytes))
        return body.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Whether `challenge` is one this server issued (its hash checks out) that hasn't expired.
    nonisolated func isValid(_ challenge: String, now: Date = .now) -> Bool {
        expiry(of: challenge).map { $0 > now } ?? false
    }

    /// For an attestation that's checked out: whether `challenge` is valid (`isValid`) and
    /// hasn't been used for one before; either way, it can't be again.
    func useOnce(_ challenge: String, now: Date = .now) -> Bool {
        guard let expires = expiry(of: challenge), expires > now, let bytes = Self.bytes(of: challenge) else { return false }
        used = used.filter { $0.value > now }
        guard used[bytes] == nil else { return false }
        used[bytes] = expires
        return true
    }

    /// How many attestations' challenges are kept, still in date.
    var usedCount: Int { used.count }

    /// When `challenge` expires, if this server issued it.
    private nonisolated func expiry(of challenge: String) -> Date? {
        guard let bytes = Self.bytes(of: challenge) else { return nil }
        let body = bytes.prefix(Self.randomBytes + Self.expiryBytes)
        let mac = [UInt8](bytes.suffix(Self.macBytes))
        let expected = [UInt8](HMAC<SHA256>.authenticationCode(for: body, using: key).prefix(Self.macBytes))
        // Compared in constant time, so its bytes can't be guessed one at a time
        var differ: UInt8 = 0
        for (a, b) in zip(mac, expected) { differ |= a ^ b }
        guard mac.count == expected.count, differ == 0 else { return nil }
        let seconds = body.suffix(Self.expiryBytes).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// The bytes of a challenge as issued, or nil if it isn't the right length or encoding.
    private static func bytes(of challenge: String) -> Data? {
        guard challenge.utf8.count <= 128 else { return nil }
        var base64 = challenge.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count == byteCount else { return nil }
        return data
    }
}

enum ClientIP {
    /// How many times a /64's limits an IPv4 address gets: a phone on IPv6 has a /64 to
    /// itself, where an office's, a café's or a carrier's NAT puts many behind one IPv4 address.
    static let ipv4Share = 10

    /// `ipv4Share` for an IPv4 address (as `key(_:)` gives it), else 1.
    static func share(of client: String) -> Double {
        isIPv4(client) ? Double(ipv4Share) : 1
    }

    /// Whether `client` is an IPv4 address other than loopback (cloudflared itself, as
    /// without its CF-Connecting-IP), which isn't shared.
    static func isIPv4(_ client: String) -> Bool {
        !client.isEmpty && client.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || $0 == UInt8(ascii: ".") }
            && client.contains(".") && !client.hasPrefix("127.")
    }

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
        return "#" + mac.prefix(5).hex
    }
}

extension Sequence<UInt8> {
    /// Lowercase hex, two digits a byte.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
