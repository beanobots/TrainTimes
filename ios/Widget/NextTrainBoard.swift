import SwiftUI
import WidgetKit

/// The Next train widget on the Home Screen, in the Transfers widget's style (`WaysBoard`). On
/// small, "R Manhattan" with walk top right, then the countdown boxed, with its line's bullet
/// top right when it isn't one of yours. On medium, a one-line
/// header with walk at its right, then one box as the large Transfers widget's top card: the
/// countdown, its train's line and when it leaves, and the minutes to the next two; or showing both
/// directions (`SavedWidget.bothWays`), a box for each side by side. A tap anywhere else
/// refreshes (`TrainWidgetView`).
struct NextTrainBoard: View {
    let entry: TrainEntry
    /// Just tapped to refresh, so ↻ shows until the new times.
    var refreshing = false
    /// The controls layer: only the walk button, where the board has room for it.
    var controls = false
    /// The large Transfers widget without a change: as with one, but saying none is selected
    /// where the ways on would be (`WaysBoard`).
    var noTransfer = false
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.boardFamily) private var boardFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.routeLook) private var routeLook
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    private var family: WidgetFamily { boardFamily ?? widgetFamily }
    private var isSmall: Bool { family == .systemSmall }
    private var isLarge: Bool { family == .systemLarge }
    private var marks: TimeMarks { entry.settings.timeMarks(withoutColor: withoutColor, renderingMode: renderingMode) }
    private var next: Arrival? { entry.trains.first }
    private var later: [Arrival] { Array(entry.trains.dropFirst()) }
    /// With a walking time, the countdown is to when to leave.
    private var walking: Bool { entry.selection.walkMinutes > 0 }
    private var noTrains: String { entry.problem ?? "No \(entry.lineLabel) trains predicted" }
    /// Medium (and the Saved Route's large), showing both directions: the other way's trains.
    private var otherWay: OtherWay? {
        (family == .systemMedium || (isLarge && routeLook)) && !noTransfer ? entry.otherWay : nil
    }

    var body: some View {
        if controls {
            VStack(spacing: 0) {
                // Centred on large's two-line header, as WaysBoard's
                header.hidden()
                    .overlay(alignment: isLarge ? .trailing : .topTrailing) { buttons }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: isSmall ? 8 : 6) {
                header
                if let otherWay, isLarge {
                    // Side by side, each with its next three under it
                    HStack(alignment: .top, spacing: 8) {
                        wayColumn(heading: entry.heading, trains: entry.trains, problem: entry.problem)
                        wayColumn(heading: otherWay.selection.heading, trains: otherWay.trains, problem: otherWay.problem)
                    }
                    .padding(.top, 4)
                } else if let otherWay {
                    HStack(spacing: 6) {
                        wayBox(heading: entry.heading, trains: entry.trains, problem: entry.problem)
                        wayBox(heading: otherWay.selection.heading, trains: otherWay.trains, problem: otherWay.problem)
                    }
                } else if routeLook, isLarge, let next {
                    routeLarge(next)
                } else if noTransfer, isLarge, let next {
                    TopCard(entry: entry, train: next, later: laterMinutes, marks: marks).padding(.top, 4)
                    // As WaysBoard's large message, in line with the card's contents
                    Text("No transfer selected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BoardInk.text)
                        .padding(.top, 8)
                        .padding(.leading, 14)
                } else if let next {
                    BoardBox {
                        if isSmall {
                            smallBox(next)
                        } else {
                            mediumBox(next)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // Small: a line not among yours running on the track, such as an N on the R
                        if isSmall, !entry.selection.routes.contains(next.route) {
                            LineBullet(route: next.route, size: 16)
                                .padding(8)
                                .accessibilityLabel("\(Lines.name(of: next.route)) train")
                        }
                    }
                } else {
                    BoardBox {
                        Text(noTrains)
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

    /// Small: your lines and "Manhattan". Medium: your lines, the station and direction. Large:
    /// the direction under the station, as WaysBoard's. Room on the right for walk, which the
    /// controls layer draws there.
    private var header: some View {
        HStack(alignment: .center, spacing: isSmall ? 5 : 8) {
            // Just the counted-down train's line lit
            let bullets = LineBullets(routes: entry.selection.routes, size: isSmall ? 22 : isLarge ? BoardStyle.large.bulletSize : 24,
                                      lit: next?.route)
            if isSmall && refreshing {
                // ↻ in the bullets' place, so it doesn't take room from the heading
                bullets.hidden()
                    .overlay {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(BoardInk.gray)
                            .accessibilityLabel("Refreshing")
                    }
            } else {
                bullets
            }
            if isSmall {
                // Beside ✕ there's room for only the lines; the card showed the way
                if !entry.closes {
                    smallHeading
                } else if routeLook {
                    // The Saved Route names the place, not the way, beside ✕: where it fits whole
                    // on a line or two, as beside several lines' bullets it may not
                    let name = entry.selection.station?.cardName ?? entry.stationName
                    ViewThatFits(in: .horizontal) {
                        Text(name).lineLimit(1)
                        Text(name.replacing(" ", with: "\n", maxReplacements: 1)).lineLimit(2)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                }
            } else if isLarge {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.stationName)
                        .font(BoardStyle.large.nameFont)
                        .foregroundStyle(BoardInk.text)
                    Text(otherWay == nil ? entry.heading : "Both directions")
                        .font(BoardStyle.large.headingFont)
                        .foregroundStyle(BoardInk.gray)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityElement(children: .combine)
            } else if otherWay != nil {
                // Each box names its direction
                Text(entry.stationName)
                    .font(.body.bold())
                    .foregroundStyle(BoardInk.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("\(entry.stationName) \(Text(entry.heading).font(.footnote).foregroundStyle(BoardInk.gray))")
                    .font(.body.bold())
                    .foregroundStyle(BoardInk.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("\(entry.stationName), \(entry.heading)")
            }
            Spacer(minLength: 4)
            // On small, ↻ is in the bullets' place
            RefreshMark(entry: entry, refreshing: refreshing, showsRefreshing: !isSmall)
            if entry.closes {
                Pill(symbol: "xmark", large: !isSmall, round: true).hidden()
            }
            Pill(symbol: "figure.walk", large: !isSmall).hidden()
        }
    }

    /// "Manhattan" on one line if it fits, else over two, broken at its first space so a word
    /// isn't split; for "Downtown & Brooklyn", just "Downtown" if the whole won't fit. One word
    /// that doesn't fit shrinks instead.
    private var smallHeading: some View {
        let full = entry.heading
        let short = full.components(separatedBy: " & ").first ?? full
        let wrapped = { (heading: String) in heading.replacing(" ", with: "\n", maxReplacements: 1) }
        return ViewThatFits(in: .horizontal) {
            Text(full).lineLimit(1)
            Text(wrapped(full)).lineLimit(2).minimumScaleFactor(0.8)
            Text(wrapped(short)).lineLimit(short.contains(" ") ? 2 : 1).minimumScaleFactor(0.6)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(BoardInk.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(full)
    }

    /// Walk, with a ✕ before it (`TrainEntry.closes`).
    private var buttons: some View {
        BoardButtons(entry: entry, large: !isSmall, spacing: isSmall ? 5 : 8) { walkButton }
    }

    /// Next train uses the first train you can reach, so no trip.
    private var walkButton: some View {
        WalkButton(intent: ToggleCountdownIntent(selection: entry.selection, widgetID: entry.widgetID),
                   route: entry.selection.firstRoute, running: entry.countingDown, large: !isSmall)
    }

    // MARK: Countdown

    /// Just the countdown, as big as the box's width allows.
    private func smallBox(_ train: Arrival) -> some View {
        let seconds = entry.selection.leaveTime(for: train).timeIntervalSince(entry.date)
        // "0:00" fits at 48; longer times and the walker take room from it
        let digits: CGFloat = seconds >= 3599 ? 0.62 : seconds >= 599 ? 0.78 : 1
        // Centred in the box: the countdown, its next train's minutes and arrival under it
        return VStack(alignment: .center, spacing: 2) {
            countdown(train, size: (walking ? 40 : 48) * digits)
            // The Saved Route: the next one's minutes under it
            if routeLook, let then = laterMinutes.first {
                Text("then \(then.label)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardInk.gray)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            arrival(train)
        }
    }

    /// As the large Transfers widget's top card: the countdown; on the right, its line and when
    /// it leaves, then the next two's minutes to go (to leave, with a walking time).
    private func mediumBox(_ train: Arrival) -> some View {
        HStack(spacing: 8) {
            countdown(train, size: 48)
            Spacer(minLength: 0)
            leavesColumn(train)
        }
    }

    // MARK: Both directions

    /// One direction on medium showing both: where it goes, the countdown, then its train's line
    /// and time and the next one's minutes. Smaller where it has less room, under a banner or
    /// with a walker and longer times.
    private func wayBox(heading: String, trains: [Arrival], problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(BoardInk.gray)
            if let train = trains.first {
                let later = trains.dropFirst().first
                // At each size, the next one's minutes go before the countdown shrinks, so a
                // longer "then 12 min" doesn't cost this side the line and size the other has
                ViewThatFits {
                    wayTimes(train, later: later, size: 38, details: true)
                    wayTimes(train, later: nil, size: 38, details: true)
                    wayTimes(train, later: later, size: 30, details: true)
                    wayTimes(train, later: nil, size: 30, details: true)
                    wayTimes(train, later: later, size: 26, details: true)
                    wayTimes(train, later: nil, size: 26, details: true)
                    wayTimes(train, later: nil, size: 26, details: false)
                }
            } else {
                Text(problem ?? "None predicted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                    .padding(.top, 4)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(BoardTile())
        .accessibilityElement(children: .combine)
    }

    /// The countdown to `train`, then with `details` its line, its time and the minutes to `later`
    /// (left off without one).
    private func wayTimes(_ train: Arrival, later: Arrival?, size: CGFloat, details: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            countdown(train, size: size)
            if details {
                HStack(spacing: 4) {
                    LineBullet(route: train.route, size: 14)
                    let then = later.map { " · then \(MinutesToGo(until: entry.selection.leaveTime(for: $0), from: entry.date).label)" }
                    Text(train.time.clock + (then ?? ""))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BoardInk.text)
                        .monospacedDigit()
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Lines.name(of: train.route)) leaves at \(Spoken.clock(train.time))")
            }
        }
    }

    /// The next two's minutes to go (to leave, with a walking time); the Saved Route's, just the
    /// next one's.
    private var laterMinutes: [MinutesToGo] {
        later.prefix(routeLook ? 1 : 2).map { minutesToGo($0) }
    }

    private func minutesToGo(_ train: Arrival) -> MinutesToGo {
        MinutesToGo(until: entry.selection.leaveTime(for: train), from: entry.date)
    }

    // MARK: Saved Route large

    /// The countdown card, then the next three as a departures board: where each goes, when it
    /// leaves and the minutes to go.
    private func routeLarge(_ train: Arrival) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                countdown(train, size: 48)
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    LineBullet(route: train.route, size: 18)
                    Text("leaves \(train.time.clock)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BoardInk.text)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Lines.name(of: train.route)) leaves at \(Spoken.clock(train.time))")
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: WaysBoard.boxHeight)
            .background(BoardTile())
            .padding(.top, 4)
            if !later.isEmpty {
                Text("Then")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BoardInk.gray)
                    .padding(.leading, 10)
                VStack(spacing: 0) {
                    ForEach(later.prefix(3), id: \.self) { thenRow($0) }
                }
            }
        }
    }

    /// One of the next rides: its line, where it goes, when it leaves, the minutes to go.
    private func thenRow(_ train: Arrival) -> some View {
        HStack(spacing: 10) {
            LineBullet(route: train.route, size: 22).frame(width: 38)
            Text(train.terminal ?? Lines.name(of: train.route))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BoardInk.text)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(train.time.clock)
                .font(.subheadline)
                .foregroundStyle(BoardInk.gray)
            Text(minutesToGo(train).label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(train.statusColor(scheduled: BoardInk.color(.text, route: routeLook)))
                .frame(minWidth: 58, alignment: .trailing)
        }
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Lines.name(of: train.route)) to \(train.terminal ?? "its last stop"), \(Spoken.clock(train.time)), \(status(train))")
    }

    /// One direction on large showing both, as medium's box with the next three listed under it.
    private func wayColumn(heading: String, trains: [Arrival], problem: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(BoardInk.gray)
            if let train = trains.first {
                countdown(train, size: 40)
                HStack(spacing: 4) {
                    LineBullet(route: train.route, size: 14)
                    Text("leaves \(train.time.clock)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BoardInk.text)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Lines.name(of: train.route)) leaves at \(Spoken.clock(train.time))")
                let then = trains.dropFirst().prefix(3)
                if !then.isEmpty {
                    Divider().padding(.vertical, 8)
                    Text("Then")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(BoardInk.gray)
                    ForEach(Array(then), id: \.self) { next in
                        HStack {
                            Text(next.time.clock)
                                .font(.footnote)
                                .foregroundStyle(BoardInk.gray)
                            Spacer(minLength: 4)
                            Text(minutesToGo(next).label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(next.statusColor(scheduled: BoardInk.color(.text, route: routeLook)))
                        }
                        .padding(.top, 4)
                    }
                }
            } else {
                Text(problem ?? "None predicted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BoardInk.text)
                    .padding(.top, 4)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BoardTile())
        .accessibilityElement(children: .combine)
    }

    private func status(_ train: Arrival) -> String {
        train.isLive ? "live" : "scheduled"
    }

    private func leavesColumn(_ train: Arrival) -> some View {
        LeavesColumn(train: train, later: laterMinutes)
    }

    private func countdown(_ train: Arrival, size: CGFloat) -> some View {
        BoardCountdown(train, on: entry, marks: marks, size: size)
    }

    /// On small, "Arrive 8:42" at the destination, when it has one and `train` is predicted there.
    @ViewBuilder private func arrival(_ train: Arrival) -> some View {
        if let destination = entry.destination, let time = entry.destinationTimes[train.trip] {
            Text("Arrive \(time.clock)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BoardInk.gray)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel("Arrives at \(destination.name) at \(Spoken.clock(time))")
        }
    }
}
