import Foundation
import Testing
@testable import TrainCore

/// What the widgets and the countdown write and say (Shared/BoardText.swift).
@Suite struct BoardTextTests {
    @Test func countdownsAreHeldToTheirWidestDigits() {
        #expect(TimerText.placeholder(seconds: 0) == "0:00")
        #expect(TimerText.placeholder(seconds: 598) == "0:00")
        // A second early, should the timer round up to 10:00
        #expect(TimerText.placeholder(seconds: 599) == "00:00")
        #expect(TimerText.placeholder(seconds: 3598) == "00:00")
        #expect(TimerText.placeholder(seconds: 3599) == "0:00:00")
    }

    @Test func clocksLeaveOutAMAndPM() {
        #expect(ClockPattern.withoutDayPeriod("h:mm a") == "h:mm")
        #expect(ClockPattern.withoutDayPeriod("a h:mm") == "h:mm")
        #expect(ClockPattern.withoutDayPeriod("ah:mm") == "h:mm")
        #expect(ClockPattern.withoutDayPeriod("h:mm B") == "h:mm")
        #expect(ClockPattern.withoutDayPeriod("HH:mm") == "HH:mm")
        // Quoted text stays as it is
        #expect(ClockPattern.withoutDayPeriod("HH 'h' mm") == "HH 'h' mm")
        #expect(ClockPattern.withoutDayPeriod("h:mm 'bis' a") == "h:mm 'bis'")
    }

    /// The R getting to the change at 10 minutes, and a D there `wait` minutes later.
    func connection(wait: Double?, staysOn: Bool = false) -> Connection {
        let atChange = arrival(10, trip: "r1")
        let next = wait.map { arrival(10 + $0, trip: staysOn ? "r1" : "d1", route: "D") }
        return Connection(first: arrival(4, trip: "r1"), arrival: atChange, next: next)
    }

    @Test func waitsAreSpokenAsTheyreShown() {
        #expect(connection(wait: 2).spokenWait(quick: false) == "2 minute wait")
        #expect(connection(wait: 2).spokenWait(quick: true) == "2 minute wait, quick change")
        // "<1 min" on the pill, not "0 minute wait"
        #expect(connection(wait: 0.4).waitLabel == "<1 min")
        #expect(connection(wait: 0.4).spokenWait(quick: true) == "under a minute's wait, quick change")
        #expect(connection(wait: nil).spokenWait(quick: false) == "No train to change to")
        #expect(connection(wait: 0, staysOn: true).spokenWait(quick: true) == "Stay on")
    }
}
