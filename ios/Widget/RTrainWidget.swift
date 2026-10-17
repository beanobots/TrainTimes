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
        .description("Live times for a widget set up in the app. Pick which one in its Edit menu. The large one shows where you change trains.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        // The alert banner runs edge to edge; TrainWidgetView puts the
        // margins back everywhere else
        .contentMarginsDisabled()
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
    /// Whether the home screen widgets show their alert in full, after a tap
    /// on its banner, instead of the times.
    var showsAlert = false
    /// Whether ↻ was just tapped, so it's lit as the new times come in.
    var refreshLit = false
    /// A medium widget with room for larger text, or with Settings › Larger
    /// widget text; see `BoardStyle`.
    var largeText = false
    /// The app's Settings, for larger text and marking live times.
    var settings = AppSettings()
    /// On a large widget with a change, the trains still to catch that get
    /// there, each with the train it meets; nil without a change.
    var connections: [Connection]? = nil
    /// The large widget's change of trains, if its saved widget has one.
    var change: Change? = nil

    var stationName: String { selection.station?.name ?? "Choose a station" }
    var heading: String { selection.heading }
    /// "R", or "N/R" with more than one line chosen.
    var lineLabel: String { selection.linesLabel }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TrainEntry {
        .preview
    }

    func snapshot(for configuration: TrainWidgetIntent, in context: Context) async -> TrainEntry {
        if context.isPreview { return context.family == .systemLarge ? .transferPreview() : .preview }
        return await Self.plan(for: configuration.selection, change: Self.change(for: configuration, in: context),
                               family: context.family, largeText: Self.hasRoom(context)).entries[0]
    }

    func timeline(for configuration: TrainWidgetIntent, in context: Context) async -> Timeline<TrainEntry> {
        let plan = await Self.plan(for: configuration.selection, change: Self.change(for: configuration, in: context),
                                   family: context.family, largeText: Self.hasRoom(context))
        // iOS rations how often widgets reload, so this may come later;
        // until it does, the entries step through the trains already known.
        let now = Date.now
        var reload = now.addingTimeInterval(2 * 60)
        if let fetched = plan.fetched {
            // Counted from when the times were fetched, as they may be ones
            // another widget fetched a while ago; and sooner if the entries
            // run out of trains first, rather than say there are none
            reload = fetched.addingTimeInterval(Self.reloadInterval(at: now))
            if let runsOut = plan.runsOut { reload = min(reload, runsOut) }
            reload = max(reload, now.addingTimeInterval(60))
        }
        return Timeline(entries: plan.entries, policy: .after(reload))
    }

    /// A timeline's entries, with what its reload goes by.
    private struct Plan {
        var entries: [TrainEntry]
        /// When its times were fetched; nil if they couldn't be.
        var fetched: Date?
        /// The last entry's date, after which the widget knows of no train to show.
        var runsOut: Date?
    }

    /// How long to wait for new times: 5 minutes, about as often as iOS
    /// reloads a widget, from 6 am to 11 pm in New York; 15 overnight. A
    /// widget's reloads are budgeted by the day, so fewer at night leaves
    /// more for the day.
    private static func reloadInterval(at date: Date) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let hour = calendar.component(.hour, from: date)
        return (6..<23).contains(hour) ? 5 * 60 : 15 * 60
    }

    /// Whether a medium widget is big enough for larger text: 158 points tall
    /// or more, as on an iPhone 12 or later, apart from the minis. With
    /// Settings › Larger widget text, every medium widget has it. A large
    /// widget always has.
    private static func hasRoom(_ context: Context) -> Bool {
        if context.family == .systemLarge { return true }
        guard context.family == .systemMedium else { return false }
        return context.displaySize.height >= 158 || SharedStore.loadSettings().largerWidgetText
    }

    /// The large widget's change of trains, if its saved widget has one.
    private static func change(for configuration: TrainWidgetIntent, in context: Context) -> Change? {
        context.family == .systemLarge ? configuration.change : nil
    }

    /// One entry for now, then one as each train's time to leave passes (its
    /// arrival, without a walking time), so the widget moves on to the next
    /// train you can catch without going back to the network; with a change,
    /// the next that gets there. The medium and large widgets also get one a
    /// minute, for their later trains' minutes to go and their maps.
    private static func plan(for selection: Selection, change: Change?, family: WidgetFamily, largeText: Bool) async -> Plan {
        let countdown = SharedStore.loadCountdown().flatMap { $0.ends > .now ? $0 : nil }
        let countingDown = countdown?.trainID == selection.trainID
        let hasMap = family == .systemMedium || family == .systemLarge
        let showsMap = hasMap && SharedStore.showsMap(for: selection.trainID)
        let showsAlert = (family == .systemSmall || hasMap) && SharedStore.showsAlert(for: selection.alertID)
        let settings = SharedStore.loadSettings()
        do {
            let board = try await Self.board(for: selection, change: change)
            // Once the alert's over, the next one starts out closed
            if board.notice == nil {
                SharedStore.closeAlert(for: selection.alertID)
            }
            // After the fetch, so the entries start when they're shown
            let now = Date.now
            let trains = selection.catchable(board.trains, now: now)
            let connections = (board.connections ?? []).filter { selection.leaveTime(for: $0.first) > now }
            // ↻ lights up as these new times come in: the first entry lights it
            // and the next fades it back
            let refreshTapped = SharedStore.loadRefreshed().map { now.timeIntervalSince($0) < 30 } ?? false
            let refreshLit = refreshTapped && now.timeIntervalSince(board.fetched) < 5
            let entry = { (date: Date, lit: Bool) -> TrainEntry in
                let positionStale = date.timeIntervalSince(board.fetched) > 60
                let shown = selection.catchable(trains, now: date).enumerated().map { index, train in
                    var train = train
                    // Only the map shows a train's stops, and only the next
                    // train's; the timeline holds many entries, in the widget's
                    // little memory, so no other train keeps them
                    if !showsMap || index > 0 { train.approach = [] }
                    // Where the feed said the train was soon goes out of date; after
                    // a minute, the stop list goes by when it's due at each stop
                    if positionStale { train.position = nil }
                    return train
                }
                return TrainEntry(date: date, selection: selection, trains: shown, notice: board.notice, countingDown: countingDown,
                                  anyCountdown: countdown != nil, showsMap: showsMap, showsAlert: showsAlert,
                                  refreshLit: lit, largeText: largeText, settings: settings,
                                  connections: change == nil ? nil : Self.shown(connections, at: date, selection: selection,
                                                                                 showsMap: showsMap),
                                  change: change)
            }
            // With a change, the trains that get there are the ones to catch
            let leaveTimes = (change == nil ? trains : connections.map(\.first)).prefix(10).map(selection.leaveTime(for:))
            var dates = Set(leaveTimes)
            if hasMap, let lastLeave = leaveTimes.last {
                let end = min(lastLeave, now.addingTimeInterval(60 * 60))
                var minute = now.addingTimeInterval(60)
                while minute < end {
                    dates.insert(minute)
                    minute.addTimeInterval(60)
                }
            }
            if refreshLit { dates.insert(now.addingTimeInterval(0.5)) }
            let entries = [entry(now, refreshLit)] + dates.filter { $0 > now }.sorted().map { entry($0, false) }
            return Plan(entries: entries, fetched: board.fetched, runsOut: leaveTimes.last)
        } catch {
            return Plan(entries: [TrainEntry(date: .now, selection: selection, trains: [], problem: "Couldn't reach the MTA",
                                             countingDown: countingDown, anyCountdown: countdown != nil, showsMap: showsMap,
                                             largeText: largeText, settings: settings, change: change)])
        }
    }

    /// The connections still to catch at `date`. Only the map shows where the
    /// trains are, and only the first's; the timeline holds many entries, in
    /// the widget's little memory, so no other keeps their stops.
    private static func shown(_ connections: [Connection], at date: Date, selection: Selection,
                              showsMap: Bool) -> [Connection] {
        connections.filter { selection.leaveTime(for: $0.first) > date }.enumerated().map { index, connection in
            var connection = connection
            connection.first.approach = []
            if !showsMap || index > 0 {
                connection.arrival.approach = []
                connection.next?.approach = []
            }
            return connection
        }
    }

    /// The trains and alert for `selection`, with `change` those of the large
    /// widget showing it, fetched; or, to redraw at once,
    /// ones fetched in the last 30 seconds (by another widget, or the
    /// countdown), or after a tap on the map or walk button or the alert
    /// banner, which changes only
    /// how the widget looks, the ones it already shows. Never ones from before ↻.
    private static func board(for selection: Selection, change: Change?) async throws -> SharedStore.SavedBoard {
        let now = Date.now
        if let saved = SharedStore.loadBoard(for: selection, change: change),
           saved.fetched > SharedStore.loadRefreshed() ?? .distantPast {
            let age = now.timeIntervalSince(saved.fetched)
            let toggled = SharedStore.loadToggled().map { now.timeIntervalSince($0) < 30 } ?? false
            if age < 30 || (toggled && age < 15 * 60) { return saved }
        }
        let board: Board
        if let change {
            board = try await TrainService.board(for: selection, change: change, includingOutages: selection.elevatorAlerts, now: now)
        } else {
            board = try await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts, now: now)
        }
        return SharedStore.saveBoard(board, for: selection, change: change, fetched: .now)
    }
}

// MARK: - Views

struct TrainWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    let entry: TrainEntry

    /// Whether live times get their symbol as well as their green.
    private var marksLive: Bool { withoutColor || entry.settings.marksLiveTimes }

    private var next: Arrival? { entry.trains.first }
    private var later: ArraySlice<Arrival> { entry.trains.dropFirst() }
    /// With a walking time, the countdown is to when to leave.
    private var walking: Bool { entry.selection.walkMinutes > 0 }
    private var noTrains: String { entry.problem ?? "No \(entry.lineLabel) trains predicted" }

    /// Whether the alert shows in full, in place of the times.
    private var alertOpen: Bool { entry.showsAlert && entry.notice != nil }

    var body: some View {
        // The home screen widgets give an alert a banner across the top, in
        // place of the top margin. Tapping it shows the alert in full, and
        // tapping that opens the app at the train's alerts.
        if let notice = entry.notice, family == .systemSmall || family == .systemMedium || family == .systemLarge {
            VStack(spacing: 0) {
                banner(notice)
                Group {
                    if alertOpen {
                        fullAlert(notice)
                            .widgetURL(entry.selection.alertsURL)
                    } else {
                        content
                    }
                }
                .padding(EdgeInsets(top: 8, leading: margins.leading, bottom: margins.bottom, trailing: margins.trailing))
            }
        } else {
            content.padding(margins)
        }
    }

    @ViewBuilder private var content: some View {
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
        case .systemLarge:
            large
        default:
            medium
        }
    }

    /// The station; the countdown with the train after it beside it; ↻ and walk.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Under a banner, the station gets one line
            header(nameLines: entry.notice == nil ? 2 : 1)
            Spacer(minLength: 2)
            if let next {
                // With larger text, the countdown has the row to itself
                let larger = entry.settings.largerWidgetText
                let after = larger ? nil : later.first
                // A bullet takes room from the countdown
                let marks = ([next] + later.prefix(larger ? 0 : 1)).contains(where: entry.selection.marksLine)
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        countdownLabel(to: next, size: larger ? (marks ? 38 : 44) : (marks ? 28 : 32))
                        if entry.selection.marksLine(of: next) {
                            LineBullet(route: next.route, size: BoardStyle.compact.timeBullet)
                        }
                    }
                    Spacer(minLength: 0)
                    if let after {
                        laterTrain(after)
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

    /// The station across the top; the countdown on the left; on the right the
    /// trains after it, or behind the map button the stops before yours; and
    /// ↻, map and walk. Larger on bigger phones.
    private var medium: some View {
        GeometryReader { geometry in
            mediumLayout(size: geometry.size, style: entry.largeText ? .large : .compact)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func mediumLayout(size: CGSize, style: BoardStyle) -> some View {
        let showsStops = entry.showsMap && next != nil
        let textLeft = LineBullets.width(count: entry.selection.routes.count, size: style.bulletSize) + style.headerSpacing
        // The column on the right starts at the top, beside the station and
        // direction, which end short of it
        let textRoom = size.width - style.columnWidth - style.columnGap - textLeft
        // From the top down to the buttons
        let columnHeight = size.height - style.buttonHeight - 8
        let rows = style.columnRows
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                header(nameLines: 1, style: style, textWidth: textRoom)
                VStack(alignment: .leading, spacing: 2) {
                    Spacer(minLength: 0)
                    if let next {
                        HStack(spacing: style.isLarge ? 5 : 4) {
                            countdownLabel(to: next, size: style.countdownSize)
                                // Its full line height is taller than the row; offered
                                // only the row, it would shrink to fit
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(height: style.countdownHeight)
                            if entry.selection.marksLine(of: next) {
                                LineBullet(route: next.route, size: style.countdownBullet)
                            }
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
            // SE's) get a row fewer. The stops spread out to fill it.
            Group {
                if showsStops, let next {
                    ViewThatFits(in: .vertical) {
                        StopList(train: next, now: entry.date, maxRows: rows, style: style, height: columnHeight)
                        StopList(train: next, now: entry.date, maxRows: max(3, rows - 1), style: style, height: columnHeight)
                        StopList(train: next, now: entry.date, maxRows: 3, style: style, height: columnHeight)
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
            .padding(.bottom, style.buttonHeight + 8)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The line's bullet, the station, and the direction (both kept within
    /// `textWidth`), the bullet centred on the text.
    private func header(nameLines: Int, style: BoardStyle = .compact, textWidth: CGFloat? = nil) -> some View {
        HStack(alignment: .textMiddle, spacing: style.headerSpacing) {
            LineBullets(routes: entry.selection.routes, size: style.bulletSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.stationName)
                    .font(style.nameFont)
                    .foregroundStyle(Color.boardText)
                    .lineLimit(nameLines)
                    .minimumScaleFactor(style.nameScale)
                Text(entry.heading)
                    .font(style.headingFont)
                    .foregroundStyle(Color.boardGray)
                    .lineLimit(1)
                    .minimumScaleFactor(style.headingScale)
            }
            .frame(maxWidth: textWidth, alignment: .leading)
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
                // A live countdown takes more room than its digits, which would
                // leave a gap before a bullet after it
                .frame(maxWidth: countdownWidth(to: train, size: size), alignment: .leading)
            if marksLive && train.isLive {
                LiveMark(size: size * 0.36)
                    .foregroundStyle(train.statusColor)
            }
        }
    }

    /// How wide the countdown is at the start of the entry, which it never
    /// outgrows as it counts down: "0:00", "00:00", or "0:00:00" past an hour.
    /// Its digits are all the same width.
    private func countdownWidth(to train: Arrival, size: CGFloat) -> CGFloat {
        let seconds = entry.selection.leaveTime(for: train).timeIntervalSince(entry.date)
        // A second early, should the timer round up
        let pattern = seconds >= 3599 ? "0:00:00" : seconds >= 599 ? "00:00" : "0:00"
        let mono = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        let font = mono.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? mono
        // A point to spare, so it's never cut short
        return pattern.width(in: font) + 1
    }

    /// The small widget's "LATER": the train after the next one, counting
    /// down while it's a live prediction, or at its timetable time; then its
    /// bullet where it could be another line.
    private func laterTrain(_ train: Arrival) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("LATER")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardGray)
            HStack(spacing: 3) {
                if marksLive && train.isLive {
                    LiveMark(size: 9).foregroundStyle(train.statusColor)
                }
                Group {
                    if train.isLive {
                        countdown(to: train)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: countdownWidth(to: train, size: 14), alignment: .trailing)
                    } else {
                        Text(train.time.clock)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(train.statusColor)
                if entry.selection.marksLine(of: train) {
                    LineBullet(route: train.route, size: BoardStyle.compact.timeBullet)
                }
            }
            .lineLimit(1)
        }
    }

    /// A train's time right-aligned in `width`, so the colons line up past
    /// 10:00, then its bullet, or (with `bulletSlot`) the empty room for one.
    /// With `liveSlot`, a live train's mark goes before its time, or for one
    /// that isn't live, the room for it, so the times still line up.
    private func timeAndBullet(_ train: Arrival, font: Font, width: CGFloat, bulletSize: CGFloat, bulletSlot: Bool,
                               liveSlot: Bool = false) -> some View {
        HStack(spacing: 3) {
            if liveSlot {
                LiveMark(size: bulletSize * 0.7)
                    .foregroundStyle(train.statusColor)
                    .opacity(train.isLive ? 1 : 0)
                    .accessibilityHidden(!train.isLive)
            }
            Text(train.time.clock)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(train.statusColor)
                // Never cut short, should it come out wider than measured
                .fixedSize()
                .frame(width: width, alignment: .trailing)
            if entry.selection.marksLine(of: train) {
                LineBullet(route: train.route, size: bulletSize)
            } else if bulletSlot {
                Color.clear.frame(width: bulletSize, height: bulletSize)
            }
        }
        .lineLimit(1)
    }

    /// The trains after the next one, up to `count`, with their minutes to go:
    /// the times in a column as wide as the longest, each followed by its
    /// bullet or the room for one, the minutes right after.
    private func laterTrains(_ count: Int, style: BoardStyle) -> some View {
        let shown = Array(later.prefix(count))
        let timeWidth = shown.map { $0.time.clock.width(in: style.timeUIFont) }.max() ?? 0
        let bulletSlot = shown.contains(where: entry.selection.marksLine)
        let liveSlot = marksLive && shown.contains(where: \.isLive)
        let minutesWidth = shown.map { minutesToGo(until: $0).width(in: style.minutesUIFont) }.max() ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            Text("LATER")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardGray)
                .padding(.bottom, style.isLarge ? 0 : 1)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, train in
                HStack(spacing: style.minutesGap) {
                    timeAndBullet(train, font: style.timeFont, width: timeWidth,
                                  bulletSize: style.timeBullet, bulletSlot: bulletSlot, liveSlot: liveSlot)
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

    // MARK: Large

    /// With a change, the change's times or map (see `transfer`); without,
    /// the medium widget's countdown and later trains, or the stops before
    /// yours, with room for more.
    @ViewBuilder private var large: some View {
        if let change = entry.change {
            GeometryReader { geometry in
                transfer(change, width: geometry.size.width)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        } else {
            largeTrain
        }
    }

    private var largeTrain: some View {
        let style = BoardStyle.large
        return VStack(alignment: .leading, spacing: 0) {
            header(nameLines: 1, style: style)
            VStack(alignment: .leading, spacing: 0) {
                if entry.showsMap, let next {
                    ViewThatFits(in: .vertical) {
                        StopList(train: next, now: entry.date, maxRows: 8, style: style)
                        StopList(train: next, now: entry.date, maxRows: 6, style: style)
                        StopList(train: next, now: entry.date, maxRows: 4, style: style)
                    }
                    .padding(.top, 14)
                } else if let next {
                    HStack(spacing: 5) {
                        countdownLabel(to: next, size: style.countdownSize)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(height: style.countdownHeight)
                        if entry.selection.marksLine(of: next) {
                            LineBullet(route: next.route, size: style.countdownBullet)
                        }
                    }
                    .padding(.top, 14)
                    hairline.padding(.top, 12)
                    ViewThatFits(in: .vertical) {
                        laterTrains(8, style: style)
                        laterTrains(6, style: style)
                        laterTrains(4, style: style)
                        laterTrains(2, style: style)
                    }
                    .padding(.top, 8)
                } else {
                    Text(noTrains)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.boardText)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .invalidatableContent()
            buttons(style).padding(.top, 8)
        }
    }

    /// A rule across the widget, under its countdown.
    private var hairline: some View {
        Rectangle()
            .fill(Color.boardText.opacity(0.12))
            .frame(height: 1)
    }

    /// A widget with a change: its line and where it changes to across the
    /// top; the countdown to your next train that gets there, with the train
    /// it meets; under it the later ones: when each leaves, when it gets there,
    /// the wait and the train it meets. Behind the map button, where they are.
    private func transfer(_ change: Change, width: CGFloat) -> some View {
        let style = BoardStyle.large
        let connections = entry.connections ?? []
        let columns = TransferColumns(connections: Array(connections.prefix(6)), width: width, marksLive: marksLive)
        return VStack(alignment: .leading, spacing: 0) {
            transferHeader(change)
            VStack(alignment: .leading, spacing: 0) {
                if let first = connections.first {
                    if entry.showsMap {
                        TransferMap(connection: first, selection: entry.selection, change: change, now: entry.date)
                            .padding(.top, 12)
                    } else {
                        transferHero(first, change: change, columns: columns)
                            .padding(.top, 14)
                        if connections.count > 1 {
                            hairline.padding(.top, 12)
                            ViewThatFits(in: .vertical) {
                                transferList(connections, rows: 5, change: change, columns: columns)
                                transferList(connections, rows: 4, change: change, columns: columns)
                                transferList(connections, rows: 3, change: change, columns: columns)
                                transferList(connections, rows: 2, change: change, columns: columns)
                            }
                            .padding(.top, 8)
                        }
                    }
                } else {
                    Text(entry.problem ?? "No \(entry.lineLabel) trains to \(change.station?.name ?? "the change") predicted")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.boardText)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .invalidatableContent()
            buttons(style).padding(.top, 8)
        }
    }

    /// The line's bullet; "Prospect Av → Atlantic Av-Barclays Ctr"; which way,
    /// and the lines changed to.
    private func transferHeader(_ change: Change) -> some View {
        let style = BoardStyle.large
        return HStack(alignment: .textMiddle, spacing: style.headerSpacing) {
            LineBullets(routes: entry.selection.routes, size: style.bulletSize)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(entry.stationName) \(Text("→").foregroundStyle(Color.boardGray)) \(change.station?.name ?? "")")
                    .font(style.nameFont)
                    .foregroundStyle(Color.boardText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 3) {
                    Text("\(entry.heading), then")
                        .lineLimit(1)
                        .minimumScaleFactor(style.headingScale)
                    ForEach(change.routes, id: \.self) { route in
                        LineBullet(route: route, size: 14)
                    }
                }
                .font(style.headingFont)
                .foregroundStyle(Color.boardGray)
            }
            .alignmentGuide(.textMiddle) { d in
                (d[.firstTextBaseline] - style.nameUIFont.capHeight + d[.lastTextBaseline]) / 2
            }
        }
    }

    /// The countdown to your next train that gets to the change, and when it
    /// leaves; beside it, under the list's wait and train met, the change it
    /// makes: the wait, the train, and how to get to it.
    private func transferHero(_ connection: Connection, change: Change, columns: TransferColumns) -> some View {
        let style = BoardStyle.large
        return ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 4) {
                countdownLabel(to: connection.first, size: style.countdownSize)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: style.countdownHeight)
                Text("\(connection.first.lineLabel) at \(connection.first.time.clock)")
                    .font(.footnote)
                    .foregroundStyle(Color.boardGray)
                    .lineLimit(1)
            }
            .frame(width: max(0, columns.waitX - 8), alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text("CHANGE AT \(change.station?.name.uppercased() ?? "")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.boardGray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 0) {
                    waitCell(connection, quick: connection.isQuick(within: change.quickMinutes))
                        .frame(width: columns.wait)
                    nextCell(connection, columns: columns)
                        .padding(.leading, columns.gap)
                }
                .frame(height: 22)
                Text(howToChange(connection, change: change))
                    .font(.footnote)
                    .foregroundStyle(Color.boardGray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.leading, columns.waitX)
        }
        .invalidatableContent()
    }

    /// "across the platform", or the walk to another one.
    private func howToChange(_ connection: Connection, change: Change) -> String {
        guard let next = connection.next else { return "none predicted yet" }
        return change.isAcross(next.route, from: entry.selection) ? "across the platform" : "\(change.walkMinutes) min walk to it"
    }

    /// The trains after the first that get to the change, up to `rows`, under
    /// their columns' names.
    private func transferList(_ connections: [Connection], rows: Int, change: Change, columns: TransferColumns) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("LEAVE")
                    .fixedSize()
                    .frame(width: columns.leave, alignment: .trailing)
                Text("ARRIVE")
                    .fixedSize()
                    .frame(width: columns.arrive, alignment: .trailing)
                    .padding(.leading, columns.gap)
                Text("WAIT")
                    .fixedSize()
                    .frame(width: columns.wait)
                    .padding(.leading, columns.gap)
                Text(change.isExpress(for: entry.selection) ? "EXPRESS" : "THEN")
                    .fixedSize()
                    .frame(width: columns.next, alignment: .leading)
                    .padding(.leading, columns.gap)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.boardGray)
            .padding(.bottom, 2)
            ForEach(Array(connections.dropFirst().prefix(rows).enumerated()), id: \.offset) { _, connection in
                transferRow(connection, change: change, columns: columns)
            }
        }
    }

    /// One of the later trains: when it leaves, when it gets to the change, the
    /// wait there and the train it meets, on a band when the wait is short.
    private func transferRow(_ connection: Connection, change: Change, columns: TransferColumns) -> some View {
        let style = BoardStyle.large
        let quick = connection.isQuick(within: change.quickMinutes)
        return HStack(spacing: 0) {
            HStack(spacing: 3) {
                if columns.liveSlot {
                    LiveMark(size: TransferColumns.markSize)
                        .foregroundStyle(connection.first.statusColor)
                        .opacity(connection.first.isLive ? 1 : 0)
                        .accessibilityHidden(!connection.first.isLive)
                }
                Text(connection.first.time.clock)
                    .font(style.timeFont)
                    .foregroundStyle(connection.first.statusColor)
                    .fixedSize()
            }
            .frame(width: columns.leave, alignment: .trailing)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardDim)
                .frame(width: columns.gap)
                .accessibilityHidden(true)
            Text(connection.arrival.time.clock)
                .font(style.minutesFont)
                .foregroundStyle(Color.boardGray)
                .fixedSize()
                .frame(width: columns.arrive, alignment: .trailing)
            waitCell(connection, quick: quick)
                .frame(width: columns.wait)
                .padding(.leading, columns.gap)
            nextCell(connection, columns: columns)
                .padding(.leading, columns.gap)
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 26)
        .background {
            if quick {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.boardText.opacity(0.08))
                    .padding(.horizontal, -8)
            }
        }
    }

    /// The wait at the change: on a pill when it's short enough to highlight.
    private func waitCell(_ connection: Connection, quick: Bool) -> some View {
        let fullColor = renderingMode == .fullColor
        return Text(connection.waitLabel)
            .font(.footnote.weight(quick ? .bold : .semibold))
            .monospacedDigit()
            .foregroundStyle(quick && fullColor ? Color.boardBackground : quick ? Color.primary : Color.boardGray)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background {
                if quick {
                    // Tinted and clear Home Screens draw a widget in one colour,
                    // which would fill the pill over its text
                    if fullColor {
                        Capsule().fill(Color.boardText)
                    } else {
                        Capsule().strokeBorder(lineWidth: 1.5)
                    }
                }
            }
            .widgetAccentable(quick)
            .fixedSize()
            .accessibilityLabel(connection.waitMinutes.map { "\($0) minute wait" } ?? "No train to change to")
    }

    /// The train met at the change: its bullet, then its time, the times lined up.
    private func nextCell(_ connection: Connection, columns: TransferColumns) -> some View {
        let style = BoardStyle.large
        return HStack(spacing: 5) {
            if let next = connection.next {
                LineBullet(route: next.route, size: style.timeBullet)
                Text(next.time.clock)
                    .font(style.timeFont)
                    .monospacedDigit()
                    .foregroundStyle(next.statusColor)
                    .fixedSize()
                    .frame(width: columns.nextTime, alignment: .trailing)
            } else {
                Color.clear.frame(width: style.timeBullet, height: style.timeBullet)
                Text("–")
                    .font(style.timeFont)
                    .foregroundStyle(Color.boardGray)
                    .frame(width: columns.nextTime, alignment: .trailing)
            }
        }
        .lineLimit(1)
        .frame(width: columns.next, alignment: .leading)
    }

    /// ↻, the medium widget's map button, and the walk button, which starts or
    /// stops the countdown to this widget's train, sharing the row equally. Each
    /// lights up in the line's colour: ↻ just after it's tapped, map while the
    /// stops show, walk while the countdown runs.
    private func buttons(_ style: BoardStyle) -> some View {
        HStack(spacing: 6) {
            RefreshButton(lit: entry.refreshLit ? LineStyle.of(entry.selection.firstRoute) : nil, fills: true,
                          widgetsOnly: !entry.anyCountdown, large: style.isLarge)
            // While the alert shows in full there are no times to swap for the stops
            if family != .systemSmall && !alertOpen {
                MapButton(selection: entry.selection, isOn: entry.showsMap, large: style.isLarge)
            }
            WalkButton(intent: ToggleCountdownIntent(selection: entry.selection), route: entry.selection.firstRoute,
                       isOn: entry.countingDown, fills: true, large: style.isLarge)
        }
    }

    /// The alert across the top of the widget, edge to edge, in its colour,
    /// with a chevron: tapping it shows the alert in full, or the times again.
    /// Tinted and clear Home Screens draw a widget in one colour, which would
    /// fill the banner over its text, so there it's a faint band instead.
    private func banner(_ notice: Notice) -> some View {
        let fullColor = renderingMode == .fullColor
        return Button(intent: ToggleAlertIntent(selection: entry.selection)) {
            HStack(spacing: 5) {
                Image(systemName: notice.symbol)
                    .widgetAccentable()
                // Open, the alert's text is below, so just its kind
                (alertOpen ? Text(notice.label).bold() : notice.bannerText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: alertOpen ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .opacity(0.7)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(fullColor ? notice.bannerForeground : Color.primary)
            .padding(.leading, margins.leading)
            .padding(.trailing, margins.trailing)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .background(fullColor ? notice.tint : Color.primary.opacity(0.15))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(alertOpen ? "Shows the train times" : "Shows the whole alert")
    }

    /// The alert in full under its banner, as much as fits; under it the next
    /// train's countdown, how many more alerts there are, and "More ›", for
    /// the app, which has every alert's details; and ↻ and walk.
    private func fullAlert(_ notice: Notice) -> some View {
        let style: BoardStyle = entry.largeText ? .large : .compact
        return VStack(alignment: .leading, spacing: 0) {
            Text(notice.text.isEmpty ? notice.label : notice.text)
                .font(style.isLarge ? .subheadline.weight(.semibold) : .footnote.weight(.semibold))
                .foregroundStyle(Color.boardText)
                // As many lines as there's room for, then "…"
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                if let next {
                    HStack(spacing: 3) {
                        countdownLabel(to: next, size: style.isLarge ? 17 : 15)
                        if entry.selection.marksLine(of: next) {
                            LineBullet(route: next.route, size: style.isLarge ? 15 : 13)
                        }
                    }
                    .invalidatableContent()
                }
                if notice.others > 0, family != .systemSmall {
                    Text("+\(notice.others) more")
                        .foregroundStyle(Color.boardGray)
                }
                Spacer(minLength: 0)
                Text("More ›")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.boardText)
            }
            .font(.caption)
            .lineLimit(1)
            buttons(style).padding(.top, family == .systemSmall ? 10 : 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// The large widget's columns for a change: when each train leaves, when it
/// gets there, the wait, and the train it meets, each as wide as its widest,
/// with even gaps across the widget.
private struct TransferColumns {
    let leave: CGFloat
    let arrive: CGFloat
    let wait: CGFloat
    /// The bullet and time of the train met.
    let next: CGFloat
    let nextTime: CGFloat
    let gap: CGFloat
    /// Room for a live mark before the time a train leaves.
    let liveSlot: Bool

    static let markSize: CGFloat = 11

    init(connections: [Connection], width: CGFloat, marksLive: Bool) {
        let style = BoardStyle.large
        let pillFont = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                                                        weight: .bold)
        let liveSlot = marksLive && connections.contains(where: { $0.first.isLive })
        let mark: CGFloat = liveSlot ? Self.markSize + 3 : 0
        let leave = (connections.map { $0.first.time.clock.width(in: style.timeUIFont) }.max() ?? 0) + mark
        let arrive = connections.map { $0.arrival.time.clock.width(in: style.minutesUIFont) }.max() ?? 0
        // The pill's text and its padding
        let wait = (connections.map { $0.waitLabel.width(in: pillFont) }.max() ?? 0) + 14
        let nextTime = connections.compactMap { $0.next?.time.clock.width(in: style.timeUIFont) }.max()
            ?? "0:00".width(in: style.timeUIFont)
        let next = style.timeBullet + 5 + nextTime
        self.liveSlot = liveSlot
        self.leave = leave
        self.arrive = arrive
        self.wait = wait
        self.nextTime = nextTime
        self.next = next
        gap = max(8, (width - leave - arrive - wait - next) / 3)
    }

    /// Where the wait starts, from the left.
    var waitX: CGFloat { leave + gap + arrive + gap }
}

extension Notice {
    /// What the banner says: "**Delays** · R trains are delayed…", or
    /// "**Elevator out** · street to Manhattan-bound platform". The kind
    /// comes first, so it shows however much of the rest is cut short.
    var bannerText: Text {
        text.isEmpty ? Text(label).bold() : Text("\(Text(label).bold()) · \(text)")
    }

    /// Black on orange, white on the blue of a plain notice.
    var bannerForeground: Color {
        if case .alert(.notice) = kind { return .white }
        return .black
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

    /// A D running on the R first, then an R, an N on the R, an R and another
    /// D: rows with and without bullets, for their times to line up.
    static var mixed: [Arrival] {
        let now = Date.now
        return [(1.1, "D"), (10, "R"), (17, "N"), (24, "R"), (45, "D")].map { minutes, route in
            Arrival(route: route, time: now.addingTimeInterval(minutes * 60), stop: "R34N",
                    lastStop: route == "R" ? "G08N" : route == "N" ? "R01N" : "D01N",
                    isLive: minutes < 20, approach: [], position: nil)
        }
    }

    /// The R from Prospect Av, changing at Atlantic Av-Barclays Ctr to the D or
    /// N, for the large widget: a quick change first, then a longer wait.
    static func transferPreview(showsMap: Bool = false) -> TrainEntry {
        let now = Date.now
        let leaving: [Double] = [3.2, 10, 17, 26, 33, 41]
        let waits: [Double] = [1, 4, 1, 2, 4, 1]
        let lines = ["D", "D", "N", "N", "N", "D"]
        let connections = leaving.indices.map { index -> Connection in
            let at = { (minutes: Double) in now.addingTimeInterval((leaving[index] + minutes) * 60) }
            let live = leaving[index] < 20
            // From 25 St, through Prospect Av, 4 Av-9 St and Union St, to Atlantic Av
            let approach = [("R35N", -1.5), ("R34N", 0.0), ("R33N", 2.0), ("R32N", 4.0), ("R31N", 6.0)].map {
                Arrival.Stop(id: $0.0, time: at($0.1))
            }
            let first = Arrival(route: "R", time: at(0), stop: "R34N", lastStop: "G08N", isLive: live, trip: "R\(index)")
            let arrival = Arrival(route: "R", time: at(6), stop: "R31N", lastStop: "G08N", isLive: live, trip: "R\(index)",
                                  approach: approach)
            // Express from 36 St
            let meets = at(6 + waits[index])
            let next = Arrival(route: lines[index], time: meets, stop: "R31N", lastStop: lines[index] == "D" ? "D01N" : "R01N",
                               isLive: live, trip: "X\(index)",
                               approach: [Arrival.Stop(id: "R36N", time: meets.addingTimeInterval(-6 * 60)),
                                          Arrival.Stop(id: "R31N", time: meets)])
            return Connection(first: first, arrival: arrival, next: next)
        }
        return TrainEntry(date: now, selection: .fallback, trains: connections.map(\.first), showsMap: showsMap,
                          connections: connections, change: Change(stationID: "R31", routes: ["D", "N"]))
    }

    /// Settings › Larger widget text and Mark live times.
    static var accessible: AppSettings {
        var settings = AppSettings()
        settings.largerWidgetText = true
        settings.marksLiveTimes = true
        return settings
    }

    static let delays = Notice(kind: .alert(.delays), label: "Delays",
                               text: "Downtown F trains are running local from Forest Hills-71 Av to 21 St-Queensbridge while we address a signal problem at 36 St",
                               others: 1)
}

#Preview(as: .systemSmall) {
    RTrainWidget()
} timeline: {
    TrainEntry.preview
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains,
               notice: Notice(kind: .alert(.delays), label: "Delays", text: "", others: 0),
               countingDown: true, refreshLit: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.delays)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed)
    // After a tap on the banner
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.delays, showsAlert: true)
    // Larger text and marked live times
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, settings: TrainEntry.accessible)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, settings: TrainEntry.accessible)
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
    // A D, an R, then an N, all on the R's track
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.delays, largeText: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, largeText: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.delays)
    // After a tap on the banner
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.delays, showsAlert: true, largeText: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.delays, showsAlert: true)
    // Marked live times, compact and large
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, settings: TrainEntry.accessible)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, largeText: true, settings: TrainEntry.accessible)
}

#Preview(as: .systemLarge) {
    RTrainWidget()
} timeline: {
    TrainEntry.transferPreview()
    TrainEntry.transferPreview(showsMap: true)
    // Without a change
    TrainEntry.preview
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, showsMap: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.delays, largeText: true)
}
