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

    /// Every widget, the app and Siri count the minutes to go alike.
    @Test func minutesToGoAreWholeMinutesThenNow() {
        func minutes(_ seconds: TimeInterval) -> MinutesToGo {
            MinutesToGo(until: now.addingTimeInterval(seconds), from: now)
        }
        #expect(minutes(12 * 60 + 59).count == 12)
        #expect(minutes(12 * 60 + 59).label == "12 min")
        #expect(minutes(12 * 60 + 59).number == "12")
        #expect(minutes(12 * 60 + 59).spoken == "12 minutes")
        #expect(minutes(60).label == "1 min")
        #expect(minutes(60).spoken == "1 minute")
        // The last minute, and a train that's due, are "Now", never "0 min"
        for seconds in [59.0, 0, -90] {
            #expect(minutes(seconds).count == 0)
            #expect(minutes(seconds).isNow)
            #expect(minutes(seconds).label == "Now")
            #expect(minutes(seconds).number == "Now")
            #expect(minutes(seconds).spoken == "Now")
        }
    }

    @Test func liveTimesAreMarkedWhereTheirGreenIsntEnough() {
        func marks(live: Bool = false, scheduled: Bool = false, withoutColor: Bool = false,
                   inOneColor: Bool = false) -> TimeMarks {
            TimeMarks(marksLiveTimes: live, marksScheduledTimes: scheduled, withoutColor: withoutColor,
                      inOneColor: inOneColor)
        }
        #expect(!marks().showsMark(isLive: true))
        #expect(!marks().showsMark(isLive: false))
        #expect(marks(live: true).showsMark(isLive: true))
        #expect(!marks(live: true).showsMark(isLive: false))
        // Differentiate Without Color, or a widget drawn in one colour, marks live times whatever Settings say
        #expect(marks(withoutColor: true).showsMark(isLive: true))
        #expect(marks(inOneColor: true).showsMark(isLive: true))
        #expect(!marks(withoutColor: true, inOneColor: true).showsMark(isLive: false))
        // Timetable times only as Settings say
        #expect(marks(scheduled: true).showsMark(isLive: false))
        #expect(!marks(scheduled: true).showsMark(isLive: true))
    }

    /// The R getting to the change at 10 minutes, and a D there `wait` minutes later.
    func connection(wait: Double?, staysOn: Bool = false) -> Connection {
        let atChange = arrival(10, trip: "r1")
        let next = wait.map { arrival(10 + $0, trip: staysOn ? "r1" : "d1", route: "D") }
        return Connection(first: arrival(4, trip: "r1"), arrival: atChange, next: next)
    }

    @Test func leewayIsSpokenAsItsShown() {
        #expect(connection(wait: 2).spokenLeeway == "2 minutes of leeway")
        #expect(connection(wait: 1.5).spokenLeeway == "1 minute of leeway")
        // The walk to the other platform comes out of it
        var walked = connection(wait: 6)
        walked.walk = 120
        #expect(walked.spokenLeeway == "4 minutes of leeway")
        // Rounded down: 0.9 minutes is no leeway, not "1 minute"
        #expect(connection(wait: 0.9).spokenLeeway == "no leeway")
        #expect(connection(wait: nil).spokenLeeway == "No train to change to")
        #expect(connection(wait: 0, staysOn: true).spokenLeeway == "Stay on")
    }

    @Test func leewayLabels() {
        #expect(Leeway.label(6) == "6 minutes of leeway")
        #expect(Leeway.label(1) == "1 minute of leeway")
        #expect(Leeway.label(6, short: true) == "6 mins of leeway")
        #expect(Leeway.label(1, short: true) == "1 min of leeway")
        #expect(Leeway.label(0) == "No leeway")
    }
}
