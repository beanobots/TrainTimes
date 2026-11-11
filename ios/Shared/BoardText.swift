import Foundation

/// `Text(timerInterval:)` takes all offered width, so callers size it to its digits.
enum TimerText {
    /// The widest text counting down from `seconds`: "0:00", "00:00" from 10 minutes, "0:00:00"
    /// from an hour. Thresholds are a second early in case the timer rounds up.
    static func placeholder(seconds: TimeInterval) -> String {
        seconds >= 3599 ? "0:00:00" : seconds >= 599 ? "00:00" : "0:00"
    }
}

/// Minutes left over before a train, after the walk to it: on walks and at changes.
enum Leeway {
    /// "6 minutes of leeway", "1 minute of leeway", or "No leeway" under a minute. `short`, where
    /// room is tight: "6 mins of leeway", "1 min of leeway".
    static func label(_ minutes: Int, short: Bool = false) -> String {
        guard minutes >= 1 else { return "No leeway" }
        let unit = short ? (minutes == 1 ? "min" : "mins") : (minutes == 1 ? "minute" : "minutes")
        return "\(minutes) \(unit) of leeway"
    }
}

/// A train's countdown just past 0:00: "At Station" for `seconds` after it's due, then on to the
/// next train. Trains only: a bus's countdown stays at 0:00.
enum AtStation {
    static let seconds: TimeInterval = 15
    static let label = "At Station"
    /// Where there's no room for `label`: the compact Dynamic Island.
    static let shortLabel = "At Stn"

    /// A bus at its stop: said for less time, as a bus stops only a moment.
    static let busSeconds: TimeInterval = 5
    static let busLabel = "At Stop"

    /// How long one on `route` is held there: a bus's (`BusLeg.prefix`, "bus:B63") or a train's.
    static func seconds(route: String?) -> TimeInterval {
        route.flatMap(BusLeg.line(of:)) == nil ? seconds : busSeconds
    }

    /// Whether a train due at `due` is at the station at `now`, held there `seconds`.
    static func covers(_ due: Date, at now: Date, seconds: TimeInterval = seconds) -> Bool {
        due <= now && now < due.addingTimeInterval(seconds)
    }
}

/// Minutes until a train or leave time, shared by the widgets, app and Siri: rounded down, so
/// the last minute and after are "Now".
struct MinutesToGo: Equatable {
    let count: Int

    init(until date: Date, from now: Date) {
        count = max(0, Int(date.timeIntervalSince(now) / 60))
    }

    var isNow: Bool { count == 0 }

    /// "Now", "1 min", "12 min"
    var label: String { isNow ? "Now" : "\(count) min" }

    /// "Now", or "12" for use with a separate "min".
    var number: String { isNow ? "Now" : "\(count)" }

    /// For VoiceOver and Siri: "Now", "1 minute", "12 minutes".
    var spoken: String { isNow ? "Now" : count == 1 ? "1 minute" : "\(count) minutes" }
}

/// Which times get a `LiveMark` or `ScheduledMark` besides their colour. VoiceOver announces
/// the kind regardless.
struct TimeMarks: Equatable {
    /// Settings › Mark live times, Differentiate Without Color, or `inOneColor` (tinted and clear
    /// Home Screens, StandBy at night), which loses the green.
    let live: Bool
    /// Settings › Mark scheduled times.
    let scheduled: Bool

    init(marksLiveTimes: Bool, marksScheduledTimes: Bool, withoutColor: Bool, inOneColor: Bool = false) {
        live = marksLiveTimes || withoutColor || inOneColor
        scheduled = marksScheduledTimes
    }

    func showsMark(isLive: Bool) -> Bool {
        isLive ? live : scheduled
    }
}

enum ClockPattern {
    /// Strips the day period ("a", "b" or "B" outside quotes) and leftover space: "h:mm a"
    /// becomes "h:mm".
    static func withoutDayPeriod(_ pattern: String) -> String {
        var quoted = false
        let kept = pattern.filter { character in
            if character == "'" { quoted.toggle() }
            return quoted || !"abB".contains(character)
        }
        return kept.trimmingCharacters(in: .whitespaces)
    }
}

extension Connection {
    /// For VoiceOver: "2 minutes of leeway", "no leeway", "Stay on", or "No train to change to".
    var spokenLeeway: String {
        if staysOn { return "Stay on" }
        guard let minutes = leewayMinutes else { return "No train to change to" }
        return minutes < 1 ? "no leeway" : Leeway.label(minutes)
    }
}
