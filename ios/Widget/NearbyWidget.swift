import CoreLocation
import SwiftUI
import WidgetKit

/// The large widget of the stations nearest you, with each of their lines'
/// next train both ways. It finds you each time it reloads.
struct NearbyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Nearby.widgetKind, provider: NearbyProvider()) { entry in
            NearbyWidgetView(entry: entry)
                .containerBackground(Color.boardBackground, for: .widget)
        }
        .configurationDisplayName("Trains near you")
        .description("The stations closest to you, with each line's next train both ways.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Timeline

struct NearbyEntry: TimelineEntry {
    let date: Date
    let content: Content
    /// The app's Settings, for marking live times.
    var settings = AppSettings()
    /// When you were found, where it wasn't just now: iOS couldn't find you
    /// afresh, so the stations are near where you were then.
    var locatedAt: Date? = nil

    enum Content {
        /// The stations nearest you, nearest first, and what the place is
        /// called. With no times when the MTA couldn't be reached.
        case stations(place: String?, stations: [NearbyStation], unreachable: Bool)
        /// Location is off for the app, or (`asked` false) it hasn't asked yet.
        case locationOff(asked: Bool)
        /// Location is on, but there was no finding you.
        case notFound
        /// None near enough; the nearest, however far.
        case noStations(place: String?, nearest: Nearby.Result?)
    }
}

struct NearbyProvider: TimelineProvider {
    /// How long a timeline's entries go on for, one a minute.
    static let minutesShown = 30

    func placeholder(in context: Context) -> NearbyEntry {
        .preview
    }

    func getSnapshot(in context: Context, completion: @escaping (NearbyEntry) -> Void) {
        if context.isPreview {
            completion(.preview)
            return
        }
        let height = context.displaySize.height
        Task { completion(await Self.plan(height: height).entries[0]) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NearbyEntry>) -> Void) {
        let height = context.displaySize.height
        Task {
            let plan = await Self.plan(height: height)
            completion(Timeline(entries: plan.entries, policy: .after(plan.reload)))
        }
    }

    /// One entry a minute for half an hour, so the minutes count down, and
    /// when to find you again: as often as the train widget reloads. Both go
    /// from once you're found and the trains fetched, so the entries start
    /// when they're shown.
    private static func plan(height: CGFloat) async -> (entries: [NearbyEntry], reload: Date) {
        let settings = SharedStore.loadSettings()
        let reload = { (now: Date) in now.addingTimeInterval(Provider.reloadInterval(at: now)) }
        switch await NearbyLocator.locate() {
        case .notAllowed(let asked):
            // The app reloads the widget once location's turned on
            let now = Date.now
            return ([NearbyEntry(date: now, content: .locationOff(asked: asked), settings: settings)],
                    now.addingTimeInterval(60 * 60))
        case .notFound:
            let now = Date.now
            return ([NearbyEntry(date: now, content: .notFound, settings: settings)], reload(now))
        case .found(let location):
            // Where iOS last found you, when it couldn't just now: the widget says when that was
            let locatedAt = Date.now.timeIntervalSince(location.timestamp) > 2 * 60 ? location.timestamp : nil
            // Its name is looked up while the trains are fetched
            async let place = NearbyLocator.placeName(for: location)
            let near = Nearby.stations(near: location, limit: 3)
            guard !near.isEmpty else {
                let name = await place
                let now = Date.now
                return ([NearbyEntry(date: now, content: .noStations(place: name, nearest: Nearby.nearest(to: location)),
                                     settings: settings, locatedAt: locatedAt)], reload(now))
            }
            // Every line at each station, both ways
            let selections = near.flatMap { result in
                result.station.routes.flatMap { route in
                    Direction.allCases.map { Selection(stationID: result.station.id, routes: [route], direction: $0) }
                }
            }
            async let fetched = TrainService.trains(for: selections, includingOtherLines: false)
            async let alertEntries = TrainService.alertEntries()
            let trains = await fetched
            let alerts = await alertEntries
            let name = await place
            let now = Date.now
            let unreachable = trains.isEmpty
            let stations = near.map { NearbyStation($0, trains: trains, alerts: alerts, kinds: settings.alertKinds, now: now) }
            let shown = NearbyLayout.fit(stations, in: NearbyLayout.room(height: height, unreachable: unreachable))
            let content = NearbyEntry.Content.stations(place: name, stations: shown, unreachable: unreachable)
            let entries = (0..<Self.minutesShown).map { minute in
                NearbyEntry(date: now.addingTimeInterval(Double(minute) * 60), content: content, settings: settings,
                            locatedAt: locatedAt)
            }
            return (entries, reload(now))
        }
    }
}

// MARK: - Stations

/// A station near you, as the widget shows it.
struct NearbyStation {
    let station: Station
    /// "0.2 mi"
    let distance: String
    let walkMinutes: Int
    /// The lines with a row of their own: those with trains, or with an alert
    /// saying why there are none.
    var lines: [NearbyLine]
    /// The lines not running now, in the small row under them.
    let notRunning: [String]
    /// At a station with more lines than there's room for, the rest, in the
    /// small row too ("4 more lines").
    var leftOut: [String] = []

    /// `result`'s lines, with their trains (each line's own, by
    /// `Selection.trainID`) and alerts of the kinds chosen in Settings.
    init(_ result: Nearby.Result, trains: [String: [Arrival]], alerts: [AlertsFeed.Entry]?,
         kinds: Set<ServiceAlert.Kind>, now: Date) {
        station = result.station
        distance = result.distance
        walkMinutes = result.walkMinutes
        let lines = result.station.routes.map {
            NearbyLine($0, at: result.station, trains: trains, alerts: alerts, kinds: kinds, now: now)
        }
        self.lines = lines.filter { !$0.isIdle }
        notRunning = lines.filter(\.isIdle).map(\.route)
    }

    /// Whether it has the small row.
    var hasSmallRow: Bool { !notRunning.isEmpty || !leftOut.isEmpty }

    /// How tall it is on the widget.
    var height: CGFloat {
        NearbyLayout.stationHeader + CGFloat(lines.count) * NearbyLayout.row + (hasSmallRow ? NearbyLayout.smallRow : 0)
    }

    /// Moves its last line with a row of its own to the lines left out, ahead
    /// of those left out before it, which came after it.
    mutating func leaveOutLastLine() {
        guard let line = lines.popLast() else { return }
        leftOut.insert(line.route, at: 0)
    }
}

/// One line at a station near you, both ways.
struct NearbyLine: Identifiable {
    let route: String
    /// Toward Manhattan (or, in it, uptown) first, then away; nil where the
    /// line goes only one way from here, at the end of the line.
    let directions: [NearbyDirection?]
    /// Its most important alert, when there are no trains either way: why not.
    let notice: Notice?
    /// The way `notice` is for, whose alerts a tap on it opens.
    let noticeSelection: Selection?

    var id: String { route }

    /// Not running now: no trains either way, and no alert to say why. A line
    /// whose trains couldn't be had isn't.
    var isIdle: Bool {
        notice == nil && directions.compactMap { $0 }.allSatisfy { $0.trains?.isEmpty == true }
    }

    init(_ route: String, at station: Station, trains: [String: [Arrival]], alerts: [AlertsFeed.Entry]?,
         kinds: Set<ServiceAlert.Kind>, now: Date) {
        self.route = route
        let named = Direction.allCases.filter { !station.directionName($0, of: route).isEmpty }
        // Where the MTA names neither, both, as "Northbound" and "Southbound"
        let goes = named.isEmpty ? Direction.allCases : named
        // Toward Manhattan first, from outside it; otherwise north, which in Manhattan is uptown
        let towardManhattan = station.borough == "Manhattan" || !Lines.servesManhattan(route) ? nil
            : goes.first(where: { station.directionName($0, of: route).contains("Manhattan") })
        let order = towardManhattan.map { [$0, $0.opposite] } ?? [.north, .south]

        // The last entry's next train is the first after the timeline ends
        let end = now.addingTimeInterval(TimeInterval(NearbyProvider.minutesShown * 60))
        var ways: [Direction: Way] = [:]
        for direction in order where goes.contains(direction) {
            let selection = Selection(stationID: station.id, routes: [route], direction: direction)
            // Each line's own trains, not those of another line running on its
            // tracks: every one due before the timeline ends, and the one after,
            // so each entry has its next train. Without their stops, which the
            // widget doesn't show, to keep them small in its little memory
            let own = trains[selection.trainID].map { list in
                var kept = list.filter { $0.route == route }
                if let after = kept.firstIndex(where: { $0.time > end }) {
                    kept = Array(kept[...after])
                }
                return kept.map { train in
                    var train = train
                    train.approach = []
                    train.position = nil
                    return train
                }
            }
            // Left out where the line ends, though others go on from here, unless some of its trains do too
            if StationDirectory.line(route, endsAt: station, going: direction), own?.isEmpty != false { continue }
            let shown = alerts.map { AlertsFeed.alerts(for: selection, in: $0, now: now).filter { kinds.contains($0.kind) } } ?? []
            ways[direction] = Way(selection: selection, trains: own, alerts: shown)
        }
        let labels = Self.labels(of: route, at: station, ways: ways)
        directions = order.map { direction in
            ways[direction].map { way in
                NearbyDirection(label: labels[direction] ?? "", selection: way.selection, trains: way.trains,
                                alert: way.alerts.first?.kind)
            }
        }
        let noTrains = ways.values.allSatisfy { $0.trains?.isEmpty == true }
        // Each way's worst alert, in their order, so of two as bad the first way's
        let worst = order.compactMap { direction -> (alert: ServiceAlert, selection: Selection)? in
            guard let way = ways[direction], let alert = way.alerts.first else { return nil }
            return (alert, way.selection)
        }
        .min { $0.alert.kind < $1.alert.kind }
        if noTrains, let worst {
            notice = Notice(kind: .alert(worst.alert.kind), label: worst.alert.kind.label, text: worst.alert.header, others: 0)
            noticeSelection = worst.selection
        } else {
            notice = nil
            noticeSelection = nil
        }
    }

    private struct Way {
        let selection: Selection
        let trains: [Arrival]?
        let alerts: [ServiceAlert]
    }

    /// What each way is called. In Manhattan, the MTA's name: "Uptown",
    /// "Downtown". From elsewhere, "Manhattan" for the way there, and for the
    /// other the borough its trains are headed for. A line that stays in one
    /// borough, like the Staten Island Railway, goes by where its trains end up.
    private static func labels(of route: String, at station: Station, ways: [Direction: Way]) -> [Direction: String] {
        // "Uptown & The Bronx" and "Uptown - Queens" are uptown
        func named(_ direction: Direction) -> String {
            var name = station.directionName(direction, of: route)
            // Where the lines here part, this one's way: "Broad St (JZ) - Uptown (M)" is uptown for the M
            let label = LineStyle.of(route).label
            if let own = name.components(separatedBy: " - ").first(where: {
                $0.hasSuffix(")") && ($0.components(separatedBy: "(").last ?? "").contains(label)
            }) {
                name = own.components(separatedBy: " (")[0]
            }
            name = name.components(separatedBy: " & ")[0]
            // Only those: "34 St - Hudson Yards" stays as it is
            let first = name.components(separatedBy: " - ")[0]
            if first == "Uptown" || first == "Downtown" { name = first }
            return name.isEmpty ? (direction == .north ? "Northbound" : "Southbound") : name
        }
        var labels: [Direction: String] = [:]
        for (direction, way) in ways {
            if station.borough == "Manhattan" {
                labels[direction] = named(direction)
            } else if Lines.servesManhattan(route) && station.directionName(direction, of: route).contains("Manhattan") {
                labels[direction] = "Manhattan"
            } else {
                labels[direction] = way.trains?.first.flatMap { StationDirectory.borough(ofStop: $0.lastStop) } ?? station.borough
            }
        }
        if labels.count == 2, Set(labels.values).count == 1 {
            for (direction, way) in ways {
                labels[direction] = way.trains?.first?.terminal ?? named(direction)
            }
        }
        return labels
    }
}

/// Where a line goes from a station near you, and its next trains.
struct NearbyDirection {
    /// "Manhattan", "Brooklyn", "Uptown"
    let label: String
    let selection: Selection
    /// Soonest first; nil when the line's feed couldn't be had.
    let trains: [Arrival]?
    /// The kind of its most important alert.
    let alert: ServiceAlert.Kind?

    /// The next train at `date`, or one held at the platform till after then.
    func next(at date: Date) -> Arrival? {
        trains?.first { $0.leaves > date }
    }
}

/// The widget's measurements, for fitting the stations to it before it's drawn.
enum NearbyLayout {
    /// The place's name and ↻ across the top.
    static let header: CGFloat = 24
    /// Under the header, and between stations.
    static let gap: CGFloat = 8
    /// A station's name and how far it is, with the rule above it.
    static let stationHeader: CGFloat = 29
    static let row: CGFloat = 26
    /// The small row of lines not running, and of those left out for room.
    static let smallRow: CGFloat = 22
    /// "Couldn't reach the MTA" along the bottom.
    static let problem: CGFloat = 22
    /// The system's margins around a large widget's content.
    static let margins: CGFloat = 16

    /// The room for stations in a widget `height` points tall.
    static func room(height: CGFloat, unreachable: Bool) -> CGFloat {
        height - 2 * margins - header - gap - (unreachable ? problem : 0)
    }

    /// As many of `stations` as fit in `room`, nearest first, each with as
    /// many of its lines as fit. One with more lines than there's room for
    /// shows its first four and the others' bullets; failing that, the
    /// farthest station is left off, and the room it leaves goes back to the
    /// others' lines; and failing that, the nearest shows fewer lines still.
    static func fit(_ stations: [NearbyStation], in room: CGFloat) -> [NearbyStation] {
        func fits(_ stations: [NearbyStation]) -> Bool {
            stations.map(\.height).reduce(0, +) + gap * CGFloat(max(stations.count - 1, 0)) <= room
        }
        // Each count starts again from every line, so none stays folded for
        // a station that's since been left off
        for count in stride(from: stations.count, to: 1, by: -1) {
            var kept = Array(stations.prefix(count))
            while !fits(kept), let index = longest(of: kept, over: 4) {
                kept[index].leaveOutLastLine()
            }
            if fits(kept) { return kept }
        }
        var nearest = Array(stations.prefix(1))
        while !fits(nearest), let index = longest(of: nearest, over: 1) {
            nearest[index].leaveOutLastLine()
        }
        return nearest
    }

    /// The station with the most rows, if any has more than `count`.
    private static func longest(of stations: [NearbyStation], over count: Int) -> Int? {
        stations.indices
            .filter { stations[$0].lines.count > count }
            .max { stations[$0].lines.count < stations[$1].lines.count }
    }
}

// MARK: - Views

struct NearbyWidgetView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: NearbyEntry

    /// Whether live times get their symbol as well as their green: always
    /// where the widget is drawn in one colour, as on tinted and clear Home
    /// Screens, which would leave out the green.
    private var marksLive: Bool { withoutColor || renderingMode != .fullColor || entry.settings.marksLiveTimes }
    /// Whether timetable times get their symbol.
    private var marksScheduled: Bool { entry.settings.marksScheduledTimes }

    /// A tap anywhere but a train opens the app at the stations near you, or
    /// without location, to allow it.
    private var url: URL {
        if case .locationOff = entry.content { return Nearby.allowURL }
        return Nearby.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch entry.content {
            case .stations(let place, let stations, let unreachable):
                header(place)
                VStack(alignment: .leading, spacing: NearbyLayout.gap) {
                    ForEach(stations, id: \.station.id) { stationView($0) }
                }
                Spacer(minLength: 0)
                if unreachable {
                    Label("Couldn't reach the MTA. Tap ↻ to try again.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(Color.boardGray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: NearbyLayout.problem)
                        // ↻ is the Refresh button
                        .accessibilityLabel("Couldn't reach the MTA. Tap Refresh to try again.")
                }
            case .locationOff(let asked):
                header(nil, located: false, refreshes: false)
                if asked {
                    message("location.slash", "Location is off for Train Times.",
                            "Allow it While Using the App or Widgets to see the stations near you and their next trains.",
                            button: "Turn It On in Settings")
                } else {
                    message("location", "See the trains near you",
                            "Let Train Times use your location While Using the App or Widgets.",
                            button: "Allow Location")
                }
            case .notFound:
                header(nil)
                message("location.slash", "Couldn't find where you are", "Tap ↻ to try again.",
                        spoken: "Tap Refresh to try again.")
            case .noStations(let place, let nearest):
                header(place)
                message("tram", "No stations within \(Nearby.rangeDescription) of you",
                        nearest.map { "The nearest is \($0.station.name), \($0.distance) away." } ?? "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Its rows are as tall as `NearbyLayout` has them, which fits text up
        // to this size, and two ways of a line share each one
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .widgetURL(url)
    }

    /// Where you are, and ↻, which finds you again. When iOS couldn't find
    /// you afresh, when it last did.
    private func header(_ place: String?, located: Bool = true, refreshes: Bool = true) -> some View {
        HStack(spacing: 6) {
            Image(systemName: located ? "location.fill" : "location.slash")
                .font(.caption.weight(.bold))
                .accessibilityHidden(true)
            Text(place ?? "Nearby")
                .font(.subheadline.bold())
                .lineLimit(1)
            if let locatedAt = entry.locatedAt {
                Text("as of \(locatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(Color.boardGray)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if refreshes {
                RefreshButton(widgetsOnly: true)
            }
        }
        .foregroundStyle(Color.boardText)
        .frame(height: NearbyLayout.header)
        .padding(.bottom, NearbyLayout.gap)
    }

    /// Its name and how far it is, then a row for each line, then any small row.
    private func stationView(_ nearby: NearbyStation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.boardButton)
                .frame(height: 1)
            // Its name opens the station, every line both ways
            Link(destination: Nearby.stationURL(nearby.station)) {
                HStack(spacing: 8) {
                    Text(nearby.station.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.boardText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Text(nearby.distance)
                        Text("·")
                        Image(systemName: "figure.walk")
                        Text("\(nearby.walkMinutes) min")
                    }
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.boardGray)
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(nearby.distance), \(nearby.walkMinutes) minute walk")
                }
                .frame(height: 22)
                .padding(.top, 6)
            }
            ForEach(nearby.lines) { line in
                if let notice = line.notice {
                    noticeRow(line, notice)
                } else {
                    HStack(spacing: 8) {
                        LineBullet(route: line.route, size: 20)
                        way(line.directions[0])
                        way(line.directions[1])
                            .padding(.leading, 6)
                    }
                    .frame(height: NearbyLayout.row)
                }
            }
            if nearby.hasSmallRow {
                foldedRow(nearby)
            }
        }
    }

    /// One way's name and its next train, which opens it in the app.
    @ViewBuilder private func way(_ direction: NearbyDirection?) -> some View {
        if let direction {
            Link(destination: direction.selection.trainURL) {
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        // On a smaller phone, beside a live mark or at a larger
                        // text size, "Manhattan" or "Downtown" shrinks to fit
                        Text(direction.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let alert = direction.alert {
                            Image(systemName: alert.symbol)
                                .font(.caption2)
                                .foregroundStyle(alert.tint)
                                .accessibilityLabel(alert.label)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.boardGray)
                    Spacer(minLength: 0)
                    time(direction.next(at: entry.date))
                }
                // Named with its line, for a way reached on its own; the time comes as its value
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenName(direction))
                .accessibilityValue(spokenTime(direction))
            }
            .frame(maxWidth: .infinity)
        } else {
            // The end of the line: trains go only the other way
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    /// "Now", "1 min", "12 min"; green for a live prediction, plain for a
    /// timetable time; "–" when there's none, or no knowing.
    private func time(_ train: Arrival?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let train {
                let minutes = max(0, Int(train.time.timeIntervalSince(entry.date) / 60))
                if marksLive && train.isLive {
                    LiveMark(size: 9).foregroundStyle(train.statusColor)
                } else if marksScheduled && !train.isLive {
                    ScheduledMark(size: 9).foregroundStyle(train.statusColor)
                }
                Text(minutes == 0 ? "Now" : "\(minutes)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(train.statusColor)
                if minutes > 0 {
                    Text("min")
                        .font(.footnote)
                        .foregroundStyle(Color.boardGray)
                }
            } else {
                Text("–")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.boardGray)
            }
        }
        .monospacedDigit()
        .fixedSize()
    }

    /// As VoiceOver names a way: "R Manhattan", and its alert, "R Uptown, Delays".
    private func spokenName(_ direction: NearbyDirection) -> String {
        let name = "\(Lines.name(of: direction.selection.firstRoute)) \(direction.label)"
        return direction.alert.map { "\(name), \($0.label)" } ?? name
    }

    /// As VoiceOver reads a way's next train: "12 minutes, live", "Now,
    /// scheduled". Whether it's live is said with the marks off too, as they
    /// and the green are all that show it.
    private func spokenTime(_ direction: NearbyDirection) -> String {
        guard direction.trains != nil else { return "Couldn't load" }
        guard let train = direction.next(at: entry.date) else { return "No trains" }
        let minutes = max(0, Int(train.time.timeIntervalSince(entry.date) / 60))
        let time = minutes == 0 ? "Now" : minutes == 1 ? "1 minute" : "\(minutes) minutes"
        return "\(time), \(train.isLive ? "live" : "scheduled")"
    }

    /// A line with no trains either way, and the alert that says why, which
    /// opens the alerts of the way it's for in the app.
    private func noticeRow(_ line: NearbyLine, _ notice: Notice) -> some View {
        Link(destination: line.noticeSelection?.alertsURL ?? Nearby.url) {
            HStack(spacing: 8) {
                LineBullet(route: line.route, size: 20)
                HStack(spacing: 4) {
                    // Its kind is in its words
                    Image(systemName: notice.symbol)
                        .font(.caption2)
                        .foregroundStyle(notice.tint)
                        .accessibilityHidden(true)
                    notice.bannerText
                        .font(.footnote)
                        .foregroundStyle(Color.boardText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: NearbyLayout.row)
        }
    }

    /// The bullets of lines left out for room, then of those not running now.
    /// It opens the station, every line both ways; lines left out for room
    /// at the top.
    private func foldedRow(_ nearby: NearbyStation) -> some View {
        Link(destination: Nearby.stationURL(nearby.station, first: nearby.leftOut)) {
            foldedLabel(nearby)
                // The whole row, not just its bullets and words
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    /// "4 more lines ›" and "Not running now", each after its lines' bullets;
    /// with no room for both, just the lines left out for room, which the
    /// station shows first.
    private func foldedLabel(_ nearby: NearbyStation) -> some View {
        Group {
            if nearby.leftOut.isEmpty {
                notRunningLabel(nearby.notRunning)
            } else if nearby.notRunning.isEmpty {
                leftOutLabel(nearby.leftOut)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        leftOutLabel(nearby.leftOut)
                        notRunningLabel(nearby.notRunning)
                    }
                    leftOutLabel(nearby.leftOut)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.boardGray)
        .lineLimit(1)
        .frame(height: NearbyLayout.smallRow)
    }

    /// "4 more lines ›", after their bullets.
    private func leftOutLabel(_ routes: [String]) -> some View {
        folded(routes) {
            Text(routes.count == 1 ? "1 more line" : "\(routes.count) more lines")
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .accessibilityHidden(true)
        }
    }

    /// "Not running now", after their bullets.
    private func notRunningLabel(_ routes: [String]) -> some View {
        folded(routes) {
            Text("Not running now")
        }
    }

    /// `routes`' bullets, then what they are.
    private func folded<Words: View>(_ routes: [String], @ViewBuilder _ words: () -> Words) -> some View {
        HStack(spacing: 3) {
            ForEach(routes, id: \.self) { route in
                LineBullet(route: route, size: 14)
            }
            HStack(spacing: 4) {
                words()
            }
            .padding(.leading, 5)
        }
    }

    /// In place of the stations: why there are none, and what to do. `spoken`
    /// is the detail as VoiceOver reads it, where it differs.
    private func message(_ symbol: String, _ title: String, _ detail: String, spoken: String? = nil,
                         button: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.boardGray)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.boardText)
                .padding(.top, 4)
            if !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.boardGray)
                    .accessibilityLabel(spoken ?? detail)
            }
            if let button {
                Text(button)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.boardText)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.boardButton))
                    .padding(.top, 10)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.bottom, NearbyLayout.header)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

extension NearbyEntry {
    /// Near 5 Av and 9 St in Park Slope, each line's trains a few minutes apart.
    static var preview: NearbyEntry {
        let now = Date.now
        let near = Nearby.stations(near: CLLocation(latitude: 40.6680, longitude: -73.9890), limit: 3)
        // Where each line's trains end up, north and south, for what each way is called
        let ends = ["F": ("F01N", "D43S"), "G": ("G22N", "F27S"), "R": ("G08N", "R45S")]
        var trains: [String: [Arrival]] = [:]
        var minutes = 1.0
        for result in near {
            for route in result.station.routes {
                for direction in Direction.allCases {
                    let selection = Selection(stationID: result.station.id, routes: [route], direction: direction)
                    let end = ends[route].map { direction == .north ? $0.0 : $0.1 } ?? ""
                    trains[selection.trainID] = [minutes, minutes + 9].map {
                        Arrival(route: route, time: now.addingTimeInterval($0 * 60 + 30), stop: selection.stopIDs.first ?? "",
                                lastStop: end, isLive: $0 < 15)
                    }
                    minutes = (minutes + 5).truncatingRemainder(dividingBy: 13)
                }
            }
        }
        let stations = near.map { NearbyStation($0, trains: trains, alerts: nil, kinds: [], now: now) }
        let shown = NearbyLayout.fit(stations, in: NearbyLayout.room(height: 354, unreachable: false))
        return NearbyEntry(date: now, content: .stations(place: "Park Slope", stations: shown, unreachable: false))
    }
}

#Preview(as: .systemLarge) {
    NearbyWidget()
} timeline: {
    NearbyEntry.preview
    NearbyEntry(date: .now, content: .locationOff(asked: false))
    NearbyEntry(date: .now, content: .locationOff(asked: true))
    NearbyEntry(date: .now, content: .notFound)
    NearbyEntry(date: .now, content: .noStations(place: "Montclair",
                                                 nearest: Nearby.nearest(to: CLLocation(latitude: 40.8259, longitude: -74.2090))))
}
