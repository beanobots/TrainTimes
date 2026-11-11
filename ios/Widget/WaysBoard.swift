import SwiftUI
import UIKit
import WidgetKit

/// The Transfers widget: your train's countdown, then the ways on from it. Timed to the change's
/// destination, or without one, to when each line's train gets to the change. On large, the
/// header, then the soonest there in a box of its own and the rest below as they fit; walk is
/// top right. On medium, just the countdown, with walk, and the soonest way. A tap anywhere
/// else refreshes (`TrainWidgetView`).
struct WaysBoard: View {
    let entry: TrainEntry
    let change: Change
    /// Just tapped to refresh, so ↻ shows until the new times.
    var refreshing = false
    /// The controls layer: only the walk button, where the board has room for it.
    var controls = false
    /// A saved bus changing to a train: the bus, in the header where your train goes. It has no
    /// countdown on the Lock Screen, so no walk button.
    var origin: Origin? = nil
    @Environment(\.widgetFamily) private var widgetFamily

    struct Origin {
        var line: String
        /// Its stop: "4 Av & 9 St".
        var name: String
        /// "Cobble Hill".
        var way: String
    }
    @Environment(\.boardFamily) private var boardFamily
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.routeLook) private var routeLook
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    private var family: WidgetFamily { boardFamily ?? widgetFamily }
    private var style: BoardStyle { BoardStyle.large.at(textSize) }
    private var marks: TimeMarks { entry.settings.timeMarks(withoutColor: withoutColor, renderingMode: renderingMode) }
    private var connections: [Connection] { entry.connections ?? [] }
    /// Your train's ways on; from an older save without them, just the train it meets.
    private func ways(_ connection: Connection) -> [Way] {
        connection.ways ?? connection.next.map { [Way(route: $0.route, connection: connection, arrival: $0)] } ?? []
    }

    /// As tall as medium's box, which fills the widget below its header.
    static let boxHeight: CGFloat = 96
    private static let rowInset: CGFloat = 10
    private static let bulletColumn: CGFloat = 38
    private static let countdownColumn: CGFloat = 60
    /// Row heights: full, and the most a row shrinks to fit one more in.
    private static let rowHeight: CGFloat = 30
    private static let tightRowHeight: CGFloat = 26
    /// The least space between the bullets of rows one above the other.
    private static let bulletGap: CGFloat = 6

    var body: some View {
        if family == .systemMedium {
            mediumBoard
        } else if controls {
            VStack(spacing: 0) {
                header.hidden()
                    .overlay(alignment: .trailing) { buttons }
                Spacer(minLength: 0)
            }
        } else {
            board
        }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let first = connections.first {
                TopCard(entry: entry, train: first.first,
                        later: connections.dropFirst().prefix(routeLook ? 1 : 2).map { minutesToLeave($0.first) },
                        marks: marks)
                    .padding(.top, 10)
                let ways = ways(first)
                if routeLook, !ways.isEmpty {
                    table(Array(ways.prefix(3)))
                        .padding(.top, 12)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if let fastest = ways.first {
                    fastestBox(fastest).padding(.top, 8)
                    otherWays(Array(ways.dropFirst()))
                        .padding(.top, 6)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    message("No trains to \(destinationName) predicted")
                }
            } else {
                message(entry.problem ?? "No \(entry.lineLabel) trains to \(changeNames) predicted")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isMedium: Bool { family == .systemMedium }

    /// A one-line header, then one box: the countdown, and the soonest way. The controls layer
    /// draws only walk, at the header's right.
    @ViewBuilder private var mediumBoard: some View {
        if controls {
            VStack(spacing: 0) {
                header.hidden()
                    .overlay(alignment: .trailing) { buttons }
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 6) {
                header
                if let first = connections.first {
                    if routeLook {
                        routeMedium(first)
                    } else {
                        mediumBox(first)
                    }
                } else {
                    mediumMessage(entry.problem ?? "No \(entry.lineLabel) trains to \(changeNames) predicted")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// The large widget's countdown box, with the soonest way where it has your train's time:
    /// the line and where to change, then the leeway and how.
    private func mediumBox(_ connection: Connection) -> some View {
        HStack(spacing: 8) {
            BoardCountdown(connection.first, on: entry, marks: marks, size: 48)
            Spacer(minLength: 0)
            if let way = ways(connection).first {
                // The countdown apart from the way, which shrinks to fit: a live timer shrunk
                // with it crashed
                let counts = transferTrain(way) != nil
                VStack(alignment: .trailing, spacing: 4) {
                    soonestWay(way, alignment: .trailing, compact: counts && entry.notice != nil)
                    if counts {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("leaves in")
                                .font(.footnote)
                                .foregroundStyle(BoardInk.gray)
                            transferCountdown(way, font: .subheadline.weight(.semibold))
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(way, fastest: true))
            } else {
                Text("No trains to \(destinationName) predicted")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BoardTile())
    }

    /// The Saved Route's: a shorter countdown box with your train's time, then the soonest way
    /// as the large table's top row.
    private func routeMedium(_ connection: Connection) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                BoardCountdown(connection.first, on: entry, marks: marks, size: 34)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    WayMark(route: connection.first.route, size: 16)
                    Text("leaves \(connection.first.time.clock)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BoardInk.text)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(BusLeg.line(of: connection.first.route).map(BusBadge.spokenName) ?? Lines.name(of: connection.first.route)) leaves at \(Spoken.clock(connection.first.time))")
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BoardTile())
            if let way = ways(connection).first, let then = way.then {
                // Two changes: a row each, the second's train by its time
                VStack(spacing: 0) {
                    changeRow(mark: way.route, title: "Change at", place: place(way), size: 20) {
                        transfer(way).scaleEffect(0.9)
                    } leaves: {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Leaves in").font(.caption2.weight(.semibold)).foregroundStyle(BoardInk.gray)
                            transferCountdown(way, font: .subheadline.weight(.semibold))
                        }
                    }
                    thenRow(then, size: 20)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(way, fastest: true))
            } else if let way = ways(connection).first {
                HStack(spacing: 10) {
                    WayMark(route: way.route, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        if !way.staysOn {
                            Text("Change at")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(BoardInk.gray)
                        }
                        Text(place(way))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(BoardInk.text)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                    transfer(way)
                    Spacer(minLength: 4)
                    if !way.staysOn {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Leaves in")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(BoardInk.gray)
                            transferCountdown(way, font: .title3.weight(.semibold))
                        }
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 4)
                .frame(height: 40)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(way, fastest: true))
            } else {
                Text("No trains to \(destinationName) predicted")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 40)
            }
        }
    }

    /// A medium row for a change: the line's mark, "Change at" over the place, how, then when it
    /// leaves.
    private func changeRow(mark route: String, title: String, place: String, size: CGFloat,
                           @ViewBuilder how: () -> some View, @ViewBuilder leaves: () -> some View) -> some View {
        HStack(spacing: 8) {
            WayMark(route: route, size: size)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BoardInk.gray)
                Text(place)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            how()
            Spacer(minLength: 4)
            leaves()
                .frame(minWidth: 58, alignment: .trailing)
        }
        .lineLimit(1)
        .padding(.horizontal, 4)
        .frame(height: 30)
    }

    /// A way's second change on medium: "Then at" the place, how, and the clock time its train
    /// leaves (further off than the first change's, so a time rather than a countdown).
    private func thenRow(_ then: Connection, size: CGFloat) -> some View {
        changeRow(mark: then.next?.route ?? "", title: "Then at", place: place(then), size: size) {
            thenTransfer(then).scaleEffect(0.9)
        } leaves: {
            VStack(alignment: .trailing, spacing: 0) {
                Text("Leaves at").font(.caption2.weight(.semibold)).foregroundStyle(BoardInk.gray)
                thenLeaves(then, font: .subheadline.weight(.semibold))
            }
        }
    }

    /// Where a second change is: "Times Sq".
    private func place(_ then: Connection) -> String {
        let name = then.place ?? then.stationID.flatMap(StationDirectory.station(id:))?.name ?? "the change"
        let main = name.mainStationName
        let short = main.replacingOccurrences(of: " Av", with: "")
        return short.allSatisfy(\.isNumber) ? main : short
    }

    /// A second change's walker and minutes, or across the platform.
    private func thenTransfer(_ then: Connection) -> some View {
        let across = then.next.map { Change.isAcross(off: then.arrival.route, at: then.arrival.stop,
                                                     on: $0.route, at: $0.stop) } ?? false
        return Group {
            if across {
                HStack(spacing: 1) {
                    Image(systemName: "tram.fill")
                    Image(systemName: "figure.walk")
                    Image(systemName: "tram.fill")
                }
                .font(.footnote.weight(.semibold))
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "figure.walk")
                    Text("\(max(1, Int((then.walk / 60).rounded()))) min")
                }
                .font(.subheadline.weight(.medium))
            }
        }
        .foregroundStyle(BoardInk.text)
        .lineLimit(1)
        .fixedSize()
    }

    /// When a second change's train leaves, as a time; "–" with none predicted.
    private func thenLeaves(_ then: Connection, font: Font) -> some View {
        Text(then.next.map { $0.time.clock } ?? "–")
            .font(font)
            .foregroundStyle(BoardInk.gray)
            .monospacedDigit()
    }

    /// The change itself: the walker and its minutes, or across the platform train · walk ·
    /// train. Nothing when staying on.
    @ViewBuilder private func transfer(_ way: Way) -> some View {
        if !way.staysOn, let connection = way.connection {
            let bus = busWalk(way)
            let across = bus == nil && (connection.next.map { change.at(connection).isAcross(from: connection.arrival, to: $0) } ?? false)
            Group {
                if across {
                    HStack(spacing: 1) {
                        Image(systemName: "tram.fill")
                        Image(systemName: "figure.walk")
                        Image(systemName: "tram.fill")
                    }
                    .font(.footnote.weight(.semibold))
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "figure.walk")
                        // A planned trip's walk is its own (`Connection.place`)
                        Text("\(bus ?? (connection.place != nil ? max(1, Int((connection.walk / 60).rounded())) : change.walkMinutes)) min")
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
            .foregroundStyle(BoardInk.text)
            .lineLimit(1)
            .fixedSize()
        }
    }

    // MARK: Saved Route large table

    private static let markColumn: CGFloat = 36
    private static let transferColumn: CGFloat = 70
    private static let leavesColumn: CGFloat = 64

    /// The marks and places together, which "Change at" is centred over: as wide as the widest,
    /// so it sits over the marks and names themselves.
    private func changeColumn(_ ways: [Way]) -> CGFloat {
        let font = UIFont.systemFont(ofSize: style.points(.subheadline), weight: .semibold)
        let widest = ways.map { place($0).width(in: font) }.max() ?? 0
        // At least as wide as its header and "Fastest" under the name
        let caption = UIFont.systemFont(ofSize: style.points(.caption1), weight: .semibold)
        return max(Self.markColumn + 8 + ceil(max(widest, "Fastest".width(in: caption))),
                   ceil("Change at".width(in: caption)) + 4)
    }

    /// The fastest way and two more on the widget's background, under column headers: where to
    /// change, how, and when the train changed to leaves. Transfer sits midway between the other
    /// two.
    private func table(_ ways: [Way]) -> some View {
        let column = changeColumn(ways)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Change at").frame(width: column)
                Spacer(minLength: 0)
                Text("Transfer").frame(width: Self.transferColumn)
                Spacer(minLength: 0)
                Text("Leaves in").frame(width: Self.leavesColumn)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(BoardInk.gray)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            // Rows to spare: a two-change way takes one and a half
            let shown = ways.reduce(into: (ways: [Way](), rows: 0.0)) { result, way in
                let rows = way.then == nil ? 1.0 : 1.6
                if result.rows + rows <= 3.3 { result.ways.append(way); result.rows += rows }
            }.ways
            ForEach(Array(shown.enumerated()), id: \.offset) { index, way in
                tableRow(way, column: column, fastest: index == 0)
                if let then = way.then {
                    thenTableRow(then, column: column)
                }
            }
        }
    }

    /// A way's second change, under its first: a hook, the line's mark and "Times Sq", how, and
    /// the time its train leaves.
    private func thenTableRow(_ then: Connection, column: CGFloat) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(BoardInk.gray)
                        .offset(x: -6)
                    WayMark(route: then.next?.route ?? "", size: 20)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(width: Self.markColumn)
                Text(place(then))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
            }
            .frame(width: column, alignment: .leading)
            Spacer(minLength: 0)
            thenTransfer(then)
                .frame(width: Self.transferColumn)
            Spacer(minLength: 0)
            thenLeaves(then, font: .subheadline.weight(.semibold))
                .frame(width: Self.leavesColumn)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 4)
        .frame(height: 28)
        .padding(.top, -6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenThen(then))
    }

    /// A second change for VoiceOver: "Then the S at Times Sq, 4 minute walk, leaves at 9:14 AM."
    private func spokenThen(_ then: Connection) -> String {
        let line = then.next.map { BusLeg.line(of: $0.route).map(BusBadge.spokenName) ?? Lines.name(of: $0.route) } ?? "next train"
        let at = then.place ?? then.stationID.flatMap(StationDirectory.station(id:))?.name ?? "the change"
        let leaves = then.next.map { "leaves at \(Spoken.clock($0.time))" } ?? "none predicted"
        return "Then the \(line) at \(at), \(leaves)."
    }

    private func tableRow(_ way: Way, column: CGFloat, fastest: Bool) -> some View {
        HStack(spacing: 6) {
            // The mark beside the name; "Fastest" under the name
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    WayMark(route: way.route, size: 24)
                        .frame(width: Self.markColumn)
                    Text(place(way))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BoardInk.text)
                }
                if fastest {
                    Text("Fastest")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.liveText)
                        .padding(.leading, Self.markColumn + 8)
                }
            }
            .frame(width: column, alignment: .leading)
            Spacer(minLength: 0)
            transfer(way)
                .frame(width: Self.transferColumn)
            Spacer(minLength: 0)
            transferCountdown(way, font: .title3.weight(.semibold))
                .frame(width: Self.leavesColumn)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 4)
        .frame(height: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(way, fastest: fastest))
    }

    private func mediumMessage(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BoardInk.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .background(BoardTile(radius: 14))
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BoardInk.text)
            .padding(.top, 14)
    }

    // MARK: Header and countdown

    /// "Atlantic Av / DeKalb Av", where the change is.
    private var changeNames: String {
        // From a bus, each change's station: not along a train of yours
        var stations: [String] = []
        for name in change.stops.compactMap(\.station?.name) where !stations.contains(name) { stations.append(name) }
        let names = origin == nil ? change.stationNames(for: entry.selection)
            : stations.count > 1 ? stations.map(\.mainStationName).joined(separator: " / ") : stations.first ?? ""
        return names.isEmpty ? "the change" : names
    }

    /// The destination's name, or without one, where the change is.
    private var destinationName: String {
        change.destination?.name ?? change.planned?.destinationStop.map { BusNames.readable($0.name) } ?? changeNames
    }

    /// Lines changed to, in the order of the ways, each once.
    private var changeRoutes: [String] {
        var routes: [String] = []
        let ways = connections.first.map(ways) ?? []
        let second = ways.compactMap(\.then?.next?.route)
        for route in ways.filter({ !$0.staysOn }).map(\.route) + second + change.everyRoute where !routes.contains(route) {
            routes.append(route)
        }
        return routes
    }

    /// Your lines; "Prospect Av → 34 St-Herald Sq"; "Manhattan, via" the lines changed to. Room
    /// on the right for walk, which the controls layer draws there.
    private var header: some View {
        HStack(spacing: style.headerSpacing) {
            if let origin {
                BusBadge(line: origin.line, size: isMedium ? 24 : style.bulletSize * 0.85)
            } else {
                // Just the counted-down train's line lit
                LineBullets(routes: entry.selection.routes, size: isMedium ? 24 : style.bulletSize,
                            lit: connections.first?.first.route)
            }
            let from = origin?.name ?? entry.stationName
            VStack(alignment: .leading, spacing: 0) {
                Text("\(from) \(Text("→").foregroundStyle(BoardInk.gray)) \(destinationName)")
                    .font(style.nameFont)
                    .foregroundStyle(BoardInk.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("\(from) to \(destinationName)")
                if !isMedium {
                HStack(spacing: 3) {
                    // "via" only with lines to name after it
                    Text("\(origin.map { "to \($0.way)" } ?? entry.heading)\(changeRoutes.isEmpty ? "" : ", via")")
                        .lineLimit(1)
                        .minimumScaleFactor(style.headingScale)
                    ForEach(changeRoutes, id: \.self) { route in
                        WayMark(route: route, size: 14, relativeTo: .footnote)
                    }
                }
                .font(style.headingFont)
                .foregroundStyle(BoardInk.gray)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            RefreshMark(entry: entry, refreshing: refreshing)
            if entry.closes {
                Pill(symbol: "xmark", large: true, round: true).hidden()
            }
            if origin == nil {
                Pill(symbol: "figure.walk", large: true).hidden()
            }
        }
    }

    /// Walk, with a ✕ before it (`TrainEntry.closes`).
    @ViewBuilder private var buttons: some View {
        if origin == nil {
            BoardButtons(entry: entry, large: true, spacing: style.headerSpacing) { walkButton }
        } else {
            BoardButtons(entry: entry, large: true, spacing: style.headerSpacing) { EmptyView() }
        }
    }

    private var walkButton: some View {
        let trip = entry.selection.firstReachable(connections, now: entry.date)?.first.trip
        return WalkButton(intent: ToggleCountdownIntent(selection: entry.selection, widgetID: entry.widgetID, trip: trip,
                                                        change: change),
                          route: entry.selection.firstRoute, running: entry.countingDown, large: true,
                          plansRoute: entry.plansRoute)
    }

    /// The minutes until it's time to leave for `train`.
    private func minutesToLeave(_ train: Arrival) -> MinutesToGo {
        MinutesToGo(until: entry.selection.leaveTime(for: train), from: entry.date)
    }

    // MARK: Ways on

    /// Where a way changes ("Atlantic", "Lexington/59 St"), or "Stay on".
    private func place(_ way: Way) -> String {
        guard !way.staysOn, let connection = way.connection,
              let name = connection.place ?? change.at(connection).station?.name else { return "Stay on" }
        let main = name.mainStationName
        let short = main.replacingOccurrences(of: " Av", with: "")
        // "Atlantic", but "4 Av", not "4"
        return short.allSatisfy(\.isNumber) ? main : short
    }

    /// "across platform" or "3 min walk"; nil when staying on.
    private func how(_ way: Way) -> String? {
        guard !way.staysOn, let connection = way.connection, let next = connection.next else { return nil }
        if let minutes = busWalk(way) { return "\(minutes) min walk" }
        return change.at(connection).isAcross(from: connection.arrival, to: next)
            ? "across platform"
            : "\(connection.place != nil ? max(1, Int((connection.walk / 60).rounded())) : change.walkMinutes) min walk"
    }

    /// A change to or from a bus: its walk, in minutes; nil between trains.
    private func busWalk(_ way: Way) -> Int? {
        guard let connection = way.connection,
              BusLeg.line(of: way.route) != nil || BusLeg.line(of: connection.arrival.route) != nil else { return nil }
        return Int((connection.walk / 60).rounded())
    }

    /// Minutes of leeway at the change, after the walk; nil when staying on or with no train to
    /// change to.
    private func leeway(_ way: Way) -> Int? {
        guard !way.staysOn, let connection = way.connection, connection.next != nil else { return nil }
        return connection.leewayMinutes
    }

    /// Over the fastest way's countdown: when the train changed to leaves the change.
    private func leavesLabel(_ way: Way) -> String {
        way.staysOn ? "" : "Leaves in"
    }

    /// The train a way changes to, at the change; nil when staying on or with none predicted.
    private func transferTrain(_ way: Way) -> Arrival? {
        way.staysOn ? nil : way.connection?.next
    }

    /// A way for VoiceOver: "D at Atlantic Av, 1 minute of leeway, across the platform. At 34 St-Herald
    /// Sq at 10:06 AM, live."
    private func spoken(_ way: Way, fastest: Bool) -> String {
        let line = BusLeg.line(of: way.route).map(BusBadge.spokenName) ?? Lines.name(of: way.route)
        var first = way.staysOn ? "Stay on the \(line)" : "\(line) at \(way.connection.flatMap { change.at($0).station?.name } ?? "the change")"
        if let connection = way.connection, !way.staysOn {
            first += ", " + connection.spokenLeeway
            if let how = how(way) { first += ", " + (how == "across platform" ? "across the platform" : how) }
        }
        let second: String
        if way.staysOn {
            second = "No change."
        } else if let train = transferTrain(way) {
            second = "Leaves at \(Spoken.clock(train.time)), \(train.isLive ? "live" : "scheduled")."
        } else {
            second = "None predicted."
        }
        return (fastest ? "Fastest: " : "") + first + ". " + second + (way.then.map { " " + spokenThen($0) } ?? "")
    }

    /// The countdown to the train a way changes to leaving the change, with its live or
    /// timetable mark per Settings, as your train's; nothing when staying on, "–" with none
    /// predicted.
    @ViewBuilder private func transferCountdown(_ way: Way, font: Font) -> some View {
        if let train = transferTrain(way) {
            HStack(spacing: 3) {
                // A live timer takes all the width it's offered, so the placeholder sizes it
                Text(TimerText.placeholder(seconds: train.time.timeIntervalSince(entry.date)))
                    .hidden()
                    .overlay(alignment: .trailing) {
                        CountdownTimer(start: entry.date, end: train.time)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1)
                    }
                    .font(font)
                    .monospacedDigit()
                    .timerForeground(train.statusColor)
                    .liveAccent(train)
                StatusMark(isLive: train.isLive, marks: marks, size: 9)
                    .foregroundStyle(train.statusColor)
                    .accessibilityHidden(true)
            }
            .fixedSize()
        } else if !way.staysOn {
            Text("–")
                .font(font)
                .foregroundStyle(Color.boardDim)
        }
    }

    /// The fastest way's countdown column: as wide as its label needs, at least the rows'.
    private func fastestLeavesWidth(_ way: Way) -> CGFloat {
        let width = leavesLabel(way).width(in: .systemFont(ofSize: style.points(.caption1), weight: .semibold))
        return max(width + 2, Self.countdownColumn)
    }

    /// The fastest way, boxed. It grows rather than cut anything short.
    private func fastestBox(_ way: Way) -> some View {
        HStack(spacing: 10) {
            // Full size where it fits: left to shrink, it shrinks the station even with room
            ViewThatFits(in: .horizontal) {
                soonestWay(way, alignment: .leading).fixedSize()
                soonestWay(way, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(leavesLabel(way))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardInk.gray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                transferCountdown(way, font: .title2.weight(.semibold))
            }
            .frame(minWidth: fastestLeavesWidth(way), alignment: .trailing)
        }
        .padding(.horizontal, Self.rowInset)
        .padding(.vertical, 10)
        .frame(minHeight: Self.boxHeight)
        .background(BoardTile())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(way, fastest: true))
    }

    /// The soonest way, the same on medium and large: "Change at", the line and where, then the
    /// leeway and how ("6 mins of leeway · across platform"). Staying on says so itself.
    /// `compact`: without "Change at" (the bullet and station say where), for medium under an
    /// alert's banner, which leaves no room for it as well as the countdown below.
    private func soonestWay(_ way: Way, alignment: HorizontalAlignment, compact: Bool = false) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            if !way.staysOn && !compact {
                Text("Change at")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardInk.gray)
            }
            HStack(spacing: 6) {
                WayMark(route: way.route, size: 26)
                Text(place(way))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
            }
            let detail = [leeway(way).map { Leeway.label($0, short: true) }, how(way)].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(BoardInk.gray)
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// Wide enough for the longest place name below, so the waits after them line up.
    private func stationColumn(_ ways: [Way]) -> CGFloat {
        let font = UIFont.systemFont(ofSize: style.points(.subheadline), weight: .semibold)
        let widest = ways.map { place($0).width(in: font) }.max() ?? 0
        return min(max(widest + 12, 74), 150)
    }

    /// "2 mins of leeway" ("2 min" if that won't fit), "none predicted", or "no change" when
    /// staying on.
    @ViewBuilder
    private func detail(_ way: Way) -> some View {
        if way.staysOn {
            Text("no change")
                .font(.subheadline)
                .foregroundStyle(BoardInk.gray)
                .lineLimit(1)
        } else if transferTrain(way) == nil {
            Text("none predicted")
                .font(.subheadline)
                .foregroundStyle(Color.boardDim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if let leeway = leeway(way) {
            ViewThatFits(in: .horizontal) {
                Text(leeway < 1 ? "no leeway" : Leeway.label(leeway, short: true))
                Text("\(leeway) min")
            }
            .font(.subheadline)
            .foregroundStyle(BoardInk.gray)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    private func row(_ way: Way, column: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 10) {
            // Always clear of the next row's bullet, however tight the rows
            WayMark(route: way.route, size: min(26, height - Self.bulletGap))
                .frame(width: Self.bulletColumn)
            HStack(spacing: 0) {
                Text(place(way))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: column, alignment: .leading)
                detail(way)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            transferCountdown(way, font: .title3.weight(.semibold))
                .frame(minWidth: Self.countdownColumn, alignment: .trailing)
        }
        .padding(.horizontal, Self.rowInset)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(way, fastest: false))
    }

    /// As many of the other ways as fit, soonest first; the slowest are left off. Rows shrink
    /// (to `tightRowHeight` at most) before one is dropped.
    private func otherWays(_ others: [Way]) -> some View {
        let column = stationColumn(others)
        let tries = (0...others.count).reversed().flatMap { [($0, Self.rowHeight), ($0, Self.tightRowHeight)] }
        return ViewThatFits(in: .vertical) {
            ForEach(Array(tries.enumerated()), id: \.offset) { _, attempt in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(others.prefix(attempt.0).enumerated()), id: \.offset) { _, way in
                        row(way, column: column, height: attempt.1)
                    }
                }
            }
        }
    }
}

/// Right of the countdown on the large Transfers widget and the medium Next train widget:
/// the counted-down train's line and when it leaves, then the next ones' minutes to go.
struct LeavesColumn: View {
    let train: Arrival
    /// To the trains after it, soonest first: two, or just the first when both won't fit.
    let later: [MinutesToGo]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 5) {
                WayMark(route: train.route, size: 18)
                Text("leaves \(train.time.clock)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(BusLeg.line(of: train.route).map(BusBadge.spokenName) ?? Lines.name(of: train.route)) leaves at \(Spoken.clock(train.time))")
            if let next = later.first {
                ViewThatFits(in: .horizontal) {
                    Text("then " + later.map(\.label).joined(separator: " · "))
                    Text("then \(next.label)")
                }
                .font(.footnote)
                .foregroundStyle(BoardInk.gray)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}
