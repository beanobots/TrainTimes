import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct RTrainWidget: Widget {
    let kind = "RTrainWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TrainWidgetIntent.self, provider: Provider()) { entry in
            TrainWidgetView(entry: entry)
                .containerBackground(Color.boardBlack, for: .widget)
        }
        .configurationDisplayName("Next train")
        .description("Live times for the train chosen in the app, or pick one for this widget in its Edit menu.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Timeline

struct TrainEntry: TimelineEntry {
    let date: Date
    /// What the app has chosen for the widget to show.
    let selection: Selection
    /// Trains still to come at `date`, soonest first.
    let trains: [Arrival]
    /// The most important alert (or elevator outage) to mention, if any.
    var notice: Notice? = nil
    var problem: String? = nil
    /// Whether the Lock Screen countdown is for this widget's train.
    var countingDown = false
    /// Whether there's a countdown for any train, which only the app can refresh.
    var anyCountdown = false
    /// Whether the medium widget shows the stops before yours instead of the later trains.
    var showsMap = false
    /// Whether ↻ was just tapped, so it's lit as the new times come in.
    var refreshLit = false

    var stationName: String { selection.station?.name ?? "Choose a station" }
    var heading: String { selection.heading }
    /// "R", or "N/R" with more than one line chosen.
    var lineLabel: String { selection.linesLabel }
}

/// What a widget's Edit menu offers: its own train, and its own walking time.
struct TrainWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a train"
    static let description = IntentDescription("Pick a station, lines and direction for this widget, or leave Train empty to show the one chosen in the app.")

    @Parameter(title: "Train")
    var stop: StopEntity?

    @Parameter(title: "Walking time (minutes)", description: "0 uses the walking time set in the app.", default: 0, inclusiveRange: (0, 60))
    var walkMinutes: Int

    /// This widget's train, or the app's, with this widget's walking time if it has one.
    var selection: Selection {
        let app = SharedStore.load()
        var selection = stop?.selection(basedOn: app) ?? app
        if walkMinutes > 0 { selection.walkMinutes = walkMinutes }
        return selection
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TrainEntry {
        .preview
    }

    func snapshot(for configuration: TrainWidgetIntent, in context: Context) async -> TrainEntry {
        if context.isPreview { return .preview }
        return await Self.entries(for: configuration.selection, family: context.family)[0]
    }

    func timeline(for configuration: TrainWidgetIntent, in context: Context) async -> Timeline<TrainEntry> {
        let entries = await Self.entries(for: configuration.selection, family: context.family)
        // iOS rations how often widgets reload, so this may come later;
        // until it does, the entries step through the trains already known.
        let reload = Date.now.addingTimeInterval(entries[0].problem == nil ? 10 * 60 : 2 * 60)
        return Timeline(entries: entries, policy: .after(reload))
    }

    /// One entry for now, then one as each train's time to leave passes (its
    /// arrival, without a walking time), so the widget moves on to the next
    /// train you can catch without going back to the network. The medium
    /// widget also gets one a minute, for its later trains' minutes to go.
    private static func entries(for selection: Selection, family: WidgetFamily) async -> [TrainEntry] {
        let countdown = SharedStore.loadCountdown().flatMap { $0.ends > .now ? $0 : nil }
        let countingDown = countdown?.trainID == selection.trainID
        let showsMap = family == .systemMedium && SharedStore.showsMap(for: selection.trainID)
        do {
            let board = try await Self.board(for: selection)
            // After the fetch, so the entries start when they're shown
            let now = Date.now
            let trains = selection.catchable(board.trains, now: now)
            // ↻ lights up as these new times come in: the first entry lights it
            // and the next fades it back
            let refreshTapped = SharedStore.loadRefreshed().map { now.timeIntervalSince($0) < 30 } ?? false
            let refreshLit = refreshTapped && now.timeIntervalSince(board.fetched) < 5
            let entry = { (date: Date, lit: Bool) -> TrainEntry in
                var shown = selection.catchable(trains, now: date)
                // Where the feed said the train was soon goes out of date; after
                // a minute, the stop list goes by when it's due at each stop
                if date.timeIntervalSince(board.fetched) > 60 {
                    shown = shown.map { train in
                        var train = train
                        train.position = nil
                        return train
                    }
                }
                return TrainEntry(date: date, selection: selection, trains: shown, notice: board.notice, countingDown: countingDown,
                                  anyCountdown: countdown != nil, showsMap: showsMap, refreshLit: lit)
            }
            let leaveTimes = trains.prefix(10).map(selection.leaveTime(for:))
            var dates = Set(leaveTimes)
            if family == .systemMedium, let lastLeave = leaveTimes.last {
                let end = min(lastLeave, now.addingTimeInterval(60 * 60))
                var minute = now.addingTimeInterval(60)
                while minute < end {
                    dates.insert(minute)
                    minute.addTimeInterval(60)
                }
            }
            if refreshLit { dates.insert(now.addingTimeInterval(0.5)) }
            return [entry(now, refreshLit)] + dates.filter { $0 > now }.sorted().map { entry($0, false) }
        } catch {
            return [TrainEntry(date: .now, selection: selection, trains: [], problem: "Couldn't reach the MTA",
                               countingDown: countingDown, anyCountdown: countdown != nil, showsMap: showsMap)]
        }
    }

    /// The trains and alert for `selection`, fetched; or, to redraw at once,
    /// ones fetched in the last 30 seconds (by another widget, or the
    /// countdown), or after a tap on the map or walk button, which changes only
    /// how the widget looks, the ones it already shows. Never ones from before ↻.
    private static func board(for selection: Selection) async throws -> SharedStore.SavedBoard {
        let now = Date.now
        if let saved = SharedStore.loadBoard(for: selection), saved.fetched > SharedStore.loadRefreshed() ?? .distantPast {
            let age = now.timeIntervalSince(saved.fetched)
            let toggled = SharedStore.loadToggled().map { now.timeIntervalSince($0) < 30 } ?? false
            if age < 30 || (toggled && age < 15 * 60) { return saved }
        }
        let board = try await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts, now: now)
        return SharedStore.saveBoard(board, for: selection, fetched: .now)
    }
}

// MARK: - Views

struct TrainWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TrainEntry

    private var next: Arrival? { entry.trains.first }
    private var later: ArraySlice<Arrival> { entry.trains.dropFirst() }
    /// With a walking time, the countdown is to when to leave.
    private var walking: Bool { entry.selection.walkMinutes > 0 }
    private var noTrains: String { entry.problem ?? "No \(entry.lineLabel) trains predicted" }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let next, walking {
                Text("\(next.lineLabel): leave \(entry.selection.leaveTime(for: next).clock) for \(next.time.clock)")
            } else if let next, let notice = entry.notice {
                Text("\(next.lineLabel) \(next.time.clock) · \(notice.label)")
            } else if let next {
                Text(inlineTimes([next] + later.prefix(2)))
            } else {
                Text(noTrains)
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(next?.lineLabel ?? entry.lineLabel).font(.headline)
                    if let next {
                        countdown(to: next).font(.system(size: 15, weight: .semibold, design: .rounded))
                    } else {
                        Text("–")
                    }
                }
                .multilineTextAlignment(.center)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 0) {
                Text("\(entry.lineLabel) · \(entry.stationName)").font(.headline).lineLimit(1)
                if let next {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if entry.selection.marksLine(of: next) { LineBullet(route: next.route, size: 16) }
                        if walking { Text("Leave in").font(.caption) }
                        countdown(to: next)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.leading)
                    }
                    if let notice = entry.notice {
                        Label(notice.label, systemImage: notice.symbol).font(.caption)
                    } else if !later.isEmpty {
                        Text("then " + later.prefix(2).map(time).joined(separator: ", ")).font(.caption)
                    }
                } else {
                    Text(noTrains).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            small
        default:
            medium
        }
    }

    /// The station; the countdown with the next two trains' times beside it; ↻ and walk.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(nameLines: 2)
            Spacer(minLength: 2)
            if let next {
                let following = later.first
                // A bullet beside a time takes room from the countdown
                let marks = entry.selection.marksLine(of: next) || (following.map { entry.selection.marksLine(of: $0) } ?? false)
                HStack(spacing: 6) {
                    countdownLabel(to: next, size: marks ? 28 : 32)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        clock(of: next)
                        if let following { clock(of: following) }
                    }
                }
                // Dims from a tap until the widget redraws
                .invalidatableContent()
            } else {
                Text(noTrains)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            buttons.padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The station across the top; the countdown on the left, with what's wrong
    /// above it; on the right the trains after it, or behind the map button the
    /// stops before yours; and ↻, map and walk.
    private var medium: some View {
        let showsStops = entry.showsMap && next != nil
        let columnWidth = showsStops ? 130 : laterWidth
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                header(nameLines: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Spacer(minLength: 0)
                    if !entry.showsMap, let notice = entry.notice {
                        Text(notice.message)
                            .font(.caption2)
                            .foregroundStyle(Color.boardGray)
                            .lineLimit(2)
                            // Gives way to the countdown where the widget is short
                            .layoutPriority(-1)
                    }
                    if let next {
                        HStack(spacing: 6) {
                            if entry.selection.marksLine(of: next) {
                                LineBullet(route: next.route, size: 18)
                            }
                            countdownLabel(to: next, size: 32)
                                .frame(height: 34)
                        }
                        .invalidatableContent()
                    } else {
                        Text(noTrains)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.trailing, columnWidth + 10)
                buttons.padding(.top, 8)
            }
            // Level with the direction, under the station name, down to the buttons;
            // shorter widgets (an iPhone SE's) get one row fewer
            Group {
                if showsStops, let next {
                    ViewThatFits(in: .vertical) {
                        StopList(train: next, now: entry.date, maxRows: 4)
                        StopList(train: next, now: entry.date, maxRows: 3)
                    }
                } else {
                    ViewThatFits(in: .vertical) {
                        laterTrains(4)
                        laterTrains(3)
                        laterTrains(2)
                    }
                }
            }
            .frame(width: columnWidth, alignment: .topLeading)
            .invalidatableContent()
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The line's bullet, the station, and the direction with an alert's icon
    /// after it, the bullet centred on the text.
    private func header(nameLines: Int) -> some View {
        HStack(alignment: .textMiddle, spacing: 7) {
            LineBullets(routes: entry.selection.routes, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.stationName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(nameLines)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 4) {
                    Text(entry.heading)
                        .font(.caption2)
                        .foregroundStyle(Color.boardGray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let notice = entry.notice {
                        Image(systemName: notice.symbol)
                            .font(.caption2)
                            .foregroundStyle(notice.tint)
                            .accessibilityLabel(notice.label)
                    }
                }
            }
            .alignmentGuide(.textMiddle) { d in
                (d[.firstTextBaseline] - Self.nameCapHeight + d[.lastTextBaseline]) / 2
            }
        }
    }

    /// The height of the station name's capitals.
    private static var nameCapHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .subheadline).capHeight
    }

    /// The countdown, after a walker when it's to when to leave.
    private func countdownLabel(to train: Arrival, size: CGFloat) -> some View {
        HStack(spacing: 3) {
            if walking {
                Image(systemName: "figure.walk")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Color.boardGray)
                    .accessibilityLabel("Leave in")
            }
            countdown(to: train)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(train.statusColor)
                .multilineTextAlignment(.leading)
        }
    }

    /// "8:12" in its live or timetable colour, after its bullet where it could be another line.
    private func clock(of train: Arrival) -> some View {
        HStack(spacing: 3) {
            if entry.selection.marksLine(of: train) {
                LineBullet(route: train.route, size: 13)
            }
            Text(train.time.clock)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(train.statusColor)
        }
        .lineLimit(1)
    }

    /// The trains after the next one, up to `count`, with their minutes to go.
    private func laterTrains(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LATER")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardGray)
                .padding(.bottom, 1)
            ForEach(Array(later.prefix(count).enumerated()), id: \.offset) { _, train in
                HStack(spacing: 3) {
                    if entry.selection.marksLine(of: train) {
                        LineBullet(route: train.route, size: 13)
                    }
                    Text(train.time.clock)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(train.statusColor)
                        .fixedSize()
                    Spacer(minLength: 4)
                    Text("\(minutes(until: train)) min")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.boardGray)
                        .minimumScaleFactor(0.75)
                }
                .lineLimit(1)
                .frame(height: StopList.rowHeight)
            }
        }
    }

    /// The later trains' column: wider for a bullet or a two-digit hour, so a
    /// time is never cut short.
    private var laterWidth: CGFloat {
        let shown = later.prefix(4)
        var width: CGFloat = 86
        if shown.contains(where: entry.selection.marksLine) { width += 16 }
        if shown.contains(where: { $0.time.clock.count > 4 }) { width += 8 }
        return width
    }

    private func minutes(until train: Arrival) -> Int {
        max(0, Int(train.time.timeIntervalSince(entry.date) / 60))
    }

    /// "8:12", or "N 8:12" where it could be more than one line.
    private func time(_ train: Arrival) -> String {
        entry.selection.marksLine(of: train) ? "\(train.lineLabel) \(train.time.clock)" : train.time.clock
    }

    /// "R 8:12 · 8:20 · 8:31", or, where they could be more than one line, each
    /// train's own: "N 8:12 · R 8:20 · D 8:31".
    private func inlineTimes(_ trains: [Arrival]) -> String {
        if !trains.contains(where: entry.selection.marksLine) {
            return "\(entry.lineLabel) " + trains.map(\.time.clock).joined(separator: " · ")
        }
        return trains.map { "\($0.lineLabel) \($0.time.clock)" }.joined(separator: " · ")
    }

    /// ↻, the medium widget's map button, and the walk button, which starts or
    /// stops the countdown to this widget's train, sharing the row equally. Each
    /// lights up in the line's colour: ↻ just after it's tapped, map while the
    /// stops show, walk while the countdown runs.
    private var buttons: some View {
        HStack(spacing: 6) {
            RefreshButton(lit: entry.refreshLit ? LineStyle.of(entry.selection.firstRoute) : nil, fills: true,
                          widgetsOnly: !entry.anyCountdown)
            if family == .systemMedium {
                MapButton(selection: entry.selection, isOn: entry.showsMap)
            }
            WalkButton(intent: ToggleCountdownIntent(selection: entry.selection), route: entry.selection.firstRoute,
                       isOn: entry.countingDown, fills: true)
        }
    }

    /// Counts down to the train (or, with a walking time, to when to leave for
    /// it) and stops at 0:00, live, without the widget reloading.
    private func countdown(to train: Arrival) -> some View {
        Text(timerInterval: entry.date...entry.selection.leaveTime(for: train), countsDown: true)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

extension Notice {
    /// What the medium widget says above the countdown: the alert's headline, or
    /// "Elevator out: street to Manhattan-bound platform".
    var message: String {
        if kind == .elevator || text.isEmpty { return text.isEmpty ? label : "\(label): \(text)" }
        return text
    }
}

extension Color {
    static let boardBlack = Color(white: 0.07)
    static let boardGray = Color(white: 0.62)
    /// Stops the train has passed.
    static let boardDim = Color(white: 0.5)
}

extension Arrival {
    /// Green for a live prediction, white for a timetable time.
    var statusColor: Color { isLive ? .liveGreen : .white }
}

extension Date {
    /// "8:12", without AM/PM, for lists of times.
    var clock: String { Self.clockFormatter.string(from: self) }

    /// The phone's hours and minutes, 12 or 24 hour as it's set, with any AM/PM
    /// taken out. (Date.FormatStyle's `amPM: .omitted` writes "08:12".)
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        var quoted = false
        let pattern = formatter.dateFormat.filter { character in
            if character == "'" { quoted.toggle() }
            return quoted || !"abB".contains(character)
        }
        formatter.dateFormat = pattern.trimmingCharacters(in: .whitespaces)
        return formatter
    }()
}

// MARK: - Previews

extension TrainEntry {
    static var preview: TrainEntry {
        let now = Date.now
        // An N running local on the R comes first, stopped at 53 St, four stops away
        let approach = ["R40N", "R39N", "R36N", "R35N", "R34N"].enumerated().map { index, stop in
            Arrival.Stop(id: stop, time: now.addingTimeInterval(Double(index) * 60))
        }
        let trains = [4.0, 12, 20, 31, 41].map {
            Arrival(route: $0 == 4 ? "N" : "R", time: now.addingTimeInterval($0 * 60), stop: "R34N", lastStop: $0 == 4 ? "R01N" : "G08N",
                    isLive: $0 < 15, approach: $0 == 4 ? approach : [],
                    position: $0 == 4 ? Arrival.Position(stop: "R40N", isStopped: true) : nil)
        }
        return TrainEntry(date: now, selection: .fallback, trains: trains)
    }
}

#Preview(as: .systemSmall) {
    RTrainWidget()
} timeline: {
    TrainEntry.preview
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains,
               notice: Notice(kind: .alert(.delays), label: "Delays", text: "", others: 0),
               countingDown: true, refreshLit: true)
}

#Preview(as: .systemMedium) {
    RTrainWidget()
} timeline: {
    TrainEntry.preview
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains,
               notice: Notice(kind: .alert(.delays), label: "Delays", text: "R trains are delayed while we address a signal problem", others: 1),
               countingDown: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, showsMap: true)
    TrainEntry(date: .now, selection: .fallback, trains: [], problem: "Couldn't reach the MTA")
}
