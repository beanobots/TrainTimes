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
        .description("Live times for a widget set up in the app. Pick which one in its Edit menu.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        // The alert banner runs edge to edge; TrainWidgetView puts the
        // margins back everywhere else
        .contentMarginsDisabled()
    }
}

/// Your next changes of trains, for a widget set up in the app with a change:
/// the next two on the medium widget, the next one big and three more on the
/// large. It sits beside the Next train widget, whose medium shows one train.
struct TransfersWidget: Widget {
    let kind = "TransfersWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TrainWidgetIntent.self, provider: Provider(transfers: true)) { entry in
            TrainWidgetView(entry: entry)
                .containerBackground(Color.boardBackground, for: .widget)
        }
        .configurationDisplayName("Transfers")
        .description("Your next changes of trains and the wait for each, for a widget set up with a change in the app.")
        .supportedFamilies([.systemMedium, .systemLarge])
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
    /// Whether the Lock Screen countdown is this widget's: for its train,
    /// started by its walk button or in the app. Only the app can refresh it,
    /// so then ↻ goes through the app.
    var countingDown = false
    /// Whether the medium widget shows the stops before yours instead of the later trains.
    var showsMap = false
    /// Whether the home screen widgets show their alert in full, after a tap
    /// on its banner, instead of the times.
    var showsAlert = false
    /// Which widget this is, for its buttons to change it and no other; see
    /// `Provider.widgetID`.
    var widgetID = ""
    /// A medium widget with room for larger text, or with Settings › Larger
    /// widget text; see `BoardStyle`.
    var largeText = false
    /// The app's Settings, for larger text and marking live times.
    var settings = AppSettings()
    /// On the Transfers widget, the trains still to catch that get to the
    /// change, each with the train it meets; nil without a change.
    var connections: [Connection]? = nil
    /// The Transfers widget's change of trains, if its saved widget has one.
    var change: Change? = nil
    /// Whether this is the Transfers widget rather than Next train.
    var transfers = false
    /// When the times were fetched, when they're the last ones because a
    /// reload couldn't reach the MTA; nil while they're up to date.
    var notUpdatedSince: Date? = nil

    var stationName: String { selection.station?.name ?? "Choose a station" }
    var heading: String { selection.heading }
    /// "R", or "N/R" with more than one line chosen.
    var lineLabel: String { selection.linesLabel }
}

struct Provider: AppIntentTimelineProvider {
    /// For the Transfers widget rather than Next train.
    var transfers = false

    func placeholder(in context: Context) -> TrainEntry {
        transfers ? .transferPreview() : .preview
    }

    func snapshot(for configuration: TrainWidgetIntent, in context: Context) async -> TrainEntry {
        if context.isPreview { return placeholder(in: context) }
        let (selection, change, _) = choice(configuration)
        return await Self.plan(for: selection, change: change, transfers: transfers, family: context.family,
                               largeText: Self.hasRoom(context), widgetID: widgetID(configuration, context)).entries[0]
    }

    func timeline(for configuration: TrainWidgetIntent, in context: Context) async -> Timeline<TrainEntry> {
        let (selection, change, switches) = choice(configuration)
        let plan = await Self.plan(for: selection, change: change, transfers: transfers, family: context.family,
                                   largeText: Self.hasRoom(context), widgetID: widgetID(configuration, context))
        // iOS rations how often widgets reload, so this may come later;
        // until it does, the entries step through the trains already known.
        let now = Date.now
        var reload = now.addingTimeInterval(2 * 60)
        if let fetched = plan.fetched {
            // Counted from when the times were fetched, as they may be ones
            // another widget fetched a while ago
            reload = fetched.addingTimeInterval(Self.reloadInterval(at: now))
        }
        // And sooner if the entries run out of trains first, rather than say there are none
        if let runsOut = plan.runsOut { reload = min(reload, runsOut) }
        // As commuting hours start or end, for the other train
        if let switches { reload = min(reload, switches) }
        reload = max(reload, now.addingTimeInterval(60))
        return Timeline(entries: plan.entries, policy: .after(reload))
    }

    /// A timeline's entries, with what its reload goes by.
    private struct Plan {
        var entries: [TrainEntry]
        /// When its times were fetched; nil if new ones couldn't be.
        var fetched: Date?
        /// The last entry's date, after which the widget knows of no train to show.
        var runsOut: Date?
    }

    /// How long to wait for new times: 5 minutes, about as often as iOS
    /// reloads a widget, from 6 am to 11 pm in New York; 15 overnight. A
    /// widget's reloads are budgeted by the day, so fewer at night leaves
    /// more for the day.
    static func reloadInterval(at date: Date) -> TimeInterval {
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

    /// Which widget this is, as near as WidgetKit lets on: its kind, its size
    /// and what its Edit menu has. Two alike in all three can't be told apart,
    /// so they change together.
    private func widgetID(_ configuration: TrainWidgetIntent, _ context: Context) -> String {
        let kind = transfers ? "TransfersWidget" : "RTrainWidget"
        let chosen = configuration.widget.map { "widget \($0.id)" }
            ?? [configuration.station?.id, configuration.line?.id, configuration.direction?.id, configuration.stop?.id]
                .map { $0 ?? "-" }.joined(separator: ",")
        return "\(kind) \(context.family) \(chosen)"
    }

    /// The train the widget shows now, and for the Transfers widget where it
    /// changes: that one's saved widget's, as `TrainWidgetIntent.transfersWidget`
    /// has it. In its commuting hours, theirs; and when they next start or end.
    private func choice(_ configuration: TrainWidgetIntent) -> (Selection, Change?, switches: Date?) {
        let now = Date.now
        guard transfers else {
            let (selection, switches) = configuration.selection(at: now)
            return (selection, nil, switches)
        }
        let widget = configuration.transfersWidget(in: SharedStore.loadWidgets())
        let shown = widget.shown(at: now)
        return (shown.selection, shown.change, widget.commute?.nextSwitch(after: now))
    }

    /// One entry for now, then one as each train's time to leave passes (its
    /// arrival, without a walking time), so the widget moves on to the next
    /// train you can catch without going back to the network; with a change,
    /// the next that gets there. The medium and large widgets also get one a
    /// minute, for their later trains' minutes to go and their maps. When the
    /// MTA can't be reached, the times last fetched, while any of them is
    /// still to catch, said to be old.
    private static func plan(for selection: Selection, change: Change?, transfers: Bool, family: WidgetFamily,
                             largeText: Bool, widgetID: String) async -> Plan {
        let countdown = SharedStore.loadCountdown().flatMap { $0.ends > .now ? $0 : nil }
        let countingDown = countdown?.isShown(onWidget: widgetID, for: selection.trainID) ?? false
        let hasMap = family == .systemMedium || family == .systemLarge
        let showsMap = hasMap && SharedStore.showsMap(for: selection.trainID, in: widgetID)
        let showsAlert = (family == .systemSmall || hasMap) && SharedStore.showsAlert(for: selection.alertID, in: widgetID)
        let settings = SharedStore.loadSettings()
        let taps = SharedStore.loadTaps(for: widgetID)
        let board: SharedStore.SavedBoard
        let updated: Bool
        do {
            board = try await Self.board(for: selection, change: change, taps: taps)
            updated = true
        } catch {
            guard let saved = SharedStore.loadBoard(for: selection, change: change),
                  Self.anyToCatch(in: saved, selection: selection, change: change, now: .now) else {
                return Plan(entries: [TrainEntry(date: .now, selection: selection, trains: [], problem: "Couldn't reach the MTA",
                                                 countingDown: countingDown, showsMap: showsMap,
                                                 widgetID: widgetID, largeText: largeText, settings: settings, change: change, transfers: transfers)])
            }
            board = saved
            updated = false
        }
        // Once the alert's over, the next one starts out closed
        if board.notice == nil {
            SharedStore.closeAlert(for: selection.alertID, in: widgetID)
        }
        // After the fetch, so the entries start when they're shown
        let now = Date.now
        let trains = selection.catchable(board.trains, now: now)
        let connections = selection.catchable(board.connections ?? [], now: now)
        let entry = { (date: Date) -> TrainEntry in
            // Where the feed said the train was soon goes out of date; after
            // a minute, the maps go by when it's due at each stop
            let positionStale = date.timeIntervalSince(board.fetched) > 60
            let shown = selection.catchable(trains, now: date).enumerated().map { index, train in
                var train = train
                // Only the map shows a train's stops, and only the next
                // train's; the timeline holds many entries, in the widget's
                // little memory, so no other train keeps them. The medium
                // and large widgets keep them with the map off too, as their
                // map button swaps to them before the widget reloads
                if !hasMap || index > 0 { train.approach = [] }
                if positionStale { train.position = nil }
                return train
            }
            return TrainEntry(date: date, selection: selection, trains: shown, notice: board.notice,
                              problem: updated ? nil : "Couldn't reach the MTA", countingDown: countingDown,
                              showsMap: showsMap, showsAlert: showsAlert, widgetID: widgetID,
                              largeText: largeText, settings: settings,
                              connections: change == nil ? nil : Self.shown(connections, at: date, selection: selection,
                                                                             keepsStops: hasMap, keepsPosition: !positionStale),
                              change: change, transfers: transfers,
                              notUpdatedSince: updated ? nil : board.fetched)
        }
        // With a change, the trains that get there are the ones to catch
        let toCatch = (change == nil ? trains : connections.map(\.first)).prefix(10)
        let leaveTimes = toCatch.map(selection.leaveTime(for:))
        // A train held at the platform can still be caught after its leave time, until it leaves
        let lastLeaveTimes = toCatch.map(selection.lastLeaveTime(for:))
        var dates = Set(leaveTimes + lastLeaveTimes)
        if hasMap, let lastLeave = leaveTimes.last {
            let end = min(lastLeave, now.addingTimeInterval(60 * 60))
            var minute = now.addingTimeInterval(60)
            while minute < end {
                dates.insert(minute)
                minute.addTimeInterval(60)
            }
        }
        let entries = [entry(now)] + dates.filter { $0 > now }.sorted().map(entry)
        // Without new times, it tries again soon
        return Plan(entries: entries, fetched: updated ? board.fetched : nil, runsOut: lastLeaveTimes.max())
    }

    /// The connections still to catch at `date`. Only the maps show where the
    /// trains are, and only the first's; the timeline holds many entries, in
    /// the widget's little memory, so no other keeps their stops. The first
    /// keeps them with the map off too, as the map button swaps to them
    /// before the widget reloads. Without `keepsPosition`, the maps go by
    /// when the trains are due at each stop.
    private static func shown(_ connections: [Connection], at date: Date, selection: Selection,
                              keepsStops: Bool, keepsPosition: Bool) -> [Connection] {
        selection.catchable(connections, now: date).enumerated().map { index, connection in
            var connection = connection
            if !keepsStops || index > 0 {
                connection.first.approach = []
                connection.arrival.approach = []
                connection.next?.approach = []
            }
            if !keepsPosition {
                connection.first.position = nil
                connection.arrival.position = nil
                connection.next?.position = nil
            }
            return connection
        }
    }

    /// Whether any of `saved`'s trains (with `change`, those that get there) is still to catch.
    private static func anyToCatch(in saved: SharedStore.SavedBoard, selection: Selection, change: Change?,
                                   now: Date) -> Bool {
        change == nil
            ? !selection.catchable(saved.trains, now: now).isEmpty
            : !selection.catchable(saved.connections ?? [], now: now).isEmpty
    }

    /// The trains and alert for `selection`, with `change` those of the large
    /// widget showing it, fetched; or, to redraw at once, ones fetched in the
    /// last 30 seconds (by another widget, or the countdown). After a tap on
    /// the map or walk button or the alert banner, which changes only how the
    /// widget looks, the ones it already shows, however old, while any of
    /// their trains is still to catch; the widget reloads a minute later, as
    /// they're old. Never ones from before this widget's ↻.
    private static func board(for selection: Selection, change: Change?,
                              taps: SharedStore.Taps) async throws -> SharedStore.SavedBoard {
        let now = Date.now
        if let saved = SharedStore.loadBoard(for: selection, change: change),
           saved.fetched > taps.refreshed ?? .distantPast {
            if now.timeIntervalSince(saved.fetched) < 30 { return saved }
            let toggled = taps.toggled.map { now.timeIntervalSince($0) < 30 } ?? false
            if toggled && anyToCatch(in: saved, selection: selection, change: change, now: now) { return saved }
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

/// Draws a toggle's part of the widget for its state, which iOS flips the
/// moment it's tapped, before the widget reloads, so what it shows changes at
/// once. The one button in it flips it. WidgetKit doesn't tell controls inside
/// a toggle apart from the toggle, so no other control is ever inside one; see
/// `TrainWidgetView.body`.
private struct SwapToggleStyle<Content: View>: ToggleStyle {
    @ViewBuilder let content: (Binding<Bool>) -> Content

    func makeBody(configuration: Configuration) -> some View {
        content(configuration.$isOn)
    }
}

extension TrainEntry {
    /// This entry with `value` at `keyPath`.
    fileprivate func with<Value>(_ keyPath: WritableKeyPath<TrainEntry, Value>, _ value: Value) -> TrainEntry {
        var entry = self
        entry[keyPath: keyPath] = value
        return entry
    }
}

struct TrainWidgetView: View {
    /// What a home screen widget's view draws: all of it, in layers, or one
    /// of its layers' pictures of it.
    enum Drawing {
        case whole
        /// The times (or the stops), with the map button in the map's toggle.
        case times
        /// Inside the alert banner's toggle: the alert or the times as they'll
        /// be once the widget reloads, with no controls.
        case picture
    }

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetContentMargins) private var margins
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    let entry: TrainEntry
    var drawing = Drawing.whole
    /// Inside the map's toggle, its state, which the map button flips.
    var mapSwitch: Binding<Bool>? = nil
    /// Whether the map button was just tapped and the widget hasn't reloaded
    /// yet; it's lit until then.
    var mapPending = false

    /// Whether live times get their symbol as well as their green: always
    /// where the widget is drawn in one colour, as on tinted and clear Home
    /// Screens and StandBy at night, which would leave out the green.
    private var marksLive: Bool { withoutColor || renderingMode != .fullColor || entry.settings.marksLiveTimes }
    /// Whether timetable times get their symbol.
    private var marksScheduled: Bool { entry.settings.marksScheduledTimes }

    private var next: Arrival? { entry.trains.first }
    private var later: ArraySlice<Arrival> { entry.trains.dropFirst() }
    /// With a walking time, the countdown is to when to leave.
    private var walking: Bool { entry.selection.walkMinutes > 0 }
    private var noTrains: String { entry.problem ?? "No \(entry.lineLabel) trains predicted" }

    /// Whether the alert shows in full, in place of the times.
    private var alertOpen: Bool { entry.showsAlert && entry.notice != nil }

    /// The home screen widgets, which have buttons.
    private var onHomeScreen: Bool { family == .systemSmall || family == .systemMedium || family == .systemLarge }

    /// The medium and large widgets, which have a map button.
    private var hasMap: Bool { family == .systemMedium || family == .systemLarge }

    /// The Transfers widget without a change has no buttons.
    private var hasButtons: Bool { !(entry.transfers && entry.change == nil) }

    /// The home screen widgets are three layers, each with its own controls
    /// and none inside another's, so a tap runs only what was tapped and
    /// shows at once: the times, with the map's toggle around them; over them
    /// the alert banner's toggle, which draws the alert under it when open;
    /// and on top ↻ and walk. Every layout ends in the same row of buttons,
    /// so each layer leaves the others' slots in it empty.
    @ViewBuilder var body: some View {
        if !onHomeScreen {
            content.padding(margins)
        } else if drawing == .whole {
            ZStack(alignment: .top) {
                timesLayer
                if let notice = entry.notice {
                    alertLayer(notice)
                }
                if hasButtons {
                    controlsLayer
                }
            }
            .widgetURL(tapURL)
        } else {
            board
        }
    }

    /// Where a tap on the widget, off its buttons, goes: the open alert to
    /// the train's alerts; the Transfers widget to the times at both stations.
    private var tapURL: URL? {
        if alertOpen { return entry.selection.alertsURL }
        if entry.transfers, let change = entry.change { return entry.selection.transferURL(changingAt: change) }
        return nil
    }

    /// The times, with the alert closed. While it's open the alert layer
    /// draws the widget, so there's no times layer, nor its map button.
    @ViewBuilder private var timesLayer: some View {
        let times = entry.with(\.showsAlert, false)
        if alertOpen {
            EmptyView()
        } else if hasMap {
            Toggle(isOn: entry.showsMap, intent: ToggleMapIntent(selection: entry.selection, widgetID: entry.widgetID)) {
                Text("Where the train is")
            }
            .toggleStyle(SwapToggleStyle { isOn in
                TrainWidgetView(entry: times.with(\.showsMap, isOn.wrappedValue), drawing: .times,
                                mapSwitch: isOn, mapPending: isOn.wrappedValue != entry.showsMap)
            })
        } else {
            TrainWidgetView(entry: times, drawing: .times)
        }
    }

    /// The banner; under it, open, the alert, and closing, the times, until
    /// the widget reloads and the times layer has them. Opening, the alert
    /// covers the times until then.
    private func alertLayer(_ notice: Notice) -> some View {
        Toggle(isOn: entry.showsAlert, intent: ToggleAlertIntent(selection: entry.selection, widgetID: entry.widgetID)) {
            Text("The whole alert")
        }
        .toggleStyle(SwapToggleStyle { isOn in
            let open = isOn.wrappedValue
            ZStack(alignment: .top) {
                if open || alertOpen {
                    TrainWidgetView(entry: entry.with(\.showsAlert, open), drawing: .picture)
                        .background {
                            if open && !alertOpen { Color.boardBackground }
                        }
                }
                Button { isOn.wrappedValue.toggle() } label: {
                    bannerFace(notice, open: open)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(open ? "Shows the train times" : "Shows the whole alert")
            }
            .frame(maxHeight: .infinity, alignment: .top)
        })
    }

    /// ↻ and walk, in their slots of the row of buttons.
    private var controlsLayer: some View {
        let style = rowStyle
        return HStack(spacing: 6) {
            RefreshButton(route: entry.selection.firstRoute, fills: true,
                          widgetsOnly: !entry.countingDown, large: style.isLarge, widgetID: entry.widgetID,
                          failed: entry.notUpdatedSince != nil)
            if hasMap {
                Pill(symbol: "map", fills: true, large: style.isLarge).hidden()
            }
            WalkButton(intent: ToggleCountdownIntent(selection: entry.selection, widgetID: entry.widgetID), route: entry.selection.firstRoute,
                       running: entry.countingDown, fills: true, large: style.isLarge)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(EdgeInsets(top: 0, leading: margins.leading, bottom: margins.bottom, trailing: margins.trailing))
    }

    /// The size of the row of buttons, as each layout has it.
    private var rowStyle: BoardStyle {
        family == .systemSmall ? .compact : entry.largeText ? .large : .compact
    }

    /// One layer's picture of the widget. The home screen widgets give an
    /// alert a banner across the top, in place of the top margin; the alert
    /// layer draws it, so here it only keeps its room.
    private var board: some View {
        VStack(spacing: 0) {
            if let notice = entry.notice {
                bannerFace(notice, open: alertOpen).hidden()
            }
            Group {
                if alertOpen, let notice = entry.notice {
                    fullAlert(notice)
                } else {
                    content
                }
            }
            .padding(entry.notice == nil ? margins
                     : EdgeInsets(top: 8, leading: margins.leading, bottom: margins.bottom, trailing: margins.trailing))
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
                        lockScreenCountdown(to: next, alignment: .center, saysAt: true)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
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
                        // Dimmed, it's a time of day rather than a countdown
                        if walking {
                            Text(luminanceReduced ? "Leave at" : "Leave in").font(.caption)
                        } else if luminanceReduced {
                            Text("at").font(.caption)
                        }
                        lockScreenCountdown(to: next, alignment: .leading)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                    }
                    if let since = entry.notUpdatedSince {
                        Label("Not updated since \(since.clock)", systemImage: "wifi.slash").font(.caption)
                    } else if let notice = entry.notice {
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
            if entry.transfers {
                transfers
            } else {
                medium
            }
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
                let size: CGFloat = larger ? (marks ? 38 : 44) : (marks ? 28 : 32)
                if let after {
                    // The train after it only while the countdown keeps most
                    // of its size beside it: a time past 10:00 can leave it
                    // too little
                    ViewThatFits(in: .horizontal) {
                        countdownRow(to: next, size: size, after: after)
                        countdownRow(to: next, size: size, after: nil)
                    }
                } else {
                    countdownRow(to: next, size: size, after: nil)
                }
            } else {
                Text(noTrains)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boardText)
            }
            buttons(.compact).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The small widget's countdown and its train's bullet, then `after` it,
    /// the train after that, on the right. With one, the countdown gives up as
    /// much as 30% of its width before a `ViewThatFits` leaves it out.
    private func countdownRow(to next: Arrival, size: CGFloat, after: Arrival?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                // The live mark goes over the bullet, not beside it, to
                // leave the countdown room
                countdownLabel(to: next, size: size, showsMark: false, shrinksTo: after == nil ? 1 : 0.7)
                markAndBullet(next, bulletSize: BoardStyle.compact.timeBullet)
            }
            Spacer(minLength: 0)
            if let after {
                laterTrain(after)
            }
        }
    }

    /// The station across the top; the countdown on the left; on the right the
    /// trains after it, or behind the map button the stops before yours; and
    /// ↻, map and walk. Larger on bigger phones.
    private var medium: some View {
        GeometryReader { geometry in
            mediumLayout(size: geometry.size, style: entry.largeText ? .large : .compact, train: next)
                // Should larger text, under a banner, make it taller than the
                // widget, it runs off the top rather than moving the map
                // button off its slot between ↻ and walk
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
        }
    }

    /// `train` is the one counted down to and, behind the map button, whose
    /// stops are listed; `heading` is in place of the direction.
    private func mediumLayout(size: CGSize, style: BoardStyle, train next: Arrival?, heading: String? = nil) -> some View {
        let textLeft = LineBullets.width(count: entry.selection.routes.count, size: style.bulletSize) + style.headerSpacing
        // The column on the right starts at the top, beside the station and
        // direction, which end short of it
        let textRoom = size.width - style.columnWidth - style.columnGap - textLeft
        // From the top down to the buttons
        let columnHeight = size.height - style.buttonHeight - 8
        let rows = style.columnRows
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                header(nameLines: 1, style: style, textWidth: textRoom, heading: heading)
                VStack(alignment: .leading, spacing: 2) {
                    Spacer(minLength: 0)
                    if let next {
                        HStack(spacing: style.isLarge ? 5 : 4) {
                            countdownLabel(to: next, size: style.countdownSize, showsMark: false)
                                // Its full line height is taller than the row; offered
                                // only the row, it would shrink to fit
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(height: style.countdownHeight)
                            markAndBullet(next, bulletSize: style.countdownBullet)
                        }
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
            column(showsStops: entry.showsMap, train: next, rows: rows, style: style, height: columnHeight)
                .padding(.bottom, style.buttonHeight + 8)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The medium widget's column on the right: the later trains, or the
    /// stops before yours. They start in the same place, so their labels line
    /// up; down to the buttons. Shorter widgets (an iPhone SE's), and larger
    /// text, get fewer rows. The stops spread out to fill it.
    @ViewBuilder
    private func column(showsStops: Bool, train next: Arrival?, rows: Int, style: BoardStyle,
                        height: CGFloat) -> some View {
        Group {
            if showsStops, let next {
                ViewThatFits(in: .vertical) {
                    StopList(train: next, now: entry.date, maxRows: rows, style: style, height: height)
                    StopList(train: next, now: entry.date, maxRows: max(3, rows - 1), style: style, height: height)
                    StopList(train: next, now: entry.date, maxRows: 3, style: style, height: height)
                }
            } else {
                ViewThatFits(in: .vertical) {
                    laterTrains(rows, style: style)
                    laterTrains(rows - 1, style: style)
                    laterTrains(rows - 2, style: style)
                    laterTrains(max(1, rows - 3), style: style)
                }
            }
        }
        .frame(width: style.columnWidth, alignment: .topLeading)
    }

    /// The line's bullet, the station, and the direction (both kept within
    /// `textWidth`), the bullet centred on the text.
    private func header(nameLines: Int, style: BoardStyle = .compact, textWidth: CGFloat? = nil,
                        heading: String? = nil) -> some View {
        HStack(alignment: .textMiddle, spacing: style.headerSpacing) {
            LineBullets(routes: entry.selection.routes, size: style.bulletSize)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.stationName)
                    .font(style.nameFont)
                    .foregroundStyle(Color.boardText)
                    .lineLimit(nameLines)
                    .minimumScaleFactor(style.nameScale)
                Text(heading ?? entry.heading)
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

    /// The countdown, after a walker when it's to when to leave. Below 1,
    /// `shrinksTo` is the share of its width it asks for, so that a
    /// `ViewThatFits` measuring it leaves the rest to what's beside it; it
    /// shrinks to fit what it's given.
    private func countdownLabel(to train: Arrival, size: CGFloat, showsMark: Bool = true,
                                shrinksTo: CGFloat = 1) -> some View {
        let width = countdownWidth(to: train, size: size)
        let shrinks = shrinksTo < 1
        return HStack(spacing: 3) {
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
                .frame(minWidth: shrinks ? 0 : nil, idealWidth: shrinks ? width * shrinksTo : nil, maxWidth: width,
                       alignment: .leading)
            if showsMark {
                statusMark(train, size: size * 0.36)
            }
        }
    }

    /// A live train's mark, or a timetable train's, as marked.
    @ViewBuilder
    private func statusMark(_ train: Arrival, size: CGFloat) -> some View {
        if marksLive && train.isLive {
            LiveMark(size: size).foregroundStyle(train.statusColor)
        } else if marksScheduled && !train.isLive {
            ScheduledMark(size: size).foregroundStyle(train.statusColor)
        }
    }

    /// A train's mark stacked over its bullet, where it could be another line,
    /// so the two take one bullet's width.
    private func markAndBullet(_ train: Arrival, bulletSize: CGFloat) -> some View {
        VStack(spacing: 1) {
            statusMark(train, size: bulletSize * 0.7)
            if entry.selection.marksLine(of: train) {
                LineBullet(route: train.route, size: bulletSize)
            }
        }
    }

    /// How wide the countdown is at the start of the entry, which it never
    /// outgrows as it counts down: "0:00", "00:00", or "0:00:00" past an hour.
    /// Its digits are all the same width.
    private func countdownWidth(to train: Arrival, size: CGFloat) -> CGFloat {
        let mono = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        let font = mono.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? mono
        return countdownWidth(to: train, in: font)
    }

    /// How wide the countdown is in `font`, with its digits all the same width.
    private func countdownWidth(to train: Arrival, in font: UIFont) -> CGFloat {
        let seconds = entry.selection.leaveTime(for: train).timeIntervalSince(entry.date)
        // A second early, should the timer round up
        let pattern = seconds >= 3599 ? "0:00:00" : seconds >= 599 ? "00:00" : "0:00"
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
                Group {
                    if train.isLive {
                        // Measured in the footnote it's drawn in, at the phone's text size
                        let font = UIFont.monospacedDigitSystemFont(
                            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .semibold)
                        countdown(to: train)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: countdownWidth(to: train, in: font), alignment: .trailing)
                    } else {
                        Text(train.time.clock)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(train.statusColor)
                markAndBullet(train, bulletSize: BoardStyle.compact.timeBullet)
            }
            .lineLimit(1)
        }
    }

    /// A train's time right-aligned in `width`, so the colons line up past
    /// 10:00, then its bullet, or (with `bulletSlot`) the empty room for one.
    /// With `markSlot`, a live or timetable train's mark, as marked, goes before
    /// its time, or for one without, the room for it, so the times still line up.
    private func timeAndBullet(_ train: Arrival, font: Font, width: CGFloat, bulletSize: CGFloat, bulletSlot: Bool,
                               markSlot: Bool = false) -> some View {
        HStack(spacing: 3) {
            if markSlot {
                let live = marksLive && train.isLive
                let scheduled = marksScheduled && !train.isLive
                // Both are there, so the slot's as wide as the wider
                ZStack {
                    LiveMark(size: bulletSize * 0.7)
                        .opacity(live ? 1 : 0)
                        .accessibilityHidden(!live)
                    ScheduledMark(size: bulletSize * 0.7)
                        .opacity(scheduled ? 1 : 0)
                        .accessibilityHidden(!scheduled)
                }
                .foregroundStyle(train.statusColor)
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
    /// bullet or the room for one, the minutes right after, where the column
    /// has room for them at the phone's text size.
    private func laterTrains(_ count: Int, style: BoardStyle) -> some View {
        let shown = Array(later.prefix(count))
        let timeWidth = shown.map { $0.time.clock.width(in: style.timeUIFont) }.max() ?? 0
        let bulletSlot = shown.contains(where: entry.selection.marksLine)
        let markSlot = shown.contains { marksLive && $0.isLive || marksScheduled && !$0.isLive }
        let minutesWidth = shown.map { minutesToGo(until: $0).width(in: style.minutesUIFont) }.max() ?? 0
        let timesWidth = (markSlot ? Self.markWidth(size: style.timeBullet * 0.7) + 3 : 0) + timeWidth
            + (bulletSlot ? 3 + style.timeBullet : 0)
        let showsMinutes = timesWidth + style.minutesGap + minutesWidth <= style.columnWidth
        return VStack(alignment: .leading, spacing: 0) {
            Text("LATER")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardGray)
                .padding(.bottom, style.isLarge ? 0 : 1)
            ForEach(Array(shown.enumerated()), id: \.offset) { _, train in
                HStack(spacing: style.minutesGap) {
                    timeAndBullet(train, font: style.timeFont, width: timeWidth,
                                  bulletSize: style.timeBullet, bulletSlot: bulletSlot, markSlot: markSlot)
                    if showsMinutes {
                        Text(minutesToGo(until: train))
                            .font(style.minutesFont)
                            .monospacedDigit()
                            .foregroundStyle(Color.boardGray)
                            .fixedSize()
                            .frame(width: minutesWidth, alignment: .trailing)
                    }
                }
                .lineLimit(1)
                .frame(height: style.rowHeight)
            }
        }
    }

    /// How wide the mark slot is with marks `size` points: the wider of the two marks.
    private static func markWidth(size: CGFloat) -> CGFloat {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
        return [LiveMark.symbol, ScheduledMark.symbol]
            .compactMap { UIImage(systemName: $0, withConfiguration: configuration)?.size.width }
            .max() ?? size * 1.5
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

    // MARK: Transfers

    /// The Transfers widget: on the medium widget the next two changes of
    /// trains, on the large the next one big and three more; behind the map
    /// button, where the trains are. Without a change, how to add one.
    @ViewBuilder private var transfers: some View {
        if let change = entry.change {
            GeometryReader { geometry in
                Group {
                    if family == .systemLarge {
                        transfersLarge(change, width: geometry.size.width)
                    } else {
                        transfersMedium(change, size: geometry.size)
                    }
                }
                // Should it come out wider or taller than the widget, it runs
                // off the right edge or the top, rather than moving the map
                // button off its slot between ↻ and walk
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
            }
            // A tap opens the times at both stations, yours and the change; see `tapURL`
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header(nameLines: 1, style: .large)
                Text("Add a change of trains to this widget in the app's Widgets tab.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boardText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The trip across the top, then the next two changes: how long until you
    /// leave, when your train leaves and gets to the change, the wait, and the
    /// train it meets. Behind the map button, as Next train's: the countdown on
    /// the left and where your train is on the right.
    @ViewBuilder private func transfersMedium(_ change: Change, size: CGSize) -> some View {
        let style: BoardStyle = entry.largeText ? .large : .compact
        if entry.showsMap, let first = entry.connections?.first {
            mediumLayout(size: size, style: style, train: first.first, heading: change.station?.name ?? "the change")
        } else {
            transferList(change, width: size.width, style: style)
        }
    }

    private func transferList(_ change: Change, width: CGFloat, style: BoardStyle) -> some View {
        let connections = Array((entry.connections ?? []).prefix(2))
        let size: CGFloat = entry.largeText ? 24 : 21
        let lead = connections.map { countdownWidth(to: $0.first, size: size) }.max() ?? 0
        let columns = TransferColumns(connections: connections, lead: lead, width: width)
        let height: CGFloat = entry.largeText ? 28 : 25
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: style.headerSpacing) {
                LineBullets(routes: entry.selection.routes, size: entry.largeText ? 26 : 22)
                transferTitle(change)
                    .font(style.nameFont)
                    .foregroundStyle(Color.boardText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            VStack(alignment: .leading, spacing: 0) {
                if connections.isEmpty {
                    Text(noTransfers(change))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.boardText)
                } else {
                    // Under several lines' stacked bullets, the two closer
                    // together; under an alert's banner there may be room for only one
                    ViewThatFits(in: .vertical) {
                        mediumTransfers(connections, change: change, columns: columns, size: size, height: height)
                        mediumTransfers(connections, change: change, columns: columns, size: size, height: height - 4,
                                        spacing: 1)
                        mediumTransfers(Array(connections.prefix(1)), change: change, columns: columns, size: size, height: height)
                    }
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            buttons(style).padding(.top, 6)
        }
    }

    private func mediumTransfers(_ connections: [Connection], change: Change, columns: TransferColumns,
                                 size: CGFloat, height: CGFloat, spacing: CGFloat = 3) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(connections.enumerated()), id: \.offset) { _, connection in
                transferRow(connection, change: change, columns: columns, height: height) {
                    countdown(to: connection.first)
                        .font(.system(size: size, weight: .bold, design: .rounded))
                        .foregroundStyle(connection.first.statusColor)
                        .liveAccent(connection.first)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }

    /// The trip and which way across the top; the next change big; then three
    /// more in the medium widget's columns, or with the map button the tracks
    /// to the change, your train on one and the one it meets on the other.
    private func transfersLarge(_ change: Change, width: CGFloat) -> some View {
        let style = BoardStyle.large
        let connections = entry.connections ?? []
        let later = Array(connections.dropFirst().prefix(3))
        let lead = later.map { "\(minutesToLeave($0.first)) min".width(in: style.timeUIFont) }.max() ?? 0
        let columns = TransferColumns(connections: later, lead: max(lead, "THEN IN".width(in: Self.labelUIFont)), width: width)
        return VStack(alignment: .leading, spacing: 0) {
            transferHeader(change)
            VStack(alignment: .leading, spacing: 0) {
                if let first = connections.first {
                    transferCard(first, change: change)
                        .padding(.top, 14)
                    if entry.showsMap {
                        // On a shorter widget, without the times, then without the
                        // note: where the train it meets is matters more
                        ViewThatFits(in: .vertical) {
                            TransferTrack(connection: first, selection: entry.selection, change: change, now: entry.date)
                            TransferTrack(connection: first, selection: entry.selection, change: change, now: entry.date,
                                          showsTimes: false)
                            TransferTrack(connection: first, selection: entry.selection, change: change, now: entry.date,
                                          showsTimes: false, showsNote: false)
                        }
                        .padding(.top, 14)
                    } else if !later.isEmpty {
                        transferLabels(change, columns: columns)
                            .padding(.top, 14)
                        ViewThatFits(in: .vertical) {
                            laterTransfers(later, change: change, columns: columns)
                            laterTransfers(Array(later.prefix(2)), change: change, columns: columns)
                            laterTransfers(Array(later.prefix(1)), change: change, columns: columns)
                        }
                        .padding(.top, 4)
                    }
                } else {
                    Text(noTransfers(change))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.boardText)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            buttons(style).padding(.top, 8)
        }
    }

    private func laterTransfers(_ connections: [Connection], change: Change, columns: TransferColumns) -> some View {
        let style = BoardStyle.large
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(connections.enumerated()), id: \.offset) { _, connection in
                transferRow(connection, change: change, columns: columns, height: 28) {
                    Text("\(minutesToLeave(connection.first)) min")
                        .font(style.timeFont)
                        .foregroundStyle(connection.first.statusColor)
                        .liveAccent(connection.first)
                        .fixedSize()
                }
            }
        }
    }

    /// "No R trains to Atlantic Av-Barclays Ctr predicted", or what went wrong.
    private func noTransfers(_ change: Change) -> String {
        entry.problem ?? "No \(entry.lineLabel) trains to \(change.station?.name ?? "the change") predicted"
    }

    /// Whole minutes until it's time to leave for `train`.
    private func minutesToLeave(_ train: Arrival) -> Int {
        max(0, Int(entry.selection.leaveTime(for: train).timeIntervalSince(entry.date) / 60))
    }

    /// "Prospect Av → Atlantic Av-Barclays Ctr"
    private func transferTitle(_ change: Change) -> Text {
        Text("\(entry.stationName) \(Text("→").foregroundStyle(Color.boardGray)) \(change.station?.name ?? "")")
    }

    /// The line's bullet; the trip; which way, and the lines changed to.
    private func transferHeader(_ change: Change) -> some View {
        let style = BoardStyle.large
        return HStack(alignment: .textMiddle, spacing: style.headerSpacing) {
            LineBullets(routes: entry.selection.routes, size: style.bulletSize)
            VStack(alignment: .leading, spacing: 0) {
                transferTitle(change)
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

    /// The next change, big: the countdown and how you change, then your train
    /// leaving, the ride to the change, the wait there, and the train it meets.
    private func transferCard(_ connection: Connection, change: Change) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                countdownLabel(to: connection.first, size: 44)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(howToChange(connection, change: change))
                    .font(.footnote)
                    .foregroundStyle(Color.boardGray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            // Times past 10:00 can leave no room for when your train gets to the change
            ViewThatFits(in: .horizontal) {
                cardTimes(connection, change: change, showsArrival: true)
                cardTimes(connection, change: change, showsArrival: false)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
    }

    /// Your train leaving, the ride, when it gets to the change (with
    /// `showsArrival`), the wait there, and the train it meets.
    private func cardTimes(_ connection: Connection, change: Change, showsArrival: Bool) -> some View {
        let style = BoardStyle.large
        return HStack(spacing: 0) {
            LineBullet(route: connection.first.route, size: 20)
            Text(connection.first.time.clock)
                .font(style.timeFont)
                .foregroundStyle(connection.first.statusColor)
                .liveAccent(connection.first)
                .fixedSize()
                .padding(.leading, 5)
            // The ride, in the line's colour
            Capsule()
                .fill(Color(hex: LineStyle.of(connection.first.route).color))
                .frame(minWidth: 12)
                .frame(height: 3)
                .padding(.horizontal, 8)
                .accessibilityHidden(true)
            if showsArrival {
                Text(connection.arrival.time.clock)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.boardGray)
                    .fixedSize()
            }
            waitCell(connection, quick: connection.isQuick(within: change.quickMinutes))
                .padding(.horizontal, 8)
            if let next = connection.next {
                LineBullet(route: next.route, size: 20)
                Text(next.time.clock)
                    .font(style.timeFont)
                    .foregroundStyle(next.statusColor)
                    .liveAccent(next)
                    .fixedSize()
                    .padding(.leading, 5)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 24)
    }

    /// "across the platform", or the walk to another one.
    private func howToChange(_ connection: Connection, change: Change) -> String {
        guard let next = connection.next else { return "none predicted yet" }
        return change.isAcross(next.route, from: entry.selection) ? "across the platform" : "\(change.walkMinutes) min walk to it"
    }

    private static let labelUIFont = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
                                                       weight: .semibold)

    /// The later changes' columns: "THEN IN", "R → ATLANTIC", "WAIT", "EXPRESS".
    private func transferLabels(_ change: Change, columns: TransferColumns) -> some View {
        let lines = entry.selection.routes.map { LineStyle.of($0).label }.joined(separator: " ")
        let station = change.station?.name.mainStationName ?? ""
        return HStack(spacing: 0) {
            Text("THEN IN")
                .fixedSize()
                .frame(width: columns.lead, alignment: .leading)
            // Without when your train gets there, just which it is
            Text(columns.showsArrival ? "\(lines) → \(station.uppercased())" : lines)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: columns.trip, alignment: .leading)
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
    }

    /// One change of trains in the Transfers widget's columns: how long until
    /// you leave (`lead`), when your train leaves and gets to the change, the
    /// wait there, and the train it meets; on a band when the wait is short.
    private func transferRow<Lead: View>(_ connection: Connection, change: Change, columns: TransferColumns,
                                         height: CGFloat, @ViewBuilder lead: () -> Lead) -> some View {
        let quick = connection.isQuick(within: change.quickMinutes)
        return HStack(spacing: 0) {
            lead()
                .frame(width: columns.lead, alignment: .leading)
            HStack(spacing: TransferColumns.tripSpacing) {
                Text(connection.first.time.clock)
                    .fixedSize()
                    .frame(width: columns.leave, alignment: .trailing)
                if columns.showsArrival {
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.boardDim)
                        .frame(width: TransferColumns.arrow)
                        .accessibilityHidden(true)
                    Text(connection.arrival.time.clock)
                        .fixedSize()
                        .frame(width: columns.arrive, alignment: .trailing)
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.boardGray)
            .padding(.leading, columns.gap)
            waitCell(connection, quick: quick)
                .frame(width: columns.wait)
                .padding(.leading, columns.gap)
            nextCell(connection, columns: columns)
                .padding(.leading, columns.gap)
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: height)
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
                    .liveAccent(next)
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

    /// The row of buttons, sharing it equally: ↻; on the medium and large
    /// widgets the map button; and the walk button, which starts or stops the
    /// countdown to this widget's train. Each flashes in the line's colour
    /// when tapped; see `FlashButton`.
    /// Only the map button is drawn here, in the map's toggle; the controls
    /// layer draws ↻ and walk in the slots kept for them. Under the open
    /// alert there are no times to swap for the stops, so the map is dimmed.
    private func buttons(_ style: BoardStyle) -> some View {
        HStack(spacing: 6) {
            Pill(symbol: "arrow.clockwise", fills: true, large: style.isLarge).hidden()
            if hasMap {
                if let mapSwitch {
                    MapButton(isOn: mapSwitch, route: entry.selection.firstRoute, pending: mapPending,
                              large: style.isLarge)
                } else {
                    Pill(symbol: "map", fills: true, large: style.isLarge)
                        .opacity(alertOpen ? 0.35 : 1)
                        .accessibilityHidden(true)
                }
            }
            Pill(symbol: "figure.walk", fills: true, large: style.isLarge).hidden()
        }
    }

    /// The alert across the top of the widget, edge to edge, in its colour,
    /// with a chevron: tapping it shows the alert in full, or the times again.
    /// Tinted and clear Home Screens draw a widget in one colour, which would
    /// fill the banner over its text, so there it's a faint band instead.
    private func bannerFace(_ notice: Notice, open: Bool) -> some View {
        let fullColor = renderingMode == .fullColor
        return HStack(spacing: 5) {
            // As tall as the brief's bullets, so the symbols line up
            Image(systemName: notice.symbol)
                .resizable()
                .scaledToFit()
                .frame(height: Self.briefSymbolHeight)
                .widgetAccentable()
            // Open, the alert's text is below, so just its kind
            if open {
                Text(notice.label).bold().lineLimit(1)
            } else if let brief = notice.brief {
                briefLabel(notice, brief)
            } else {
                notice.bannerText.lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: open ? "chevron.up" : "chevron.down")
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

    /// How tall the banner's triangle, the brief's bullets and its ⇅ are.
    private static let briefSymbolHeight: CGFloat = 14

    /// A delay as "(2)(5) Both directions": the lines it names as bullets, and
    /// which way, in place of its whole headline. The triangle says it's a delay,
    /// as there isn't room for the word too on a small widget.
    private func briefLabel(_ notice: Notice, _ brief: AlertBrief) -> some View {
        HStack(spacing: 3) {
            ForEach(brief.routes, id: \.self) { route in
                LineBullet(route: route, size: Self.briefSymbolHeight)
            }
            if let direction = brief.direction {
                // "Both directions" is too long beside two bullets on a small widget, so there it's ⇅
                ViewThatFits(in: .horizontal) {
                    Text(direction)
                    if direction == "Both directions" {
                        Image(systemName: "arrow.up.arrow.down")
                            .resizable()
                            .scaledToFit()
                            .frame(height: Self.briefSymbolHeight)
                    }
                }
                .bold()
                .padding(.leading, 2)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([notice.label] + brief.routes.map { "\(LineStyle.of($0).label) train" } + [brief.direction].compactMap { $0 })
            .joined(separator: ", "))
    }

    /// The alert's text, with the lines it names as bullets the height of its
    /// line, centred on its capitals. Tinted and clear Home Screens would fill
    /// a bullet in one colour over its letter, so there the lines stay words.
    private func alertText(_ notice: Notice, textStyle: UIFont.TextStyle) -> Text {
        let plain = notice.text.isEmpty ? notice.label : notice.text
        guard renderingMode == .fullColor, let marked = notice.markedText else { return Text(plain) }
        let font = UIFont.preferredFont(forTextStyle: textStyle)
        let size = (font.lineHeight * 0.95).rounded()
        let drop = (size - font.capHeight) / 2
        var text = Text(verbatim: "")
        var rest = marked[...]
        var afterBullet = false
        while let match = rest.firstMatch(of: #/\[([A-Z0-9]{1,3})\]/#) {
            let before = rest[..<match.range.lowerBound]
            // A thin space between bullets side by side, as in "[2][5] trains"
            let gap = afterBullet && before.isEmpty ? "\u{2009}" : String(before)
            text = Text("\(text)\(Text(verbatim: gap))")
            if let data = BulletImage.data(for: [Lines.normalized(String(match.1))]),
               let image = UIImage(data: data, scale: BulletImage.pixelSide / size) {
                text = Text("\(text)\(Text(Image(uiImage: image)).baselineOffset(-drop))")
            } else {
                text = Text("\(text)\(Text(verbatim: String(match.1)))")
            }
            afterBullet = true
            rest = rest[match.range.upperBound...]
        }
        return Text("\(text)\(Text(verbatim: String(rest)))").accessibilityLabel(plain)
    }

    /// The alert in full under its banner, as much as fits; under it the next
    /// train's countdown, how many more alerts there are, and "More ›", for
    /// the app, which has every alert's details; and ↻ and walk.
    private func fullAlert(_ notice: Notice) -> some View {
        let style: BoardStyle = entry.largeText ? .large : .compact
        return VStack(alignment: .leading, spacing: 0) {
            alertText(notice, textStyle: style.isLarge ? .subheadline : .footnote)
                .font(style.isLarge ? .subheadline.weight(.semibold) : .footnote.weight(.semibold))
                .foregroundStyle(Color.boardText)
                // As many lines as there's room for, then "…"
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                if let next {
                    HStack(spacing: 3) {
                        countdownLabel(to: next, size: style.isLarge ? 17 : 15, showsMark: false)
                        markAndBullet(next, bulletSize: style.isLarge ? 15 : 13)
                    }
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
    /// it) and stops at 0:00, live, without the widget reloading. A train held
    /// at the platform is still shown after then, at 0:00.
    private func countdown(to train: Arrival) -> some View {
        Text(timerInterval: entry.date...max(entry.date, entry.selection.leaveTime(for: train)), countsDown: true)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// The lock screen's countdown. Dimmed, iOS stops a timer's seconds and
    /// shows "3:--", so it's the time instead, after a small "at" with
    /// `saysAt`, where nothing beside it says so. Otherwise the timer is held
    /// to a hidden stand-in for its digits: left to size itself, it's laid out
    /// afresh as the screen wakes, and its first digit is cut off.
    @ViewBuilder
    private func lockScreenCountdown(to train: Arrival, alignment: Alignment, saysAt: Bool = false) -> some View {
        let leave = entry.selection.leaveTime(for: train)
        if luminanceReduced {
            let time = Text(leave.clock)
            let shown = saysAt ? Text("\(Text("at ").font(.caption2))\(time)") : time
            shown
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            let seconds = leave.timeIntervalSince(entry.date)
            // A second early, should the timer round up
            Text(seconds >= 3599 ? "0:00:00" : seconds >= 599 ? "00:00" : "0:00")
                .monospacedDigit()
                .lineLimit(1)
                .hidden()
                .overlay(alignment: alignment) {
                    // A train held at the platform is still shown after its leave time
                    Text(timerInterval: entry.date...max(entry.date, leave), countsDown: true)
                        .monospacedDigit()
                        .lineLimit(1)
                        .multilineTextAlignment(alignment == .center ? .center : .leading)
                }
        }
    }
}

/// The Transfers widget's columns: how long until you leave, when your train
/// leaves and gets to the change, the wait, and the train it meets, each as
/// wide as its widest, with even gaps across the widget. Where they don't all
/// fit, as with times past 10:00 on a smaller phone, when your train gets to
/// the change is left out.
private struct TransferColumns {
    let lead: CGFloat
    let leave: CGFloat
    let arrive: CGFloat
    let wait: CGFloat
    let nextTime: CGFloat
    let gap: CGFloat
    /// Whether there's room for when your train gets to the change.
    let showsArrival: Bool

    static let arrow: CGFloat = 12
    /// Between the times and the arrow from one to the other.
    static let tripSpacing: CGFloat = 5
    /// The least room between two columns.
    static let minimumGap: CGFloat = 6

    /// When your train leaves, an arrow, and when it gets there; or just when it leaves.
    var trip: CGFloat { showsArrival ? leave + Self.tripSpacing * 2 + Self.arrow + arrive : leave }
    /// The bullet and time of the train met.
    var next: CGFloat { BoardStyle.large.timeBullet + 5 + nextTime }

    /// `lead` is how wide the first column is, and `width` the room for them all.
    init(connections: [Connection], lead: CGFloat, width: CGFloat) {
        let style = BoardStyle.large
        let points = { (style: UIFont.TextStyle) in UIFont.preferredFont(forTextStyle: style).pointSize }
        let tripFont = UIFont.monospacedDigitSystemFont(ofSize: points(.subheadline), weight: .medium)
        let pillFont = UIFont.monospacedDigitSystemFont(ofSize: points(.footnote), weight: .bold)
        let leave = connections.map { $0.first.time.clock.width(in: tripFont) }.max() ?? 0
        let arrive = connections.map { $0.arrival.time.clock.width(in: tripFont) }.max() ?? 0
        // The pill's text and its padding
        let wait = (connections.map { $0.waitLabel.width(in: pillFont) }.max() ?? 0) + 14
        let nextTime = connections.compactMap { $0.next?.time.clock.width(in: style.timeUIFont) }.max()
            ?? "0:00".width(in: style.timeUIFont)
        self.lead = lead
        self.leave = leave
        self.arrive = arrive
        self.wait = wait
        self.nextTime = nextTime
        let withoutArrival = lead + leave + wait + style.timeBullet + 5 + nextTime
        let used = withoutArrival + Self.tripSpacing * 2 + Self.arrow + arrive
        let showsArrival = used + 3 * Self.minimumGap <= width
        self.showsArrival = showsArrival
        gap = max(Self.minimumGap, (width - (showsArrival ? used : withoutArrival)) / 3)
    }
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
        // Assigned rather than self.init(_:), which Xcode's previews can't build
        self = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension Arrival {
    /// Green for a live prediction, white (black in light mode) for a timetable time.
    var statusColor: Color { isLive ? .liveText : .boardText }
}

extension View {
    /// For a time with no live mark: where the widget is drawn in one colour,
    /// as on tinted and clear Home Screens, a live one is in the accent
    /// colour in place of its green, so it still stands out.
    func liveAccent(_ train: Arrival) -> some View {
        widgetAccentable(train.isLive)
    }
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
            let first = Arrival(route: "R", time: at(0), stop: "R34N", lastStop: "G08N", isLive: live, trip: "R\(index)",
                                approach: Array(approach.prefix(2)))
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
        return TrainEntry(date: now, selection: .fallback, trains: connections.map(\.first), showsMap: showsMap, largeText: true,
                          connections: connections, change: Change(stationID: "R31", routes: ["D", "N"]), transfers: true)
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

    static let briefDelays = Notice(kind: .alert(.delays), label: "Delays",
                                    text: "2 and 5 trains are running with delays in both directions after we addressed a signal problem near 3 Av/149 St.",
                                    others: 0,
                                    brief: AlertBrief(header: "[2][5] trains are running with delays in both directions after we addressed a signal problem near 3 Av/149 St."),
                                    markedText: "[2][5] trains are running with delays in both directions after we addressed a signal problem near 3 Av/149 St.")
}

#Preview(as: .systemSmall) {
    RTrainWidget()
} timeline: {
    TrainEntry.preview
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains,
               notice: Notice(kind: .alert(.delays), label: "Delays", text: "", others: 0),
               countingDown: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.delays)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.briefDelays)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed)
    // After a tap on the banner
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.delays, showsAlert: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.briefDelays, showsAlert: true)
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
    // The last times, after a reload that couldn't reach the MTA
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, problem: "Couldn't reach the MTA",
               notUpdatedSince: Date.now.addingTimeInterval(-6 * 60))
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

#Preview("Transfers", as: .systemMedium) {
    TransfersWidget()
} timeline: {
    TrainEntry.transferPreview()
    TrainEntry.transferPreview(showsMap: true)
}

#Preview("Transfers", as: .systemLarge) {
    TransfersWidget()
} timeline: {
    TrainEntry.transferPreview()
    TrainEntry.transferPreview(showsMap: true)
}
