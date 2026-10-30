import Foundation

/// What the APNs client needs: enough for `send-test` on its own.
struct APNSConfig: Sendable {
    var keyPath: String
    var keyID: String
    var teamID: String
    var topic: String

    static let defaultTopic = "dev.dctp.leeway.push-type.liveactivity"

    /// The topic of widget reloads: the same app's, as `<bundle ID>.push-type.widgets`.
    var widgetTopic: String {
        let suffix = ".push-type.liveactivity"
        let app = topic.hasSuffix(suffix) ? String(topic.dropLast(suffix.count)) : topic
        return app + ".push-type.widgets"
    }

    init(environment env: [String: String]) throws {
        keyPath = try Config.required("APNS_KEY_PATH", in: env)
        keyID = try Config.required("APNS_KEY_ID", in: env)
        teamID = try Config.required("APNS_TEAM_ID", in: env)
        topic = Config.optional("APNS_TOPIC", in: env) ?? Self.defaultTopic
    }
}

/// How requests that change registrations prove they're from the app.
enum AuthMode: Sendable {
    /// App Attest assertions, from keys attested in these environments.
    case attest(Set<AttestEnvironment>)
    /// `Authorization: Bearer <API_SECRET>`: for development only (the
    /// simulator has no App Attest).
    case secret(String)
}

/// Limits on what clients can ask of the server.
struct Limits: Sendable {
    var maxRegistrations = 100_000
    var maxRegistrationsPerKey = 5
    var requestsPerMinute = 30.0
    var requestBurst = 30.0
    /// `GET /feeds`'s own limit: a refresh reads several feeds for each widget at once.
    var feedRequestsPerMinute = 240.0
    var feedRequestBurst = 120.0
    var maxChallenges = 10_000
    /// Outstanding challenges per client: one for each request the app is
    /// about to sign, with room for a few it gave up on.
    var challengesPerIP = 10
    var keysPerIPPerDay = 10
    /// Attest keys unused this long are forgotten.
    var keyRetention: TimeInterval = 90 * 86400
    /// `GET /routes` asks Google at most this often a day for each client, and for everyone,
    /// to stay inside Google's free allowance.
    var routesPerIPPerDay = 30
    var routesPerDay = 300
    /// `GET /buses` and `/buses/nearby` ask Bus Time at most this often a day for each client,
    /// and for everyone: a Nearby asks for up to 7 at once, and what's kept doesn't count.
    var busTimePerIPPerDay = 2_000
    var busTimePerDay = 100_000
}

/// The server's settings, from environment variables.
struct Config: Sendable {
    var apns: APNSConfig
    var auth: AuthMode
    /// "TEAMID.bundle.id", whose SHA256 is App Attest's rpIdHash.
    var appID: String
    var dataDirectory: URL
    var host: String
    var port: Int
    var pollInterval: TimeInterval
    var pushTiming: PushTiming
    var pushConcurrency: Int
    var limits: Limits
    var logPushes: Bool
    /// Google's Routes API key, for `GET /routes`; nil turns it off.
    var googleRoutesKey: String?
    /// MTA Bus Time's API key, for `GET /buses`; nil turns it off.
    var busTimeKey: String?
    /// The file launchd sends stdout and stderr to, if the server's to move
    /// to the new one when newsyslog rotates it.
    var logFile: String?

    static let defaultAppID = "XUU899AG4D.dev.dctp.leeway"

    struct Problem: Error, CustomStringConvertible {
        let description: String
    }

    init(environment env: [String: String]) throws {
        apns = try APNSConfig(environment: env)
        switch Self.optional("ATTEST_MODE", in: env)?.lowercased() ?? "on" {
        case "on":
            let environments: Set<AttestEnvironment>
            switch Self.optional("ATTEST_ENVIRONMENT", in: env)?.lowercased() ?? "production" {
            case "production": environments = [.production]
            case "development": environments = [.development]
            case "both": environments = [.development, .production]
            case let other:
                throw Problem(description: "ATTEST_ENVIRONMENT must be development, production or both, not \"\(other)\"")
            }
            auth = .attest(environments)
        case "off":
            guard let secret = Self.optional("API_SECRET", in: env) else {
                throw Problem(description: "ATTEST_MODE=off needs API_SECRET (try: openssl rand -hex 32)")
            }
            guard secret.utf8.count >= 16 else {
                throw Problem(description: "API_SECRET must be at least 16 characters (try: openssl rand -hex 32)")
            }
            auth = .secret(secret)
        case let other:
            throw Problem(description: "ATTEST_MODE must be on or off, not \"\(other)\"")
        }
        appID = Self.optional("APP_ID", in: env) ?? Self.defaultAppID
        dataDirectory = URL(fileURLWithPath: try Self.required("DATA_DIR", in: env), isDirectory: true)
        // Loopback unless asked otherwise: cloudflared on this machine forwards to it
        host = Self.optional("HOST", in: env) ?? "127.0.0.1"
        port = try Self.integer("PORT", in: env, default: 8080, range: 1...65535)
        pollInterval = TimeInterval(try Self.integer("POLL_SECONDS", in: env, default: 20, range: 5...3600))
        var timing = PushTiming()
        timing.earlier = TimeInterval(try Self.integer("PUSH_EARLIER_SECONDS", in: env, default: Int(timing.earlier),
                                                       range: 1...3600))
        timing.later = TimeInterval(try Self.integer("PUSH_LATER_SECONDS", in: env, default: Int(timing.later),
                                                     range: 1...3600))
        timing.following = TimeInterval(try Self.integer("PUSH_FOLLOWING_SECONDS", in: env, default: Int(timing.following),
                                                         range: 1...3600))
        timing.refresh = TimeInterval(try Self.integer("REFRESH_SECONDS", in: env, default: Int(timing.refresh),
                                                       range: 60...3600))
        pushTiming = timing
        pushConcurrency = try Self.integer("PUSH_CONCURRENCY", in: env, default: 100, range: 1...1000)
        var limits = Limits()
        limits.maxRegistrations = try Self.integer("MAX_REGISTRATIONS", in: env, default: limits.maxRegistrations,
                                                   range: 1...10_000_000)
        limits.maxRegistrationsPerKey = try Self.integer("MAX_REGISTRATIONS_PER_KEY", in: env,
                                                         default: limits.maxRegistrationsPerKey, range: 1...1000)
        limits.requestsPerMinute = Double(try Self.integer("RATE_LIMIT_PER_MINUTE", in: env, default: Int(limits.requestsPerMinute),
                                                           range: 1...100_000))
        limits.requestBurst = Double(try Self.integer("RATE_LIMIT_BURST", in: env, default: Int(limits.requestsPerMinute),
                                                      range: 1...100_000))
        limits.feedRequestsPerMinute = Double(try Self.integer("FEED_RATE_LIMIT_PER_MINUTE", in: env,
                                                               default: Int(limits.feedRequestsPerMinute), range: 1...100_000))
        limits.feedRequestBurst = Double(try Self.integer("FEED_RATE_LIMIT_BURST", in: env,
                                                          default: Int(limits.feedRequestBurst), range: 1...100_000))
        limits.maxChallenges = try Self.integer("MAX_CHALLENGES", in: env, default: limits.maxChallenges, range: 1...10_000_000)
        limits.challengesPerIP = try Self.integer("MAX_CHALLENGES_PER_IP", in: env, default: limits.challengesPerIP,
                                                  range: 1...100_000)
        limits.keysPerIPPerDay = try Self.integer("MAX_KEYS_PER_IP_PER_DAY", in: env, default: limits.keysPerIPPerDay,
                                                  range: 1...100_000)
        limits.routesPerIPPerDay = try Self.integer("ROUTES_PER_IP_PER_DAY", in: env, default: limits.routesPerIPPerDay,
                                                    range: 1...100_000)
        limits.routesPerDay = try Self.integer("ROUTES_PER_DAY", in: env, default: limits.routesPerDay, range: 1...1_000_000)
        limits.busTimePerIPPerDay = try Self.integer("BUS_TIME_PER_IP_PER_DAY", in: env, default: limits.busTimePerIPPerDay,
                                                     range: 1...1_000_000)
        limits.busTimePerDay = try Self.integer("BUS_TIME_PER_DAY", in: env, default: limits.busTimePerDay,
                                                range: 1...10_000_000)
        self.limits = limits
        logPushes = Self.optional("LOG_PUSHES", in: env) == "1"
        googleRoutesKey = Self.optional("GOOGLE_ROUTES_API_KEY", in: env)
        busTimeKey = Self.optional("BUS_TIME_API_KEY", in: env)
        logFile = Self.optional("LOG_FILE", in: env)
    }

    static func required(_ name: String, in env: [String: String]) throws -> String {
        guard let value = optional(name, in: env) else {
            throw Problem(description: "Missing required environment variable \(name)")
        }
        return value
    }

    static func optional(_ name: String, in env: [String: String]) -> String? {
        guard let value = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func integer(_ name: String, in env: [String: String], default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let text = optional(name, in: env) else { return value }
        guard let number = Int(text), range.contains(number) else {
            throw Problem(description: "\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound), not \"\(text)\"")
        }
        return number
    }
}
