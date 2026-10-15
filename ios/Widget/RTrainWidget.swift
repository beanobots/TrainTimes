import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct RTrainWidget: Widget {
    let kind = "RTrainWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TrainWidgetIntent.self, provider: Provider()) { entry in
            TrainWidgetView(entry: entry)
                .containerBackground(Color.boardBackground, for: .widget)
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
    /// A medium widget with room for larger text; see `BoardStyle`.
    var largeText = false

    var stationName: String { selection.station?.name ?? "Choose a station" }
    var heading: String { selection.heading }
    /// "R", or "N/R" with more than one line chosen.
    var lineLabel: String { selection.linesLabel }
}

/// What a widget's Edit menu offers: a station, a line and a direction, in any
/// order (see WidgetChoices.swift). The walking time is the app's.
struct TrainWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a train"
    static let description = IntentDescription("Pick a station, line and direction for this widget, or leave them empty to show the train chosen in the app.")

    @Parameter(title: "Station")
    var station: StationEntity?

    @Parameter(title: "Line")
    var line: LineEntity?

    @Parameter(title: "Direction")
    var direction: DirectionEntity?

    /// The whole train in one choice, as widgets set up before were. It's no
    /// longer in the Edit menu, but such a widget keeps its train until the
    /// three above are chosen.
    @Parameter(title: "Train")
    var stop: StopEntity?

    static var parameterSummary: some ParameterSummary {
        Summary {
            \.$station
            \.$line
            \.$direction
        }
    }

    /// This widget's train, with the app's walking time: the app's train until
    /// all three are chosen, or where the line doesn't stop at the station.
    var selection: Selection {
        let app = SharedStore.load()
        guard station != nil || line != nil || direction != nil else {
            return stop?.selection(basedOn: app) ?? app
        }
        guard let station = station?.station, let routes = line?.routes, let direction = direction?.direction,
              routes.allSatisfy(station.routes.contains) else { return app }
        return Selection(stationID: station.id, routes: routes, direction: direction,
                         elevatorAlerts: app.elevatorAlerts, walkMinutes: app.walkMinutes).validated()
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TrainEntry {
        .preview
    }

    func snapshot(for configuration: TrainWidgetIntent, in context: Context) async -> TrainEntry {
        if context.isPreview { return .preview }
        return await Self.entries(for: configuration.selection, family: context.family, largeText: Self.hasRoom(context))[0]
    }

    func timeline(for configuration: TrainWidgetIntent, in context: Context) async -> Timeline<TrainEntry> {
        let entries = await Self.entries(for: configuration.selection, family: context.family, largeText: Self.hasRoom(context))
        // iOS rations how often widgets reload, so this may come later;
        // until it does, the entries step through the trains already known.
        let reload = Date.now.addingTimeInterval(entries[0].problem == nil ? 10 * 60 : 2 * 60)
        return Timeline(entries: entries, policy: .after(reload))
    }

    /// Whether a medium widget is big enough for larger text: 158 points tall
    /// or more, as on an iPhone 12 or later, apart from the minis.
    private static func hasRoom(_ context: Context) -> Bool {
        context.family == .systemMedium && context.displaySize.height >= 158
    }

    /// One entry for now, then one as each train's time to leave passes (its
    /// arrival, without a walking time), so the widget moves on to the next
    /// train you can catch without going back to the network. The medium
    /// widget also gets one a minute, for its later trains' minutes to go.
    private static func entries(for selection: Selection, family: WidgetFamily, largeText: Bool) async -> [TrainEntry] {
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
                                  anyCountdown: countdown != nil, showsMap: showsMap, refreshLit: lit, largeText: largeText)
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
                               countingDown: countingDown, anyCountdown: countdown != nil, showsMap: showsMap, largeText: largeText)]
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
                    .foregroundStyle(Color.boardText)
            }
            buttons(.compact).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The station across the top; the countdown on the left, with what's wrong
    /// above it; on the right the trains after it, or behind the map button the
    /// stops before yours; and ↻, map and walk. Larger on bigger phones.
    private var medium: some View {
        GeometryReader { geometry in
            mediumLayout(width: geometry.size.width, style: entry.largeText ? .large : .compact)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func mediumLayout(width: CGFloat, style: BoardStyle) -> some View {
        let showsStops = entry.showsMap && next != nil
        let textLeft = LineBullets.width(count: entry.selection.routes.count, size: style.bulletSize) + style.headerSpacing
        // The direction ends short of the column on the right. Where the
        // station does too, the column starts at the top beside it, with a
        // row more, rather than under it.
        let textRoom = width - style.columnWidth - style.columnGap - textLeft
        let raised = headerTextWidth(style) <= textRoom
        let rows = style.rows(raised: raised)
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                header(nameLines: 1, style: style, headingWidth: textRoom)
                VStack(alignment: .leading, spacing: 2) {
                    Spacer(minLength: 0)
                    if !entry.showsMap, let notice = entry.notice {
                        Text(notice.message)
                            .font(style.alertFont)
                            .foregroundStyle(Color.boardGray)
                            .lineLimit(style.alertLines)
                            // Gives way to the countdown where the widget is short
                            .layoutPriority(-1)
                    }
                    if let next {
                        HStack(spacing: style.isLarge ? 7 : 6) {
                            if entry.selection.marksLine(of: next) {
                                LineBullet(route: next.route, size: style.countdownBullet)
                            }
                            countdownLabel(to: next, size: style.countdownSize)
                                // Its full line height is taller than the row; offered
                                // only the row, it would shrink to fit
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(height: style.countdownHeight)
                        }
                        .invalidatableContent()
                    } else {
                        Text(noTrains)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.boardText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.trailing, style.columnWidth + style.columnGap)
                buttons(style).padding(.top, 8)
            }
            // The later trains and the stops start in the same place, so their
            // labels line up; down to the buttons. Shorter widgets (an iPhone
            // SE's) get a row fewer.
            Group {
                if showsStops, let next {
                    ViewThatFits(in: .vertical) {
                        StopList(train: next, now: entry.date, maxRows: rows, style: style)
                        StopList(train: next, now: entry.date, maxRows: max(3, rows - 1), style: style)
                        StopList(train: next, now: entry.date, maxRows: 3, style: style)
                    }
                } else {
                    ViewThatFits(in: .vertical) {
                        laterTrains(rows, style: style)
                        laterTrains(rows - 1, style: style)
                        laterTrains(rows - 2, style: style)
                    }
                }
            }
            .frame(width: style.columnWidth, alignment: .topLeading)
            .invalidatableContent()
            .padding(.top, raised ? 0 : style.columnTop)
            .padding(.bottom, style.buttonHeight + 8)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// How wide the station is, or the direction with an alert's icon after
    /// it, whichever is wider.
    private func headerTextWidth(_ style: BoardStyle) -> CGFloat {
        let name = entry.stationName.width(in: style.nameUIFont)
        var heading = entry.heading.width(in: style.headingUIFont)
        if entry.notice != nil { heading += style.headingUIFont.pointSize * 1.2 + 4 }
        return max(name, heading)
    }

    /// The line's bullet, the station, and the direction with an alert's icon
    /// after it (kept within `headingWidth`), the bullet centred on the text.
    private func header(nameLines: Int, style: BoardStyle = .compact, headingWidth: CGFloat? = nil) -> some View {
        HStack(alignment: .textMiddle, spacing: style.headerSpacing) {
            LineBullets(routes: entry.selection.routes, size: style.bulletSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.stationName)
                    .font(style.nameFont)
                    .foregroundStyle(Color.boardText)
                    .lineLimit(nameLines)
                    .minimumScaleFactor(style.nameScale)
                HStack(spacing: 4) {
                    Text(entry.heading)
                        .font(style.headingFont)
                        .foregroundStyle(Color.boardGray)
                        .lineLimit(1)
                        .minimumScaleFactor(style.headingScale)
                    if let notice = entry.notice {
                        Image(systemName: notice.symbol)
                            .font(style.headingFont)
                            .foregroundStyle(notice.tint)
                            .accessibilityLabel(notice.label)
                    }
                }
                .frame(maxWidth: headingWidth, alignment: .leading)
            }
            .alignmentGuide(.textMiddle) { d in
                (d[.firstTextBaseline] - style.nameUIFont.capHeight + d[.lastTextBaseline]) / 2
            }
        }
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

    /// The trains after the next one, up to `count`, with their minutes to go:
    /// the times in a column as wide as the longest, the minutes right after it.
    private func laterTrains(_ count: Int, style: BoardStyle) -> some View {
        let shown = Array(later.prefix(count))
        let timeWidth = shown.map { train in
            train.time.clock.width(in: style.timeUIFont) + (entry.selection.marksLine(of: train) ? style.timeBullet + 3 : 0)
        }.max() ?? 0
        let minutesWidth = shown.map { minutesToGo(until: $0).width(in: style.minutesUIFont) }.max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Text("LATER")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardGray)
                .padding(.bottom, style.isLarge ? 0 : 1)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, train in
                HStack(spacing: style.minutesGap) {
                    HStack(spacing: 3) {
                        if entry.selection.marksLine(of: train) {
                            LineBullet(route: train.route, size: style.timeBullet)
                        }
                        Text(train.time.clock)
                            .font(style.timeFont)
                            .monospacedDigit()
                            .foregroundStyle(train.statusColor)
                            // Never cut short, should it come out wider than measured
                            .fixedSize()
                    }
                    .frame(width: timeWidth, alignment: .leading)
                    Text(minutesToGo(until: train))
                        .font(style.minutesFont)
                        .monospacedDigit()
                        .foregroundStyle(Color.boardGray)
                        .fixedSize()
                        .frame(width: minutesWidth, alignment: .trailing)
                }
                .lineLimit(1)
                .frame(height: style.rowHeight)
            }
        }
    }

    /// "12 min"
    private func minutesToGo(until train: Arrival) -> String {
        "\(minutes(until: train)) min"
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
    private func buttons(_ style: BoardStyle) -> some View {
        HStack(spacing: 6) {
            RefreshButton(lit: entry.refreshLit ? LineStyle.of(entry.selection.firstRoute) : nil, fills: true,
                          widgetsOnly: !entry.anyCountdown, large: style.isLarge)
            if family == .systemMedium {
                MapButton(selection: entry.selection, isOn: entry.showsMap, large: style.isLarge)
            }
            WalkButton(intent: ToggleCountdownIntent(selection: entry.selection), route: entry.selection.firstRoute,
                       isOn: entry.countingDown, fills: true, large: style.isLarge)
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
    /// The Lock Screen countdown's background, dark in light mode too.
    static let boardBlack = Color(white: 0.07)

    // The home screen widgets follow the phone's light or dark setting: the
    // station board's black in dark mode, white in light

    static let boardBackground = Color(light: UIColor.white, dark: UIColor(white: 0.07, alpha: 1))
    /// Station names and timetable times.
    static let boardText = Color(light: UIColor.black, dark: UIColor.white)
    /// Directions, labels and minutes to go.
    static let boardGray = Color(light: UIColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1), dark: UIColor(white: 0.62, alpha: 1))
    /// Stops the train has passed.
    static let boardDim = Color(light: UIColor(red: 0.63, green: 0.63, blue: 0.65, alpha: 1), dark: UIColor(white: 0.5, alpha: 1))
    /// A button's face when it isn't lit.
    static let boardButton = Color(light: UIColor(white: 0, alpha: 0.06), dark: UIColor(white: 1, alpha: 0.15))

    init(light: UIColor, dark: UIColor) {
        self.init(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension Arrival {
    /// Green for a live prediction, white (black in light mode) for a timetable time.
    var statusColor: Color { isLive ? .liveText : .boardText }
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
        let trains = [4.0, 12, 20, 31, 41, 50].map {
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
    // An iPhone 12's and later's widgets have room for larger text
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, largeText: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains,
               notice: Notice(kind: .alert(.delays), label: "Delays", text: "R trains are delayed while we address a signal problem", others: 1),
               largeText: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, showsMap: true, largeText: true)
}
