import Foundation
import Testing
@testable import TrainCore

/// How the Next train and Transfers widgets plan their timelines
/// (Shared/TimelinePlan.swift): when entries come, what each keeps, and when
/// the widget reloads.
@Suite struct TimelinePlanTests {
    func time(_ minutes: Double) -> Date {
        now.addingTimeInterval(minutes * 60)
    }

    /// A train with its stops and where the feed says it is.
    func mapped(_ minutes: Double, trip: String) -> Arrival {
        var train = arrival(minutes, trip: trip)
        train.approach = [Arrival.Stop(id: "R35N", time: time(minutes - 2)), Arrival.Stop(id: "R34N", time: time(minutes))]
        train.position = Arrival.Position(stop: "R35N", isStopped: true)
        return train
    }

    /// Noon, or `hour`, in New York on a weekday.
    func newYork(hour: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        return try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: hour)))
    }

    // MARK: Entries

    @Test func anEntryAsEachTrainsTimeToLeavePasses() {
        let trains = [arrival(2, trip: "a"), arrival(6, trip: "b"), arrival(9, trip: "c")]
        #expect(TimelinePlan.dates(after: now, toCatch: trains, selection: prospect, everyMinute: false)
            == [time(2), time(6), time(9)])

        // With a walk, its leave times; and every entry's first train is still one to catch
        var walking = prospect
        walking.walkMinutes = 3
        let dates = TimelinePlan.dates(after: now, toCatch: trains, selection: walking, everyMinute: false)
        #expect(dates == [time(3), time(6)])
        for date in [now] + dates {
            let shown = TimelinePlan.trains(trains, at: date, selection: walking, fetched: now, keepsStops: true)
            let first = shown.first
            #expect(first.map { walking.leaveTime(for: $0) > date } ?? true)
        }
    }

    @Test func aHeldTrainKeepsItsEntryUntilItLeaves() {
        var held = arrival(2, trip: "a")
        held.departure = time(4)
        let trains = [held, arrival(6, trip: "b")]
        #expect(TimelinePlan.dates(after: now, toCatch: trains, selection: prospect, everyMinute: false)
            == [time(2), time(4), time(6)])
        #expect(TimelinePlan.runsOut(trains, selection: prospect) == time(6))
        #expect(TimelinePlan.runsOut([held], selection: prospect) == time(4))
        #expect(TimelinePlan.runsOut([], selection: prospect) == nil)
    }

    @Test func mapsGetAnEntryAMinuteForAnHourAtMost() {
        let soon = [arrival(2, trip: "a"), arrival(5.5, trip: "b")]
        #expect(TimelinePlan.dates(after: now, toCatch: soon, selection: prospect, everyMinute: true)
            == [time(1), time(2), time(3), time(4), time(5), time(5.5)])

        // Ten trains get entries of their own, the last of them 90 minutes off; the minutes stop at an hour
        let many = (1...15).map { arrival(Double($0 * 9), trip: "t\($0)") }
        let dates = TimelinePlan.dates(after: now, toCatch: many, selection: prospect, everyMinute: true)
        #expect(dates.first == time(1))
        #expect(dates.last == time(90))
        #expect(!dates.contains(time(99)))
        #expect(dates.filter { $0 > time(59) && $0 < time(90) } == [time(63), time(72), time(81)])
        #expect(dates.count == 59 + 4)
        #expect(TimelinePlan.runsOut(many, selection: prospect) == time(90))
    }

    @Test func onlyTheNextTrainKeepsItsStopsAndPositionsGoAfterAMinute() {
        let trains = [mapped(-1, trip: "gone"), mapped(4, trip: "a"), mapped(8, trip: "b")]
        let fresh = TimelinePlan.trains(trains, at: now, selection: prospect, fetched: now, keepsStops: true)
        #expect(fresh.map(\.trip) == ["a", "b"])
        #expect(fresh.map(\.approach.count) == [2, 0])
        #expect(fresh[0].position != nil)

        let later = TimelinePlan.trains(trains, at: time(1.5), selection: prospect, fetched: now, keepsStops: true)
        #expect(later[0].approach.count == 2)
        #expect(later.allSatisfy { $0.position == nil })

        // The small widget has no map
        let small = TimelinePlan.trains(trains, at: now, selection: prospect, fetched: now, keepsStops: false)
        #expect(small.allSatisfy { $0.approach.isEmpty })
    }

    @Test func connectionsLoseTheirPositionsAfterAMinuteToo() {
        let connections = [4.0, 8].map { minutes in
            Connection(first: mapped(minutes, trip: "r\(minutes)"), arrival: mapped(minutes + 6, trip: "r\(minutes)"),
                       next: mapped(minutes + 8, trip: "d\(minutes)"))
        }
        let fresh = TimelinePlan.connections(connections, at: now, selection: prospect, fetched: now, keepsStops: true)
        #expect(fresh[0].first.approach.count == 2 && fresh[0].arrival.approach.count == 2)
        #expect(fresh[0].next?.approach.count == 2)
        #expect(fresh[1].first.approach.isEmpty && fresh[1].arrival.approach.isEmpty)
        #expect(fresh[1].next?.approach.isEmpty == true)
        #expect(fresh[0].arrival.position != nil)

        let later = TimelinePlan.connections(connections, at: time(1.5), selection: prospect, fetched: now,
                                             keepsStops: true)
        #expect(later[0].arrival.approach.count == 2)
        for connection in later {
            #expect(connection.first.position == nil)
            #expect(connection.arrival.position == nil)
            #expect(connection.next?.position == nil)
        }

        // Once its train at your station has gone, a connection goes
        let gone = TimelinePlan.connections(connections, at: time(5), selection: prospect, fetched: now, keepsStops: true)
        #expect(gone.map(\.first.trip) == ["r8.0"])
        #expect(gone[0].arrival.approach.count == 2)
    }

    // MARK: Reloads

    @Test func reloadsLessOftenOvernight() throws {
        let (noon, six, eleven, two) = (try newYork(hour: 12), try newYork(hour: 6), try newYork(hour: 23),
                                        try newYork(hour: 2))
        #expect(TimelinePlan.reloadInterval(at: noon) == 5 * 60)
        #expect(TimelinePlan.reloadInterval(at: six) == 5 * 60)
        #expect(TimelinePlan.reloadInterval(at: eleven) == 15 * 60)
        #expect(TimelinePlan.reloadInterval(at: two) == 15 * 60)
    }

    @Test func reloadsByWhenTheTimesWereFetchedButNeverWithinAMinute() throws {
        let noon = try newYork(hour: 12)
        let minute = { (minutes: Double) in noon.addingTimeInterval(minutes * 60) }
        #expect(TimelinePlan.reload(now: noon, fetched: noon, runsOut: nil, switches: nil) == minute(5))
        // Times another widget fetched a while ago
        #expect(TimelinePlan.reload(now: noon, fetched: minute(-3), runsOut: nil, switches: nil) == minute(2))
        #expect(TimelinePlan.reload(now: noon, fetched: minute(-10), runsOut: nil, switches: nil) == minute(1))
        // Without new times, soon
        #expect(TimelinePlan.reload(now: noon, fetched: nil, runsOut: nil, switches: nil) == minute(2))
        // Sooner as the trains run out, or commuting hours switch
        #expect(TimelinePlan.reload(now: noon, fetched: noon, runsOut: minute(3), switches: nil) == minute(3))
        #expect(TimelinePlan.reload(now: noon, fetched: noon, runsOut: minute(3), switches: minute(2)) == minute(2))
        #expect(TimelinePlan.reload(now: noon, fetched: noon, runsOut: minute(0.2), switches: nil) == minute(1))
    }

    @Test func showingOldTimesItTriesAgainLessOftenTheOlderTheyAre() throws {
        let (noon, two) = (try newYork(hour: 12), try newYork(hour: 2))
        let minute = { (minutes: Double) in noon.addingTimeInterval(minutes * 60) }
        // Just after times that came, soon
        #expect(TimelinePlan.reload(now: noon, fetched: nil, old: minute(-1), runsOut: nil, switches: nil) == minute(2))
        // Then after as long as they're old
        #expect(TimelinePlan.reload(now: noon, fetched: nil, old: minute(-3.5), runsOut: nil, switches: nil)
            == minute(3.5))
        // But no later than with new ones, overnight too
        #expect(TimelinePlan.reload(now: noon, fetched: nil, old: minute(-20), runsOut: nil, switches: nil) == minute(5))
        #expect(TimelinePlan.reload(now: two, fetched: nil, old: two.addingTimeInterval(-40 * 60), runsOut: nil,
                                    switches: nil) == two.addingTimeInterval(15 * 60))
        // And sooner as they run out of trains, or commuting hours switch
        #expect(TimelinePlan.reload(now: noon, fetched: nil, old: minute(-20), runsOut: minute(3), switches: nil)
            == minute(3))
        #expect(TimelinePlan.reload(now: noon, fetched: nil, old: minute(-20), runsOut: nil, switches: minute(4))
            == minute(4))
        // Ones from after now, saved before the clock was set back, are tried again soon
        #expect(TimelinePlan.reload(now: noon, fetched: nil, old: minute(10), runsOut: nil, switches: nil) == minute(2))
    }

    @Test func aTapAfterATryFailsDoesntPutOffTheNext() throws {
        let (noon, two) = (try newYork(hour: 12), try newYork(hour: 2))
        let minute = { (minutes: Double) in noon.addingTimeInterval(minutes * 60) }
        // A try at noon fails, with times 5 minutes old: the next is at 12:05
        #expect(TimelinePlan.reload(now: noon, fetched: nil, old: minute(-5), runsOut: nil, switches: nil) == minute(5))
        // A tap at 12:04 redraws the widget with them, and the next try is still at 12:05
        #expect(TimelinePlan.reload(now: minute(4), fetched: nil, old: minute(-5), failed: noon, runsOut: nil,
                                    switches: nil) == minute(5))
        // Overnight too: not 15 minutes after the tap
        let twoTen = two.addingTimeInterval(10 * 60)
        #expect(TimelinePlan.reload(now: twoTen, fetched: nil, old: two.addingTimeInterval(-40 * 60), failed: two,
                                    runsOut: nil, switches: nil) == two.addingTimeInterval(15 * 60))
        // But never within a minute of the tap, nor long after it once that try's next is past
        #expect(TimelinePlan.reload(now: minute(4.5), fetched: nil, old: minute(-5), failed: noon, runsOut: nil,
                                    switches: nil) == minute(5.5))
        #expect(TimelinePlan.reload(now: minute(30), fetched: nil, old: minute(-5), failed: noon, runsOut: nil,
                                    switches: nil) == minute(31))
        // And sooner as they run out of trains
        #expect(TimelinePlan.reload(now: minute(2), fetched: nil, old: minute(-5), failed: noon, runsOut: minute(4),
                                    switches: nil) == minute(4))
        // A try that failed after now, before the clock was set back, failed now
        #expect(TimelinePlan.reload(now: noon, fetched: nil, old: minute(-5), failed: minute(10), runsOut: nil,
                                    switches: nil) == minute(5))
    }

    @Test func savedTimesAreReusedOnlyWhenFreshOrAfterATap() {
        let some = { true }
        let none = { false }
        // Fetched in the last 30 seconds, by another widget or the countdown
        #expect(TimelinePlan.reuses(saved: now.addingTimeInterval(-20), refreshed: nil, toggled: nil, anyToCatch: none,
                                    now: now))
        #expect(!TimelinePlan.reuses(saved: now.addingTimeInterval(-40), refreshed: nil, toggled: nil, anyToCatch: some,
                                     now: now))
        // After a tap on the map, older ones, while a train's still to catch
        let tapped = now.addingTimeInterval(-5)
        #expect(TimelinePlan.reuses(saved: time(-20), refreshed: nil, toggled: tapped, anyToCatch: some, now: now))
        #expect(!TimelinePlan.reuses(saved: time(-20), refreshed: nil, toggled: tapped, anyToCatch: none, now: now))
        #expect(!TimelinePlan.reuses(saved: time(-20), refreshed: nil, toggled: time(-1), anyToCatch: some, now: now))
        // Never from before the widget's ↻
        #expect(!TimelinePlan.reuses(saved: now.addingTimeInterval(-10), refreshed: now.addingTimeInterval(-5),
                                     toggled: tapped, anyToCatch: some, now: now))
    }

    // MARK: The clock set back

    @Test func aTimeFromAfterNowIsOld() {
        #expect(now.addingTimeInterval(-29).isWithin(30, before: now))
        #expect(now.isWithin(30, before: now))
        #expect(!now.addingTimeInterval(-30).isWithin(30, before: now))
        #expect(!now.addingTimeInterval(1).isWithin(30, before: now))
        #expect(!now.addingTimeInterval(1).isWithin(0, before: now))
    }

    @Test func timesSavedBeforeTheClockWasSetBackAreFetchedAgain() {
        let some = { true }
        // Saved "later" than now: not fresh, so ↻ and the next reload fetch
        #expect(!TimelinePlan.reuses(saved: time(10), refreshed: nil, toggled: nil, anyToCatch: some, now: now))
        #expect(!TimelinePlan.reuses(saved: time(10), refreshed: now.addingTimeInterval(-1), toggled: nil,
                                     anyToCatch: some, now: now))
        // Nor is a tap from then a tap just now
        #expect(!TimelinePlan.reuses(saved: time(-20), refreshed: nil, toggled: time(10), anyToCatch: some, now: now))
    }

    @Test func aWidgetWhoseTimesAreFromAfterNowReloadsAsOldOnesDo() throws {
        let noon = try newYork(hour: 12)
        let minute = { (minutes: Double) in noon.addingTimeInterval(minutes * 60) }
        #expect(TimelinePlan.reload(now: noon, fetched: minute(60), runsOut: nil, switches: nil) == minute(1))
        #expect(TimelinePlan.reload(now: noon, fetched: minute(0.5), runsOut: nil, switches: nil) == minute(1))
    }

    @Test func positionsFromAfterNowGoToo() {
        let trains = [mapped(4, trip: "a")]
        let ahead = TimelinePlan.trains(trains, at: now, selection: prospect, fetched: time(10), keepsStops: true)
        #expect(ahead[0].approach.count == 2)
        #expect(ahead[0].position == nil)
        let connections = [Connection(first: mapped(4, trip: "a"), arrival: mapped(10, trip: "a"), next: nil)]
        let shown = TimelinePlan.connections(connections, at: now, selection: prospect, fetched: time(10), keepsStops: true)
        #expect(shown[0].first.position == nil)
    }
}
