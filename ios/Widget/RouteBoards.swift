import SwiftUI
import WidgetKit

// The Saved Route widget's bus and Citi Bike boards: what a saved bus or dock widget shows in
// place of trains (`TrainEntry.route`), drawn as the subway's Saved Route boards are (`routeLook`):
// a card until a tap, then the times or counts, with a ✕ back to the card.

/// A bus or a Citi Bike dock's Saved Route, fetched.
enum RouteTimes {
    case bus(BusBoard)
    case dock(DockBoard)

    /// "4 Av & 9 St", "5 Av & 3 St".
    var placeName: String {
        switch self {
        case .bus(let board): board.choice.stopName
        case .dock(let board): board.dock.name
        }
    }

    /// Under the place on its card: "to Cobble Hill", "Both directions", "Citi Bike dock".
    var cardHeading: String {
        switch self {
        case .bus(let board): board.choice.bothWays && board.otherWay != nil ? "Both directions" : "to \(board.choice.wayName)"
        case .dock: "Citi Bike dock"
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
struct BusBoard {
    var choice: BusChoice
    /// Soonest first.
    var buses: [BusArrival]
    /// Showing both directions: the other way and its next buses.
    var otherWay: BusChoice? = nil
    var otherBuses: [BusArrival] = []
    /// Why there are no times, when there aren't.
    var problem: String? = nil

    /// The buses still to come at `date`.
    func coming(at date: Date, other: Bool = false) -> [BusArrival] {
        (other ? otherBuses : buses).filter { ($0.time ?? .distantPast) > date }
    }

    /// Its next buses now, and the other way's with both directions (MTA Bus Time, through the
    /// push server).
    static func fetch(_ choice: BusChoice, now: Date) async -> BusBoard {
        let other = choice.bothWays ? choice.otherWay : nil
        async let times = BusTimes.arrivals(line: choice.line, at: choice.place, now: now)
        async let otherTimes = other.asyncMap { await BusTimes.arrivals(line: $0.line, at: $0.place, now: now) }
        let mine = await times
        let theirs = await otherTimes
        return BusBoard(choice: choice, buses: mine?.arrivals ?? [], otherWay: other, otherBuses: theirs??.arrivals ?? [],
                        problem: mine == nil ? "Couldn't reach Bus Time" : nil)
    }
}

/// A saved Citi Bike widget's dock: its counts now, and the nearest other docks'.
struct DockBoard {
    var dock: DockChoice
    var counts: CitiBike.Dock?
    var nearby: [Nearby] = []
    /// Which counts show, as Settings › Biking has it (Docks always).
    var kinds = SharedBikeKinds.both
    var fetched: Date
    var problem: String? = nil

    struct Nearby: Hashable {
        var dock: CitiBike.Dock
        var walkMinutes: Int
    }

    /// The nearby docks the large widget lists.
    static let nearbyCount = 3

    /// The dock's counts now, with its nearest others: with E-Bikes alone, only those with one.
    static func fetch(_ dock: DockChoice, kinds: SharedBikeKinds, now: Date) async -> DockBoard {
        guard let docks = await CitiBike.docks() else {
            return DockBoard(dock: dock, kinds: kinds, fetched: now, problem: "Couldn't reach Citi Bike")
        }
        let here = dock.location
        let nearby = docks
            .filter { $0.id != dock.id && (kinds != .eBikes || $0.available(.eBike) > 0) }
            .map { (dock: $0, meters: $0.location.distance(from: here)) }
            .sorted { $0.meters < $1.meters }
            .prefix(nearbyCount)
            .map { Nearby(dock: $0.dock, walkMinutes: TripPlanner.walkMinutes($0.meters)) }
        let counts = docks.first { $0.id == dock.id }
        return DockBoard(dock: dock, counts: counts, nearby: Array(nearby), kinds: kinds, fetched: now,
                         problem: counts == nil ? "This dock isn't in service" : nil)
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

extension Optional {
    /// `transform` on the wrapped value, awaited; nil without one.
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

// MARK: - Marks

/// Citi Bike's mark: a bike on its blue; with E-Bikes alone, a yellow bolt on it.
struct DockMark: View {
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
            Text(route.placeName)
                .font(.headline)
                .foregroundStyle(BoardInk.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(route.cardHeading)
                .font(.caption)
                .foregroundStyle(BoardInk.gray)
                .lineLimit(2)
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

    private var tint: Color {
        switch route {
        case .bus(let board): BusBadge.isSBS(board.choice.line) ? BusBadge.sbsBlue : BusBadge.blue
        case .dock: DockMark.blue
        }
    }

    @ViewBuilder private func mark(_ size: CGFloat) -> some View {
        switch route {
        case .bus(let board): BusBadge(line: board.choice.line, size: size)
        case .dock(let board): DockMark(size: size, eBikes: board.kinds == .eBikes)
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
        case .bus(let board): BusRouteBoard(entry: entry, board: board, family: family, refreshing: refreshing, controls: controls)
        case .dock(let board): DockRouteBoard(entry: entry, board: board, family: family, refreshing: refreshing, controls: controls)
        }
    }
}

/// The ✕ back to the card, at the header's right; nothing else takes taps but the refresh under it.
private struct RouteControls<Header: View>: View {
    let entry: TrainEntry
    let large: Bool
    @ViewBuilder let header: Header

    var body: some View {
        VStack(spacing: 0) {
            header.hidden()
                .overlay(alignment: large ? .trailing : .topTrailing) {
                    BoardButtons(entry: entry, large: large, spacing: 8) { EmptyView() }
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
    let board: BusBoard
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
            RouteControls(entry: entry, large: !isSmall) { header }
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

    private var header: some View {
        HStack(alignment: .center, spacing: isSmall ? 6 : 8) {
            BusBadge(line: line, size: isSmall ? 22 : isLarge ? 30 : 24)
            if isSmall {
                Text(entry.closes ? board.choice.stopName : board.choice.wayName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("\(board.choice.stopName) \(Text(heading).font(.footnote).foregroundStyle(BoardInk.gray))")
                    .font(.body.bold())
                    .foregroundStyle(BoardInk.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("\(board.choice.stopName), \(heading)")
            }
            Spacer(minLength: 4)
            RefreshMark(entry: entry, refreshing: refreshing)
            CloseRoom(entry: entry, large: !isSmall)
        }
    }

    // MARK: Times

    private func countdown(_ bus: BusArrival, time: Date, size: CGFloat) -> some View {
        BoardCountdown(start: entry.date, end: time, isLive: bus.isLive, marks: marks, size: size)
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
        return VStack(alignment: .leading, spacing: 0) {
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
                    HStack(spacing: 4) {
                        BusBadge(line: line, size: 14)
                        let next = buses.dropFirst().first?.time.map { " · then \(minutes($0).label)" }
                        Text(time.clock + (next ?? ""))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BoardInk.text)
                            .fixedSize()
                    }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isLarge ? .topLeading : .leading)
        .background(BoardTile())
        .accessibilityElement(children: .combine)
    }
}

/// A saved Citi Bike dock: its counts (Bikes, E-Bikes and Docks, as Settings has them). Small:
/// stacked rows in a box. Medium: a tile each. Large: the tiles, then the nearest other docks'
/// counts under column headers.
private struct DockRouteBoard: View {
    let entry: TrainEntry
    let board: DockBoard
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

    private var header: some View {
        HStack(spacing: 8) {
            DockMark(size: isSmall ? 22 : isLarge ? 30 : 26, eBikes: board.kinds == .eBikes)
            Text(board.dock.name)
                .font(isSmall ? .footnote.bold() : .body.bold())
                .foregroundStyle(BoardInk.text)
                .lineLimit(isSmall ? 2 : 1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            if !isSmall {
                // When the counts were had
                Text(board.fetched, format: .dateTime.hour().minute())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardInk.gray)
                    .accessibilityLabel("At \(Spoken.clock(board.fetched))")
            }
            RefreshMark(entry: entry, refreshing: refreshing)
            CloseRoom(entry: entry, large: !isSmall)
        }
    }

    private func row(_ dock: CitiBike.Dock, _ column: DockBoard.Column) -> some View {
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

    private func tile(_ dock: CitiBike.Dock, _ column: DockBoard.Column) -> some View {
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
                    Text("Nearby docks")
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
    private func spoken(_ other: DockBoard.Nearby) -> String {
        let counts = board.columns.map { "\($0.count(other.dock)) \($0.name.lowercased())" }.joined(separator: ", ")
        return "\(other.dock.name), \(other.walkMinutes) minute walk: \(counts)"
    }
}
