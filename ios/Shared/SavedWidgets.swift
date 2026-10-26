import Foundation

/// A widget configured in the app's Widgets tab. Home and Lock Screen widgets pick one in their
/// Edit menu.
struct SavedWidget: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// Blank to use the station's name.
    var name: String
    var selection: Selection
    /// A transfer, shown by the large widget.
    var change: Change?
    /// Hours when this widget shows a different train.
    var commute: CommutingHours?
    /// Where you're going without a change, for Next train to show when each train gets there.
    /// With a change, its own destination is used instead (and this is kept for if it's removed).
    var destinationID: String?
    /// Whether the medium Next train widget shows the other direction beside this one.
    var bothWays: Bool

    /// Id of the widget migrated from the app's train before saved widgets existed.
    static let firstID = UUID(uuidString: "5D1C8A0E-0F57-4E2B-9C3A-7B1E2D4F6A01")!

    /// Id of `default(_:)`, which isn't saved.
    static let defaultID = UUID(uuidString: "0B7E4C2A-93D1-4F6E-A8B5-2C9D1E3F4A70")!

    /// What widgets show until they pick a saved one: Settings' default train, unnamed.
    static func `default`(_ selection: Selection) -> SavedWidget {
        SavedWidget(id: defaultID, selection: selection)
    }

    init(id: UUID = UUID(), name: String = "", selection: Selection, change: Change? = nil,
         commute: CommutingHours? = nil, destinationID: String? = nil, bothWays: Bool = false) {
        self.id = id
        self.name = name
        self.selection = selection
        self.change = change
        self.commute = commute
        self.destinationID = destinationID
        self.bothWays = bothWays
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, selection, change, commute, destinationID, bothWays
    }

    /// A missing name defaults to blank; an unreadable change is dropped. New properties must
    /// default here too, since one undecodable widget fails them all.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                  selection: try container.decode(Selection.self, forKey: .selection).droppingSavedWalk,
                  change: try? container.decodeIfPresent(Change.self, forKey: .change),
                  commute: try container.decodeIfPresent(CommutingHours.self, forKey: .commute),
                  destinationID: try container.decodeIfPresent(String.self, forKey: .destinationID),
                  bothWays: try container.decodeIfPresent(Bool.self, forKey: .bothWays) ?? false)
    }

    /// Where Next train times its trains to: the destination, when there's no change.
    var directDestination: Station? {
        change == nil ? destinationID.flatMap(StationDirectory.station(id:)) : nil
    }

    /// The name, or the station's.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (selection.station?.name ?? "Train") : trimmed
    }

    /// What to show at `date`: during commuting hours, their train and change with this one's
    /// alert settings; otherwise itself.
    func shown(at date: Date) -> SavedWidget {
        guard let commute, commute.isActive(at: date) else { return self }
        var shown = self
        shown.selection = commute.selection
        shown.selection.serviceAlerts = selection.serviceAlerts
        shown.selection.elevatorAlerts = selection.elevatorAlerts
        shown.change = commute.change
        shown.destinationID = commute.destinationID
        return shown
    }

    /// Sets the train, keeping the change only if it's still on the way, and the destination
    /// only on the same lines and direction.
    mutating func setSelection(_ new: Selection) {
        change = keptChange(change, from: selection, to: new)
        destinationID = keptDestination(destinationID, from: selection, to: new)
        selection = new
    }
}

/// `change` after its train goes from `old` to `new`: dropped for another line or direction;
/// kept for another station the same way while still ahead.
private func keptChange(_ change: Change?, from old: Selection, to new: Selection) -> Change? {
    guard old != new else { return change }
    guard old.routes == new.routes, old.direction == new.direction else { return nil }
    return change?.validated(for: new)
}

/// A destination without a change after its train goes from `old` to `new`: dropped for another
/// line or direction, or starting there.
private func keptDestination(_ id: String?, from old: Selection, to new: Selection) -> String? {
    guard old.routes == new.routes, old.direction == new.direction, id != new.stationID else { return nil }
    return id
}

/// The saved widgets in Widgets tab order. Widgets that pick none show Settings' default train
/// (`SavedWidget.default(_:)`). Older saves' `defaultID` is ignored.
struct SavedWidgets: Codable, Hashable, Sendable {
    /// Never empty.
    private(set) var widgets: [SavedWidget]

    init(widgets: [SavedWidget]) {
        self.widgets = widgets.isEmpty ? [SavedWidget(selection: .fallback)] : widgets
    }

    private enum CodingKeys: String, CodingKey {
        case widgets
    }

    /// Goes through `init(widgets:)` so empty widgets stay valid.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(widgets: try container.decode([SavedWidget].self, forKey: .widgets))
    }

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

    /// Never deletes the last one.
    mutating func delete(_ id: UUID) {
        guard widgets.count > 1 else { return }
        widgets.removeAll { $0.id == id }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { widgets[$0] }
        var rest = widgets.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: destination - before)
        widgets = rest
    }

    /// Checks every train and change against the station list via `Selection.validated` and
    /// `Change.validated`.
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

/// Times on chosen days when a saved widget shows another train (e.g. the evening train home), in
/// the phone's time zone. An end before the start runs past midnight.
struct CommutingHours: Codable, Hashable, Sendable {
    /// The train for these hours, with its walking time. Alert settings come from the saved widget.
    var selection: Selection
    /// A transfer, for the Transfers widget.
    var change: Change?
    /// Where you're going without a change; see `SavedWidget.destinationID`.
    var destinationID: String? = nil
    /// Minutes after midnight.
    var start: Int = 16 * 60
    var end: Int = 18 * 60
    /// `Calendar` weekdays (1 is Sunday); defaults to Monday to Friday.
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]

    private enum CodingKeys: String, CodingKey {
        case selection, change, destinationID, start, end, weekdays
    }

    /// Sets the train, keeping the change only if it's still on the way, and the destination
    /// only on the same lines and direction.
    mutating func setSelection(_ new: Selection) {
        change = keptChange(change, from: selection, to: new)
        destinationID = keptDestination(destinationID, from: selection, to: new)
        selection = new
    }

    /// Whether `date` is in these hours. Past midnight counts toward the day the range started.
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
        // Every start and end over the next week
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
    /// Missing fields take their defaults; an unreadable change is dropped. In an extension to
    /// keep the memberwise init.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(selection: try container.decode(Selection.self, forKey: .selection).droppingSavedWalk,
                  change: try? container.decodeIfPresent(Change.self, forKey: .change))
        destinationID = try container.decodeIfPresent(String.self, forKey: .destinationID)
        start = try container.decodeIfPresent(Int.self, forKey: .start) ?? start
        end = try container.decodeIfPresent(Int.self, forKey: .end) ?? end
        weekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? weekdays
    }
}
