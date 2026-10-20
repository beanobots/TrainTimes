import Foundation

/// A live countdown, `Text(timerInterval:)`, takes all the width it's offered,
/// so the widgets and the countdown hold it to the width of its digits.
enum TimerText {
    /// The widest a countdown gets counting down from `seconds`: "0:00",
    /// "00:00" from 10 minutes, "0:00:00" from an hour. A second early,
    /// should the timer round up.
    static func placeholder(seconds: TimeInterval) -> String {
        seconds >= 3599 ? "0:00:00" : seconds >= 599 ? "00:00" : "0:00"
    }
}

/// The minutes to go until a train, or until it's time to leave for it, as
/// the widgets, the app and Siri all count them: whole minutes, rounded down,
/// so the last minute and after are "Now".
struct MinutesToGo: Equatable {
    let count: Int

    init(until date: Date, from now: Date) {
        count = max(0, Int(date.timeIntervalSince(now) / 60))
    }

    var isNow: Bool { count == 0 }

    /// "Now", "1 min", "12 min"
    var label: String { isNow ? "Now" : "\(count) min" }

    /// "Now", or "12" with a "min" of its own after it.
    var number: String { isNow ? "Now" : "\(count)" }

    /// As VoiceOver and Siri say it: "Now", "1 minute", "12 minutes".
    var spoken: String { isNow ? "Now" : count == 1 ? "1 minute" : "\(count) minutes" }
}

/// Which times get a mark beside them as well as their colour: `LiveMark` or
/// `ScheduledMark`. VoiceOver says which a time is either way.
struct TimeMarks: Equatable {
    /// With Settings › Mark live times, the phone's Differentiate Without
    /// Color, or `inOneColor`, where a widget is drawn in one colour (tinted
    /// and clear Home Screens, StandBy at night), which leaves out the green.
    let live: Bool
    /// With Settings › Mark scheduled times.
    let scheduled: Bool

    init(marksLiveTimes: Bool, marksScheduledTimes: Bool, withoutColor: Bool, inOneColor: Bool = false) {
        live = marksLiveTimes || withoutColor || inOneColor
        scheduled = marksScheduledTimes
    }

    /// Whether a time gets its mark: a live prediction's, or a timetable time's.
    func showsMark(isLive: Bool) -> Bool {
        isLive ? live : scheduled
    }
}

enum ClockPattern {
    /// `pattern`, a date format such as the phone's "h:mm a", without its AM
    /// or PM ("a", "b" or "B", outside quotes) or the space it leaves: "h:mm".
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
    /// The wait at the change as VoiceOver says it: "2 minute wait", "under a
    /// minute's wait", and after a wait highlighted as `quick`, "quick change";
    /// or "Stay on", or "No train to change to".
    func spokenWait(quick: Bool) -> String {
        if staysOn { return "Stay on" }
        guard let minutes = waitMinutes else { return "No train to change to" }
        let wait = minutes < 1 ? "under a minute's wait" : "\(minutes) minute wait"
        return quick ? "\(wait), quick change" : wait
    }
}
