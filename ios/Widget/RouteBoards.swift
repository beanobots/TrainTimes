import CoreLocation
import SwiftUI
import WidgetKit

// The Saved Route widget's bus boards and the Citi Bike widget's dock boards: what they show in
// place of trains (`TrainEntry.route`), drawn as the subway's Saved Route boards are (`routeLook`):
// a card until a tap, then the times or counts, with a ✕ back to the card.

/// A Saved Route's bus, or the Citi Bike widget's dock, fetched.
enum RouteTimes {
    case bus(SavedBusBoard)
    case dock(SavedDockBoard)

    /// "4 Av & 9 St", "5 Av & 3 St".
    var placeName: String {
        switch self {
        case .bus(let board): board.choice.stopName
        case .dock(let board): board.dock.name
        }
    }

    /// Under the place on its card: "to Cobble Hill", "Both directions", "Citi Bike dock";
    /// for the nearest dock, which its card doesn't name, what VoiceOver says of it.
    var cardHeading: String {
        switch self {
        case .bus(let board): board.choice.bothWays && board.otherWay != nil ? "Both directions" : "to \(board.choice.wayName)"
        case .dock(let board): board.nearest ? "nearest Citi Bike dock" : "Citi Bike dock"
        }
    }

    var problem: String? {
        switch self {
        case .bus(let board): board.problem
        case .dock(let board): board.problem
        }
    }
}

/// A saved bus widget's next buses at its stop, and the other way's when it shows both.
struct SavedBusBoard {
    var choice: BusChoice
    /// Soonest first.
    var buses: [BusArrival]
    /// Showing both directions: the other way and its next buses.
    var otherWay: BusChoice? = nil
    var otherBuses: [BusArrival] = []
    /// Why there are no times, when there aren't.
    var problem: String? = nil
    /// With changes to a train (`BusChoice.changes`): each change's trains, in its order.
    var changeTrains: [[Arrival]] = []
    /// Planned From and To (`BusChoice.planned`): the trains and buses its ways ride.
    var plannedTimes: PlannedTrips.Times? = nil

    /// One change's trains, by its place in `BusChoice.changes`.
    private typealias ChangeTrains = (index: Int, trains: [Arrival])

    /// The buses still to come at `date`.
    /// The buses still to come at `date`, and one just due while it's at the stop
    /// (`AtStation.busSeconds`).
    func coming(at date: Date, other: Bool = false) -> [BusArrival] {
        (other ? otherBuses : buses).filter { ($0.time ?? .distantPast) > date.addingTimeInterval(-AtStation.busSeconds) }
    }

    /// Seconds a planned trip's trains and buses are waited for, well inside the widget's own
    /// wait (`routeFetchWait`, 8 s); late, its ways are followed with the stop's buses alone.
    private static let plannedFetchWait: TimeInterval = 5

    /// Its next buses now, and the other way's with both directions (MTA Bus Time, through the
    /// push server).
    static func fetch(_ choice: BusChoice, now: Date) async -> SavedBusBoard {
        let other = choice.bothWays ? choice.otherWay : nil
        let key = savedKey(choice)
        // Saved within the server's own keeping of Bus Time (`BusTimes.reuse`), by another
        // widget or the app's preview: what the server would send again, so not asked
        let fresh = SharedStore.loadBuses(for: key).flatMap { $0.fetched.isWithin(BusTimes.reuse, before: .now) ? $0 : nil }
        // Every line a home stop rides, merged
        async let times = fresh != nil ? nil : BusTimes.arrivals(lines: choice.allLines, at: choice.place, now: now)
        async let otherTimes = fresh != nil ? nil
            : other.asyncMap { await BusTimes.arrivals(lines: $0.allLines, at: $0.place, now: now) }
        // A planned trip's trains and buses, every ride's: by a deadline of its own, inside the
        // widget's, so a slow leg leaves the board its stop's buses rather than all old ones
        let plannedBy = Date.now.addingTimeInterval(Self.plannedFetchWait)
        let plannedFetch = choice.planned.map { trip in Task { await PlannedTrips.fetch(trip, now: now) } }
        async let planned = plannedFetch.asyncMap { await TrainService.value(of: $0, by: plannedBy) ?? nil }
        // Each change's trains, alongside: just the trains, no alerts
        async let trains = withTaskGroup(of: ChangeTrains.self) { group in
            for (index, change) in (choice.planned == nil ? choice.changes ?? [] : []).enumerated() {
                group.addTask {
                    let board = try? await TrainService.board(for: change.selection, arrivingAt: nil, includingAlerts: false,
                                                              includingOutages: false,
                                                              waitingAfterOwnLines: TimelinePlan.firstDrawWait, now: now)
                    return (index, board?.trains ?? [])
                }
            }
            var trains = Array(repeating: [Arrival](), count: choice.changes?.count ?? 0)
            for await (index, found) in group { trains[index] = found }
            return trains
        }
        if let fresh {
            let coming = { (buses: [BusArrival]) in buses.filter { ($0.time ?? .distantPast) > now } }
            return SavedBusBoard(choice: choice, buses: coming(fresh.buses), otherWay: other,
                                 otherBuses: other == nil ? [] : coming(fresh.otherBuses), changeTrains: await trains,
                                 plannedTimes: await planned ?? nil)
        }
        let mine = await times
        let theirs = await otherTimes
        // A failed fetch keeps the last good one's buses still to come
        let saved = mine == nil || (other != nil && (theirs ?? nil) == nil) ? SharedStore.loadBuses(for: key) : nil
        let buses = mine?.arrivals ?? saved?.buses.filter { ($0.time ?? .distantPast) > now } ?? []
        let otherBuses = other == nil ? [] : theirs??.arrivals ?? saved?.otherBuses.filter { ($0.time ?? .distantPast) > now } ?? []
        if let mine {
            SharedStore.saveBuses(.init(fetched: now, buses: mine.arrivals, otherBuses: otherBuses), for: key)
        }
        return SavedBusBoard(choice: choice, buses: buses, otherWay: other, otherBuses: otherBuses,
                             problem: mine == nil && buses.isEmpty ? "Couldn't reach Bus Time" : nil, changeTrains: await trains,
                             plannedTimes: await planned ?? nil)
    }

    /// When a fetch doesn't finish in time: the last good one's buses still to come, if any.
    static func saved(_ choice: BusChoice, now: Date) -> SavedBusBoard {
        let other = choice.bothWays ? choice.otherWay : nil
        let saved = SharedStore.loadBuses(for: savedKey(choice))
        let buses = saved?.buses.filter { ($0.time ?? .distantPast) > now } ?? []
        let otherBuses = other == nil ? [] : saved?.otherBuses.filter { ($0.time ?? .distantPast) > now } ?? []
        return SavedBusBoard(choice: choice, buses: buses, otherWay: other, otherBuses: otherBuses,
                             problem: buses.isEmpty ? "Couldn't reach Bus Time" : nil)
    }

    /// Its saved buses' key (`SharedStore.loadBuses`): the bus, and the other way's with both.
    private static func savedKey(_ choice: BusChoice) -> String {
        let other = choice.bothWays ? choice.otherWay : nil
        return choice.countdownID + (other.map { " " + $0.countdownID } ?? "")
    }

    /// With changes to a train, `entry` as a train's change board at its date: each bus with its
    /// ways on (`BusChoice.connections`); nil without changes.
    func changeEntry(_ entry: TrainEntry) -> (entry: TrainEntry, change: Change)? {
        if let trip = choice.planned, trip.ways.contains(where: { $0.rides.count > 1 }) {
            // Its ways followed, every ride train or bus; the change for the board's names and alerts
            var change = choice.trainChange ?? Change(stationID: "", routes: [])
            change.planned = trip
            change.destinationID = trip.destinationID
            var times = plannedTimes ?? PlannedTrips.Times(trains: [], buses: [:])
            // The buses at the stop as fetched for the board, not again
            if let start = trip.start?.bus { times.buses[PlannedTrips.busKey(start)] = buses }
            var shown = entry
            shown.connections = PlannedTrips.connections(trip, times: times, now: entry.date)
            shown.change = change
            shown.transfers = true
            return (shown, change)
        }
        guard let change = choice.trainChange else { return nil }
        var shown = entry
        shown.connections = choice.connections(buses: buses, trains: changeTrains, at: entry.date)
        shown.change = change
        shown.transfers = true
        return (shown, change)
    }
}

/// The Citi Bike widget's dock, its favorite or the nearest to you: its counts now, and the
/// nearest other docks'.
struct SavedDockBoard {
    var dock: DockChoice
    var counts: CitiBike.Dock?
    var nearby: [Nearby] = []
    /// Which counts show, as Settings › Biking has it (Docks always).
    var kinds = SharedBikeKinds.both
    var fetched: Date
    var problem: String? = nil
    /// The dock nearest you rather than a favorite: its card says "Nearby", and `nearby` are the
    /// next nearest to you.
    var nearest = false

    struct Nearby: Hashable {
        var dock: CitiBike.Dock
        var walkMinutes: Int
    }

    /// The nearby docks the large widget lists.
    static let nearbyCount = 3
    /// How far it looks for them, and for the nearest dock: as far as the push server looks.
    private static let nearbyRange: Double = 2000

    /// The dock's counts now, with its nearest others: with E-Bikes alone, only those with one.
    static func fetch(_ dock: DockChoice, kinds: SharedBikeKinds, now: Date) async -> SavedDockBoard {
        // The few round the dock, itself among them at 0 m: not the whole city's. With E-Bikes
        // alone, those without one are left out here (`nearest`), so it's one request, for more
        // of them, to have three that do
        let asked = kinds == .eBikes ? CitiBike.mostAsked : nearbyCount + 1
        guard let around = await CitiBike.docks(near: dock.location, limit: asked, within: nearbyRange,
                                                has: .any) else {
            return SavedDockBoard(dock: dock, kinds: kinds, fetched: now, problem: "Couldn't reach Citi Bike")
        }
        // Asked for by id only if it's not among them (moved, or another at the same spot)
        var counts = around.first { $0.id == dock.id }
        if counts == nil {
            guard let own = await CitiBike.docks(ids: [dock.id]) else {
                return SavedDockBoard(dock: dock, kinds: kinds, fetched: now, problem: "Couldn't reach Citi Bike")
            }
            counts = own.first
        }
        return SavedDockBoard(dock: dock, counts: counts,
                              nearby: nearest(to: dock.location, among: around, except: dock.id, kinds: kinds),
                              kinds: kinds, fetched: now, problem: counts == nil ? "This dock isn't in service" : nil)
    }

    /// The dock nearest `here` that's in service (with E-Bikes alone, the nearest with one), and
    /// the next nearest to `here`. Nil if Citi Bike can't be reached or has none.
    static func fetchNearest(to here: CLLocation, kinds: SharedBikeKinds, now: Date) async -> SavedDockBoard? {
        // The nearest few, not the whole city's
        guard let docks = await CitiBike.docks(near: here, limit: nearbyCount + 1, within: nearbyRange,
                                               has: kinds == .eBikes ? .ebike : .service) else { return nil }
        guard let closest = docks.first else { return nil }
        return SavedDockBoard(dock: DockChoice(closest), counts: closest,
                              nearby: nearest(to: here, among: docks, except: closest.id, kinds: kinds),
                              kinds: kinds, fetched: now, nearest: true)
    }

    /// The `nearbyCount` docks nearest `here` but `id`: with E-Bikes alone, only those with one.
    private static func nearest(to here: CLLocation, among docks: [CitiBike.Dock], except id: String,
                                kinds: SharedBikeKinds) -> [Nearby] {
        docks
            .filter { $0.id != id && (kinds != .eBikes || $0.available(.eBike) > 0) }
            .map { (dock: $0, meters: $0.location.distance(from: here)) }
            .sorted { $0.meters < $1.meters }
            .prefix(nearbyCount)
            .map { Nearby(dock: $0.dock, walkMinutes: TripPlanner.walkMinutes($0.meters)) }
    }

    /// The counts it shows, in order: Bikes and E-Bikes as Settings has them, then Docks.
    var columns: [Column] {
        [kinds.showsBikes ? .bikes : nil, kinds.showsEBikes ? .eBikes : nil, .docks].compactMap { $0 }
    }

    enum Column: CaseIterable {
        case bikes, eBikes, docks

        var name: String {
            switch self {
            case .bikes: "Bikes"
            case .eBikes: "E-Bikes"
            case .docks: "Docks"
            }
        }

        func count(_ dock: CitiBike.Dock) -> Int {
            switch self {
            case .bikes: dock.available(.bike)
            case .eBikes: dock.available(.eBike)
            case .docks: dock.free
            }
        }
    }
}

private extension Optional {
    /// `transform` on the wrapped value, awaited; nil without one.
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

// MARK: - Marks

/// Citi Bike's mark: a bike on its blue; with E-Bikes alone, a yellow bolt on it.
struct CitiBikeMark: View {
    let size: CGFloat
    var eBikes = false

    /// Citi Bike's blue.
    static let blue = Color(red: 0.0, green: 0.42, blue: 0.80)

    var body: some View {
        Image(systemName: "bicycle")
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.blue))
            .overlay(alignment: .topTrailing) {
                if eBikes {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.24, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: size * 0.4, height: size * 0.4)
                        .background(Circle().fill(.yellow))
                        .offset(x: size * 0.08, y: -size * 0.08)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(eBikes ? "Citi Bike e-bikes" : "Citi Bike")
    }
}

// MARK: - Cards

/// A bus or dock's card until a tap, as the subway's (`StopCard`, bullet row): the place and way,
/// then its mark big along the bottom, tinted with its colour.
struct RouteCard: View {
    let route: RouteTimes
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNearest ? "Nearby" : route.placeName)
                .font(.headline)
                .foregroundStyle(BoardInk.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if !isNearest {
                Text(route.cardHeading)
                    .font(.caption)
                    .foregroundStyle(BoardInk.gray)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            ViewThatFits(in: .vertical) {
                ForEach([52, 44, 36, 28] as [CGFloat], id: \.self) { mark($0) }
            }
        }
        .padding(12)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(renderingMode == .fullColor ? tint.opacity(0.14) : BoardInk.color(.tile, route: true)))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// The nearest dock's card, which says only "Nearby": the dock may be another by the tap.
    private var isNearest: Bool {
        if case .dock(let board) = route { board.nearest } else { false }
    }

    private var tint: Color {
        switch route {
        case .bus(let board): BusBadge.isSBS(board.choice.line) ? BusBadge.sbsBlue : BusBadge.blue
        case .dock: CitiBikeMark.blue
        }
    }

    @ViewBuilder private func mark(_ size: CGFloat) -> some View {
        switch route {
        case .bus(let board):
            // A home stop's lines, each badge smaller for more
            let lines = Array(board.choice.allLines.prefix(3))
            HStack(spacing: 3) {
                ForEach(lines, id: \.self) { BusBadge(line: $0, size: lines.count > 1 ? size * 0.7 : size) }
            }
        case .dock(let board): CitiBikeMark(size: size, eBikes: board.kinds == .eBikes)
        }
    }
}

// MARK: - Boards

/// A bus or dock's board, open: in a widget, and as the picture under its controls; `controls`
/// draws just the ✕, where the header leaves room for it.
struct RouteBoard: View {
    let entry: TrainEntry
    let route: RouteTimes
    var refreshing = false
    var controls = false
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.boardFamily) private var boardFamily

    private var family: WidgetFamily { boardFamily ?? widgetFamily }

    var body: some View {
        switch route {
        case .bus(let board):
            // With a change to a train: medium and large draw it as a train's change board
            if family != .systemSmall, let changed = board.changeEntry(entry) {
                WaysBoard(entry: changed.entry, change: changed.change, refreshing: refreshing, controls: controls,
                          origin: WaysBoard.Origin(line: board.choice.line, name: board.choice.stopName,
                                                   way: board.choice.wayName))
            } else {
                BusRouteBoard(entry: entry, board: board, family: family, refreshing: refreshing, controls: controls)
            }
        case .dock(let board): DockRouteBoard(entry: entry, board: board, family: family, refreshing: refreshing, controls: controls)
        }
    }
}

/// The ✕ back to the card, at the header's right; nothing else takes taps but the refresh under it.
private struct RouteControls<Header: View>: View {
    let entry: TrainEntry
    let large: Bool
    /// A bus's walk button, after the ✕; nil for a dock's.
    var walk: AnyView? = nil
    @ViewBuilder let header: Header

    var body: some View {
        VStack(spacing: 0) {
            header.hidden()
                .overlay(alignment: large ? .trailing : .topTrailing) {
                    BoardButtons(entry: entry, large: large, spacing: 8) { walk }
                }
            Spacer(minLength: 0)
        }
    }
}

/// Room at a header's right for the ✕ (`RouteControls`), when it shows.
private struct CloseRoom: View {
    let entry: TrainEntry
    let large: Bool

    var body: some View {
        if entry.closes {
            Pill(symbol: "xmark", large: large, round: true).hidden()
        }
    }
}

/// A saved bus, as the subway's Saved Route board with its badge where a line's bullet goes.
/// Small: the badge and stop, the countdown, the next one's minutes. Medium: the stop and way, the
/// countdown, the bus's time and the next one's minutes; both directions, a tile each. Large: the
/// countdown card and the next three; both directions, side by side.
private struct BusRouteBoard: View {
    let entry: TrainEntry
    let board: SavedBusBoard
    let family: WidgetFamily
    let refreshing: Bool
    let controls: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    private var isSmall: Bool { family == .systemSmall }
    private var isLarge: Bool { family == .systemLarge }
    private var marks: TimeMarks { entry.settings.timeMarks(withoutColor: withoutColor, renderingMode: renderingMode) }
    private var line: String { board.choice.line }
    private var coming: [BusArrival] { board.coming(at: entry.date) }
    /// Medium and large, showing both directions: the other way.
    private var otherWay: BusChoice? { isSmall ? nil : board.otherWay }

    var body: some View {
        if controls {
            RouteControls(entry: entry, large: !isSmall, walk: AnyView(walkButton)) { header }
        } else {
            VStack(alignment: .leading, spacing: isLarge ? 10 : isSmall ? 8 : 6) {
                header
                if let other = otherWay {
                    HStack(alignment: .top, spacing: isLarge ? 8 : 6) {
                        way(board.choice.wayName, buses: coming)
                        way(other.wayName, buses: board.coming(at: entry.date, other: true))
                    }
                    .padding(.top, isLarge ? 4 : 0)
                } else if let bus = coming.first, let time = bus.time {
                    if isLarge {
                        large(bus, time: time)
                    } else {
                        BoardBox {
                            if isSmall { smallBox(bus, time: time) } else { mediumBox(bus, time: time) }
                        }
                    }
                } else {
                    BoardBox {
                        Text(board.problem ?? "No \(BusBadge.label(line)) buses predicted")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BoardInk.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Header

    private var heading: String { otherWay == nil ? "to \(board.choice.wayName)" : "Both directions" }

    /// Small: just the badge, as a train's small board has just its bullet.
    private var header: some View {
        HStack(alignment: .center, spacing: isSmall ? 6 : 8) {
            BusBadge(line: line, size: isSmall ? 22 : isLarge ? 30 : 24)
            if isSmall {
                EmptyView()
            } else if isLarge {
                VStack(alignment: .leading, spacing: 0) {
                    Text(board.choice.stopName)
                        .font(BoardStyle.large.nameFont)
                        .foregroundStyle(BoardInk.text)
                    Text(heading)
                        .font(BoardStyle.large.headingFont)
                        .foregroundStyle(BoardInk.gray)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityElement(children: .combine)
            } else if otherWay != nil {
                Text("\(board.choice.stopName) \(Text("Both directions").font(.footnote).foregroundStyle(BoardInk.gray))")
                    .font(.body.bold())
                    .foregroundStyle(BoardInk.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            } else {
                Text("\(board.choice.stopName) \(Text(heading).font(.footnote).foregroundStyle(BoardInk.gray))")
                    .font(.body.bold())
                    .foregroundStyle(BoardInk.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("\(board.choice.stopName), \(heading)")
            }
            Spacer(minLength: isSmall ? 2 : 4)
            RefreshMark(entry: entry, refreshing: refreshing)
            CloseRoom(entry: entry, large: !isSmall)
            // Room for the walk button (`RouteControls`), as Next train's
            Pill(symbol: "figure.walk", large: !isSmall).hidden()
        }
    }

    /// Counts down to the bus on the Lock Screen, lit while it does, as Next train's.
    private var walkButton: some View {
        WalkButton(intent: ToggleBusCountdownIntent(bus: board.choice, widgetID: entry.widgetID),
                   route: BusLeg.prefix + line, running: entry.countingDown, large: !isSmall,
                   plansRoute: entry.plansRoute)
    }

    // MARK: Times

    /// To `bus`, then "At Stop" once it's due, for its moment there.
    private func countdown(_ bus: BusArrival, time: Date, size: CGFloat) -> some View {
        BoardCountdown(start: entry.date, end: time, isLive: bus.isLive, marks: marks, size: size,
                       atStation: time <= entry.date, atLabel: AtStation.busLabel)
    }

    private func minutes(_ time: Date) -> MinutesToGo {
        MinutesToGo(until: time, from: entry.date)
    }

    /// The next one's minutes: "then 11 min".
    private var then: String? {
        coming.dropFirst().first?.time.map { "then \(minutes($0).label)" }
    }

    private func color(_ bus: BusArrival) -> Color {
        bus.isLive ? .liveText : BoardInk.color(.text, route: true)
    }

    private func smallBox(_ bus: BusArrival, time: Date) -> some View {
        let digits: CGFloat = time.timeIntervalSince(entry.date) >= 599 ? 0.78 : 1
        // Centred in the box, as the small train board's
        return VStack(alignment: .center, spacing: 2) {
            countdown(bus, time: time, size: 48 * digits)
            if let then {
                Text(then)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardInk.gray)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func mediumBox(_ bus: BusArrival, time: Date) -> some View {
        HStack(spacing: 8) {
            countdown(bus, time: time, size: 48)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                leaves(time, badge: 18, font: .subheadline.weight(.semibold))
                if let then {
                    Text(then)
                        .font(.footnote)
                        .foregroundStyle(BoardInk.gray)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// "[B63] leaves 8:42".
    private func leaves(_ time: Date, badge: CGFloat, font: Font) -> some View {
        HStack(spacing: 5) {
            BusBadge(line: line, size: badge)
            Text("leaves \(time.clock)")
                .font(font)
                .foregroundStyle(BoardInk.text)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(BusBadge.spokenName(line)) leaves at \(Spoken.clock(time))")
    }

    /// The countdown card, then the next three as a departures board.
    private func large(_ bus: BusArrival, time: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                countdown(bus, time: time, size: 48)
                Spacer(minLength: 0)
                leaves(time, badge: 18, font: .subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: WaysBoard.boxHeight)
            .background(BoardTile())
            .padding(.top, 4)
            let later = coming.dropFirst().prefix(3)
            if !later.isEmpty {
                Text("Then")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardInk.gray)
                    .padding(.leading, 10)
                VStack(spacing: 0) {
                    ForEach(Array(later.enumerated()), id: \.offset) { _, next in
                        if let time = next.time { thenRow(next, time: time) }
                    }
                }
            }
        }
    }

    private func thenRow(_ bus: BusArrival, time: Date) -> some View {
        let going = bus.destination.map(BusStopTimes.destination) ?? board.choice.wayName
        return HStack(spacing: 10) {
            BusBadge(line: bus.line, size: 22).frame(width: 46)
            Text(going)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BoardInk.text)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(time.clock)
                .font(.subheadline)
                .foregroundStyle(BoardInk.gray)
            Text(minutes(time).label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color(bus))
                .frame(minWidth: 58, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(BusBadge.spokenName(bus.line)) to \(going), \(Spoken.clock(time)), \(bus.isLive ? "live" : "scheduled")")
    }

    /// One direction showing both: medium's tile (the way, the countdown, its time and the next
    /// one's minutes), or large's column with the next three under it.
    private func way(_ name: String, buses: [BusArrival]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(BoardInk.gray)
            if let bus = buses.first, let time = bus.time {
                countdown(bus, time: time, size: isLarge ? 40 : 38)
                if isLarge {
                    leaves(time, badge: 14, font: .caption.weight(.semibold))
                    let later = buses.dropFirst().prefix(3).compactMap(\.time)
                    if !later.isEmpty {
                        Divider().padding(.vertical, 8)
                        Text("Then")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BoardInk.gray)
                        ForEach(Array(zip(buses.dropFirst().prefix(3), later).enumerated()), id: \.offset) { _, pair in
                            HStack {
                                Text(pair.1.clock)
                                    .font(.footnote)
                                    .foregroundStyle(BoardInk.gray)
                                Spacer(minLength: 4)
                                Text(minutes(pair.1).label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(color(pair.0))
                            }
                            .padding(.top, 4)
                        }
                    }
                } else {
                    // Where there isn't room, the badge goes (the header has it), then the next
                    // one's minutes
                    let next = buses.dropFirst().first?.time.map { " · then \(minutes($0).label)" }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            BusBadge(line: line, size: 14)
                            Text(time.clock + (next ?? ""))
                        }
                        Text(time.clock + (next ?? ""))
                        HStack(spacing: 4) {
                            BusBadge(line: line, size: 14)
                            Text(time.clock)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(BusBadge.spokenName(line)) leaves at \(Spoken.clock(time))")
                }
            } else {
                Text(board.problem ?? "None predicted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                    .padding(.top, 4)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(isLarge ? 12 : 0)
        .padding(.horizontal, isLarge ? 0 : 12)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: isLarge ? .topLeading : .leading)
        .background(BoardTile())
        .accessibilityElement(children: .combine)
    }
}

/// The Citi Bike widget's dock: its counts (Bikes, E-Bikes and Docks, as Settings has them). Small:
/// stacked rows in a box. Medium: a tile each. Large: the tiles, then the nearest other docks'
/// counts under column headers.
private struct DockRouteBoard: View {
    let entry: TrainEntry
    let board: SavedDockBoard
    let family: WidgetFamily
    let refreshing: Bool
    let controls: Bool

    private var isSmall: Bool { family == .systemSmall }
    private var isLarge: Bool { family == .systemLarge }

    var body: some View {
        if controls {
            RouteControls(entry: entry, large: !isSmall) { header }
        } else {
            VStack(alignment: .leading, spacing: isSmall ? 8 : 10) {
                header
                if let counts = board.counts {
                    if isSmall {
                        BoardBox {
                            VStack(spacing: 4) {
                                ForEach(board.columns, id: \.self) { row(counts, $0) }
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ForEach(board.columns, id: \.self) { tile(counts, $0) }
                        }
                        .frame(maxHeight: isLarge ? 104 : .infinity)
                        if isLarge { nearby }
                    }
                } else {
                    BoardBox {
                        Text(board.problem ?? "No counts")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BoardInk.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if isLarge { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// The mark, the dock's name, the time and ✕ on one line. Only on small, and only when the
    /// name doesn't fit beside them, it goes on the line under.
    @ViewBuilder private var header: some View {
        if isSmall {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    mark
                    name.fixedSize()
                    Spacer(minLength: 0)
                    headerEnd
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        mark
                        Spacer(minLength: 0)
                        headerEnd
                    }
                    name.minimumScaleFactor(0.75)
                }
            }
        } else {
            HStack(spacing: 8) {
                mark
                name.minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                headerEnd
            }
        }
    }

    private var mark: some View {
        CitiBikeMark(size: isSmall ? 22 : isLarge ? 30 : 26, eBikes: board.kinds == .eBikes)
    }

    private var name: some View {
        Text(board.dock.name)
            .font(isSmall ? .footnote.bold() : .body.bold())
            .foregroundStyle(BoardInk.text)
            .lineLimit(1)
    }

    /// When the counts were had (not on small), ↻ and room for the ✕.
    @ViewBuilder private var headerEnd: some View {
        if !isSmall {
            Text(board.fetched, format: .dateTime.hour().minute())
                .font(.caption.weight(.semibold))
                .foregroundStyle(BoardInk.gray)
                .accessibilityLabel("At \(Spoken.clock(board.fetched))")
        }
        RefreshMark(entry: entry, refreshing: refreshing)
        CloseRoom(entry: entry, large: !isSmall)
    }

    private func row(_ dock: CitiBike.Dock, _ column: SavedDockBoard.Column) -> some View {
        HStack {
            Text(column.name)
                .font(.caption)
                .foregroundStyle(BoardInk.gray)
            Spacer()
            Text("\(column.count(dock))")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(BoardInk.text)
        }
        .accessibilityElement(children: .combine)
    }

    private func tile(_ dock: CitiBike.Dock, _ column: SavedDockBoard.Column) -> some View {
        VStack(spacing: 2) {
            Text("\(column.count(dock))")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(BoardInk.text)
                .minimumScaleFactor(0.6)
            Text(column.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(BoardInk.gray)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BoardTile())
        .accessibilityElement(children: .combine)
    }

    private static let countColumn: CGFloat = 50

    /// The nearest other docks: "Nearby docks" and the counts' names on one line, then a row
    /// each, numbers only.
    @ViewBuilder private var nearby: some View {
        if !board.nearby.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(board.nearest ? "Next nearest" : "Nearby docks")
                    Spacer(minLength: 6)
                    ForEach(board.columns, id: \.self) { column in
                        Text(column.name).lineLimit(1).fixedSize().frame(width: Self.countColumn)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(BoardInk.gray)
                .accessibilityHidden(true)
                ForEach(board.nearby, id: \.self) { other in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(other.dock.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(BoardInk.text)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(other.walkMinutes) min walk")
                                .font(.caption)
                                .foregroundStyle(BoardInk.gray)
                        }
                        Spacer(minLength: 6)
                        ForEach(board.columns, id: \.self) { column in
                            Text("\(column.count(other.dock))")
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(BoardInk.text)
                                .frame(width: Self.countColumn)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spoken(other))
                }
            }
            .padding(.horizontal, 4)
        }
    }

    /// "4 Av & 9 St, 2 minute walk: 0 bikes, 1 e-bike, 22 docks".
    private func spoken(_ other: SavedDockBoard.Nearby) -> String {
        let counts = board.columns.map { "\($0.count(other.dock)) \($0.name.lowercased())" }.joined(separator: ", ")
        return "\(other.dock.name), \(other.walkMinutes) minute walk: \(counts)"
    }
}

// MARK: - Previews

extension TrainEntry {
    /// A saved B63 at 4 Av & 9 St toward Cobble Hill; with `both`, toward Bay Ridge too.
    static func busPreview(both: Bool = false) -> TrainEntry {
        let now = Date.now
        let stop = BusStopTimes.Stop(id: "301234", name: "4 AV/9 ST", latitude: 40.6705, longitude: -73.9886, direction: "N")
        let other = BusStopTimes.Stop(id: "301235", name: "4 AV/9 ST", latitude: 40.6703, longitude: -73.9888, direction: "S")
        let choice = BusChoice(line: "B63", stop: stop, destination: "COBBLE HILL", otherStop: other,
                               otherDestination: "BAY RIDGE", bothWays: both)
        let buses = { (minutes: [Double], to: String) in
            minutes.enumerated().map { index, minute in
                BusArrival(line: "B63", destination: to, expected: index < 2 ? now.addingTimeInterval(minute * 60) : nil,
                           aimed: now.addingTimeInterval(minute * 60))
            }
        }
        let board = SavedBusBoard(choice: choice, buses: buses([3.1, 14, 25, 37], "COBBLE HILL"),
                                  otherWay: both ? choice.otherWay : nil,
                                  otherBuses: both ? buses([7.3, 19, 31, 44], "BAY RIDGE") : [])
        var entry = TrainEntry(date: now, selection: .fallback, trains: [])
        entry.route = .bus(board)
        return entry
    }

    /// A saved dock at 5 Av & 3 St, counting as Settings has `kinds`.
    /// The Citi Bike widget's favorite dock at 5 Av & 3 St (or `name`), counting as Settings has
    /// `kinds`; with `nearest`, the dock nearest you, 4 Av & 9 St.
    static func dockPreview(kinds: SharedBikeKinds = .both, nearest: Bool = false, name: String? = nil) -> TrainEntry {
        let dock = { (id: String, name: String, bikes: Int, eBikes: Int, docks: Int) in
            CitiBike.Dock(id: id, name: name, lat: 40.67, lon: -73.98, bikes: bikes, eBikes: eBikes, docks: docks,
                          renting: true, returning: true)
        }
        let others: [SavedDockBoard.Nearby] = nearest ? [
            .init(dock: dock("1", "5 Av & 3 St", 6, 2, 9), walkMinutes: 6),
            .init(dock: dock("3", "7 Av & 9 St", 11, 4, 3), walkMinutes: 7),
            .init(dock: dock("4", "Prospect Park West & 8 St", 14, 2, 12), walkMinutes: 9),
        ] : [
            .init(dock: dock("2", "4 Av & 9 St", 0, 1, 22), walkMinutes: 2),
            .init(dock: dock("3", "7 Av & 9 St", 11, 4, 3), walkMinutes: 4),
            .init(dock: dock("4", "Prospect Park West & 8 St", 14, 2, 12), walkMinutes: 8),
        ]
        let counts = nearest ? dock("2", name ?? "4 Av & 9 St", 3, 1, 22) : dock("1", name ?? "5 Av & 3 St", 6, 2, 9)
        let board = SavedDockBoard(dock: DockChoice(counts), counts: counts, nearby: others, kinds: kinds,
                                   fetched: .now, nearest: nearest)
        var entry = TrainEntry(date: .now, selection: .fallback, trains: [])
        entry.route = .dock(board)
        return entry
    }
}

#Preview("Bus", as: .systemMedium) {
    LeewayWidget()
} timeline: {
    TrainEntry.busPreview().asCard()
    TrainEntry.busPreview().asCard(opened: true)
    TrainEntry.busPreview(both: true).asCard(opened: true)
}

#Preview("Bus, small", as: .systemSmall) {
    LeewayWidget()
} timeline: {
    TrainEntry.busPreview().asCard()
    TrainEntry.busPreview().asCard(opened: true)
}

#Preview("Bus, large", as: .systemLarge) {
    LeewayWidget()
} timeline: {
    TrainEntry.busPreview().asCard(opened: true)
    TrainEntry.busPreview(both: true).asCard(opened: true)
}

// MARK: - Lock Screen

/// What the Saved Route's Lock Screen widgets show, for a train, a bus or a dock.
struct LockFace {
    enum Mark {
        case line(String)
        case bus(String)
        case bike(eBikes: Bool)
    }

    var mark: Mark
    /// "4 Av-9 St".
    var name: String
    /// "Manhattan", "Cobble Hill"; nil for a dock.
    var way: String?
    /// To when it leaves (or to leave for it), and whether it's a prediction; nil with none.
    var countdown: (start: Date, end: Date, isLive: Bool)?
    /// In place of the countdown's 0:00 while it's due: "At Stop", "At Stn".
    var atLabel: String? = nil
    /// "then 9 min".
    var then: String?
    /// Why there's no countdown.
    var problem: String
    /// A dock's counts, as Settings has them: "6 Bikes", "2 E-Bikes", "9 Docks".
    var counts: [(number: Int, name: String)] = []

    /// "R", "B63", for the inline widget.
    var markLabel: String {
        switch mark {
        case .line(let route): LineStyle.of(route).label
        case .bus(let line): BusBadge.label(line)
        case .bike: "Citi Bike"
        }
    }
}

/// The Saved Route on the Lock Screen. Inline: "R in 4:12 · 4 Av-9 St to Manhattan".
/// Rectangular: top left the mark and name, the way right under them; bottom right the countdown,
/// "then 9 min" under it; a dock's counts in evenly spread columns. Circular: the mark over the
/// countdown, or a dock's bikes.
struct RouteLockScreen: View {
    let face: LockFace
    let family: WidgetFamily
    var refreshing = false
    @Environment(\.isLuminanceReduced) private var luminanceReduced

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        // The rectangle is too small for bigger text sizes: they'd only shrink the name away
        default: rectangular.dynamicTypeSize(...DynamicTypeSize.large)
        }
    }

    /// The countdown as a live timer, or dimmed, the clock time it counts to; while it's due,
    /// "At Stop" or "At Stn".
    @ViewBuilder private func countdown(_ countdown: (start: Date, end: Date, isLive: Bool)) -> some View {
        if let atLabel = face.atLabel {
            Text(atLabel)
        } else if luminanceReduced {
            Text(countdown.end.clock)
        } else {
            Text(TimerText.placeholder(seconds: countdown.end.timeIntervalSince(countdown.start)))
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(timerInterval: countdown.start...max(countdown.start, countdown.end), countsDown: true)
                        .multilineTextAlignment(.trailing)
                }
        }
    }

    @ViewBuilder private var inline: some View {
        let place = [face.name, face.way.map { "to \($0)" }].compactMap { $0 }.joined(separator: " ")
        if !face.counts.isEmpty {
            // "6 bikes · 2 e-bikes · 5 Av & 3 St"
            Text((face.counts.filter { $0.name != "Docks" }.map { "\($0.number) \($0.name.lowercased())" } + [face.name])
                .joined(separator: " · "))
        } else if let countdown = face.countdown {
            if let atLabel = face.atLabel {
                Text("\(face.markLabel) \(atLabel) · \(place)")
            } else if luminanceReduced {
                Text("\(face.markLabel) at \(countdown.end.clock) · \(place)")
            } else {
                Text("\(face.markLabel) in \(Text(timerInterval: countdown.start...max(countdown.start, countdown.end), countsDown: true)) · \(place)")
            }
        } else {
            Text("\(face.markLabel) · \(face.problem)")
        }
    }

    @ViewBuilder private func mark(_ size: CGFloat) -> some View {
        switch face.mark {
        case .line(let route):
            Text(LineStyle.of(route).label)
                .font(.system(size: size * 0.62, weight: .bold))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(lineWidth: 1.5))
                .accessibilityLabel(Lines.name(of: route))
        case .bus(let line):
            Text(BusBadge.label(line))
                .font(.system(size: size * 0.55, weight: .bold))
                .padding(.horizontal, size * 0.2)
                .frame(height: size)
                .overlay(RoundedRectangle(cornerRadius: size * 0.28).stroke(lineWidth: 1.5))
                .fixedSize()
                .accessibilityLabel(BusBadge.spokenName(line))
        case .bike(let eBikes):
            Image(systemName: eBikes ? "bolt.fill" : "bicycle")
                .font(.system(size: size * 0.7, weight: .bold))
                .accessibilityLabel(eBikes ? "Citi Bike e-bikes" : "Citi Bike")
        }
    }

    private var heading: some View {
        HStack(spacing: 6) {
            mark(face.counts.isEmpty ? 17 : 15)
            // As big as fits: a long name shrinks before the mark or countdown do
            Text(face.name)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if refreshing {
                Spacer(minLength: 0)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var rectangular: some View {
        if !face.counts.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                heading
                HStack(spacing: 0) {
                    ForEach(face.counts, id: \.name) { count in
                        VStack(spacing: -2) {
                            Text("\(count.number)").font(.system(size: 18, weight: .bold, design: .rounded))
                            Text(count.name).font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // The two corners share the height, so each can be bigger
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    if let way = face.way {
                        Text(way)
                            .font(.footnote)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
                VStack(alignment: .trailing, spacing: -3) {
                    if let time = face.countdown {
                        countdown(time)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let then = face.then {
                            Text(then).font(.caption2.weight(.semibold))
                        }
                    } else {
                        Text(face.problem).font(.caption2).multilineTextAlignment(.trailing)
                    }
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                if refreshing {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .bold))
                        .accessibilityLabel("Refreshing")
                } else {
                    switch face.mark {
                    case .line: mark(26)
                    case .bus: mark(22)
                    case .bike: mark(18)
                    }
                }
                Group {
                    if !face.counts.isEmpty {
                        // The bikes Settings counts: "6 · 2", or just e-bikes' "2"
                        Text(face.counts.filter { $0.name != "Docks" }.map { "\($0.number)" }.joined(separator: " · "))
                    } else if let time = face.countdown {
                        countdown(time)
                    } else {
                        Text("–")
                    }
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 6)
            }
            .accessibilityElement(children: .combine)
            // Not "6 · 2": what each count is
            .accessibilityLabel(Text(spokenCounts), isEnabled: !refreshing && !face.counts.isEmpty)
        }
    }

    /// "Citi Bike, 6 bikes, 2 e-bikes", for the circular face.
    private var spokenCounts: String {
        let counts = face.counts.filter { $0.name != "Docks" }.map { count in
            let name = count.name.lowercased()
            return "\(count.number) \(count.number == 1 ? String(name.dropLast()) : name)"
        }
        return (["Citi Bike"] + counts).joined(separator: ", ")
    }
}

extension RouteTimes {
    /// Its Lock Screen face at `date`.
    func lockFace(at date: Date) -> LockFace {
        switch self {
        case .bus(let board):
            let coming = board.coming(at: date)
            let then = coming.dropFirst().first?.time.map { "then \(MinutesToGo(until: $0, from: date).label)" }
            let due = coming.first?.time.map { $0 <= date } ?? false
            return LockFace(mark: .bus(board.choice.line), name: board.choice.stopName, way: board.choice.wayName,
                            countdown: coming.first.flatMap { bus in bus.time.map { (date, $0, bus.isLive) } },
                            atLabel: due ? AtStation.busLabel : nil,
                            then: then, problem: board.problem ?? "No buses predicted")
        case .dock(let board):
            let counts = board.counts.map { dock in board.columns.map { ($0.count(dock), $0.name) } } ?? []
            return LockFace(mark: .bike(eBikes: board.kinds == .eBikes), name: board.dock.name,
                            problem: board.problem ?? "No counts", counts: counts)
        }
    }
}

#Preview("Lock Screen, rectangular", as: .accessoryRectangular) {
    LeewayWidget()
} timeline: {
    TrainEntry.preview
    TrainEntry.busPreview()
}

#Preview("Lock Screen, circular", as: .accessoryCircular) {
    LeewayWidget()
} timeline: {
    TrainEntry.preview
    TrainEntry.busPreview()
}

#Preview("Lock Screen, inline", as: .accessoryInline) {
    LeewayWidget()
} timeline: {
    TrainEntry.preview
    TrainEntry.busPreview()
}

#Preview("Lock Screen faces") {
    let now = Date.now
    let faces: [LockFace] = [
        LockFace(mark: .line("R"), name: "4 Av-9 St", way: "Manhattan", countdown: (now, now + 252, true),
                 then: "then 9 min", problem: ""),
        TrainEntry.busPreview().route!.lockFace(at: now),
        TrainEntry.dockPreview().route!.lockFace(at: now),
    ]
    VStack(spacing: 14) {
        ForEach(faces.indices, id: \.self) { index in
            RouteLockScreen(face: faces[index], family: .accessoryInline)
            HStack(spacing: 14) {
                RouteLockScreen(face: faces[index], family: .accessoryRectangular)
                    .frame(width: 160, height: 72)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.12)))
                RouteLockScreen(face: faces[index], family: .accessoryCircular)
                    .frame(width: 72, height: 72)
            }
        }
    }
    .foregroundStyle(.white)
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        .overlay(Color.black.opacity(0.25)).ignoresSafeArea())
}

extension TrainEntry {
    /// `transferPreview` with the B63 from near the change as another way on.
    static var busChangePreview: TrainEntry {
        var entry = transferPreview()
        let stop = BusStop(id: "301234", name: "ATLANTIC AV/4 AV", latitude: 40.684, longitude: -73.977, direction: "N")
        let leg = BusLeg(line: "B63", stop: stop, destination: "PIER 6 BKLYN BRIDGE PK", walkMinutes: 3)
        let buses = (0..<6).map { index in
            BusArrival(line: "B63", destination: leg.destination, expected: entry.date.addingTimeInterval(Double(index) * 420 + 600))
        }
        entry.connections = entry.connections?.map { TrainService.addingBuses([(leg, buses)], to: $0) }
        entry.change?.buses = [leg]
        return entry
    }
}

#Preview("Change to a bus", as: .systemLarge) {
    LeewayWidget()
} timeline: {
    TrainEntry.busChangePreview
}

#Preview("Change to a bus, medium", as: .systemMedium) {
    LeewayWidget()
} timeline: {
    TrainEntry.busChangePreview
}

extension TrainEntry {
    /// `busPreview` changing to the R at 4 Av-9 St, or the F/G there, 3 minutes' walk from the stop.
    static var busToTrainPreview: TrainEntry {
        var entry = busPreview()
        guard case .bus(var board) = entry.route else { return entry }
        let station = { (routes: [String]) in
            var selection = Selection.fallback
            selection.stationID = "R33"
            selection.routes = routes
            selection.direction = .north
            return selection
        }
        board.choice.changes = [
            BusChange(stop: board.choice.stop, minutes: 6, walkMinutes: 3, selection: station(["R"])),
        ]
        board.changeTrains = [[4.0, 13, 21, 30, 38].map { minutes in
            Arrival(route: "R", time: entry.date.addingTimeInterval(minutes * 60 + 600), stop: "R33N", lastStop: "R01N",
                    isLive: minutes < 25)
        }]
        entry.route = .bus(board)
        return entry
    }
}

#Preview("Bus to a train", as: .systemLarge) {
    LeewayWidget()
} timeline: {
    TrainEntry.busToTrainPreview.asCard(opened: true)
}

#Preview("Bus to a train, medium", as: .systemMedium) {
    LeewayWidget()
} timeline: {
    TrainEntry.busToTrainPreview.asCard(opened: true)
}

private extension TrainEntry {
    /// A moment after the first train's due: "At Station".
    static var atStationPreview: TrainEntry {
        var entry = TrainEntry.preview
        if let first = entry.trains.first { entry.date = first.time.addingTimeInterval(3) }
        return entry
    }

    /// A moment after the first bus is due: "At Stop".
    static var atStopPreview: TrainEntry {
        var entry = TrainEntry.busPreview().asCard(opened: true)
        if case .bus(let board) = entry.route, let due = board.buses.first?.time {
            entry.date = due.addingTimeInterval(2)
        }
        return entry
    }
}

#Preview("At Station, small", as: .systemSmall) {
    LeewayWidget()
} timeline: {
    TrainEntry.atStationPreview
}

#Preview("At Station, medium", as: .systemMedium) {
    LeewayWidget()
} timeline: {
    TrainEntry.atStationPreview
}

#Preview("At Stop, small", as: .systemSmall) {
    LeewayWidget()
} timeline: {
    TrainEntry.atStopPreview
}

#Preview("At Stop, medium", as: .systemMedium) {
    LeewayWidget()
} timeline: {
    TrainEntry.atStopPreview
}
