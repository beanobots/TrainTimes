import AppIntents
import SwiftUI
import WidgetKit

struct RTrainWidget: Widget {
    let kind = "RTrainWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            TrainWidgetView(entry: entry)
                .containerBackground(Color.boardBlack, for: .widget)
        }
        .configurationDisplayName("Next R train")
        .description("Manhattan-bound R trains at Prospect Av, live from the MTA.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Timeline

struct TrainEntry: TimelineEntry {
    let date: Date
    /// Trains still to come at `date`, soonest first.
    let trains: [Arrival]
    var problem: String? = nil
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> TrainEntry {
        .preview
    }

    func getSnapshot(in context: Context, completion: @escaping (TrainEntry) -> Void) {
        if context.isPreview {
            completion(.preview)
            return
        }
        Task { completion(await Self.entries()[0]) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TrainEntry>) -> Void) {
        Task {
            let entries = await Self.entries()
            // iOS rations how often widgets reload, so this may come later;
            // until it does, the entries step through the trains already known.
            let reload = Date.now.addingTimeInterval(entries[0].problem == nil ? 10 * 60 : 2 * 60)
            completion(Timeline(entries: entries, policy: .after(reload)))
        }
    }

    /// One entry for now, then one as each train arrives, so the widget moves
    /// on to the following train without going back to the network.
    private static func entries() async -> [TrainEntry] {
        let now = Date.now
        do {
            let request = URLRequest(url: Settings.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let trains = try SubwayFeed.upcoming(from: data, now: now)
            var entries = [TrainEntry(date: now, trains: trains)]
            for train in trains.prefix(10) {
                entries.append(TrainEntry(date: train.time, trains: trains.filter { $0.time > train.time }))
            }
            return entries
        } catch {
            return [TrainEntry(date: now, trains: [], problem: "Couldn't reach the MTA")]
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
    private var route: String { next?.route ?? Settings.routes.sorted().last ?? "R" }
    private var noTrains: String { entry.problem ?? "No \(Settings.routes.sorted().joined(separator: "/")) trains predicted" }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let next {
                Text("\(next.route) " + ([next] + later.prefix(2)).map(\.time.clock).joined(separator: " · "))
            } else {
                Text(noTrains)
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(route).font(.headline)
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
                Text("\(route) · \(Settings.station)").font(.headline)
                if let next {
                    countdown(to: next)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.leading)
                    if !later.isEmpty {
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
                nextTrain(listsLater: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .bottomTrailing) { refreshButton }
        default:
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Spacer(minLength: 4)
                    nextTrain(listsLater: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                laterTrains
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            RouteBullet(route: route, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(Settings.station).font(.subheadline.bold()).foregroundStyle(.white)
                Text(Settings.heading).font(.caption2).foregroundStyle(Color.boardGray)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// A live countdown to the next train and its arrival time, plus the two
    /// after it unless they're listed alongside.
    @ViewBuilder private func nextTrain(listsLater: Bool) -> some View {
        if let next {
            countdown(to: next)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(next.statusColor)
                .multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                Text(next.time.formatted(date: .omitted, time: .shortened))
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

    private var laterTrains: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("NEXT").font(.caption2.weight(.semibold)).foregroundStyle(Color.boardGray)
                Spacer(minLength: 0)
                refreshButton
            }
            ForEach(Array(later.prefix(4).enumerated()), id: \.offset) { _, train in
                HStack(spacing: 8) {
                    if Settings.routes.count > 1 {
                        RouteBullet(route: train.route, size: 16)
                    }
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

    /// Counts down to the train and stops at 0:00, live, without the widget reloading.
    private func countdown(to train: Arrival) -> some View {
        Text(timerInterval: entry.date...train.time, countsDown: true)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

struct RouteBullet: View {
    let route: String
    let size: CGFloat

    var body: some View {
        Text(route)
            .font(.system(size: size * 0.62, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.mtaYellow))
    }
}

extension Color {
    static let mtaYellow = Color(red: 252 / 255, green: 204 / 255, blue: 10 / 255)
    static let boardBlack = Color(white: 0.07)
    static let boardGray = Color(white: 0.62)
    static let liveGreen = Color(red: 0.30, green: 0.85, blue: 0.39)
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
            Arrival(route: "R", time: now.addingTimeInterval($0 * 60), terminal: "Forest Hills", isLive: $0 < 15)
        }
        return TrainEntry(date: now, trains: trains)
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
    TrainEntry(date: .now, trains: [], problem: "Couldn't reach the MTA")
}
