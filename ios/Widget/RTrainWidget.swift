import AppIntents
import SwiftUI
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
        return await Self.entries(for: configuration.selection)[0]
    }

    func timeline(for configuration: TrainWidgetIntent, in context: Context) async -> Timeline<TrainEntry> {
        let entries = await Self.entries(for: configuration.selection)
        // iOS rations how often widgets reload, so this may come later;
        // until it does, the entries step through the trains already known.
        let reload = Date.now.addingTimeInterval(entries[0].problem == nil ? 10 * 60 : 2 * 60)
        return Timeline(entries: entries, policy: .after(reload))
    }

    /// One entry for now, then one as each train's time to leave passes (its
    /// arrival, without a walking time), so the widget moves on to the next
    /// train you can catch without going back to the network.
    private static func entries(for selection: Selection) async -> [TrainEntry] {
        let now = Date.now
        let countingDown = SharedStore.loadCountdown().map { $0.trainID == selection.trainID && $0.ends > now } ?? false
        do {
            let board = try await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts, now: now)
            let trains = selection.catchable(board.trains, now: now)
            let notice = board.notice(includingElevators: selection.elevatorAlerts)
            var entries = [TrainEntry(date: now, selection: selection, trains: trains, notice: notice, countingDown: countingDown)]
            for train in trains.prefix(10) {
                let moment = selection.leaveTime(for: train)
                let after = trains.filter { selection.leaveTime(for: $0) > moment }
                entries.append(TrainEntry(date: moment, selection: selection, trains: after, notice: notice, countingDown: countingDown))
            }
            return entries
        } catch {
            return [TrainEntry(date: now, selection: selection, trains: [], problem: "Couldn't reach the MTA", countingDown: countingDown)]
        }
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
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 2)
                nextTrain
                // No room for the alert's label beside the buttons; its icon says there is one
                HStack(spacing: 6) {
                    if let notice = entry.notice {
                        Image(systemName: notice.symbol)
                            .font(.caption)
                            .foregroundStyle(notice.tint)
                            .accessibilityLabel(notice.label)
                    }
                    Spacer(minLength: 0)
                    buttons
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Spacer(minLength: 4)
                        nextTrain
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        laterTrains(count: entry.notice == nil ? 3 : 2)
                        Spacer(minLength: 4)
                        buttons
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let notice = entry.notice {
                    NoticeLine(notice: notice)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            LineBullets(routes: entry.selection.routes, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.stationName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(entry.heading)
                    .font(.caption2)
                    .foregroundStyle(Color.boardGray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// A live countdown to the next train, and its arrival time.
    @ViewBuilder private var nextTrain: some View {
        if let next {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if walking {
                    Text("Leave in")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.boardGray)
                        .fixedSize()
                }
                countdown(to: next)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(next.statusColor)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: 4) {
                Text(next.time.formatted(date: .omitted, time: .shortened) + (walking ? " train" : ""))
                    .foregroundStyle(next.statusColor)
                    .layoutPriority(1)
                if entry.selection.marksLine(of: next) {
                    LineBullet(route: next.route, size: 15)
                }
                // The small widget has no room for where it's going
                if let terminal = next.terminal, family != .systemSmall {
                    Text("· \(terminal)").foregroundStyle(Color.boardGray)
                }
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
        } else {
            Text(noTrains)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    private func laterTrains(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEXT").font(.caption2.weight(.semibold)).foregroundStyle(Color.boardGray)
            ForEach(Array(later.prefix(count).enumerated()), id: \.offset) { _, train in
                HStack(spacing: 8) {
                    Text(train.time.clock)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(train.statusColor)
                    if entry.selection.marksLine(of: train) {
                        LineBullet(route: train.route, size: 15)
                    }
                    // The headline train already names where it's going; only say so for trains that differ
                    if let terminal = train.terminal, terminal != next?.terminal {
                        Text(terminal)
                            .font(.footnote)
                            .foregroundStyle(Color.boardGray)
                            .lineLimit(1)
                    }
                }
            }
        }
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

    /// ↻ and the walk button, which starts or stops the countdown to this widget's train.
    private var buttons: some View {
        HStack(spacing: 6) {
            RefreshButton()
            WalkButton(intent: ToggleCountdownIntent(selection: entry.selection), route: entry.selection.firstRoute, isOn: entry.countingDown)
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

/// The medium widget's line about what might get in the way: "Delays", "Elevator out",
/// and the alert's headline.
struct NoticeLine: View {
    let notice: Notice

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: notice.symbol).foregroundStyle(notice.tint)
            Text(notice.label).fontWeight(.semibold).foregroundStyle(.white).layoutPriority(1)
            Text(notice.text).foregroundStyle(Color.boardGray)
            if notice.others > 0 {
                Text("+\(notice.others)").foregroundStyle(Color.boardGray).layoutPriority(1)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

extension Color {
    static let boardBlack = Color(white: 0.07)
    static let boardGray = Color(white: 0.62)
}

extension Arrival {
    /// Green for a live prediction, white for a timetable time.
    var statusColor: Color { isLive ? .liveGreen : .white }
}

extension Date {
    /// "8:12", without AM/PM, for lists of times.
    var clock: String {
        formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits))
    }
}

// MARK: - Previews

extension TrainEntry {
    static var preview: TrainEntry {
        let now = Date.now
        // An N running local on the R comes first
        let trains = [4.0, 12, 20, 31, 41].map {
            Arrival(route: $0 == 4 ? "N" : "R", time: now.addingTimeInterval($0 * 60), stop: "R34N", lastStop: $0 == 4 ? "R01N" : "G08N", isLive: $0 < 15)
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
               countingDown: true)
}

#Preview(as: .systemMedium) {
    RTrainWidget()
} timeline: {
    TrainEntry.preview
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains,
               notice: Notice(kind: .alert(.delays), label: "Delays", text: "R trains are delayed while we address a signal problem", others: 1),
               countingDown: true)
    TrainEntry(date: .now, selection: .fallback, trains: [], problem: "Couldn't reach the MTA")
}
