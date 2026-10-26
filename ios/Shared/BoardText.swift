import Foundation

/// `Text(timerInterval:)` takes all offered width, so callers size it to its digits.
enum TimerText {
    /// The widest text counting down from `seconds`: "0:00", "00:00" from 10 minutes, "0:00:00"
    /// from an hour. Thresholds are a second early in case the timer rounds up.
    static func placeholder(seconds: TimeInterval) -> String {
        seconds >= 3599 ? "0:00:00" : seconds >= 599 ? "00:00" : "0:00"
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
    /// For VoiceOver: "2 minute wait", "under a minute's wait" (plus ", quick change" if
    /// `quick`), "Stay on", or "No train to change to".
    func spokenWait(quick: Bool) -> String {
        if staysOn { return "Stay on" }
        guard let minutes = waitMinutes else { return "No train to change to" }
        let wait = minutes < 1 ? "under a minute's wait" : "\(minutes) minute wait"
        return quick ? "\(wait), quick change" : wait
    }
}
