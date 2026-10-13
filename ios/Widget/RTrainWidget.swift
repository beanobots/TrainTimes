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

    var stationName: String { selection.station?.name ?? "Choose a station" }
    var heading: String { selection.station?.directionLabel(selection.direction) ?? "" }
    var lineLabel: String { LineStyle.of(selection.route).label }
}

/// What a widget's Edit menu offers: its own train, and its own walking time.
struct TrainWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a train"
    static let description = IntentDescription("Pick a station, line and direction for this widget, or leave Train empty to show the one chosen in the app.")

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
        do {
            let board = try await TrainService.board(for: selection, includingOutages: selection.elevatorAlerts, now: now)
            let trains = selection.catchable(board.trains, now: now)
            let notice = board.notice(includingElevators: selection.elevatorAlerts)
            var entries = [TrainEntry(date: now, selection: selection, trains: trains, notice: notice)]
            for train in trains.prefix(10) {
                let moment = selection.leaveTime(for: train)
                let after = trains.filter { selection.leaveTime(for: $0) > moment }
                entries.append(TrainEntry(date: moment, selection: selection, trains: after, notice: notice))
            }
            return entries
        } catch {
            return [TrainEntry(date: now, selection: selection, trains: [], problem: "Couldn't reach the MTA")]
        }
    }
}

/// The widget's refresh button runs this; WidgetKit then reloads the timeline.
struct RefreshIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh train times"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        .result()
    }
}

// MARK: - Views

struct TrainWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TrainEntry

    private var next: Arrival? { entry.trains.first }
    private var later: ArraySlice<Arrival> { entry.trains.dropFirst() }
    private var route: String { entry.selection.route }
    /// With a walking time, the countdown is to when to leave.
    private var walking: Bool { entry.selection.walkMinutes > 0 }
    private var noTrains: String { entry.problem ?? "No \(entry.lineLabel) trains predicted" }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let next, walking {
                Text("\(entry.lineLabel): leave \(entry.selection.leaveTime(for: next).clock) for \(next.time.clock)")
            } else if let next, let notice = entry.notice {
                Text("\(entry.lineLabel) \(next.time.clock) · \(notice.label)")
            } else if let next {
                Text("\(entry.lineLabel) " + ([next] + later.prefix(2)).map(\.time.clock).joined(separator: " · "))
            } else {
                Text(noTrains)
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(entry.lineLabel).font(.headline)
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
                        if walking { Text("Leave in").font(.caption) }
                        countdown(to: next)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.leading)
                    }
                    if let notice = entry.notice {
                        Label(notice.label, systemImage: notice.symbol).font(.caption)
                    } else if !later.isEmpty {
                        Text("then " + later.prefix(2).map(\.time.clock).joined(separator: ", ")).font(.caption)
                    }
                } else {
                    Text(noTrains).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 4)
                nextTrain(listsLater: entry.notice == nil)
                if let notice = entry.notice {
                    NoticeLine(notice: notice, showsText: false).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .bottomTrailing) { refreshButton }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Spacer(minLength: 4)
                        nextTrain(listsLater: false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    laterTrains(count: entry.notice == nil ? 4 : 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                if let notice = entry.notice {
                    NoticeLine(notice: notice, showsText: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            LineBullet(route: route, size: 26)
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

    /// A live countdown to the next train and its arrival time, plus the two
    /// after it unless they're listed alongside.
    @ViewBuilder private func nextTrain(listsLater: Bool) -> some View {
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
                if let terminal = next.terminal {
                    Text("· \(terminal)").foregroundStyle(Color.boardGray)
                }
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            if listsLater && !later.isEmpty {
                thenLine.padding(.top, 2)
            }
        } else {
            Text(noTrains)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
    }

    /// "Then 8:22, 8:30", each time in green or white like the others.
    private var thenLine: some View {
        HStack(spacing: 0) {
            Text("Then ").foregroundStyle(Color.boardGray)
            ForEach(Array(later.prefix(2).enumerated()), id: \.offset) { index, train in
                if index > 0 { Text(", ").foregroundStyle(Color.boardGray) }
                Text(train.time.clock).foregroundStyle(train.statusColor)
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func laterTrains(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("NEXT").font(.caption2.weight(.semibold)).foregroundStyle(Color.boardGray)
                Spacer(minLength: 0)
                refreshButton
            }
            ForEach(Array(later.prefix(count).enumerated()), id: \.offset) { _, train in
                HStack(spacing: 8) {
                    Text(train.time.clock)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(train.statusColor)
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

    private var refreshButton: some View {
        Button(intent: RefreshIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.boardGray)
        }
        .buttonStyle(.plain)
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

/// The widget's one line about what might get in the way: "Delays", "Elevator out".
struct NoticeLine: View {
    let notice: Notice
    /// The medium widget has room for the alert's headline; the small one only for its label.
    let showsText: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: notice.symbol).foregroundStyle(notice.tint)
            Text(notice.label).fontWeight(.semibold).foregroundStyle(.white).layoutPriority(1)
            if showsText {
                Text(notice.text).foregroundStyle(Color.boardGray)
            }
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
        let trains = [4.0, 12, 20, 31, 41].map {
            Arrival(route: "R", time: now.addingTimeInterval($0 * 60), lastStop: "G08N", isLive: $0 < 15)
        }
        return TrainEntry(date: now, selection: .fallback, trains: trains)
    }
}

#Preview(as: .systemSmall) {
    RTrainWidget()
} timeline: {
    TrainEntry.preview
}

#Preview(as: .systemMedium) {
    RTrainWidget()
} timeline: {
    TrainEntry.preview
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains,
               notice: Notice(kind: .alert(.delays), label: "Delays", text: "R trains are delayed while we address a signal problem", others: 1))
    TrainEntry(date: .now, selection: .fallback, trains: [], problem: "Couldn't reach the MTA")
}
