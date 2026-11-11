import SwiftUI
import WidgetKit

/// Which Home Screen widget the Widgets tab draws a saved widget as.
enum WidgetLook: String, CaseIterable, Identifiable {
    /// The Saved Route widget's sizes.
    case small, medium, largeTransfers

    var id: Self { self }

    /// As the Home Screen's widget gallery names it.
    var kindName: String { "Saved Route" }

    var sizeName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .largeTransfers: "Large"
        }
    }

    /// "Saved Route · Medium".
    var title: String { "\(kindName) · \(sizeName)" }

    /// Its outline in the picker's tiles: square, wide, or as wide and tall.
    var glyph: CGSize {
        switch self {
        case .small: CGSize(width: 16, height: 16)
        case .medium: CGSize(width: 34, height: 16)
        case .largeTransfers: CGSize(width: 34, height: 34)
        }
    }

    var family: WidgetFamily {
        switch self {
        case .small: .systemSmall
        case .medium: .systemMedium
        case .largeTransfers: .systemLarge
        }
    }

    /// The widget's size on a 6.1" iPhone. Medium and large narrow where there's less room, as on
    /// smaller iPhones, whose widgets are narrower.
    var size: CGSize {
        switch self {
        case .small: CGSize(width: 158, height: 158)
        case .medium: CGSize(width: 338, height: 158)
        case .largeTransfers: CGSize(width: 338, height: 354)
        }
    }
}

/// A saved widget drawn as the Home Screen draws it (`TrainWidgetView`), with its train's times as
/// now: the widgets' saved ones at once, then fetched, again as its train or change is edited.
/// Its buttons don't take taps, so a tap goes to whatever it's in.
struct WidgetPreview: View {
    let widget: SavedWidget
    var look: WidgetLook = .medium
    /// Drawn instead of fetched times, for a canvas preview with none.
    var sample: TrainEntry?
    /// Routes' shared feeds, for its first load as the tab opens.
    var firstLoads: FirstLoads?
    @Environment(SettingsStore.self) private var settingsStore
    @State private var board: SharedStore.SavedBoard?
    /// Showing both directions: the other way's times.
    @State private var otherBoard: SharedStore.SavedBoard?
    /// The last fetch couldn't reach the MTA.
    @State private var failed = false
    /// A bus or dock widget's times or counts, once fetched.
    @State private var route: RouteTimes?

    /// Home Screen widgets' corner radius and content margins on iPhone.
    private static let cornerRadius: CGFloat = 24
    private static let margins = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    private static let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    /// The timeline's minute, for `shown` and the times fetched for it to move on together.
    @State private var minute = Date.now

    /// What the widget shows now, with commuting hours.
    private var shown: SavedWidget { widget.shown(at: minute) }
    /// Medium and large show the change.
    private var change: Change? { trip.change }
    /// Drawn with its ways on, with a change.
    private var transfers: Bool { change != nil }
    /// Timed to a destination without a change.
    private var destination: Station? { trip.destination }
    /// Medium and large without a change show both directions.
    private var bothWays: Bool { trip.bothWays }

    /// What decides the times fetched; not walking time, which only decides which are catchable.
    struct Trip: Equatable, Sendable {
        var selection: Selection
        var change: Change?
        var destination: Station?
        var settings: AppSettings
        var bothWays: Bool

        /// `widget`'s, drawn as `look` at `date`.
        init(_ widget: SavedWidget, look: WidgetLook, settings: AppSettings, at date: Date) {
            let shown = widget.shown(at: date)
            selection = shown.selection
            selection.walkMinutes = 0
            change = look == .small ? nil : shown.change
            destination = shown.directDestination
            self.settings = settings
            bothWays = look != .small && change == nil && shown.bothWays
        }

        /// The stops its feeds are fetched for: both ways', showing both.
        var feedStops: Set<String> {
            var stops = TrainService.routeFeedStops(for: selection, change: change, destination: destination)
            if bothWays {
                stops.formUnion(TrainService.feedStops(for: selection.otherWay, change: nil, destination: nil))
            }
            return stops
        }
    }

    private var trip: Trip {
        Trip(widget, look: look, settings: settingsStore.settings, at: minute)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            TrainWidgetView(entry: sample ?? planning(entry(at: context.date)))
                // Into commuting hours or out, the other trip's times fetched for it
                .onChange(of: context.date, initial: true) { _, date in minute = date }
        }
        .environment(\.boardFamily, look.family)
        .environment(\.boardMargins, Self.margins)
        .environment(\.routeLook, true)
        // As WidgetKit draws a widget's toggles, not as switches
        .toggleStyle(.button)
        .frame(minWidth: look == .small ? look.size.width : 0, maxWidth: look.size.width)
        .frame(height: look.size.height)
        .background(Color.routeBackground)
        .clipShape(Self.shape)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        // Its toggles and buttons don't take taps here, so it's neither; what it's in decides
        .accessibilityRemoveTraits([.isToggle, .isButton])
        .task(id: trip) { if widget.kind == .subway, sample == nil { await load(trip) } }
        .task(id: routeTrip) { await loadRoute(routeTrip) }
    }

    /// A bus widget's: what decides its fetch.
    private struct RouteTrip: Equatable {
        var bus: BusChoice?
    }

    private var routeTrip: RouteTrip {
        RouteTrip(bus: widget.bus)
    }

    /// As the widget's timeline entry at `date`: the trains still to catch.
    private func entry(at date: Date) -> TrainEntry {
        if widget.kind != .subway { return routeEntry(at: date) }
        let selection = shown.selection
        let settings = settingsStore.settings
        guard let board else {
            return TrainEntry(date: date, selection: selection, trains: [],
                              problem: failed ? "Couldn't reach the MTA" : "Getting times…",
                              settings: settings, change: change, transfers: transfers)
        }
        let trains = selection.catchable(board.trains, now: date)
        let connections = selection.catchable(board.connections ?? [], now: date)
        return TrainEntry(date: date, selection: selection,
                          trains: TimelinePlan.trains(trains, at: date, selection: selection, fetched: board.fetched,
                                                      keepsStops: false),
                          notice: board.notice,
                          problem: failed ? "Couldn't reach the MTA" : nil,
                          settings: settings,
                          connections: change == nil ? nil
                              : TimelinePlan.connections(connections, at: date, selection: selection,
                                                         fetched: board.fetched, keepsStops: false),
                          change: change, transfers: transfers,
                          notUpdatedSince: failed ? board.fetched : nil,
                          destination: destination, destinationTimes: board.destinationTimes ?? [:],
                          otherWay: otherWay(at: date))
    }

    /// `entry` with the New Trip button in the countdown's place, where the route goes
    /// somewhere, as the widget has it (`TrainEntry.plansRoute`).
    private func planning(_ entry: TrainEntry) -> TrainEntry {
        var entry = entry
        entry.plansRoute = shown.hasEnd ? widget.id : nil
        return entry
    }

    /// A bus widget's entry: its times, or until they're fetched, saying so.
    private func routeEntry(at date: Date) -> TrainEntry {
        var entry = TrainEntry(date: date, selection: widget.selection, trains: [], settings: settingsStore.settings)
        if let route {
            entry.route = route
        } else if let bus = widget.bus {
            entry.route = .bus(SavedBusBoard(choice: bus, buses: [], problem: "Getting times…"))
        }
        return entry
    }

    private func loadRoute(_ trip: RouteTrip) async {
        route = nil
        guard widget.kind != .subway else { return }
        try? await Task.sleep(for: .seconds(0.2))
        guard !Task.isCancelled else { return }
        let fetched: RouteTimes? = if widget.kind == .bus, let bus = trip.bus {
            .bus(await SavedBusBoard.fetch(bus, now: .now))
        } else {
            nil
        }
        guard !Task.isCancelled else { return }
        route = fetched
    }

    /// Showing both directions, the other way's trains at `date`.
    private func otherWay(at date: Date) -> OtherWay? {
        guard bothWays else { return nil }
        let selection = shown.selection.otherWay
        guard let otherBoard else {
            return OtherWay(selection: selection, trains: [], problem: failed ? "Couldn't reach the MTA" : "Getting times…")
        }
        return OtherWay(selection: selection, trains: selection.catchable(otherBoard.trains, now: date))
    }

    /// The widgets' saved times for `trip` at once, if any, then new ones once edits pause.
    private func load(_ trip: Trip) async {
        let selection = shown.selection
        let change = trip.change
        // Without saved ones, none: another train's times would show under this one's name
        board = SharedStore.loadBoard(for: selection, change: change, destinationID: trip.destination?.id)
        otherBoard = trip.bothWays ? SharedStore.loadBoard(for: selection.otherWay) : nil
        failed = false
        try? await Task.sleep(for: .seconds(0.4))
        guard !Task.isCancelled else { return }
        do {
            let (fetched, other) = try await Self.boards(for: selection, trip: trip,
                                                         sharing: firstLoads?.take(for: widget.id))
            guard !Task.isCancelled else { return }
            // Saved as the widget saves them, so its reload after an edit draws these, not fetches again
            SharedStore.saveBoard(fetched, for: selection, change: change, destinationID: trip.destination?.id,
                                  fetched: .now)
            otherBoard = other.map { SharedStore.saveBoard($0, for: selection.otherWay, fetched: .now) }
            board = SharedStore.SavedBoard(fetched: .now, trains: fetched.trains,
                                           notice: fetched.notice(for: selection, settings: trip.settings),
                                           connections: change == nil ? nil : fetched.connections,
                                           destinationTimes: trip.destination == nil ? nil : fetched.destinationTimes)
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    /// `selection`'s board for `trip`, and the other way's showing both. Both ways' feeds
    /// downloaded once for the two (`TrainService.sharingFeeds`), or in `shared` with other routes'.
    static func boards(for selection: Selection, trip: Trip, sharing shared: TrainService.FeedBatch? = nil,
                       now: Date = AppClock.now) async throws -> (Board, Board?) {
        let alerts = selection.mentionsAlerts(with: trip.settings)
        let change = trip.change
        return try await TrainService.sharingFeeds(atStops: trip.feedStops, joining: shared) {
            // Alongside its own, as the widget fetches it
            async let otherWay = Self.otherBoard(for: selection, if: trip.bothWays, settings: trip.settings, now: now)
            let fetched = if let change {
                try await TrainService.routeBoard(for: selection, change: change, includingAlerts: alerts,
                                                  includingOutages: selection.elevatorAlerts, now: now)
            } else {
                try await TrainService.board(for: selection, arrivingAt: trip.destination, includingAlerts: alerts,
                                             includingOutages: selection.elevatorAlerts, now: now)
            }
            return (fetched, try await otherWay)
        }
    }

    /// `selection` going the other way, fetched, when showing both directions. With the alerts
    /// the widget fetches it with, as it's saved for it.
    private static func otherBoard(for selection: Selection, if bothWays: Bool, settings: AppSettings,
                                   now: Date) async throws -> Board? {
        guard bothWays else { return nil }
        let other = selection.otherWay
        return try await TrainService.board(for: other, arrivingAt: nil,
                                            includingAlerts: other.mentionsAlerts(with: settings),
                                            includingOutages: other.elevatorAlerts, now: now)
    }
}

/// Routes' first loads as the tab opens, in one `TrainService.FeedBatch` for every route's
/// stops: each feed downloaded once for them all, not once a route. Each route takes it for its
/// first load only, and only for moments, so a refresh or edit fetches its own as before and
/// is never shown older times than a fetch would.
@MainActor final class FirstLoads {
    private var batch: TrainService.FeedBatch?
    /// The routes yet to take it; it's let go once they all have.
    private var waiting: Set<UUID> = []
    private var started = Date.distantPast
    /// As long as the app reuses a feed fetched moments ago anyway (`TrainService`).
    static let life: TimeInterval = 15

    /// A new batch for `widgets`' first loads, each as `look` draws it.
    func start(_ widgets: [SavedWidget], look: (UUID) -> WidgetLook, settings: AppSettings, at date: Date = .now) {
        let subway = widgets.filter { $0.kind == .subway }
        let stops = subway.reduce(into: Set<String>()) {
            $0.formUnion(WidgetPreview.Trip($1, look: look($1.id), settings: settings, at: date).feedStops)
        }
        batch = subway.isEmpty ? nil : TrainService.FeedBatch(stops: stops)
        waiting = Set(subway.map(\.id))
        started = date
    }

    /// The batch for route `id`'s first load since `start`; nil after, or once it's old.
    func take(for id: UUID, now: Date = .now) -> TrainService.FeedBatch? {
        guard waiting.remove(id) != nil else { return nil }
        guard now.timeIntervalSince(started) < Self.life else {
            batch = nil
            return nil
        }
        let taken = batch
        // Kept by the loads using it till they're done
        if waiting.isEmpty { batch = nil }
        return taken
    }
}

#Preview {
    let widget = SharedStore.firstWidgets.widgets.first ?? .default(.fallback)
    VStack(spacing: 20) {
        ForEach(WidgetLook.allCases) { look in
            WidgetPreview(widget: widget, look: look)
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemGroupedBackground))
    .environment(SettingsStore())
}
