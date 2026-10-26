import Foundation

/// One of the server's environment variables, as Configuration edits it.
/// The server's README has what each does; the ranges are Config.swift's.
struct Setting: Identifiable, Sendable {
    enum Kind: Sendable {
        case text(required: Bool)
        case secret
        case choice([String], default: String)
        /// "1" or "0".
        case toggle
        case integer(ClosedRange<Int>, default: Int)
    }

    let key: String
    let label: String
    let hint: String?
    let kind: Kind

    var id: String { key }

    init(_ key: String, _ label: String, _ kind: Kind, hint: String? = nil) {
        self.key = key
        self.label = label
        self.kind = kind
        self.hint = hint
    }

    /// What's wrong with `value`, nil or blank meaning left out (the default).
    func problem(with value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch kind {
        case .text(let required):
            return required && value.isEmpty ? "Required" : nil
        case .secret, .toggle:
            return nil
        case .choice(let options, _):
            return value.isEmpty || options.contains(value.lowercased()) ? nil
                : "One of \(options.joined(separator: ", "))"
        case .integer(let range, _):
            guard !value.isEmpty else { return nil }
            guard let number = Int(value), range.contains(number) else {
                return "A whole number from \(range.lowerBound) to \(range.upperBound)"
            }
            return nil
        }
    }

    /// `value`, or the server's default when it's left out.
    func effective(_ value: String?) -> String? {
        if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        switch kind {
        case .integer(_, let value): return String(value)
        case .choice(_, let value): return value
        case .toggle: return "0"
        case .text, .secret: return nil
        }
    }
}

struct SettingGroup: Identifiable, Sendable {
    let title: String
    let footer: String?
    let settings: [Setting]
    var id: String { title }
}

extension Setting {
    static let pushEarlier = Setting("PUSH_EARLIER_SECONDS", "Train earlier by more than", .integer(1...3600, default: 15),
                                     hint: "Seconds. Less than later, as a train coming sooner could be missed.")
    static let pushLater = Setting("PUSH_LATER_SECONDS", "Train later by more than", .integer(1...3600, default: 60),
                                   hint: "Seconds.")
    static let pushFollowing = Setting("PUSH_FOLLOWING_SECONDS", "Following train moves", .integer(1...3600, default: 60),
                                       hint: "Seconds, this much or more.")
    static let refresh = Setting("REFRESH_SECONDS", "Low-priority refresh after", .integer(60...3600, default: 300),
                                 hint: "Seconds since the last push.")
    static let poll = Setting("POLL_SECONDS", "Read the feeds every", .integer(5...3600, default: 20),
                              hint: "Seconds. A pass that runs over skips ticks.")

    static let groups: [SettingGroup] = [
        SettingGroup(title: "Push timing", footer: "When a countdown's new times are worth a push.", settings: [
            pushEarlier, pushLater, pushFollowing, refresh, poll,
        ]),
        SettingGroup(title: "APNs & App Attest", footer: nil, settings: [
            Setting("APNS_KEY_PATH", "Key path", .text(required: true), hint: "The APNs auth key (.p8)."),
            Setting("APNS_KEY_ID", "Key ID", .text(required: true)),
            Setting("APNS_TEAM_ID", "Team ID", .text(required: true)),
            Setting("APNS_TOPIC", "Topic", .text(required: false)),
            Setting("ATTEST_MODE", "App Attest", .choice(["on", "off"], default: "on"),
                    hint: "Off is for development only, and needs an API secret."),
            Setting("ATTEST_ENVIRONMENT", "Attest environment", .choice(["production", "development", "both"],
                                                                         default: "production"),
                    hint: "Development for builds from Xcode, production for TestFlight and the App Store."),
            Setting("APP_ID", "App ID", .text(required: false)),
            Setting("API_SECRET", "API secret", .secret, hint: "Only with App Attest off; at least 16 characters."),
        ]),
        SettingGroup(title: "Polling & pushes", footer: nil, settings: [
            Setting("PUSH_CONCURRENCY", "Pushes in flight", .integer(1...1000, default: 100)),
            Setting("MAX_REGISTRATIONS", "Countdowns in all", .integer(1...10_000_000, default: 100_000)),
            Setting("MAX_REGISTRATIONS_PER_KEY", "Countdowns per key", .integer(1...1000, default: 5),
                    hint: "Registering one more drops that key's oldest."),
            Setting("LOG_PUSHES", "Log every push", .toggle),
        ]),
        SettingGroup(title: "Rate limits", footer: "Per client address; an IPv6 address counts by its /64.", settings: [
            Setting("RATE_LIMIT_PER_MINUTE", "Requests per minute", .integer(1...100_000, default: 30)),
            Setting("FEED_RATE_LIMIT_PER_MINUTE", "Feed requests per minute", .integer(1...100_000, default: 240),
                    hint: "The app's and widgets' reads of MTA feeds, apart from the limit above."),
            Setting("MAX_CHALLENGES", "Challenges outstanding", .integer(1...10_000_000, default: 10_000),
                    hint: "In all."),
            Setting("MAX_CHALLENGES_PER_IP", "Challenges per address", .integer(1...100_000, default: 10)),
            Setting("MAX_KEYS_PER_IP_PER_DAY", "Keys per address per day", .integer(1...100_000, default: 10)),
        ]),
    ]
}
