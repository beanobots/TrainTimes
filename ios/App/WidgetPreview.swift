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
    private var change: Change? { look == .small ? nil : shown.change }
    /// Drawn with its ways on, with a change.
    private var transfers: Bool { change != nil }
    /// Timed to a destination without a change.
    private var destination: Station? { shown.directDestination }
    /// Medium and large without a change show both directions.
    private var bothWays: Bool { look != .small && change == nil && shown.bothWays }

    /// What decides the times fetched; not walking time, which only decides which are catchable.
    private struct Trip: Equatable {
        var selection: Selection
        var change: Change?
        var destination: Station?
        var settings: AppSettings
        var bothWays: Bool
    }

    private var trip: Trip {
        var selection = shown.selection
        selection.walkMinutes = 0
        return Trip(selection: selection, change: change, destination: destination, settings: settingsStore.settings,
                    bothWays: bothWays)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            TrainWidgetView(entry: entry(at: context.date))
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
        // Its toggles don't take taps here, so it's not a switch; what it's in decides
        .accessibilityRemoveTraits(.isToggle)
        .task(id: trip) { if widget.kind == .subway { await load(trip) } }
        .task(id: routeTrip) { await loadRoute(routeTrip) }
    }

    /// A bus or dock widget's: what decides its fetch.
    private struct RouteTrip: Equatable {
        var bus: BusChoice?
        var dock: DockChoice?
        var kinds: SharedBikeKinds
    }

    private var routeTrip: RouteTrip {
        RouteTrip(bus: widget.bus, dock: widget.dock, kinds: settingsStore.settings.bikeKinds)
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

    /// A bus or dock widget's entry: its times or counts, or until they're fetched, saying so.
    private func routeEntry(at date: Date) -> TrainEntry {
        var entry = TrainEntry(date: date, selection: widget.selection, trains: [], settings: settingsStore.settings)
        if let route {
            entry.route = route
        } else if let bus = widget.bus {
            entry.route = .bus(SavedBusBoard(choice: bus, buses: [], problem: "Getting times…"))
        } else if let dock = widget.dock {
            entry.route = .dock(SavedDockBoard(dock: dock, kinds: settingsStore.settings.bikeKinds, fetched: date,
                                               problem: "Getting counts…"))
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
        } else if let dock = trip.dock {
            .dock(await SavedDockBoard.fetch(dock, kinds: trip.kinds, now: .now))
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
        let alerts = selection.mentionsAlerts(with: trip.settings)
        // Alongside its own: just its trains, as the widget shows of it
        async let otherWay = Self.otherBoard(for: selection, if: trip.bothWays)
        do {
            let fetched = if let change {
                await TrainService.addingBuses(
                    to: try await TrainService.board(for: selection, change: change, includingAlerts: alerts,
                                                     includingOutages: selection.elevatorAlerts),
                    change: change)
            } else {
                try await TrainService.board(for: selection, arrivingAt: trip.destination, includingAlerts: alerts,
                                             includingOutages: selection.elevatorAlerts)
            }
            let other = try await otherWay
            guard !Task.isCancelled else { return }
            otherBoard = other.map { SharedStore.SavedBoard(fetched: .now, trains: $0.trains, notice: nil) }
            board = SharedStore.SavedBoard(fetched: .now, trains: fetched.trains,
                                           notice: fetched.notice(for: selection, settings: trip.settings),
                                           connections: change == nil ? nil : fetched.connections,
                                           destinationTimes: trip.destination == nil ? nil : fetched.destinationTimes)
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    /// `selection` going the other way, fetched, when showing both directions.
    private static func otherBoard(for selection: Selection, if bothWays: Bool) async throws -> Board? {
        guard bothWays else { return nil }
        return try await TrainService.board(for: selection.otherWay, arrivingAt: nil, includingAlerts: false,
                                            includingOutages: false)
    }
}

/// A stand-in for a Home Screen wallpaper, behind the Widgets tab's widgets.
struct WallpaperBackdrop: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.29, blue: 0.62), Color(red: 0.55, green: 0.33, blue: 0.68),
                                Color(red: 0.95, green: 0.55, blue: 0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

#Preview {
    let widget = SharedStore.firstWidgets.widgets[0]
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
