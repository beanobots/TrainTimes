import AppIntents
import CoreLocation
import SwiftUI
import WidgetKit

/// Large widget: what's near you, as Edit Widget picks: the nearest stations, with each line's
/// next train both ways; the nearest bus stop, its routes' next buses each way; the nearest Citi
/// Bike dock's counts. A card until a tap opens it, with a ✕ back to the card. Relocates on every
/// reload, less often than the train widgets' (`NearbyProvider.reloadInterval`).
struct NearbyWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Nearby.widgetKind, intent: NearbyWidgetIntent.self, provider: NearbyProvider()) { entry in
            NearbyWidgetView(entry: entry)
                .environment(\.routeLook, true)
                .containerBackground(Color.routeBackground, for: .widget)
        }
        .configurationDisplayName("Nearby")
        .description("The subway, buses and Citi Bike docks closest to you.")
        .supportedFamilies([.systemLarge])
    }
}

/// Nearby's Edit Widget: which of subway, bus and Citi Bike it shows.
struct NearbyWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Nearby"
    static let description = IntentDescription("What's near you, as you move.")

    @Parameter(title: "Subway", default: true)
    var subway: Bool

    @Parameter(title: "Bus", default: true)
    var bus: Bool

    @Parameter(title: "Citi Bike", default: true)
    var bike: Bool

    init() {}

    var modes: NearbyModes { NearbyModes(subway: subway, bus: bus, bike: bike) }
}

/// Which kinds Nearby shows.
struct NearbyModes: Hashable {
    var subway = true
    var bus = true
    var bike = true

    /// "Subway, bus and Citi Bike near you".
    var summary: String {
        let names = [subway ? "Subway" : nil, bus ? "bus" : nil, bike ? "Citi Bike" : nil].compactMap { $0 }
        guard let last = names.last else { return "Nothing chosen to show" }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
        return list.prefix(1).uppercased() + list.dropFirst() + " near you"
    }
}

/// The nearest Citi Bike dock, for Nearby.
struct NearbyDock {
    var dock: CitiBike.Dock
    var meters: Double

    var walkMinutes: Int { TripPlanner.walkMinutes(meters) }
}

// MARK: - Timeline

struct NearbyEntry: TimelineEntry {
    let date: Date
    let content: Content
    /// The app's Settings, for marking live times.
    var settings = AppSettings()
    /// Timestamp of an older fix, set when iOS couldn't get a fresh one.
    var locatedAt: Date? = nil
    var modes = NearbyModes()
    /// With Bus on: the nearest bus place and its next buses.
    var bus: NearbyBusPlace? = nil
    /// With Citi Bike on: the nearest dock.
    var dock: NearbyDock? = nil
    /// The board's open, from a tap on its card; else the card.
    var opened = true

    enum Content {
        /// Nearest stations first, plus the place name. No times if the MTA was unreachable, or
        /// the timetable's (`fromTimetable`) for the lines it couldn't give.
        case stations(place: String?, stations: [NearbyStation], unreachable: Bool, fromTimetable: Bool = false)
        /// Location is off for the app, or (`asked` false) it hasn't asked yet.
        case locationOff(asked: Bool)
        /// Location is allowed but no fix was found.
        case notFound
        /// None in range; `nearest` is the closest, however far.
        case noStations(place: String?, nearest: Nearby.Result?)
    }
}

struct NearbyProvider: AppIntentTimelineProvider {
    /// Fewest timeline entries, one per minute; more if the next reload is later.
    static let minutesShown = 30

    /// 15 minutes by day, an hour overnight (when the train widgets' `TimelinePlan.reloadInterval`
    /// is longer than 5) or while only the card shows (not `opened`): each reload relocates you and
    /// fetches every nearby line and alerts, and the entries count down meanwhile. Transit
    /// Directions' Nearby relocates on its own taps.
    static func reloadInterval(at date: Date, opened: Bool = true) -> TimeInterval {
        !opened || TimelinePlan.reloadInterval(at: date) > 5 * 60 ? 60 * 60 : 15 * 60
    }

    /// While only the card shows, an entry every 5 minutes rather than every minute: the card has
    /// no times, and the board a tap shows at once is then at most 5 minutes behind until the
    /// tap's reload replaces it.
    static let closedStep = 5

    /// How long, after locating, the widget waits for trains, alerts and the timetable before
    /// drawing without what's missing.
    static let fetchWait: TimeInterval = 5

    /// Entries needed from `now` to the reload after it, at least `minutesShown`.
    static func minutes(at now: Date, opened: Bool = true) -> Int {
        max(minutesShown, Int((reloadInterval(at: now, opened: opened) / 60).rounded(.up)))
    }

    /// What its card's tap opens (`OpenBoards`).
    static let boardID = Nearby.widgetKind

    func placeholder(in context: Context) -> NearbyEntry {
        .preview
    }

    func snapshot(for configuration: NearbyWidgetIntent, in context: Context) async -> NearbyEntry {
        if context.isPreview { return .preview }
        return Self.withCards(await Self.plan(height: context.displaySize.height, modes: configuration.modes).entries)[0]
    }

    func timeline(for configuration: NearbyWidgetIntent, in context: Context) async -> Timeline<NearbyEntry> {
        let plan = await Self.plan(height: context.displaySize.height, modes: configuration.modes)
        return Timeline(entries: Self.withCards(plan.entries), policy: .after(plan.reload))
    }

    /// `entries` as the card, but open until a tap's board closes (`OpenBoards`), with an entry for then.
    private static func withCards(_ entries: [NearbyEntry], now: Date = .now) -> [NearbyEntry] {
        let closes = OpenBoards.closes(boardID, now: now)
        var cards = entries.map { entry in
            var card = entry
            card.opened = closes.map { entry.date < $0 } ?? false
            return card
        }
        if let closes, let last = cards.lastIndex(where: { $0.date < closes }), !cards.contains(where: { $0.date == closes }) {
            var closed = cards[last]
            closed = NearbyEntry(date: closes, content: closed.content, settings: closed.settings, locatedAt: closed.locatedAt,
                                 modes: closed.modes, bus: closed.bus, dock: closed.dock, opened: false)
            cards.insert(closed, at: last + 1)
        }
        return cards
    }

    /// A minute-by-minute countdown through the reload (`reloadInterval`), both timed from after
    /// locating and fetching so entries start when shown; every `closedStep` minutes for the card.
    private static func plan(height: CGFloat, modes: NearbyModes) async -> (entries: [NearbyEntry], reload: Date) {
        let settings = SharedStore.loadSettings()
        // Just the card (no board open): less often, with fewer entries
        let opened = OpenBoards.closes(boardID) != nil
        let reload = { (now: Date) in now.addingTimeInterval(Self.reloadInterval(at: now, opened: opened)) }
        // A fix either widget found lately rather than a new one, so a reload doesn't hold up
        // Transit Directions' taps (`NearbyLocator.locateQuickly`)
        switch await NearbyLocator.locateQuickly() {
        case .notAllowed(let asked):
            // The app reloads the widget when location is turned on
            let now = Date.now
            return ([NearbyEntry(date: now, content: .locationOff(asked: asked), settings: settings, modes: modes)],
                    now.addingTimeInterval(60 * 60))
        case .notFound:
            let now = Date.now
            return ([NearbyEntry(date: now, content: .notFound, settings: settings, modes: modes)], reload(now))
        case .found(let location):
            // An older fix: the widget shows when it was taken
            let locatedAt = Date.now.timeIntervalSince(location.timestamp) > NearbyLocator.savedFixLife ? location.timestamp : nil
            // Look up the place name during the train fetch and wait only briefly after; if it's
            // late, show "Nearby". The lookup continues and saves the name for the next reload
            let place = Task { await NearbyLocator.placeName(for: location) }
            let placeName = {
                await TrainService.value(of: place, by: Date.now.addingTimeInterval(NearbyLocator.nameWait)) ?? nil
            }
            // The nearest bus place and dock alongside the trains
            let busPlace = Task { modes.bus ? await NearbyBuses.places(near: location)?.first : nil }
            let nearestDock = Task { () -> NearbyDock? in
                guard modes.bike, let docks = await CitiBike.docks() else { return nil }
                return docks.map { NearbyDock(dock: $0, meters: $0.location.distance(from: location)) }
                    .filter { $0.meters < 800 }
                    .min { $0.meters < $1.meters }
            }
            let near = modes.subway ? Nearby.stations(near: location, limit: 3) : []
            guard !near.isEmpty || !modes.subway else {
                let name = await placeName()
                let now = Date.now
                return ([NearbyEntry(date: now, content: .noStations(place: name, nearest: Nearby.nearest(to: location)),
                                     settings: settings, locatedAt: locatedAt, modes: modes)], reload(now))
            }
            // Every line at each station, both ways
            let selections = near.flatMap(\.station.lineSelections)
            let fetched = Task { await TrainService.trains(for: selections, includingOtherLines: false) }
            // Skipped when Settings has every alert kind off
            let alertEntries = Task {
                await TrainService.alertEntries(if: !settings.alertKinds.isEmpty, routes: Set(selections.flatMap(\.routes)))
            }
            // About once a day, a new timetable to fall back on
            let timetable = Task { await TimetableStore.refresh() }
            // Each fetch's timeout only counts idle time, so a slow connection could hold up the
            // widget past iOS's limit and leave it blank: whatever's late by `fetchWait` is left
            // out, shown as unreachable, and fetched again on the next reload
            let deadline = Date.now.addingTimeInterval(Self.fetchWait)
            var trains = await TrainService.value(of: fetched, by: deadline) ?? [:]
            let alerts = await TrainService.value(of: alertEntries, by: deadline) ?? nil
            let bus = await TrainService.value(of: busPlace, by: deadline) ?? nil
            let dock = await TrainService.value(of: nearestDock, by: deadline) ?? nil
            let name = await placeName()
            let now = Date.now
            var unreachable = !selections.isEmpty && trains.isEmpty
            // Lines the MTA couldn't give, from the timetable
            let missing = selections.filter { trains[$0.trainID] == nil }
            var fromTimetable = false
            if !missing.isEmpty, let timetable = TimetableStore.load(now: now) {
                trains.merge(TrainService.trains(for: missing, from: timetable, now: now)) { live, _ in live }
                unreachable = true
                fromTimetable = true
            }
            // A first download may finish within the wait; if not, a later reload's will
            _ = await TrainService.value(of: timetable, by: deadline)
            let minutes = Self.minutes(at: now, opened: opened)
            let end = now.addingTimeInterval(Double(minutes) * 60)
            let stations = near.map {
                NearbyStation($0, trains: trains, alerts: alerts, kinds: settings.alertKinds, now: now, until: end)
            }
            // The bus stop and dock first take their room
            let others = (bus.map { NearbyLayout.busHeight($0, at: now) + NearbyLayout.gap } ?? 0)
                + (dock == nil ? 0 : NearbyLayout.dockHeight + NearbyLayout.gap)
            let shown = NearbyLayout.fit(stations, in: NearbyLayout.room(height: height, unreachable: unreachable) - others)
            let content = NearbyEntry.Content.stations(place: name, stations: shown, unreachable: unreachable,
                                                       fromTimetable: fromTimetable)
            let entries = stride(from: 0, to: minutes, by: opened ? 1 : Self.closedStep).map { minute in
                NearbyEntry(date: now.addingTimeInterval(Double(minute) * 60), content: content, settings: settings,
                            locatedAt: locatedAt, modes: modes, bus: bus, dock: dock)
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
    /// Lines with their own row: those with trains, or an alert explaining why not.
    var lines: [NearbyLine]
    /// Lines not running now, shown in a small row below.
    let notRunning: [String]
    /// Lines that didn't fit, in a small row above `notRunning` ("4 more lines").
    var leftOut: [String] = []

    /// Each line gets its own trains (by `Selection.trainID`) and alerts of the Settings kinds,
    /// for a timeline from `now` to `end`.
    init(_ result: Nearby.Result, trains: [String: [Arrival]], alerts: [AlertsFeed.Entry]?,
         kinds: Set<ServiceAlert.Kind>, now: Date, until end: Date) {
        station = result.station
        distance = result.distance
        walkMinutes = result.walkMinutes
        let lines = result.station.routes.map {
            NearbyLine($0, at: result.station, trains: trains, alerts: alerts, kinds: kinds, now: now, until: end)
        }
        self.lines = lines.filter { !$0.isIdle }
        notRunning = lines.filter(\.isIdle).map(\.route)
    }

    /// Height on the widget, including the small rows.
    var height: CGFloat {
        let smallRows = CGFloat([leftOut, notRunning].filter { !$0.isEmpty }.count)
        return NearbyLayout.stationHeader + CGFloat(lines.count) * NearbyLayout.row + smallRows * NearbyLayout.smallRow
    }

    /// Moves the last full-row line to the front of `leftOut`, keeping station order.
    mutating func leaveOutLastLine() {
        guard let line = lines.popLast() else { return }
        leftOut.insert(line.route, at: 0)
    }
}

/// One line at a station near you, both ways.
struct NearbyLine: Identifiable {
    let route: String
    /// Toward Manhattan (uptown within it) first; nil where the line ends here.
    let directions: [NearbyDirection?]
    /// The most important alert, set only when there are no trains either way.
    let notice: Notice?
    /// The direction `notice` is for; tapping opens its alerts.
    let noticeSelection: Selection?

    var id: String { route }

    /// No trains either way and no alert explaining why. False if trains failed to load.
    var isIdle: Bool {
        notice == nil && directions.compactMap { $0 }.allSatisfy { $0.trains?.isEmpty == true }
    }

    init(_ route: String, at station: Station, trains: [String: [Arrival]], alerts: [AlertsFeed.Entry]?,
         kinds: Set<ServiceAlert.Kind>, now: Date, until end: Date) {
        self.route = route
        // Named, ordered directions with the line's own trains, as in the app's Nearby list
        let ways = station.ways(of: route, trains: trains, now: now)
        // The last entry's next train is the first after the timeline ends (`end`)
        var directions: [NearbyDirection?] = []
        // Worst alert across directions; ties go to the first direction
        var worst: (alert: ServiceAlert, selection: Selection)?
        for way in ways {
            guard let way else {
                directions.append(nil)
                continue
            }
            let shown = alerts.map { AlertsFeed.alerts(for: way.selection, in: $0, now: now).filter { kinds.contains($0.kind) } } ?? []
            if let alert = shown.first, worst.map({ alert.kind < $0.alert.kind }) ?? true {
                worst = (alert, way.selection)
            }
            // Keep trains through the timeline's end plus one, so every entry has a next train.
            // Strip stops (unused here) to save the widget's limited memory
            let kept = way.trains.map { list in
                var kept = list
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
            directions.append(NearbyDirection(label: way.label, selection: way.selection, trains: kept,
                                              alert: shown.first?.kind))
        }
        self.directions = directions
        let noTrains = ways.compactMap { $0 }.allSatisfy { $0.trains?.isEmpty == true }
        if noTrains, let worst {
            notice = Notice(worst.alert)
            noticeSelection = worst.selection
        } else {
            notice = nil
            noticeSelection = nil
        }
    }
}

/// One direction of a line at a nearby station, with its next trains.
struct NearbyDirection {
    /// "Manhattan", "Brooklyn", "Uptown"
    let label: String
    let selection: Selection
    /// Soonest first; nil if the line's feed failed to load.
    let trains: [Arrival]?
    /// Kind of its most important alert.
    let alert: ServiceAlert.Kind?

    /// The next train at `date`, including one still held at the platform.
    func next(at date: Date) -> Arrival? {
        trains?.first { $0.leaves > date }
    }
}

/// Widget measurements, for fitting stations before drawing.
enum NearbyLayout {
    /// Location symbol, place name and "Trains near you" at the top.
    static let header: CGFloat = 38
    /// Below the header.
    static let headerGap: CGFloat = 8
    /// Between stations' boxes.
    static let gap: CGFloat = 8
    /// A station box's padding above and below its rows.
    static let boxPadding: CGFloat = 6
    /// Station name and distance, plus the box's padding above and below.
    static let stationHeader: CGFloat = 22 + 2 * boxPadding
    static let row: CGFloat = 26
    /// A small row of left-out or not-running lines.
    static let smallRow: CGFloat = 22
    /// "Couldn't reach the MTA" at the bottom.
    static let problem: CGFloat = 22
    /// System margins around a large widget's content.
    static let margins: CGFloat = 16

    /// A bus place's box: its name, then a row per route (up to `busRoutes`).
    static func busHeight(_ place: NearbyBusPlace, at date: Date) -> CGFloat {
        stationHeader + CGFloat(min(place.lines(at: date).count, busRoutes)) * row
    }

    static let busRoutes = 2
    /// A dock's box: its name, then its counts.
    static let dockHeight: CGFloat = stationHeader + 30

    /// Height available for stations in a widget `height` points tall.
    static func room(height: CGFloat, unreachable: Bool) -> CGFloat {
        height - 2 * margins - header - headerGap - (unreachable ? problem : 0)
    }

    /// As many `stations` as fit, nearest first. Fold lines past four into bullets; else drop the
    /// farthest station and retry; else show only the nearest with fewer lines.
    static func fit(_ stations: [NearbyStation], in room: CGFloat) -> [NearbyStation] {
        func fits(_ stations: [NearbyStation]) -> Bool {
            stations.map(\.height).reduce(0, +) + gap * CGFloat(max(stations.count - 1, 0)) <= room
        }
        // Restart from all lines for each count, so nothing stays folded for a dropped station
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

    /// Which times get a symbol; always live ones on tinted/clear Home Screens (no green).
    private var marks: TimeMarks { entry.settings.timeMarks(withoutColor: withoutColor, renderingMode: renderingMode) }

    /// The card until a tap opens the board, as the Saved Route's. Open: each place in a box of
    /// its own, with a ✕ back to the card at the top right; a tap anywhere else relocates and
    /// refreshes, but with location off, where a tap opens the app to allow it.
    @ViewBuilder var body: some View {
        if case .locationOff = entry.content {
            board(refreshing: false)
        } else if !entry.opened {
            // Opens at once on the tap, drawn from what the card was drawn with, then reloads
            Toggle(isOn: false, intent: OpenBoardIntent(widgetID: NearbyProvider.boardID, leaves: nil)) {
                Text("Show what's near you")
            }
            .toggleStyle(SwapToggleStyle { isOn in
                Group {
                    if isOn.wrappedValue {
                        board(refreshing: true)
                    } else {
                        card
                    }
                }
                .contentShape(Rectangle())
            })
            .accessibilityLabel("Nearby, \(entry.modes.summary)")
            .accessibilityAddTraits(.isButton)
        } else {
            ZStack(alignment: .topTrailing) {
                // A toggle that's always off, as iOS flips it on tap before the intent runs: it
                // shows ↻ at once, until the reload draws it off again
                Toggle(isOn: false, intent: RefreshWidgetsIntent()) { Text("Refresh") }
                    .toggleStyle(SwapToggleStyle { isOn in
                        board(refreshing: isOn.wrappedValue)
                            .contentShape(Rectangle())
                    })
                    .accessibilityHint("Finds what's near you again, and its times")
                EndTripButton(large: true, closing: NearbyProvider.boardID)
                    .frame(height: NearbyLayout.header)
            }
        }
    }

    /// Until a tap: "Nearby", what it shows, and a mark for each kind big along the bottom.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nearby")
                .font(.headline)
                .foregroundStyle(BoardInk.text)
            Text(entry.modes.summary)
                .font(.caption)
                .foregroundStyle(BoardInk.gray)
                .lineLimit(2)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                if entry.modes.subway { disc("tram.fill", tint: .black) }
                if entry.modes.bus { disc("bus.fill", tint: BusBadge.blue) }
                if entry.modes.bike { CitiBikeMark(size: 52) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(renderingMode == .fullColor ? Color.accentColor.opacity(0.12) : BoardInk.color(.tile, route: true)))
    }

    private func disc(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 52 * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(Circle().fill(tint))
            .accessibilityHidden(true)
    }

    /// `refreshing`: just tapped, so ↻ shows until the new times.
    private func board(refreshing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch entry.content {
            case .stations(let place, let stations, let unreachable, let fromTimetable):
                header(place, refreshing: refreshing)
                VStack(alignment: .leading, spacing: NearbyLayout.gap) {
                    ForEach(stations, id: \.station.id) { stationView($0) }
                    if let bus = entry.bus { busView(bus) }
                    if let dock = entry.dock { dockView(dock) }
                }
                if stations.isEmpty, entry.bus == nil, entry.dock == nil {
                    message("location", entry.modes == NearbyModes(subway: false, bus: false, bike: false)
                                ? "Nothing chosen to show" : "Nothing near you",
                            entry.modes.subway || entry.modes.bus || entry.modes.bike
                                ? "No bus stop or dock within a quarter mile." : "Pick what to show in Edit Widget.")
                }
                Spacer(minLength: 0)
                if unreachable {
                    Label(fromTimetable ? "Couldn't reach the MTA: timetable times. Tap to try again."
                              : "Couldn't reach the MTA. Tap to try again.", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(BoardInk.gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: NearbyLayout.problem)
                }
            case .locationOff(let asked):
                header(nil, located: false, refreshing: false)
                if asked {
                    message("location.slash", "Location is off for Leeway.",
                            "Allow it While Using the App or Widgets to see the stations near you and their next trains.",
                            button: "Turn It On in Settings")
                } else {
                    message("location", "See the trains near you",
                            "Let Leeway use your location While Using the App or Widgets.",
                            button: "Allow Location")
                }
            case .notFound:
                header(nil, refreshing: refreshing)
                message("location.slash", "Couldn't find where you are", "Tap to try again.")
            case .noStations(let place, let nearest):
                header(place, refreshing: refreshing)
                message("tram", "No stations within \(Nearby.rangeDescription) of you",
                        nearest.map { "The nearest is \($0.station.name), \($0.distance) away." } ?? "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // `NearbyLayout`'s fixed row heights, each shared by two directions, fit text up to here
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    /// As the Transfers header, with a location symbol where its line bullet goes: the place
    /// name, then "Trains near you", or the fix time if it's old; ↻ from a tap until the new times.
    private func header(_ place: String?, located: Bool = true, refreshing: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: located ? "location.fill" : "location.slash")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(located ? Color.blue : Color.boardGray))
                .widgetAccentable()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(place ?? "Nearby")
                    .font(.body.bold())
                    .foregroundStyle(BoardInk.text)
                Group {
                    if let locatedAt = entry.locatedAt {
                        Text("as of \(locatedAt.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Near you")
                    }
                }
                .font(.footnote)
                .foregroundStyle(BoardInk.gray)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if refreshing {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(BoardInk.gray)
                    .accessibilityLabel("Refreshing")
            }
            if entry.opened, located {
                // Room for the ✕, drawn over it
                Pill(symbol: "xmark", large: true, round: true).hidden()
            }
        }
        .frame(height: NearbyLayout.header)
        .padding(.bottom, NearbyLayout.headerGap)
    }

    /// Name and distance, a row per line, then any small rows, in a box of its own.
    private func stationView(_ nearby: NearbyStation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(nearby.station.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(BoardInk.text)
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
                .foregroundStyle(BoardInk.gray)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(nearby.distance), \(nearby.walkMinutes) minute walk")
            }
            .frame(height: 22)
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
            if !nearby.leftOut.isEmpty {
                leftOutRow(nearby)
            }
            if !nearby.notRunning.isEmpty {
                notRunningRow(nearby)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, NearbyLayout.boxPadding)
        .background(BoardTile())
    }

    /// A box's name and walk, as a station's.
    private func boxHeader(_ name: String, distance: String, walkMinutes: Int) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.subheadline.bold())
                .foregroundStyle(BoardInk.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(distance)
                Text("·")
                Image(systemName: "figure.walk")
                Text("\(walkMinutes) min")
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(BoardInk.gray)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(distance), \(walkMinutes) minute walk")
        }
        .frame(height: 22)
    }

    private func miles(_ meters: Double) -> String {
        Nearby.distance(meters)
    }

    /// The nearest bus place: a row per route (as many as `NearbyLayout.busRoutes`), each way's
    /// next bus as a line's next trains.
    private func busView(_ place: NearbyBusPlace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            boxHeader(place.name, distance: miles(place.meters), walkMinutes: place.walkMinutes)
            ForEach(place.lines(at: entry.date).prefix(NearbyLayout.busRoutes), id: \.line) { line in
                HStack(spacing: 8) {
                    BusBadge(line: line.line, size: 20)
                        .frame(minWidth: 34)
                    ForEach(0..<2, id: \.self) { index in
                        if line.ways.indices.contains(index) {
                            busWay(line.ways[index], line: line.line)
                                .padding(.leading, index == 1 ? 6 : 0)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: NearbyLayout.row)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, NearbyLayout.boxPadding)
        .background(BoardTile())
    }

    private func busWay(_ way: NearbyBusPick.Way, line: String) -> some View {
        let next = way.arrivals.first { ($0.time ?? .distantPast) > entry.date }
        return HStack(spacing: 6) {
            Text(way.name)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .font(.footnote)
                .foregroundStyle(BoardInk.gray)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let next, let time = next.time {
                    let minutes = MinutesToGo(until: time, from: entry.date)
                    let color = next.isLive ? Color.liveText : BoardInk.color(.text, route: true)
                    StatusMark(isLive: next.isLive, marks: marks, size: 9)
                        .foregroundStyle(color)
                    Text(minutes.number)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color)
                    if !minutes.isNow {
                        Text("min")
                            .font(.footnote)
                            .foregroundStyle(BoardInk.gray)
                    }
                } else {
                    Text("–")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(BoardInk.gray)
                }
            }
            .monospacedDigit()
            .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(BusBadge.spokenName(line)) \(way.name)")
        .accessibilityValue(next?.time.map { MinutesToGo(until: $0, from: entry.date).spoken } ?? "No buses")
        .frame(maxWidth: .infinity)
    }

    /// The nearest dock: its counts, as Settings › Biking has them (Docks always).
    private func dockView(_ nearby: NearbyDock) -> some View {
        let kinds = entry.settings.bikeKinds
        let counts: [(Int, String)] = [
            kinds.showsBikes ? (nearby.dock.available(.bike), "Bikes") : nil,
            kinds.showsEBikes ? (nearby.dock.available(.eBike), "E-Bikes") : nil,
            (nearby.dock.free, "Docks"),
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 0) {
            boxHeader(nearby.dock.name, distance: miles(nearby.meters), walkMinutes: nearby.walkMinutes)
            HStack(spacing: 0) {
                ForEach(counts, id: \.1) { count in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(count.0)")
                            .font(.title3.bold())
                            .monospacedDigit()
                            .foregroundStyle(BoardInk.text)
                        Text(count.1)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BoardInk.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, NearbyLayout.boxPadding)
        .background(BoardTile())
    }

    /// A direction's name and next train.
    @ViewBuilder private func way(_ direction: NearbyDirection?) -> some View {
        if let direction {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    // Shrinks on small phones, beside a live mark, or at large text sizes
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
                .foregroundStyle(BoardInk.gray)
                Spacer(minLength: 0)
                time(direction.next(at: entry.date))
            }
            // Label includes the line so it makes sense alone; the time is the value
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenName(direction))
            .accessibilityValue(spokenTime(direction))
            .frame(maxWidth: .infinity)
        } else {
            // End of the line: trains only go the other way
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    /// "Now", "1 min", "12 min"; green if live; "–" if none or unknown.
    private func time(_ train: Arrival?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let train {
                let minutes = MinutesToGo(until: train.time, from: entry.date)
                StatusMark(isLive: train.isLive, marks: marks, size: 9)
                    .foregroundStyle(train.statusColor(scheduled: BoardInk.color(.text, route: true)))
                Text(minutes.number)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(train.statusColor(scheduled: BoardInk.color(.text, route: true)))
                if !minutes.isNow {
                    Text("min")
                        .font(.footnote)
                        .foregroundStyle(BoardInk.gray)
                }
            } else {
                Text("–")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BoardInk.gray)
            }
        }
        .monospacedDigit()
        .fixedSize()
    }

    /// VoiceOver name: "R Manhattan", or with an alert "R Uptown, Delays".
    private func spokenName(_ direction: NearbyDirection) -> String {
        let name = "\(Lines.name(of: direction.selection.firstRoute)) \(direction.label)"
        return direction.alert.map { "\(name), \($0.label)" } ?? name
    }

    /// "12 minutes, live", "Now, scheduled". Always says live/scheduled, even with marks off.
    private func spokenTime(_ direction: NearbyDirection) -> String {
        guard direction.trains != nil else { return "Couldn't load" }
        guard let train = direction.next(at: entry.date) else { return "No trains" }
        return "\(MinutesToGo(until: train.time, from: entry.date).spoken), \(train.isLive ? "live" : "scheduled")"
    }

    /// A line with no trains and the alert explaining why.
    private func noticeRow(_ line: NearbyLine, _ notice: Notice) -> some View {
        HStack(spacing: 8) {
            LineBullet(route: line.route, size: 20)
            HStack(spacing: 4) {
                // Hidden: the text already states the kind
                Image(systemName: notice.symbol)
                    .font(.caption2)
                    .foregroundStyle(notice.tint)
                    .accessibilityHidden(true)
                notice.bannerText
                    .font(.footnote)
                    .foregroundStyle(BoardInk.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: NearbyLayout.row)
    }

    /// Bullets of left-out lines and "4 more lines" (the app has them).
    private func leftOutRow(_ nearby: NearbyStation) -> some View {
        folded(nearby.leftOut) {
            Text(nearby.leftOut.count == 1 ? "1 more line" : "\(nearby.leftOut.count) more lines")
        }
    }

    /// Bullets of lines not running and "Not running now".
    private func notRunningRow(_ nearby: NearbyStation) -> some View {
        folded(nearby.notRunning) {
            Text("Not running now")
        }
    }

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
        .font(.footnote)
        .foregroundStyle(BoardInk.gray)
        .lineLimit(1)
        .frame(height: NearbyLayout.smallRow)
    }

    /// Shown instead of stations.
    private func message(_ symbol: String, _ title: String, _ detail: String, button: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(BoardInk.gray)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BoardInk.text)
                .padding(.top, 4)
            if !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(BoardInk.gray)
            }
            if let button {
                // Opens the app to allow location
                Link(destination: Nearby.allowURL) {
                    Text(button)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(BoardInk.text)
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.boardButton))
                }
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
    /// Near 5 Av and 9 St in Park Slope, with staggered trains per line.
    static var preview: NearbyEntry {
        let now = Date.now
        let near = Nearby.stations(near: CLLocation(latitude: 40.6680, longitude: -73.9890), limit: 3)
        // Each line's north/south terminals, which determine the direction labels
        let ends = ["F": ("F01N", "D43S"), "G": ("G22N", "F27S"), "R": ("G08N", "R45S")]
        var trains: [String: [Arrival]] = [:]
        var minutes = 1.0
        for selection in near.flatMap(\.station.lineSelections) {
            let route = selection.firstRoute
            let end = ends[route].map { selection.direction == .north ? $0.0 : $0.1 } ?? ""
            trains[selection.trainID] = [minutes, minutes + 9].map {
                Arrival(route: route, time: now.addingTimeInterval($0 * 60 + 30), stop: selection.stopIDs.first ?? "",
                        lastStop: end, isLive: $0 < 15)
            }
            minutes = (minutes + 5).truncatingRemainder(dividingBy: 13)
        }
        let end = now.addingTimeInterval(Double(NearbyProvider.minutesShown) * 60)
        let stations = near.map { NearbyStation($0, trains: trains, alerts: nil, kinds: [], now: now, until: end) }
        let shown = NearbyLayout.fit(stations, in: NearbyLayout.room(height: 354, unreachable: false))
        return NearbyEntry(date: now, content: .stations(place: "Park Slope", stations: shown, unreachable: false))
    }
}

extension NearbyEntry {
    /// `preview` with Park Slope's buses and nearest dock, open or as the card.
    static func everything(opened: Bool = true) -> NearbyEntry {
        var entry = preview
        entry.bus = NearbyBuses.preview().first
        entry.dock = NearbyDock(dock: CitiBike.Dock(id: "1", name: "5 Av & 3 St", lat: 40.67, lon: -73.98, bikes: 6, eBikes: 2,
                                                    docks: 9, renting: true, returning: true), meters: 160)
        entry.opened = opened
        // Fewer stations, for the bus stop and dock's room
        if case .stations(let place, let stations, _, _) = entry.content, let bus = entry.bus {
            let others = NearbyLayout.busHeight(bus, at: entry.date) + NearbyLayout.dockHeight + 2 * NearbyLayout.gap
            let shown = NearbyLayout.fit(stations, in: NearbyLayout.room(height: 354, unreachable: false) - others)
            entry = NearbyEntry(date: entry.date, content: .stations(place: place, stations: shown, unreachable: false),
                                settings: entry.settings, modes: entry.modes, bus: entry.bus, dock: entry.dock,
                                opened: opened)
        }
        return entry
    }
}

#Preview(as: .systemLarge) {
    NearbyWidget()
} timeline: {
    NearbyEntry.everything(opened: false)
    NearbyEntry.everything()
    NearbyEntry.preview
    NearbyEntry(date: .now, content: .locationOff(asked: false))
    NearbyEntry(date: .now, content: .locationOff(asked: true))
    NearbyEntry(date: .now, content: .notFound)
    NearbyEntry(date: .now, content: .noStations(place: "Montclair",
                                                 nearest: Nearby.nearest(to: CLLocation(latitude: 40.8259, longitude: -74.2090))))
}
