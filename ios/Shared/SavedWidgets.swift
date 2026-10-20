import Foundation

/// A widget set up in the app's Widgets tab: a train, and what its widget
/// mentions. A widget on the Home Screen or Lock Screen picks one in its Edit menu.
struct SavedWidget: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// Blank to go by the station's name.
    var name: String
    var selection: Selection
    /// Where to change to another train, which the large widget shows.
    var change: Change?
    /// When widgets showing this one show another train instead.
    var commute: CommutingHours?

    /// The id of the one made from the app's train before there were saved widgets.
    static let firstID = UUID(uuidString: "5D1C8A0E-0F57-4E2B-9C3A-7B1E2D4F6A01")!

    init(id: UUID = UUID(), name: String = "", selection: Selection, change: Change? = nil,
         commute: CommutingHours? = nil) {
        self.id = id
        self.name = name
        self.selection = selection
        self.change = change
        self.commute = commute
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, selection, change, commute
    }

    /// One saved without a name still loads, going by the station's, and one
    /// whose change can't be read loses just that. Any property added later
    /// needs a default here too: one widget that can't be read leaves them all unread.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                  selection: try container.decode(Selection.self, forKey: .selection),
                  change: try? container.decodeIfPresent(Change.self, forKey: .change),
                  commute: try container.decodeIfPresent(CommutingHours.self, forKey: .commute))
    }

    /// Its name, or the station's.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (selection.station?.name ?? "Train") : trimmed
    }

    /// What a widget showing this one shows at `date`: in its commuting hours
    /// their train and change, mentioning the alerts this one does; otherwise itself.
    func shown(at date: Date) -> SavedWidget {
        guard let commute, commute.isActive(at: date) else { return self }
        var shown = self
        shown.selection = commute.selection
        shown.selection.serviceAlerts = selection.serviceAlerts
        shown.selection.elevatorAlerts = selection.elevatorAlerts
        shown.change = commute.change
        return shown
    }

    /// Another train, keeping the change only where it's still on its way,
    /// in the one change to the widget.
    mutating func setSelection(_ new: Selection) {
        change = keptChange(change, from: selection, to: new)
        selection = new
    }
}

/// What becomes of `change` when its train goes from `old` to `new`. Another
/// line or direction goes another way, which the change isn't on, so it goes;
/// another station the same way keeps it while it's still ahead.
private func keptChange(_ change: Change?, from old: Selection, to new: Selection) -> Change? {
    guard old != new else { return change }
    guard old.routes == new.routes, old.direction == new.direction else { return nil }
    return change?.validated(for: new)
}

/// The saved widgets, in the order the Widgets tab lists them, and which one
/// is the default: the one widgets show until they pick another, and whose
/// train, as it shows it at the time, Siri and its countdown go by.
struct SavedWidgets: Codable, Hashable, Sendable {
    /// Never empty.
    private(set) var widgets: [SavedWidget]
    private(set) var defaultID: UUID

    init(widgets: [SavedWidget], defaultID: UUID? = nil) {
        let widgets = widgets.isEmpty ? [SavedWidget(selection: .fallback)] : widgets
        self.widgets = widgets
        self.defaultID = defaultID.flatMap { id in widgets.contains { $0.id == id } ? id : nil } ?? widgets[0].id
    }

    private enum CodingKeys: String, CodingKey {
        case widgets, defaultID
    }

    /// Through `init(widgets:defaultID:)`, so a saved file with no widgets, or
    /// a default that's gone, still loads as something valid.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(widgets: try container.decode([SavedWidget].self, forKey: .widgets),
                  defaultID: try container.decodeIfPresent(UUID.self, forKey: .defaultID))
    }

    var defaultWidget: SavedWidget { widget(defaultID) ?? widgets[0] }

    func widget(_ id: UUID) -> SavedWidget? {
        widgets.first { $0.id == id }
    }

    /// Replaces the saved widget with the same id.
    mutating func update(_ widget: SavedWidget) {
        guard let index = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        widgets[index] = widget
    }

    mutating func add(_ widget: SavedWidget) {
        widgets.append(widget)
    }

    /// The last one stays; deleting the default makes the first of the rest it.
    mutating func delete(_ id: UUID) {
        guard widgets.count > 1 else { return }
        widgets.removeAll { $0.id == id }
        if id == defaultID { defaultID = widgets[0].id }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { widgets[$0] }
        var rest = widgets.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: destination - before)
        widgets = rest
    }

    mutating func makeDefault(_ id: UUID) {
        if widget(id) != nil { defaultID = id }
    }

    /// Each saved train and change checked against the station list, as
    /// `Selection.validated` and `Change.validated` do.
    func validated() -> SavedWidgets {
        var saved = self
        saved.widgets = widgets.map { widget in
            var widget = widget
            widget.selection = widget.selection.validated()
            widget.change = widget.change?.validated(for: widget.selection)
            if var commute = widget.commute {
                commute.selection = commute.selection.validated()
                commute.change = commute.change?.validated(for: commute.selection)
                widget.commute = commute
            }
            return widget
        }
        return saved
    }
}

/// The times of day, on the days chosen, a saved widget shows another train,
/// say the train home in the evening. In the phone's time zone. A range that
/// ends before it starts runs past midnight, into the next day.
struct CommutingHours: Codable, Hashable, Sendable {
    /// The train shown in these hours, with its walking time. Which alerts
    /// it mentions is the saved widget's.
    var selection: Selection
    /// Where that train is left for another, for the Transfers widget.
    var change: Change?
    /// Minutes after midnight.
    var start: Int = 7 * 60
    var end: Int = 10 * 60
    /// `Calendar` weekdays, 1 for Sunday; Monday to Friday to start with.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]

    private enum CodingKeys: String, CodingKey {
        case selection, change, start, end, weekdays
    }

    /// Another train in these hours, keeping their change only where it's
    /// still on its way, as a saved widget's own train does.
    mutating func setSelection(_ new: Selection) {
        change = keptChange(change, from: selection, to: new)
        selection = new
    }

    /// Whether `date` is in these hours. One that starts after midnight is
    /// in the day it started on's hours.
    func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        guard start != end else { return false }
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday else { return false }
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if start < end {
            return weekdays.contains(weekday) && (start..<end).contains(minute)
        }
        let yesterday = weekday == 1 ? 7 : weekday - 1
        return (weekdays.contains(weekday) && minute >= start) || (weekdays.contains(yesterday) && minute < end)
    }

    /// The next time after `date` these hours start or end; nil if they never do.
    func nextSwitch(after date: Date, calendar: Calendar = .current) -> Date? {
        let active = isActive(at: date, calendar: calendar)
        let today = calendar.startOfDay(for: date)
        // Each start and end over the next week, the soonest first
        let candidates = (0...7).flatMap { offset -> [Date] in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return [] }
            return [start, end].compactMap {
                calendar.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: day)
            }
        }
        return candidates.filter { $0 > date }.sorted().first { isActive(at: $0, calendar: calendar) != active }
    }
}

extension CommutingHours {
    /// Hours saved without any of these still load, with them at their
    /// defaults, and a change that can't be read is left out. Here, not in
    /// the type, so it keeps its memberwise init.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(selection: try container.decode(Selection.self, forKey: .selection),
                  change: try? container.decodeIfPresent(Change.self, forKey: .change))
        start = try container.decodeIfPresent(Int.self, forKey: .start) ?? start
        end = try container.decodeIfPresent(Int.self, forKey: .end) ?? end
        weekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? weekdays
    }
}
