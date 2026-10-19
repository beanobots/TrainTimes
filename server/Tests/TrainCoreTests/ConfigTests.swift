import Foundation
import Testing
@testable import TrainCore

@Suite struct ConfigTests {
    /// What's required, and nothing else.
    let required = ["APNS_KEY_PATH": "/k.p8", "APNS_KEY_ID": "KEY", "APNS_TEAM_ID": "TEAM", "DATA_DIR": "/data"]

    func parse(_ settings: [String: String]) throws -> Config {
        try Config(environment: required.merging(settings) { _, given in given })
    }

    func environments(_ config: Config) -> Set<AttestEnvironment>? {
        if case .attest(let environments) = config.auth { return environments }
        return nil
    }

    @Test func defaultsToAppAttestInProduction() throws {
        let config = try parse([:])
        #expect(environments(config) == [.production])
        #expect(config.apns.keyPath == "/k.p8")
        #expect(config.apns.topic == APNSConfig.defaultTopic)
        #expect(config.appID == Config.defaultAppID)
        #expect(config.dataDirectory.path == "/data")
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 8080)
        #expect(config.pollInterval == 30)
        #expect(config.pushConcurrency == 100)
        #expect(!config.logPushes)
        #expect(config.logFile == nil)
        let defaults = Limits()
        #expect(config.limits.maxRegistrations == defaults.maxRegistrations)
        #expect(config.limits.maxRegistrationsPerKey == defaults.maxRegistrationsPerKey)
        #expect(config.limits.requestsPerMinute == defaults.requestsPerMinute)
        #expect(config.limits.requestBurst == defaults.requestsPerMinute)
        #expect(config.limits.maxChallenges == defaults.maxChallenges)
        #expect(config.limits.challengesPerIP == defaults.challengesPerIP)
        #expect(config.limits.keysPerIPPerDay == defaults.keysPerIPPerDay)

        // An old plist's API_SECRET doesn't turn App Attest off
        #expect(environments(try parse(["API_SECRET": String(repeating: "s", count: 32)])) == [.production])
    }

    @Test func readsTheAttestEnvironments() throws {
        #expect(environments(try parse(["ATTEST_ENVIRONMENT": "development"])) == [.development])
        #expect(environments(try parse(["ATTEST_ENVIRONMENT": "Both"])) == [.development, .production])
        #expect(environments(try parse(["ATTEST_MODE": "on", "ATTEST_ENVIRONMENT": "production"])) == [.production])
        #expect(throws: Config.Problem.self) { try parse(["ATTEST_ENVIRONMENT": "staging"]) }
        #expect(throws: Config.Problem.self) { try parse(["ATTEST_MODE": "maybe"]) }
    }

    @Test func turnsAttestOffOnlyWithALongEnoughSecret() throws {
        #expect(throws: Config.Problem.self) { try parse(["ATTEST_MODE": "off"]) }
        #expect(throws: Config.Problem.self) { try parse(["ATTEST_MODE": "off", "API_SECRET": String(repeating: "s", count: 15)]) }
        let config = try parse(["ATTEST_MODE": "OFF", "API_SECRET": " \(String(repeating: "s", count: 16))\n"])
        guard case .secret(let secret) = config.auth else {
            Issue.record("not API_SECRET")
            return
        }
        #expect(secret == String(repeating: "s", count: 16))
    }

    @Test func burstFollowsTheRateUnlessGiven() throws {
        let rate = try parse(["RATE_LIMIT_PER_MINUTE": "60"])
        #expect(rate.limits.requestsPerMinute == 60)
        #expect(rate.limits.requestBurst == 60)
        let both = try parse(["RATE_LIMIT_PER_MINUTE": "60", "RATE_LIMIT_BURST": "5"])
        #expect(both.limits.requestBurst == 5)
    }

    @Test func readsWhatsGiven() throws {
        let config = try parse([
            "HOST": "0.0.0.0", "PORT": "9000", "POLL_SECONDS": "15", "PUSH_CONCURRENCY": "8", "APP_ID": "T.app",
            "APNS_TOPIC": "t", "MAX_KEYS_PER_IP_PER_DAY": "3", "LOG_PUSHES": "1", "LOG_FILE": "/logs/server.log",
        ])
        #expect(config.host == "0.0.0.0")
        #expect(config.port == 9000)
        #expect(config.pollInterval == 15)
        #expect(config.pushConcurrency == 8)
        #expect(config.appID == "T.app")
        #expect(config.apns.topic == "t")
        #expect(config.limits.keysPerIPPerDay == 3)
        #expect(config.logPushes)
        #expect(config.logFile == "/logs/server.log")
    }

    @Test func refusesWhatsMissingOrOutOfRange() throws {
        for name in required.keys {
            var settings = required
            settings[name] = nil
            #expect(throws: Config.Problem.self) { try Config(environment: settings) }
            // Blank is as good as missing
            settings[name] = "  "
            #expect(throws: Config.Problem.self) { try Config(environment: settings) }
        }
        let bad = [("PORT", "0"), ("PORT", "65536"), ("POLL_SECONDS", "4"), ("PUSH_CONCURRENCY", "many"),
                   ("RATE_LIMIT_BURST", "-1"), ("MAX_REGISTRATIONS", "0"), ("MAX_KEYS_PER_IP_PER_DAY", "1.5")]
        for (name, value) in bad {
            #expect(throws: Config.Problem.self) { try parse([name: value]) }
        }
    }
}
