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
