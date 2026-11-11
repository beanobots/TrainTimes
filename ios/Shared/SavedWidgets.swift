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
    /// What it shows: a subway train (`selection`) or a bus (`bus`). A Citi Bike dock (`dock`) only
    /// in saves from before docks were the Citi Bike widget's, which `SavedWidgets` drops; kept
    /// here as the push server shares this file.
    var kind: SavedRouteKind = .subway
    /// A bus widget's bus.
    var bus: BusChoice? = nil
    /// A Citi Bike widget's dock.
    var dock: DockChoice? = nil

    /// Id of the widget migrated from the app's train before saved widgets existed.
    static let firstID = UUID(uuidString: "5D1C8A0E-0F57-4E2B-9C3A-7B1E2D4F6A01")!

    /// Id of `default(_:)`, which isn't saved.
    static let defaultID = UUID(uuidString: "0B7E4C2A-93D1-4F6E-A8B5-2C9D1E3F4A70")!

    /// What widgets show until they pick a saved one: Settings' default train, unnamed, both
    /// ways if Settings has it so.
    static func `default`(_ selection: Selection, bothWays: Bool = false) -> SavedWidget {
        SavedWidget(id: defaultID, selection: selection, bothWays: bothWays)
    }

    init(id: UUID = UUID(), name: String = "", selection: Selection, change: Change? = nil,
         commute: CommutingHours? = nil, destinationID: String? = nil, bothWays: Bool = false,
         kind: SavedRouteKind = .subway, bus: BusChoice? = nil, dock: DockChoice? = nil) {
        self.id = id
        self.name = name
        self.selection = selection
        self.change = change
        self.commute = commute
        self.destinationID = destinationID
        self.bothWays = bothWays
        self.kind = kind
        self.bus = bus
        self.dock = dock
    }

    /// What widgets show until they pick a saved one, when Settings' home stop is a bus.
    static func `default`(bus: BusChoice) -> SavedWidget {
        SavedWidget(id: defaultID, selection: .fallback, bothWays: bus.bothWays, kind: .bus, bus: bus)
    }

    /// A bus widget, for `bus`.
    static func bus(_ bus: BusChoice, name: String = "") -> SavedWidget {
        SavedWidget(name: name, selection: .fallback, bothWays: bus.bothWays, kind: .bus, bus: bus)
    }

    /// A Citi Bike widget, for `dock`.
    static func dock(_ dock: DockChoice, name: String = "") -> SavedWidget {
        SavedWidget(name: name, selection: .fallback, kind: .bike, dock: dock)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, selection, change, commute, destinationID, bothWays, kind, bus, dock
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
                  bothWays: try container.decodeIfPresent(Bool.self, forKey: .bothWays) ?? false,
                  kind: (try? container.decodeIfPresent(SavedRouteKind.self, forKey: .kind)) ?? .subway,
                  bus: try? container.decodeIfPresent(BusChoice.self, forKey: .bus),
                  dock: try? container.decodeIfPresent(DockChoice.self, forKey: .dock))
        // A bus or dock widget that lost its bus or dock is shown as the subway one it falls back to
        if (kind == .bus && bus == nil) || (kind == .bike && dock == nil) { kind = .subway }
    }

    /// Planned From and To: the ways there, each ride a train or a bus, carried by its change
    /// (from a station) or its bus (from a stop) so every widget path has it. Nil for a route
    /// picked by hand.
    var trip: PlannedTrip? {
        kind == .bus ? bus?.planned : change?.planned
    }

    /// Where it goes: its change's destination, or without one its own.
    var destination: Station? {
        (trip?.destinationID ?? change?.destinationID ?? destinationID).flatMap(StationDirectory.station(id:))
    }

    /// A saved route with somewhere it goes, a station or a stop: New Trip can plan to it
    /// (`PlanRouteTripIntent`). Not the unsaved default, a countdown-only route, nor a dock.
    var hasEnd: Bool {
        id != Self.defaultID && kind != .bike
            && (trip?.destinationID ?? trip?.destinationStop?.id ?? change?.destinationID ?? destinationID) != nil
    }

    /// Where Next train times its trains to: the destination, when there's no change.
    var directDestination: Station? {
        change == nil ? destinationID.flatMap(StationDirectory.station(id:)) : nil
    }

    /// The name typed for it, or `summary`.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? summary : trimmed
    }

    /// Whether a name was typed for it.
    var isNamed: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// What you ride and from where: "R from 4 Av-9 St", "B63 from 5 Av/3 St",
    /// "Citi Bike at 5 Av & 3 St".
    var summary: String {
        switch kind {
        case .subway:
            let lines = selection.routes.map { LineStyle.of($0).label }.joined(separator: " ")
            return selection.station.map { "\(lines) from \($0.name)" } ?? "Train"
        case .bus:
            return bus.map { "\($0.allLines.map(BusNames.label).joined(separator: ", ")) from \($0.stopName)" } ?? "Bus"
        case .bike:
            return dock.map { "Citi Bike at \($0.name)" } ?? "Citi Bike"
        }
    }

    /// Which way it goes: "to Manhattan", "change at DeKalb Av for the Q", "both ways";
    /// empty for a dock.
    var way: String {
        // Planned From and To: where it goes
        if kind != .bike, let destination { return "to \(destination.name)" }
        if let stop = trip?.destinationStop { return "to \(BusNames.readable(stop.name))" }
        switch kind {
        case .subway:
            if let change {
                let onward = Lines.list(change.allRoutes, joinedBy: "or")
                // Alternatives change at more than one station
                guard change.alternatives.isEmpty, let station = change.station else {
                    return "change for the \(onward)"
                }
                return "change at \(station.name) for the \(onward)"
            }
            if bothWays { return "both ways" }
            if let directDestination { return "to \(directDestination.name)" }
            let heading = selection.heading
            return heading.isEmpty ? selection.direction.compassName.lowercased() : "to \(heading)"
        case .bus:
            guard let bus else { return "" }
            return bus.bothWays ? "both ways" : "to \(bus.wayName)"
        case .bike:
            return ""
        }
    }

    /// Every line it rides, each once: the train's, then the change's.
    var allRoutes: [String] {
        var routes = selection.routes
        for route in change?.allRoutes ?? [] where !routes.contains(route) {
            routes.append(route)
        }
        return routes
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
    /// Possibly none: every route can be deleted, and widgets then show Settings' default train.
    private(set) var widgets: [SavedWidget]
    /// Citi Bike docks saved before they were the Citi Bike widget's: not listed, but kept (and
    /// saved again), so a Saved Route widget still showing one says it's moved, not a train.
    private(set) var movedDocks: [SavedWidget] = []
    /// Widgets this version can't read (saved by a newer one, say), kept as they were saved and
    /// saved again, so going back a version never loses them. Not listed, nor shown by widgets.
    private(set) var unreadable: [Unreadable] = []

    /// An unreadable widget, and where it goes among the rest.
    struct Unreadable: Hashable, Sendable {
        /// The listed widget it follows: it keeps its place after that one as widgets move, and
        /// takes the place of that one's when it's deleted. Nil: before them all.
        var after: UUID?
        var json: SavedJSON
    }

    init(widgets: [SavedWidget], movedDocks: [SavedWidget] = [], unreadable: [Unreadable] = []) {
        self.widgets = widgets
        self.movedDocks = movedDocks
        self.unreadable = unreadable
    }

    private enum CodingKeys: String, CodingKey {
        case widgets
    }

    /// A saved widget, or what was saved if it can't be read as one.
    private enum Entry: Decodable {
        case widget(SavedWidget)
        case unreadable(SavedJSON)

        init(from decoder: Decoder) throws {
            if let widget = try? SavedWidget(from: decoder) {
                self = .widget(widget)
            } else {
                self = .unreadable(try SavedJSON(from: decoder))
            }
        }
    }

    /// One widget at a time: one that can't be read is kept as `unreadable`, not the end of them
    /// all. Citi Bike docks saved before they were the Citi Bike widget's are kept apart, as
    /// `movedDocks`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list = try container.nestedUnkeyedContainer(forKey: .widgets)
        var widgets: [SavedWidget] = []
        var docks: [SavedWidget] = []
        var unreadable: [Unreadable] = []
        while !list.isAtEnd {
            switch try list.decode(Entry.self) {
            case .widget(let widget) where widget.kind == .bike: docks.append(widget)
            case .widget(let widget): widgets.append(widget)
            case .unreadable(let json): unreadable.append(Unreadable(after: widgets.last?.id, json: json))
            }
        }
        self.init(widgets: widgets, movedDocks: docks, unreadable: unreadable)
    }

    /// The unreadable each after the widget it follows, and `movedDocks` last: with none
    /// unreadable, as before them.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var list = container.nestedUnkeyedContainer(forKey: .widgets)
        let ids = Set(widgets.map(\.id))
        for entry in unreadable where entry.after == nil {
            try list.encode(entry.json)
        }
        for widget in widgets {
            try list.encode(widget)
            for entry in unreadable where entry.after == widget.id {
                try list.encode(entry.json)
            }
        }
        // Following a widget that's gone some other way than `delete`: at the end
        for entry in unreadable where entry.after.map({ !ids.contains($0) }) ?? false {
            try list.encode(entry.json)
        }
        for dock in movedDocks {
            try list.encode(dock)
        }
    }

    func widget(_ id: UUID) -> SavedWidget? {
        widgets.first { $0.id == id }
    }

    /// The Citi Bike dock saved as `id` before docks were the Citi Bike widget's, if it was one.
    func movedDock(_ id: UUID) -> SavedWidget? {
        movedDocks.first { $0.id == id }
    }

    /// Replaces the saved widget with the same id.
    mutating func update(_ widget: SavedWidget) {
        guard let index = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        widgets[index] = widget
    }

    mutating func add(_ widget: SavedWidget) {
        widgets.append(widget)
    }

    /// Any unreadable widgets after it then follow the one before it, keeping their place.
    mutating func delete(_ id: UUID) {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
        let before = index > 0 ? widgets[index - 1].id : nil
        for at in unreadable.indices where unreadable[at].after == id {
            unreadable[at].after = before
        }
        widgets.removeAll { $0.id == id }
    }

    /// Unreadable widgets move with the widget before them.
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

/// JSON as it was read, to write back as it was: a saved widget this version can't read
/// (`SavedWidgets.unreadable`). Whole numbers are kept exactly; others as `Double`.
indirect enum SavedJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([SavedJSON])
    case object([String: SavedJSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? value.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([SavedJSON].self) {
            self = .array(array)
        } else {
            self = .object(try value.decode([String: SavedJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
}
