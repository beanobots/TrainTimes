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
    /// Medium, showing both directions: the other way's trains.
    private var otherWay: OtherWay? { family == .systemMedium && !noTransfer ? entry.otherWay : nil }

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
                if let otherWay {
                    HStack(spacing: 6) {
                        wayBox(heading: entry.heading, trains: entry.trains, problem: entry.problem)
                        wayBox(heading: otherWay.selection.heading, trains: otherWay.trains, problem: otherWay.problem)
                    }
                } else if noTransfer, isLarge, let next {
                    TopCard(entry: entry, train: next, later: laterMinutes, marks: marks).padding(.top, 4)
                    // As WaysBoard's large message, in line with the card's contents
                    Text("No transfer selected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.boardText)
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
                            .foregroundStyle(Color.boardText)
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
                            .foregroundStyle(Color.boardGray)
                            .accessibilityLabel("Refreshing")
                    }
            } else {
                bullets
            }
            if isSmall {
                // Beside ✕ there's room for only the lines; the card showed the way
                if !entry.closes { smallHeading }
            } else if isLarge {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.stationName)
                        .font(BoardStyle.large.nameFont)
                        .foregroundStyle(Color.boardText)
                    Text(entry.heading)
                        .font(BoardStyle.large.headingFont)
                        .foregroundStyle(Color.boardGray)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityElement(children: .combine)
            } else if otherWay != nil {
                // Each box names its direction
                Text(entry.stationName)
                    .font(.body.bold())
                    .foregroundStyle(Color.boardText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("\(entry.stationName) \(Text(entry.heading).font(.footnote).foregroundStyle(Color.boardGray))")
                    .font(.body.bold())
                    .foregroundStyle(Color.boardText)
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
        .foregroundStyle(Color.boardText)
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
        return VStack(alignment: .leading, spacing: 0) {
            countdown(train, size: (walking ? 40 : 48) * digits)
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
                .foregroundStyle(Color.boardGray)
            if let train = trains.first {
                let later = trains.dropFirst().first
                ViewThatFits {
                    wayTimes(train, later: later, size: 38, details: true)
                    wayTimes(train, later: later, size: 30, details: true)
                    wayTimes(train, later: later, size: 26, details: true)
                    wayTimes(train, later: later, size: 26, details: false)
                }
            } else {
                Text(problem ?? "None predicted")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boardText)
                    .padding(.top, 4)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }

    /// The countdown to `train`, then with `details` its line, its time and the minutes to `later`.
    private func wayTimes(_ train: Arrival, later: Arrival?, size: CGFloat, details: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            countdown(train, size: size)
            if details {
                HStack(spacing: 4) {
                    LineBullet(route: train.route, size: 14)
                    let then = later.map { " · then \(MinutesToGo(until: entry.selection.leaveTime(for: $0), from: entry.date).label)" }
                    Text(train.time.clock + (then ?? ""))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.boardText)
                        .monospacedDigit()
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Lines.name(of: train.route)) leaves at \(Spoken.clock(train.time))")
            }
        }
    }

    /// The next two's minutes to go (to leave, with a walking time).
    private var laterMinutes: [MinutesToGo] {
        later.prefix(2).map { MinutesToGo(until: entry.selection.leaveTime(for: $0), from: entry.date) }
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
                .foregroundStyle(Color.boardGray)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel("Arrives at \(destination.name) at \(Spoken.clock(time))")
        }
    }
}
