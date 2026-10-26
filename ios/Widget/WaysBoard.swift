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
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.boardFamily) private var boardFamily
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.widgetRenderingMode) private var renderingMode
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
                TopCard(entry: entry, train: first.first, later: connections.dropFirst().prefix(2).map { minutesToLeave($0.first) },
                        marks: marks)
                    .padding(.top, 10)
                let ways = ways(first)
                if let fastest = ways.first {
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
                    mediumBox(first)
                } else {
                    mediumMessage(entry.problem ?? "No \(entry.lineLabel) trains to \(changeNames) predicted")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// The large widget's countdown box, with the soonest way where it has your train's time:
    /// the line and where to change, then the wait and how.
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
                                .foregroundStyle(Color.boardGray)
                            transferCountdown(way, font: .subheadline.weight(.semibold))
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken(way, fastest: true))
            } else {
                Text("No trains to \(destinationName) predicted")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.boardText)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
    }

    private func mediumMessage(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.boardText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.boardText.opacity(0.07)))
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.boardText)
            .padding(.top, 14)
    }

    // MARK: Header and countdown

    /// "Atlantic Av / DeKalb Av", where the change is.
    private var changeNames: String {
        let names = change.stationNames(for: entry.selection)
        return names.isEmpty ? "the change" : names
    }

    /// The destination's name, or without one, where the change is.
    private var destinationName: String { change.destination?.name ?? changeNames }

    /// Lines changed to, in the order of the ways, each once.
    private var changeRoutes: [String] {
        var routes: [String] = []
        let ways = connections.first.map(ways) ?? []
        for route in ways.filter({ !$0.staysOn }).map(\.route) + change.allRoutes where !routes.contains(route) {
            routes.append(route)
        }
        return routes
    }

    /// Your lines; "Prospect Av → 34 St-Herald Sq"; "Manhattan, via" the lines changed to. Room
    /// on the right for walk, which the controls layer draws there.
    private var header: some View {
        HStack(spacing: style.headerSpacing) {
            // Just the counted-down train's line lit
            LineBullets(routes: entry.selection.routes, size: isMedium ? 24 : style.bulletSize,
                        lit: connections.first?.first.route)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(entry.stationName) \(Text("→").foregroundStyle(Color.boardGray)) \(destinationName)")
                    .font(style.nameFont)
                    .foregroundStyle(Color.boardText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("\(entry.stationName) to \(destinationName)")
                if !isMedium {
                HStack(spacing: 3) {
                    Text("\(entry.heading), via")
                        .lineLimit(1)
                        .minimumScaleFactor(style.headingScale)
                    ForEach(changeRoutes, id: \.self) { route in
                        LineBullet(route: route, size: 14, relativeTo: .footnote)
                    }
                }
                .font(style.headingFont)
                .foregroundStyle(Color.boardGray)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            RefreshMark(entry: entry, refreshing: refreshing)
            if entry.closes {
                Pill(symbol: "xmark", large: true, round: true).hidden()
            }
            Pill(symbol: "figure.walk", large: true).hidden()
        }
    }

    /// Walk, with a ✕ before it (`TrainEntry.closes`).
    private var buttons: some View {
        BoardButtons(entry: entry, large: true, spacing: style.headerSpacing) { walkButton }
    }

    private var walkButton: some View {
        let trip = entry.selection.firstReachable(connections, now: entry.date)?.first.trip
        return WalkButton(intent: ToggleCountdownIntent(selection: entry.selection, widgetID: entry.widgetID, trip: trip,
                                                        change: change),
                          route: entry.selection.firstRoute, running: entry.countingDown, large: true)
    }

    /// The minutes until it's time to leave for `train`.
    private func minutesToLeave(_ train: Arrival) -> MinutesToGo {
        MinutesToGo(until: entry.selection.leaveTime(for: train), from: entry.date)
    }

    // MARK: Ways on

    /// Where a way changes ("Atlantic", "Lexington/59 St"), or "Stay on".
    private func place(_ way: Way) -> String {
        guard !way.staysOn, let connection = way.connection,
              let name = change.at(connection).station?.name else { return "Stay on" }
        return name.mainStationName.replacingOccurrences(of: " Av", with: "")
    }

    /// "across platform" or "3 min walk"; nil when staying on.
    private func how(_ way: Way) -> String? {
        guard !way.staysOn, let connection = way.connection, let next = connection.next else { return nil }
        return change.at(connection).isAcross(from: connection.arrival, to: next)
            ? "across platform" : "\(change.walkMinutes) min walk"
    }

    /// "1 min", "<1 min"; nil when staying on or with no train to change to.
    private func wait(_ way: Way) -> String? {
        guard !way.staysOn, let connection = way.connection, connection.next != nil else { return nil }
        return connection.waitLabel
    }

    /// Over the fastest way's countdown: when the train changed to leaves the change.
    private func leavesLabel(_ way: Way) -> String {
        way.staysOn ? "" : "Leaves in"
    }

    /// The train a way changes to, at the change; nil when staying on or with none predicted.
    private func transferTrain(_ way: Way) -> Arrival? {
        way.staysOn ? nil : way.connection?.next
    }

    /// A way for VoiceOver: "D at Atlantic Av, 1 minute wait, across the platform. At 34 St-Herald
    /// Sq at 10:06 AM, live."
    private func spoken(_ way: Way, fastest: Bool) -> String {
        let line = Lines.name(of: way.route)
        var first = way.staysOn ? "Stay on the \(line)" : "\(line) at \(way.connection.flatMap { change.at($0).station?.name } ?? "the change")"
        if let connection = way.connection, !way.staysOn {
            first += ", " + connection.spokenWait(quick: false)
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
        return (fastest ? "Fastest: " : "") + first + ". " + second
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
                    .foregroundStyle(Color.boardGray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                transferCountdown(way, font: .title2.weight(.semibold))
            }
            .frame(minWidth: fastestLeavesWidth(way), alignment: .trailing)
        }
        .padding(.horizontal, Self.rowInset)
        .padding(.vertical, 10)
        .frame(minHeight: Self.boxHeight)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(way, fastest: true))
    }

    /// The soonest way, the same on medium and large: "Change at", the line and where, then the
    /// wait and how ("6 min wait · across platform"). Staying on says so itself.
    /// `compact`: without "Change at" (the bullet and station say where), for medium under an
    /// alert's banner, which leaves no room for it as well as the countdown below.
    private func soonestWay(_ way: Way, alignment: HorizontalAlignment, compact: Bool = false) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            if !way.staysOn && !compact {
                Text("Change at")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.boardGray)
            }
            HStack(spacing: 6) {
                LineBullet(route: way.route, size: 26)
                Text(place(way))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.boardText)
            }
            let detail = [wait(way).map { "\($0) wait" }, how(way)].compactMap { $0 }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.boardGray)
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

    /// "2 min wait" ("2 min" if that won't fit), "none predicted", or "no change" when staying on.
    @ViewBuilder
    private func detail(_ way: Way) -> some View {
        if way.staysOn {
            Text("no change")
                .font(.subheadline)
                .foregroundStyle(Color.boardGray)
                .lineLimit(1)
        } else if transferTrain(way) == nil {
            Text("none predicted")
                .font(.subheadline)
                .foregroundStyle(Color.boardDim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if let wait = wait(way) {
            ViewThatFits(in: .horizontal) {
                Text("\(wait) wait")
                Text(wait)
            }
            .font(.subheadline)
            .foregroundStyle(Color.boardGray)
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    private func row(_ way: Way, column: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 10) {
            // Always clear of the next row's bullet, however tight the rows
            LineBullet(route: way.route, size: min(26, height - Self.bulletGap))
                .frame(width: Self.bulletColumn)
            HStack(spacing: 0) {
                Text(place(way))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boardText)
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
                LineBullet(route: train.route, size: 18)
                Text("leaves \(train.time.clock)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boardText)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Lines.name(of: train.route)) leaves at \(Spoken.clock(train.time))")
            if let next = later.first {
                ViewThatFits(in: .horizontal) {
                    Text("then " + later.map(\.label).joined(separator: " · "))
                    Text("then \(next.label)")
                }
                .font(.footnote)
                .foregroundStyle(Color.boardGray)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}
