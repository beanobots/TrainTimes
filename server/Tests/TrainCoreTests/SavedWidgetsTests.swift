import Foundation
import Testing
@testable import TrainCore

/// The widgets set up in the app's Widgets tab: loading what older versions
/// saved, checking it against the station list, ordering, and commuting hours.
@Suite struct SavedWidgetsTests {
    /// In New York, as the app's widgets are.
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    /// That day and time in New York.
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Loading

    @Test func widgetsSavedByOlderVersionsStillLoad() throws {
        // A change from before it had a way, commuting hours from before they
        // had days, and a widget from before it had a name
        let json = #"""
        {"widgets": [
            {"id": "5D1C8A0E-0F57-4E2B-9C3A-7B1E2D4F6A01", "name": "Home",
             "selection": {"stationID": "R34", "route": "R", "direction": "N"},
             "change": {"stationID": "R31", "routes": ["D", "N"], "quickMinutes": 2, "walkMinutes": 3},
             "commute": {"selection": {"stationID": "R31", "routes": ["R"], "direction": "S"}, "start": 1020, "end": 1140}},
            {"id": "6E2D9B1F-1A68-4F3C-8D4B-8C2F3E5A7B12",
             "selection": {"stationID": "L24", "routes": ["L"], "direction": "N"}}
        ], "defaultID": "6E2D9B1F-1A68-4F3C-8D4B-8C2F3E5A7B12"}
        """#
        let saved = try JSONDecoder().decode(SavedWidgets.self, from: Data(json.utf8))
        #expect(saved.widgets.count == 2)
        #expect(saved.defaultWidget.id == saved.widgets[1].id)
        let home = saved.widgets[0]
        #expect(home.change?.departureDirection(for: home.selection) == .north)
        #expect(home.commute?.weekdays == [2, 3, 4, 5, 6])
        #expect(home.commute?.start == 17 * 60)
        #expect(saved.widgets[1].name.isEmpty)
        #expect(saved.widgets[1].title == "Atlantic Av")
    }

    @Test func aChangeThatCantBeReadIsLostOnItsOwn() throws {
        let json = #"""
        {"id": "5D1C8A0E-0F57-4E2B-9C3A-7B1E2D4F6A01", "name": "",
         "selection": {"stationID": "R34", "routes": ["R"], "direction": "N"},
         "change": {"station": "R31"}}
        """#
        let widget = try JSONDecoder().decode(SavedWidget.self, from: Data(json.utf8))
        #expect(widget.selection == prospect)
        #expect(widget.change == nil)
    }

    @Test func savesAsItLoads() throws {
        var commute = CommutingHours(selection: Selection(stationID: "R31", routes: ["R"], direction: .south),
                                     change: Change(stationID: "R34", routes: ["N"]))
        commute.weekdays = [1, 7]
        let saved = SavedWidgets(widgets: [
            SavedWidget(name: "Home", selection: prospect,
                        change: Change(stationID: "R31", routes: ["D"], direction: .north, quickMinutes: 1),
                        commute: commute),
        ])
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(SavedWidgets.self, from: data) == saved)
    }

    // MARK: Checking

    @Test func checkingDropsAChangeThatCantBeMade() {
        let seven = Selection(stationID: "720", routes: ["7"], direction: .north)
        let saved = SavedWidgets(widgets: [
            SavedWidget(selection: prospect, change: Change(stationID: "D24", routes: ["R", "N"])),
            // The G only ends its run at Court Sq going the 7's way
            SavedWidget(selection: seven, change: Change(stationID: "G22", routes: ["G"]),
                        commute: CommutingHours(selection: seven, change: Change(stationID: "G22", routes: ["G"],
                                                                                   direction: .south))),
        ]).validated()
        #expect(saved.widgets[0].change?.routes == ["N"])
        #expect(saved.widgets[1].change == nil)
        #expect(saved.widgets[1].commute?.change?.routes == ["G"])
    }

    @Test func commutingHoursShowTheirTrainAndChange() {
        let home = Selection(stationID: "R31", routes: ["R"], direction: .south, serviceAlerts: true, walkMinutes: 2)
        let change = Change(stationID: "R31", routes: ["D", "N"])
        var widget = SavedWidget(selection: Selection(stationID: "R34", routes: ["R"], direction: .north, elevatorAlerts: true,
                                                      serviceAlerts: false),
                                 change: change)
        widget.commute = CommutingHours(selection: home, change: nil, start: 17 * 60, end: 19 * 60)
        // The phone's time zone, which they go by
        let local = { (hour: Int) in
            Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: hour))!
        }
        let evening = widget.shown(at: local(18))
        #expect(evening.selection.stationID == "R31")
        #expect(evening.selection.walkMinutes == 2)
        // The alerts it mentions are the widget's
        #expect(evening.selection.elevatorAlerts)
        #expect(!evening.selection.serviceAlerts)
        #expect(evening.change == nil)
        #expect(widget.shown(at: local(8)) == widget)
    }

    // MARK: Ordering

    @Test func movingWidgets() {
        let ids = (0..<4).map { _ in UUID() }
        var saved = SavedWidgets(widgets: ids.map { SavedWidget(id: $0, selection: prospect) })
        saved.move(fromOffsets: IndexSet([0, 2]), toOffset: 4)
        #expect(saved.widgets.map(\.id) == [ids[1], ids[3], ids[0], ids[2]])
        saved.move(fromOffsets: IndexSet([3]), toOffset: 0)
        #expect(saved.widgets.map(\.id) == [ids[2], ids[1], ids[3], ids[0]])
        // Deleting the default makes the first of the rest it; the last one stays
        saved.makeDefault(ids[2])
        saved.delete(ids[2])
        #expect(saved.defaultWidget.id == ids[1])
        for id in ids { saved.delete(id) }
        #expect(saved.widgets.count == 1)
    }

    // MARK: Commuting hours

    @Test func hoursOnTheirDays() {
        // 7 to 10 on weekdays, to start with; 19 October 2026 is a Monday
        let hours = CommutingHours(selection: prospect)
        #expect(hours.isActive(at: date(2026, 10, 19, 7), calendar: calendar))
        #expect(hours.isActive(at: date(2026, 10, 19, 9, 59), calendar: calendar))
        #expect(!hours.isActive(at: date(2026, 10, 19, 10), calendar: calendar))
        #expect(!hours.isActive(at: date(2026, 10, 19, 6, 59), calendar: calendar))
        #expect(!hours.isActive(at: date(2026, 10, 18, 8), calendar: calendar))
    }

    @Test func hoursPastMidnightBelongToTheDayTheyStart() {
        // Friday 22:00 to 2:00
        let hours = CommutingHours(selection: prospect, start: 22 * 60, end: 2 * 60, weekdays: [6])
        #expect(hours.isActive(at: date(2026, 10, 23, 23), calendar: calendar))
        #expect(hours.isActive(at: date(2026, 10, 24, 1, 30), calendar: calendar))
        #expect(!hours.isActive(at: date(2026, 10, 24, 2), calendar: calendar))
        #expect(!hours.isActive(at: date(2026, 10, 24, 23), calendar: calendar))
        // Thursday night's are Thursday's, which isn't chosen
        #expect(!hours.isActive(at: date(2026, 10, 23, 1), calendar: calendar))
        // Saturday into Sunday wraps around the week
        let saturday = CommutingHours(selection: prospect, start: 23 * 60, end: 60, weekdays: [7])
        #expect(saturday.isActive(at: date(2026, 10, 25, 0, 30), calendar: calendar))
        #expect(!saturday.isActive(at: date(2026, 10, 26, 0, 30), calendar: calendar))
    }

    @Test func hoursThatNeverRun() {
        let same = CommutingHours(selection: prospect, start: 8 * 60, end: 8 * 60)
        #expect(!same.isActive(at: date(2026, 10, 19, 8), calendar: calendar))
        #expect(same.nextSwitch(after: date(2026, 10, 19, 7), calendar: calendar) == nil)
        let noDays = CommutingHours(selection: prospect, weekdays: [])
        #expect(!noDays.isActive(at: date(2026, 10, 19, 8), calendar: calendar))
        #expect(noDays.nextSwitch(after: date(2026, 10, 19, 6), calendar: calendar) == nil)
    }

    @Test func theNextSwitch() {
        let hours = CommutingHours(selection: prospect)
        #expect(hours.nextSwitch(after: date(2026, 10, 19, 6), calendar: calendar) == date(2026, 10, 19, 7))
        #expect(hours.nextSwitch(after: date(2026, 10, 19, 8), calendar: calendar) == date(2026, 10, 19, 10))
        // Friday evening, it's Monday morning
        #expect(hours.nextSwitch(after: date(2026, 10, 23, 21), calendar: calendar) == date(2026, 10, 26, 7))
        // Past midnight, the end the next day
        let night = CommutingHours(selection: prospect, start: 22 * 60, end: 2 * 60, weekdays: [6])
        #expect(night.nextSwitch(after: date(2026, 10, 23, 23), calendar: calendar) == date(2026, 10, 24, 2))
    }

    @Test func theNextSwitchOverAChangeOfClocks() {
        // The clocks went forward at 2:00 on Sunday 8 March 2026, and back at 2:00 on Sunday 1 November
        let everyDay = CommutingHours(selection: prospect, weekdays: Set(1...7))
        let spring = everyDay.nextSwitch(after: date(2026, 3, 7, 23), calendar: calendar)
        #expect(spring == date(2026, 3, 8, 7))
        #expect(spring.map { calendar.component(.hour, from: $0) } == 7)
        let autumn = everyDay.nextSwitch(after: date(2026, 10, 31, 23), calendar: calendar)
        #expect(autumn.map { calendar.component(.hour, from: $0) } == 7)
        #expect(autumn.map { calendar.component(.day, from: $0) } == 1)
    }
}
