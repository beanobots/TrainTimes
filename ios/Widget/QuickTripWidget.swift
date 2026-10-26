import AppIntents
import CoreLocation
import os
import SwiftUI
import WidgetKit

/// Transit Directions: a trip shared from Apple Maps or Google Maps (the Share extension), or
/// planned here with Quick Trip, for an hour, as Transfers shows it with a change and Next train
/// without. Otherwise three buttons: Favorite Stop, your default train; Nearby, any line either
/// way at a station near you; and Quick Trip, to plan one. A ✕ beside walk goes back to them.
/// Nothing to pick in its Edit menu.
struct DirectionsWidget: Widget {
    let kind = WidgetKind.directions

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DirectionsProvider()) { entry in
            GeometryReader { proxy in
                Group {
                    if let bus = entry.busBoard {
                        BusBoardView(entry: bus, date: entry.date)
                            .transition(.identity)
                            .environment(\.endTripFace, EndTripFace(view: AnyView(QuickTripView(entry: entry.home, still: true)),
                                                                    size: proxy.size))
                    } else if let board = entry.board {
                        TrainWidgetView(entry: board)
                            // In at once, without the fade WidgetKit gives a view that's new: after
                            // Favorite Stop's tap, its toggle already drew the same board
                            .transition(.identity)
                            // The buttons its ✕ shows at once on a tap
                            .environment(\.endTripFace, EndTripFace(view: AnyView(QuickTripView(entry: entry.home, still: true)),
                                                                    size: proxy.size))
                    } else {
                        QuickTripView(entry: entry)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .environment(\.widgetSize, proxy.size)
            }
            .coordinateSpace(.named(EndTripFace.space))
            .containerBackground(Color.boardBackground, for: .widget)
        }
        .configurationDisplayName("Magic Widget")
        .description("Plan a Quick Trip, see your favorite stop or a train near you, or show directions shared to Leeway from Apple Maps or Google Maps.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct DirectionsEntry: TimelineEntry {
    let date: Date
    /// A trip, or Favorite Stop, as Next train or Transfers draws it; nil on Quick Trip's own screens.
    var board: TrainEntry? = nil
    var quickTrip = QuickTrip()
    /// Settings' default train: Favorite Stop, and where a Quick Trip starts unless picked.
    var favorite = Selection.fallback
    /// On `.nearby`, the stations nearest you, or why there aren't any.
    var nearby: NearbyList? = nil
    /// On `.trips`, the journeys to pick from (`QuickTrip.savedTrips`); on the buttons too, for
    /// Trip's toggle to draw them at once on a tap.
    var trips: [SavedWidget] = []
    /// On `.trips`, each journey's board from saved times, by `SavedWidget.id`, for its card's
    /// toggle to draw at once on a tap.
    var tripBoards: [UUID: TrainEntry] = [:]
    /// On the buttons, Favorite Stop as drawn from saved times, which its tap shows at once.
    var favoriteBoard: TrainEntry? = nil
    /// On the buttons, Nearby's stations from a recent fix, which its tap shows at once; nil
    /// without one, for "Finding your location".
    var nearbyAtOnce: NearbyList? = nil
    /// On `.nearby` with its "Bus" switch on, the closest bus stop each way.
    var buses: NearbyBusList? = nil
    /// A trip with a bus from New Trip (`SharedBusTrip`), drawn in place of everything else.
    var busBoard: BusBoardEntry? = nil

    /// On `.nearbyLine`, shown straight from Nearby as the only station: the one within
    /// `DirectionsProvider.nearbyRange`, or the nearest when none is.
    var onlyNearby: Bool { quickTrip.nearbyOnly == true }

    /// The Quick Trip and Favorite Stop buttons, as a board's ✕ goes back to.
    var home: DirectionsEntry {
        DirectionsEntry(date: date, quickTrip: QuickTrip(screen: .home), favorite: favorite)
    }

    /// What Nearby's toggle draws at once on a tap, as its redraw will: the stations near a
    /// recent fix (with just one, its lines, unless buses are on), else "Finding your location";
    /// with buses on, "Finding buses" under them.
    var nearbyFace: DirectionsEntry {
        let buses = quickTrip.includesBuses
        if !buses, case .stations(let stations, _) = nearbyAtOnce, stations.count == 1 {
            return DirectionsEntry(date: date, quickTrip: .only(stations[0]), favorite: favorite)
        }
        return DirectionsEntry(date: date, quickTrip: QuickTrip(screen: .nearby, nearbyBuses: quickTrip.nearbyBuses),
                               favorite: favorite, nearby: nearbyAtOnce ?? .finding, buses: buses ? .finding : nil)
    }

    /// What Trip's toggle draws at once on a tap: the journeys, as on the buttons.
    var tripsFace: DirectionsEntry {
        DirectionsEntry(date: date, quickTrip: QuickTrip(screen: .trips), favorite: favorite, trips: trips)
    }
}

extension QuickTrip {
    /// `result`'s lines, shown straight from Nearby as the only station.
    static func only(_ result: Nearby.Result) -> QuickTrip {
        QuickTrip(screen: .nearbyLine, nearbyStationID: result.station.id, nearbyMeters: result.meters, nearbyOnly: true)
    }
}

/// The Nearby button's stations, as found on its reload.
enum NearbyList {
    /// Nearest first: those within `DirectionsProvider.nearbyRange`, else just the nearest.
    /// `since`: when the fix was taken, if it's older than `NearbyLocator.savedFixLife` (no new
    /// one could be had), so the screen can say so.
    case stations([Nearby.Result], since: Date?)
    /// Location is off for the app, or (`asked` false) it hasn't asked yet.
    case locationOff(asked: Bool)
    /// Location is allowed but no fix was found.
    case notFound
    /// No station even within `Nearby`'s own range, far wider.
    case noneClose
    /// Waiting for a new fix, as iOS has no recent one; redrawn once there is.
    case finding
}

/// A trip while there is one, or Favorite Stop, from `Provider`; otherwise Quick Trip's screens.
struct DirectionsProvider: TimelineProvider {
    private let provider = Provider(directions: true)


    func placeholder(in context: Context) -> DirectionsEntry {
        DirectionsEntry(date: .now)
    }

    /// Settings' default train, which Favorite Stop shows.
    private static var favorite: Selection { SharedStore.defaultTrain }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (DirectionsEntry) -> Void) {
        Task { completion(await snapshot(in: context)) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<DirectionsEntry>) -> Void) {
        Task {
            let signpost = Signposts.widget.beginInterval("Directions timeline", id: Signposts.widget.makeSignpostID())
            // Read once per launch of the widget's process; timed to see what a cold start costs
            Signposts.interval("Load stations") { _ = StationDirectory.all.count }
            await timeline(in: context) { timeline in
                Signposts.widget.endInterval("Directions timeline", signpost)
                completion(timeline)
            }
        }
    }

    private func snapshot(in context: Context) async -> DirectionsEntry {
        if context.isPreview { return placeholder(in: context) }
        let now = Date.now
        let quickTrip = QuickTrip.load().shown(at: now)
        if let shown = SharedStore.loadSharedBusTrip(at: now) {
            return DirectionsEntry(date: now, favorite: Self.favorite, busBoard: await BusBoardEntry.fetch(shown.trip, otherWay: shown.otherWay, now: now))
        }
        guard SharedStore.loadSharedTrip(at: now) == nil, quickTrip.screen != .favorite else {
            return DirectionsEntry(date: now, board: await provider.snapshot(for: TrainWidgetIntent(), in: context),
                                   favorite: Self.favorite)
        }
        return await screens(quickTrip, at: now, in: context).entries[0]
    }

    /// A shared trip's board, Favorite Stop's, or the buttons, Nearby or Trip, each with what it
    /// needs fetched first, as iOS suspends the widget once it has the timeline.
    private func timeline(in context: Context, completion: @Sendable (Timeline<DirectionsEntry>) -> Void) async {
        let now = Date.now
        let quickTrip = QuickTrip.load().shown(at: now)
        // A trip with a bus from New Trip: redrawn as each bus (or train) goes, reloaded for new
        // times every few minutes, then the buttons once it ends
        if let shown = SharedStore.loadSharedBusTrip(at: now) {
            let board = await BusBoardEntry.fetch(shown.trip, otherWay: shown.otherWay, now: now)
            let favorite = Self.favorite
            let entries = board.dates(from: now, until: shown.expires)
                .map { DirectionsEntry(date: $0, favorite: favorite, busBoard: board) }
            let after = quickTrip.shown(at: shown.expires)
            let ended = after.screen == .favorite || shown.expires > now.addingTimeInterval(BusBoardEntry.reload) ? []
                : [await screens(after, at: shown.expires, in: context, favoriteBoard: false).entries[0]]
            let reload = min(shown.expires, now.addingTimeInterval(BusBoardEntry.reload))
            completion(Timeline(entries: entries + ended, policy: .after(reload)))
            return
        }
        if let trip = SharedStore.loadSharedTrip(at: now) {
            let boards = await provider.timeline(for: TrainWidgetIntent(), in: context)
            let during = boards.entries.filter { $0.date < trip.expires }
            let favorite = Self.favorite
            let entries = (during.isEmpty ? Array(boards.entries.prefix(1)) : during)
                .map { DirectionsEntry(date: $0.date, board: $0, favorite: favorite) }
            // Then the buttons once it ends, without waiting for a reload; Favorite Stop needs one.
            // Without Favorite Stop's board for its tap, an hour off: that comes with a reload
            let after = quickTrip.shown(at: trip.expires)
            let ended = after.screen == .favorite ? []
                : [await screens(after, at: trip.expires, in: context, favoriteBoard: false).entries[0]]
            completion(Timeline(entries: entries + ended, policy: boards.policy))
            return
        }
        if quickTrip.screen == .favorite {
            await favorite(quickTrip, in: context, completion: completion)
            return
        }
        // iOS suspends the widget once it has its timeline, so what Trip's journeys need comes
        // first: their trains, fetched while Trip's toggle draws them (up to `tripsWait`)
        if quickTrip.screen == .trips {
            let trips = QuickTrip.savedTrips(SharedStore.loadWidgets(), at: now)
            let fetching = Task { await prefetchTrips(trips) }
            _ = await TrainService.value(of: fetching, by: Date.now.addingTimeInterval(Self.tripsWait))
        }
        let screens = await screens(quickTrip, at: .now, in: context)
        // Nearby's station, as its lines or ways show (straight from Nearby, with just one near
        // you): each line both ways, fetched while they draw (up to `nearbyWait`), so the trip a
        // way or Both starts draws at once from them (`Provider`'s `quickTripReuse`). Again on
        // each of its screens, but only what's older than that reuse allows
        if let first = screens.entries.first, first.quickTrip.screen == .nearbyLine,
           let station = first.quickTrip.nearbyStationID.flatMap(StationDirectory.station(id:)) {
            let fetching = Task { await prefetchNearby(station) }
            _ = await TrainService.value(of: fetching, by: Date.now.addingTimeInterval(Self.nearbyWait))
        }
        completion(screens)
    }

    /// How long Trip waits for its journeys' trains before drawing them without.
    private static let tripsWait: TimeInterval = 4

    /// How long Nearby's station waits for its lines' trains before drawing without them.
    private static let nearbyWait: TimeInterval = 2

    /// Favorite Stop, with its latest times. Its toggle on the buttons draws it at once from saved
    /// times while they're fetched; fetched before the timeline, as iOS suspends the widget once
    /// it has it, so a redraw after it would never come.
    private func favorite(_ quickTrip: QuickTrip, in context: Context,
                          completion: @Sendable (Timeline<DirectionsEntry>) -> Void) async {
        let boards = await provider.timeline(for: TrainWidgetIntent(), in: context)
        let favorite = Self.favorite
        completion(Timeline(entries: boards.entries.map { DirectionsEntry(date: $0.date, board: $0, favorite: favorite) },
                            policy: boards.policy))
    }

    /// Trip's journeys' trains, fetched and saved before they're shown, so the cards' toggles
    /// draw them on a tap and the one picked draws at once. Together, so a feed is downloaded
    /// once for them all: journeys from the same station share its trains, and others on the
    /// same lines their feed (`TrainService.sharingFeeds`).
    private func prefetchTrips(_ trips: [SavedWidget]) async {
        await prefetch(trips.compactMap(QuickTrip.option(for:)), named: "Prefetch trips")
    }

    /// Each way of each of `station`'s lines (`Station.ways`), as its direction cards and Both
    /// show them, fetched and saved before one's tapped, so its trip draws at once.
    private func prefetchNearby(_ station: Station) async {
        let selections = station.routes.flatMap { route in
            station.ways(of: route, trains: [:], now: .now).compactMap { $0?.selection }
        }
        await prefetch(selections.map { SharedTrip.Option(selection: $0) }, named: "Prefetch nearby")
    }

    /// `options`' trains, fetched and saved together (`Provider.prefetch`), so a feed is
    /// downloaded once for them all (`TrainService.sharingFeeds`).
    private func prefetch(_ options: [SharedTrip.Option], named name: StaticString) async {
        // The same train and change twice is fetched once anyway (`Provider.prefetch` reuses it)
        let stops = options.reduce(into: Set<String>()) { stops, option in
            stops.formUnion(TrainService.feedStops(for: option.selection, change: option.change,
                                                   destination: option.directDestination))
        }
        await Signposts.interval(name) {
            await TrainService.sharingFeeds(atStops: stops) {
                await withTaskGroup(of: Void.self) { group in
                    for option in options {
                        group.addTask { await Provider.prefetch(option, within: TimelinePlan.quickTripReuseWindow) }
                    }
                }
            }
        }
    }

    /// The buttons, Nearby or Trip: as now, then the buttons once Nearby or Trip has been left
    /// long enough. Taps redraw them, so no reload. The buttons come with Favorite Stop from
    /// saved times (`favoriteBoard`), a quarter-minute at a time at first, then a minute at a
    /// time while they have trains, so its tap shows it at once, then without, so the tap
    /// waits for its redraw; and with Nearby's stations from a recent fix (`nearbyAtOnce`).
    private func screens(_ quickTrip: QuickTrip, at now: Date, in context: Context,
                         favoriteBoard: Bool = true) async -> Timeline<DirectionsEntry> {
        let saved = SharedStore.loadWidgets()
        let favorite = SharedStore.defaultTrain
        let located = quickTrip.screen == .nearby ? await Self.locate() : nil
        let nearby = located.map(Self.nearbyList)
        // With Nearby's "Bus" switch on, the closest stop each way, fetched before the timeline
        // like the stations, as iOS suspends the widget once it has it
        var buses: NearbyBusList? = nil
        if quickTrip.includesBuses, case .found(let location)? = located {
            buses = await Signposts.interval("Nearby buses") { await NearbyBuses.places(near: location) }
                .map(NearbyBusList.places) ?? .unavailable
        }
        // On the buttons, Nearby's stations from a recent fix, worked out once: each entry's until
        // the fix is too old
        let fix = quickTrip.screen == .home ? NearbyLocator.savedFix(at: now) : nil
        let nearbyAtOnce = fix.map { Self.nearbyList(.found($0)) }
        let nearbyUntil = fix.map { $0.timestamp.addingTimeInterval(NearbyLocator.savedFixLife) } ?? now
        // Each journey's board from saved times, for its card's toggle
        var journeys: [UUID: [TrainEntry]] = [:]
        if quickTrip.screen == .trips {
            for trip in QuickTrip.savedTrips(saved, at: now) {
                guard let option = QuickTrip.option(for: trip) else { continue }
                // None for a journey without trains, whose card's tap then waits for the redraw
                let boards = await provider.savedEntries(for: option, title: trip.title, in: context,
                                                         until: now.addingTimeInterval(Double(Self.tripBoardMinutes + 1) * 60))
                if boards.first?.trains.isEmpty == false {
                    journeys[trip.id] = boards
                }
            }
        }
        let entry = { (date: Date, shown: QuickTrip, board: TrainEntry?) in
            var shown = shown
            // With just one station near you, or none and the nearest, its lines at once, as
            // there's none to choose; not with buses on, which show beside it
            if shown.screen == .nearby, !shown.includesBuses, case .stations(let stations, _) = nearby, stations.count == 1 {
                var only = QuickTrip.only(stations[0])
                only.touched = shown.touched
                shown = only
            }
            return DirectionsEntry(date: date, quickTrip: shown, favorite: favorite,
                                   nearby: shown.screen == .nearby ? nearby : nil,
                                   trips: [.trips, .home].contains(shown.screen) ? QuickTrip.savedTrips(saved, at: date) : [],
                                   tripBoards: shown.screen == .trips
                                       ? journeys.compactMapValues { boards in boards.last { $0.date <= date } ?? boards.first }
                                       : [:],
                                   favoriteBoard: board,
                                   nearbyAtOnce: shown.screen == .home && date < nearbyUntil ? nearbyAtOnce : nil,
                                   buses: shown.screen == .nearby ? buses : nil)
        }
        if quickTrip.screen == .home {
            // Only as far as the next reload, as each entry is a whole drawing of the buttons and
            // what their toggles draw, and a long timeline made the ✕ back to them slow
            let horizon = now.addingTimeInterval(Self.homeRedraw)
            let saved = favoriteBoard ? await provider.savedEntries(in: context, until: horizon) : []
            let boards = Self.closer(Self.turningOver(saved.filter { $0.date >= now && $0.date < horizon },
                                                      until: horizon),
                                     from: now)
            let withTrains = boards.prefix { !$0.trains.isEmpty }
            let entries = [entry(now, quickTrip, withTrains.first)]
                + withTrains.dropFirst().map { entry($0.date, quickTrip, $0) }
                + (boards.dropFirst(withTrains.count).first.map { [entry($0.date, quickTrip, nil)] } ?? [])
            // Again after `homeRedraw`, from newer saved times or the timetable's, so Favorite
            // Stop's tap can still draw its board at once; not more often, as reloads that
            // aren't taps are rationed
            return Timeline(entries: entries, policy: .after(horizon))
        }
        var entries = [entry(now, quickTrip, nil)]
        // The journeys' boards a minute at a time, for their countdowns, while the times are fresh;
        // Nearby's minutes to go (`NearbyWayRow`, the buses') while its saved times are shown
        let minutes = !journeys.isEmpty ? Self.tripBoardMinutes : quickTrip.screen == .trips ? 0 : Self.nearbyMinutes
        if minutes > 0 {
            entries += (1...minutes).map { now.addingTimeInterval(Double($0) * 60) }
                .filter { date in quickTrip.planningExpires.map { date < $0 } ?? true }
                .map { entry($0, quickTrip, nil) }
        }
        if let expires = quickTrip.planningExpires {
            entries.append(entry(expires, quickTrip.shown(at: expires), nil))
        }
        return Timeline(entries: entries, policy: .never)
    }

    /// Meters: a quarter mile, about a five-minute walk. Nearby lists only stations this close,
    /// else the nearest.
    static let nearbyRange: Double = 0.25 * 1_609.344

    /// The most stations Nearby lists, two by two.
    static let nearbyLimit = 4

    /// How often the buttons reload by themselves, for Favorite Stop's board from saved times,
    /// and so how far ahead their timeline goes.
    private static let homeRedraw: TimeInterval = 15 * 60

    /// How long Trip's journeys' boards are drawn a minute at a time: as long as their times
    /// stand for a tap (`TimelinePlan.quickTripReuseWindow`).
    private static let tripBoardMinutes = 5

    /// How long Nearby's screens are drawn a minute at a time: as long as its rows show saved
    /// times (`NearbyWayRow.freshFor`), after which they show none.
    private static let nearbyMinutes = Int(NearbyWayRow.freshFor / 60)

    /// How long the buttons' Favorite Stop board is drawn `closerStep` at a time, so the
    /// countdown its toggle draws at once (frozen, `CountdownTimer`) is near the real one.
    private static let closerMinutes: TimeInterval = 3
    private static let closerStep: TimeInterval = 30

    /// `boards` drawn as the minutes to Favorite Stop's next train turn over, so the board its
    /// toggle draws at once on a tap is right to the minute, rather than a minute from whenever
    /// the timeline began: just those where the next train changes, then one more as each of its
    /// minutes goes by, each the one before as at its time.
    private static func turningOver(_ boards: [TrainEntry], until horizon: Date) -> [TrainEntry] {
        // A board a minute adds nothing the turnovers don't, so only where the next train changes
        var changes: [TrainEntry] = []
        for board in boards {
            if let last = changes.last, last.trains.first?.trip == board.trains.first?.trip,
               last.trains.count == board.trains.count { continue }
            changes.append(board)
        }
        return changes.indices.flatMap { index -> [TrainEntry] in
            let board = changes[index]
            let next = index + 1 < changes.count ? changes[index + 1].date : horizon
            guard let train = board.trains.first else { return [board] }
            let leave = board.selection.leaveTime(for: train)
            // Each time its whole minutes to go drop by one (`MinutesToGo`), before the next board: a
            // second past each whole minute before it leaves, as at the minute itself it's still the last
            let turns = stride(from: leave.addingTimeInterval(1 - 60 * floor(leave.timeIntervalSince(board.date) / 60)),
                               to: next, by: 60)
                .filter { $0 > board.date }
            return [board] + turns.map { board.at($0) }
        }
    }

    /// `boards` with one more every `closerStep` between them for the first `closerMinutes`
    /// from `now`, each the one before as at its time.
    private static func closer(_ boards: [TrainEntry], from now: Date) -> [TrainEntry] {
        let end = now.addingTimeInterval(closerMinutes * 60)
        return boards.indices.flatMap { index -> [TrainEntry] in
            let board = boards[index]
            guard board.date < end else { return [board] }
            let next = min(index + 1 < boards.count ? boards[index + 1].date : end, end)
            return stride(from: board.date, to: next, by: closerStep).map { board.at($0) }
        }
    }

    /// Where you are, for the Nearby button's stations (`nearbyList(_:)`) and buses: by a recent fix if
    /// there's one, else once you're found, waiting at most `NearbyLocator.wait` before going
    /// by the last fix (`NearbyLocator.locateQuickly`), while Nearby's toggle draws "Finding your
    /// location". Found before the timeline, as iOS suspends the widget once it has it.
    private static func locate() async -> NearbyLocator.Outcome {
        await Signposts.interval("Locate", { await NearbyLocator.locateQuickly() })
    }


    /// Up to `nearbyLimit` stations within `nearbyRange` of where `outcome` says you are, nearest
    /// first; with none that close, the nearest; or why there are none.
    private static func nearbyList(_ outcome: NearbyLocator.Outcome) -> NearbyList {
        switch outcome {
        case .notAllowed(let asked):
            return .locationOff(asked: asked)
        case .notFound:
            return .notFound
        case .found(let location):
            let near = Nearby.stations(near: location, limit: nearbyLimit)
            let close = near.filter { $0.meters <= nearbyRange }
            let shown = close.isEmpty ? Array(near.prefix(1)) : close
            let old = Date.now.timeIntervalSince(location.timestamp) > NearbyLocator.savedFixLife
            return shown.isEmpty ? .noneClose : .stations(shown, since: old ? location.timestamp : nil)
        }
    }

}

// MARK: - Views

/// Transit Directions' own screens: its Favorite Stop, Nearby and Trip buttons, Nearby's stations
/// and lines, and Trip's journeys.
struct QuickTripView: View {
    let entry: DirectionsEntry
    /// The buttons as a picture, without any: what a board's ✕ shows at once on a tap.
    var still = false
    @Environment(\.widgetContentMargins) private var margins
    @Environment(\.widgetSize) private var widgetSize

    private var quickTrip: QuickTrip { entry.quickTrip }

    var body: some View {
        Group {
            if quickTrip.screen == .nearby {
                nearbyScreen.padding(margins)
            } else if quickTrip.screen == .nearbyLine {
                nearbyLineScreen.padding(margins)
            } else if quickTrip.screen == .nearbyBus, let place = quickTrip.nearbyBusPlace {
                NearbyBusScreen(place: place, pick: quickTrip.nearbyBus, date: entry.date, still: still).padding(margins)
            } else if quickTrip.screen == .trips {
                tripsScreen.padding(margins)
            } else if still {
                cards
            } else {
                home
            }
        }
        // A tap anywhere else on Nearby or Trip redraws it, rather than opening the app as a tap
        // on no control does
        .background {
            if !still, quickTrip.screen != .home {
                // The only station's lines relocate you, as Nearby does; a way picked stays
                Button(intent: ShowQuickTripScreenIntent(entry.onlyNearby && quickTrip.nearbyRoute == nil ? .nearby : quickTrip.screen)) {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
        }
        // Each screen in at once, in place of the last: a toggle's face already drew it on the
        // tap, so the redraw gives way to the same unseen. Not sliding in, which could leave a
        // screen undrawn, off to the side, until the next redraw
        .id(quickTrip.screen)
        .transition(.identity)
    }

    // MARK: Buttons

    /// Favorite Stop, Nearby and Trip. iOS flips a toggle on tap before its intent runs, so each
    /// is one, drawing what its tap shows at once until the redraw shows the same. Favorite
    /// Stop's toggle is the whole widget, its face its card and the circles (`cards`), and on a
    /// tap its board from saved times (`favoriteBoard`), as only a face that is the toggle itself
    /// draws on a device; without that board, it's a button, waiting for the redraw. Nearby's and
    /// Trip's are clear, over their halves of the circles' column, drawing "Finding your
    /// location" or the journeys over the whole widget (`wholeWidgetFace`).
    private var home: some View {
        ZStack {
            if let board = entry.favoriteBoard {
                // Sized to the widget exactly, as WidgetKit takes taps on a toggle only over its
                // label's own size (`TrainWidgetView.refreshToggle`)
                let style = SwapToggleStyle { isOn in
                    // Swapped, not crossfaded, which drew both at the start of the swap
                    Group {
                        if isOn.wrappedValue {
                            TrainWidgetView(entry: board, still: true)
                                .transition(.pressed)
                        } else {
                            cards
                                .transition(.identity)
                        }
                    }
                    .frame(width: widgetSize?.width, height: widgetSize?.height)
                    .contentShape(Rectangle())
                }
                Toggle(isOn: false, intent: ShowQuickTripScreenIntent(.favorite, from: .home)) {
                    Text("Favorite Stop")
                }
                .toggleStyle(style)
                .accessibilityLabel(favoriteLabel)
                .accessibilityAddTraits(.isButton)
            } else {
                Button(intent: ShowQuickTripScreenIntent(.favorite, from: .home)) {
                    cards
                        .frame(width: widgetSize?.width, height: widgetSize?.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favoriteLabel)
            }
            HStack(spacing: 0) {
                // Favorite Stop's part is its toggle's, under these
                Color.clear
                VStack(spacing: 0) {
                    homeToggle(.nearby, label: "Nearby", hint: "Shows a train at a station near you",
                               face: AnyView(QuickTripView(entry: entry.nearbyFace, still: true)))
                    homeToggle(.trips, label: "Trip", hint: "Shows one of your saved trains",
                               face: AnyView(QuickTripView(entry: entry.tripsFace, still: true)))
                }
                .frame(width: circlesColumn)
            }
        }
    }

    private var favoriteLabel: String { "Favorite Stop, \(entry.favorite.station?.name ?? "")" }

    /// A clear toggle over its half of the circles' column, to show `screen`, drawing `face` over
    /// the whole widget on a tap. From the buttons, as a face can be drawn over them until the
    /// redraw (`ShowQuickTripScreenIntent.from`).
    private func homeToggle(_ screen: QuickTrip.Screen, label: String, hint: String, face: AnyView?) -> some View {
        let style = SwapToggleStyle { isOn in
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .wholeWidgetFace(isOn.wrappedValue && face != nil) { face }
        }
        return Toggle(isOn: false, intent: ShowQuickTripScreenIntent(screen, from: .home)) {
            Text(label)
        }
        .toggleStyle(style)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }

    /// How big Favorite Stop's line, Nearby's and Trip's circles are.
    private static let circleSize: CGFloat = 52
    /// Between Nearby's and Trip's circles.
    private static let circleGap: CGFloat = 10
    /// Room to the right of Nearby's and Trip's circles, besides the margin.
    private static let circleTrailing: CGFloat = 8

    /// The right of the widget, edge to edge, for Nearby's and Trip's circles: a margin from
    /// Favorite Stop's card, as from the edge, plus `circleTrailing`. Their toggles take it all,
    /// so a tap by a circle is its, rather than Favorite Stop's.
    private var circlesColumn: CGFloat {
        margins.trailing + Self.circleSize + Self.circleTrailing + margins.trailing
    }

    /// Favorite Stop's card, then Nearby's and Trip's circles one above the other, as drawn under
    /// the toggles and by a board's ✕.
    private var cards: some View {
        HStack(spacing: 0) {
            favoriteCard
                .padding(.leading, margins.leading)
                .padding(.top, margins.top)
                .padding(.bottom, margins.bottom)
            VStack(spacing: Self.circleGap) {
                symbolBadge("location.fill", tint: HomeTint.nearby)
                symbolBadge(QuickTripSymbol.name, tint: HomeTint.trip)
            }
            .frame(width: circlesColumn)
            .frame(maxHeight: .infinity)
        }
    }

    /// Favorite Stop's station, way and lines, drawn as Settings picks (`FavoriteCardStyle`).
    /// No times: its board, drawn on a tap, has those.
    private var favoriteCard: some View {
        StopCard(station: entry.favorite.station?.cardName ?? "", heading: entry.favorite.cardHeading,
                 routes: entry.favorite.routes, style: SharedStore.loadSettings().favoriteCard, fitsHeading: false)
    }

    /// Nearby's or Trip's symbol, white in a circle of its colour.
    private func symbolBadge(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: Self.circleSize * 0.48, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.circleSize, height: Self.circleSize)
            .background(Circle().fill(tint))
    }

    // MARK: Trips

    /// The journeys to pick from, as cards sharing out the room (two by two for four), with ✕
    /// back to the buttons: a picture of the cards, with a clear toggle over each (none when
    /// `still`). A tap draws that journey's board at once from the times fetched as this showed
    /// (`tripBoards`), until the redraw shows the same.
    private var tripsScreen: some View {
        let compact = entry.trips.count > 3
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Trip", systemImage: QuickTripSymbol.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.boardText)
                Spacer()
                homeButton
            }
            .padding(.bottom, 3)
            ZStack {
                tripGrid { tripCard($0, compact: compact) }
                    .accessibilityHidden(!still)
                if !still {
                    tripGrid(tripToggle)
                }
            }
        }
    }

    /// The journeys in a row, or two by two for four, each `cell` taking its share of the room
    /// with the gaps between, so a tap between two cards is still one's rather than opening the app.
    private func tripGrid<Cell: View>(@ViewBuilder _ cell: @escaping (SavedWidget) -> Cell) -> some View {
        let trips = entry.trips
        let columns = trips.count == 4 ? 2 : max(min(trips.count, 3), 1)
        let rows = stride(from: 0, to: trips.count, by: columns).map { Array(trips[$0..<min($0 + columns, trips.count)]) }
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    ForEach(rows[index]) { trip in
                        cell(trip)
                            .padding(3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    ForEach(rows[index].count..<columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(-3)
    }

    /// A clear toggle over a journey's card, to show it (`StartSavedTripIntent`), drawing its
    /// board over the whole widget on a tap if there's one to draw.
    private func tripToggle(_ trip: SavedWidget) -> some View {
        let board = entry.tripBoards[trip.id]
        let style = SwapToggleStyle { isOn in
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .wholeWidgetFace(isOn.wrappedValue && board != nil) {
                    if let board {
                        TrainWidgetView(entry: board, still: true)
                    }
                }
        }
        return Toggle(isOn: false, intent: StartSavedTripIntent(trip)) {
            Text(trip.title)
        }
        .toggleStyle(style)
        .accessibilityLabel(tripLabel(trip))
        .accessibilityAddTraits(.isButton)
    }

    /// A journey: its lines (then those it changes to), its name, and without a change or a
    /// destination, which way it goes.
    private func tripCard(_ trip: SavedWidget, compact: Bool) -> some View {
        let size: CGFloat = compact ? 15 : 20
        return VStack(alignment: .leading, spacing: 1) {
            // Every line, yours then those changed to (at any of the change's stations): the
            // biggest bullets that fit, then as many as fit with how many more
            ViewThatFits(in: .horizontal) {
                ForEach([size, size * 0.8, size * 0.65], id: \.self) { size in
                    tripBullets(trip, size: size)
                }
                tripBullets(trip, size: size * 0.65, limit: 6)
            }
            Spacer(minLength: 0)
            Text(trip.title)
                .font((compact ? Font.caption : .subheadline).bold())
                .foregroundStyle(Color.boardText)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.7)
            // Which way, for a journey with neither a change nor a destination; the others' bullets
            // and name say enough. Its room kept on them, so the cards stay the same size
            let showsWay = trip.change == nil && trip.directDestination == nil
            Text(trip.selection.heading)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.boardGray)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .opacity(showsWay ? 1 : 0)
                .accessibilityHidden(!showsWay)
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.boardText.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    /// `trip`'s lines, then → and the lines it changes to; with `limit`, only that many of all
    /// of them, then "+n".
    private func tripBullets(_ trip: SavedWidget, size: CGFloat, limit: Int? = nil) -> some View {
        let own = trip.selection.routes
        let onward = trip.change?.allRoutes ?? []
        let shownOwn = Array(own.prefix(limit ?? own.count))
        let shownOnward = Array(onward.prefix(max((limit ?? .max) - shownOwn.count, 0)))
        let more = own.count + onward.count - shownOwn.count - shownOnward.count
        return HStack(spacing: 2) {
            ForEach(shownOwn, id: \.self) { LineBullet(route: $0, size: size) }
            if !onward.isEmpty {
                Image(systemName: "arrow.right")
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundStyle(Color.boardGray)
                ForEach(shownOnward, id: \.self) { LineBullet(route: $0, size: size) }
            }
            if more > 0 {
                Text("+\(more)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.boardGray)
            }
        }
        .fixedSize()
    }

    /// "Change at Atlantic Av", "To 34 St-Herald Sq", or which way it goes.
    private func tripDetail(_ trip: SavedWidget) -> String {
        if let change = trip.change, change.station != nil { return "Change at \(change.stationNames(for: trip.selection))" }
        if let destination = trip.directDestination { return "To \(destination.name)" }
        return trip.selection.heading
    }

    private func tripLabel(_ trip: SavedWidget) -> String {
        let onward = trip.change.map { ", changing to the \(Lines.list($0.allRoutes))" } ?? ""
        return "\(trip.title), \(Lines.list(trip.selection.routes))\(onward), \(tripDetail(trip))"
    }

    // MARK: Nearby

    /// The stations nearest you, each with its lines and how far it is, with ✕ back to the
    /// buttons; or why there aren't any.
    private var nearbyScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Nearby", systemImage: "location.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.boardText)
                // No new fix could be had in time, so it's where you were then
                if case .stations(_, let since?) = entry.nearby {
                    Text("as of \(since.clock)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.boardGray)
                        .accessibilityLabel("Near where you were at \(Spoken.clock(since))")
                }
                Spacer()
                NearbyBusSwitch(on: quickTrip.includesBuses, still: still)
                homeButton
            }
            switch entry.nearby {
            case .stations(let stations, _):
                placeGrid(nearbyPlaces(stations))
            case .noneClose where quickTrip.includesBuses:
                // No subway near, but buses may be
                let places = nearbyPlaces([])
                if places.isEmpty {
                    nearbyProblem(entry.buses == .unavailable ? "Bus times aren't available just now"
                                  : "No stations or bus stops within \(Nearby.rangeDescription)", link: nil)
                } else {
                    placeGrid(places)
                }
            case .locationOff(let asked):
                nearbyProblem(asked ? "Location is off for Leeway" : "Leeway needs your location",
                              link: (Nearby.allowURL, asked ? "Turn On in Settings" : "Allow Location"))
            case .noneClose:
                nearbyProblem("No stations within \(Nearby.rangeDescription)", link: nil)
            case .finding:
                VStack(spacing: 6) {
                    Image(systemName: "location.magnifyingglass")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.boardText)
                    Text("Finding your location…")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.boardGray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            case .notFound, nil:
                nearbyProblem("Couldn't find where you are", link: nil)
            }
        }
        .buttonStyle(.plain)
    }

    /// A station or bus place in Nearby's grid.
    private enum NearbyPlace {
        case station(Nearby.Result)
        case bus(NearbyBusPlace)

        var meters: Double {
            switch self {
            case .station(let result): result.meters
            case .bus(let place): place.meters
            }
        }

        var isStation: Bool {
            if case .station = self { return true }
            return false
        }
    }

    /// The stations near you, and with buses on the bus places too: the four nearest of both,
    /// stations first, then bus places, each nearest first.
    private func nearbyPlaces(_ stations: [Nearby.Result]) -> [NearbyPlace] {
        let buses = quickTrip.includesBuses ? entry.buses?.places ?? [] : []
        guard !buses.isEmpty else { return stations.map(NearbyPlace.station) }
        let nearest = (stations.map(NearbyPlace.station) + buses.map(NearbyPlace.bus))
            .sorted { $0.meters < $1.meters }
            .prefix(4)
        return nearest.filter(\.isStation) + nearest.filter { !$0.isStation }
    }

    /// The places as cards sharing out the room below the title, each the same width: up to
    /// three in a row, four two by two.
    private func placeGrid(_ places: [NearbyPlace]) -> some View {
        let columns = max(places.count == 4 ? 2 : min(places.count, 3), 1)
        let rows = stride(from: 0, to: places.count, by: columns).map { Array(places.indices[$0..<min($0 + columns, places.count)]) }
        return GeometryReader { proxy in
            let width = (proxy.size.width - 6 * CGFloat(columns - 1)) / CGFloat(columns)
            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(rows[row], id: \.self) { index in
                            placeCard(places[index], compact: rows.count > 1)
                                .frame(width: width)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// A station's or bus place's card: its lines' bullets or badges flowing beside its walk in
    /// the top right, then on under it, and its name; `compact` two rows of cards.
    @ViewBuilder private func placeCard(_ place: NearbyPlace, compact: Bool) -> some View {
        switch place {
        case .station(let result):
            tappable(PickNearbyStationIntent(result)) {
                card(name: result.station.name, walk: result.walkMinutes, count: result.station.routes.count,
                     compact: compact) { size, shown in
                    ForEach(result.station.routes.prefix(shown), id: \.self) { LineBullet(route: $0, size: size) }
                }
            }
            .accessibilityLabel("\(result.station.name), \(result.walkMinutes) minute walk")
        case .bus(let bus):
            let lines = bus.lines(at: entry.date).map(\.line)
            tappable(PickNearbyBusPlaceIntent(bus)) {
                card(name: bus.name, walk: bus.walkMinutes, count: lines.count, compact: compact) { size, shown in
                    ForEach(lines.prefix(shown), id: \.self) { BusBadge(line: $0, size: size) }
                }
            }
            .accessibilityLabel("\(bus.name) bus stop, \(lines.map(BusBadge.spokenName).joined(separator: ", ")), "
                                + "\(bus.walkMinutes) minute walk")
        }
    }

    /// `marks(size, shown)` draws the first `shown` of `count` lines at `size`: two rows of cards
    /// show four and "+N"; one row shows them all, smaller the more there are, as they flow.
    private func card<Marks: View>(name: String, walk: Int, count: Int, compact: Bool,
                                   @ViewBuilder marks: (CGFloat, Int) -> Marks) -> some View {
        let shown = compact ? min(count, 4) : count
        let size: CGFloat = compact ? 15 : count <= 4 ? 20 : count <= 6 ? 17 : 14
        return VStack(alignment: .leading, spacing: 1) {
            ZStack(alignment: .topTrailing) {
                FlowRow(spacing: 2, firstLineInset: 56) {
                    marks(size, shown)
                    if count > shown {
                        Text("+\(count - shown)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.boardGray)
                            .frame(height: size)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                WalkTime(minutes: walk)
            }
            Spacer(minLength: 0)
            Text(name)
                .font(.subheadline.bold())
                .foregroundStyle(Color.boardText)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.7)
        }
        .padding(compact ? 8 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.boardText.opacity(0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Why there are no stations, with a link to the app to fix it if there's one.
    private func nearbyProblem(_ text: String, link: (url: URL, title: String)?) -> some View {
        VStack(spacing: 6) {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.boardGray)
            if let link {
                let label = Text(link.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.boardText)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Color.boardButton))
                // Only drawn on a toggle's face (`tappable`)
                if still {
                    label
                } else {
                    Link(destination: link.url) { label }
                }
            }
        }
        // In the middle of the room below the title
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A nearby station's lines, a big bullet each, to pick one; then (`nearbyRoute`), or at
    /// once for a station with one line, a card for each way it goes, to show its trains.
    @ViewBuilder private var nearbyLineScreen: some View {
        if let station = quickTrip.nearbyStationID.flatMap(StationDirectory.station(id:)) {
            let result = Nearby.Result(station: station, meters: quickTrip.nearbyMeters ?? 0)
            if let route = quickTrip.nearbyRoute ?? (station.routes.count == 1 ? station.routes.first : nil) {
                directionScreen(result, route: route)
            } else {
                linesScreen(result)
            }
        }
    }

    /// Page one: the station's lines filling the room under the header: up to four, a tall card
    /// each, its bullet big and where it goes each way; more, two rows of tiles.
    private func linesScreen(_ result: Nearby.Result) -> some View {
        let routes = result.station.routes
        return VStack(alignment: .leading, spacing: 6) {
            // The only station: no list to go back to
            nearbyHeader(result, route: nil, back: entry.onlyNearby ? nil : ShowQuickTripScreenIntent(.nearby),
                         backLabel: "Back to the stations near you")
            NearbyLineGrid(items: routes) { route, tall in
                tappable(PickNearbyLineIntent(route, at: result, only: entry.onlyNearby)) {
                    let ends = result.station.ways(of: route, trains: [:], now: .now).compactMap { $0 }
                        .map { $0.label.isEmpty ? $0.direction.rawValue : $0.label }
                    NearbyLineCard(ends: ends, tall: tall) {
                        LineBullet(route: route, size: tall ? (routes.count > 3 ? 30 : 36) : 26)
                    }
                }
                .accessibilityLabel("\(Lines.name(of: route)) train")
            }
        }
        .buttonStyle(.plain)
    }

    /// Page two: a row for each way `route` goes, with where it ends and its next train, then
    /// where it goes two ways, Both, a tile down their side. ‹ back to the station's lines, or for
    /// a station with one line, as Nearby's lines would.
    private func directionScreen(_ result: Nearby.Result, route: String) -> some View {
        let ways = result.station.ways(of: route, trains: [:], now: .now).compactMap { $0 }
        let oneLine = result.station.routes.count == 1
        return VStack(alignment: .leading, spacing: 6) {
            if oneLine {
                nearbyHeader(result, route: route, back: entry.onlyNearby ? nil : ShowQuickTripScreenIntent(.nearby),
                             backLabel: "Back to the stations near you")
            } else {
                nearbyHeader(result, route: route, back: PickNearbyLineIntent(nil, at: result, only: entry.onlyNearby),
                             backLabel: "Back to \(result.station.name)'s lines")
            }
            HStack(spacing: 6) {
                VStack(spacing: 6) {
                    ForEach(ways, id: \.selection.trainID) { way in
                        let label = way.label.isEmpty ? way.direction.rawValue : way.label
                        tappable(ShowNearbyTrainIntent(way.selection)) {
                            NearbyWayRow(route: route, way: way, label: label,
                                         end: destination(of: route, way: way, label: label), date: entry.date)
                        }
                    }
                }
                if ways.count == 2, let first = ways.first {
                    tappable(ShowNearbyTrainIntent(first.selection, bothWays: true)) {
                        NearbyBothTile(route: route)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Where `route` ends going `way` ("Forest Hills-71 Av"), under its card's `label`; nil
    /// where the label already names it, or for a line not in lines.json.
    private func destination(of route: String, way: LineWay, label: String) -> String? {
        guard let end = StationDirectory.end(of: route, going: way.selection.direction(of: route)),
              label != end.name, label != end.short else { return nil }
        return end.name
    }

    /// ‹ (`back`, if any), `route`'s bullet, the station's name, and how far it is below, with
    /// "Nearest station" when none was within `nearbyRange`; ✕ to the buttons.
    private func nearbyHeader<Back: AppIntent>(_ result: Nearby.Result, route: String?, back: Back?,
                                               backLabel: String) -> some View {
        let title = HStack(alignment: .top, spacing: 6) {
            if back != nil {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.boardGray)
                    .padding(.top, 3)
            }
            if let route {
                LineBullet(route: route, size: 20)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    Text(result.station.name)
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.boardText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 1)
                    if quickTrip.nearbyMeters != nil {
                        WalkTime(minutes: result.walkMinutes)
                            .padding(.top, 3)
                    }
                }
                // None within range, so the nearest, further off
                if quickTrip.nearbyMeters != nil, result.meters > DirectionsProvider.nearbyRange {
                    Text("Nearest station")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(HomeTint.nearby)
                }
            }
        }
        .contentShape(Rectangle())
        return HStack(alignment: .top, spacing: 6) {
            if let back {
                tappable(back) { title }
                    .accessibilityLabel(backLabel)
            } else {
                title
            }
            Spacer()
            // Straight from Nearby, as the only station: Nearby's switch, there being no list
            if entry.onlyNearby {
                NearbyBusSwitch(on: false, still: still)
            }
            homeButton
        }
    }

    /// ✕ back to the Favorite Stop, Nearby and Quick Trip buttons.
    /// A button for `intent`, or when `still` (a toggle's face) just its label. A face is there
    /// to be tapped before it shows, over the buttons, so its own buttons took taps meant for
    /// those under them: Nearby's direction cards, drawn on its face from a recent fix, took
    /// Favorite Stop's taps.
    @ViewBuilder private func tappable<Intent: AppIntent, Label: View>(_ intent: Intent,
                                                                       @ViewBuilder label: () -> Label) -> some View {
        if still {
            label()
        } else {
            Button(intent: intent, label: label)
        }
    }

    /// Room for it only when `still`: a toggle's face can't hold buttons, and a ✕ drawn there
    /// would be over another toggle until the redraw, which a tap on it would flip.
    @ViewBuilder private var homeButton: some View {
        if still {
            Pill(symbol: "xmark", large: true, round: true)
                .hidden()
        } else {
            Button(intent: ShowQuickTripScreenIntent(.home)) {
                Pill(symbol: "xmark", large: true, round: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Favorite Stop, Nearby and Trip")
        }
    }

}

/// Nearby's and Trip's colours on the buttons, from hues no line's bullet is near, so Favorite
/// Stop's card, in its line's colour, never matches them.
enum HomeTint {
    static let nearby = Color(hex: 0x00A3A3)
    static let trip = Color(hex: 0x7B61FF)
}

// MARK: - Previews

extension DirectionsEntry {
    /// Trip's journeys: to work with a change, to Herald Sq, the G, and Atlantic Av's N and R.
    static var previewTrips: [SavedWidget] {
        var work = SavedWidget(selection: .fallback, change: Change(stationID: "R31", routes: ["B", "D", "N", "Q"]))
        work.name = "Work"
        var herald = SavedWidget(selection: .fallback)
        herald.name = "Herald Sq"
        herald.destinationID = "R17"
        let g = SavedWidget(selection: Selection(stationID: "F24", routes: ["G"], direction: .north))
        let atlantic = SavedWidget(selection: Selection(stationID: "R31", routes: ["N", "R"], direction: .south))
        return [work, herald, g, atlantic]
    }

}

#Preview("Transit Directions", as: .systemMedium) {
    DirectionsWidget()
} timeline: {
    // Favorite Stop's board ready for its tap, then not
    DirectionsEntry(date: .now, favoriteBoard: TrainEntry.preview)
    DirectionsEntry(date: .now)
    // Nearby: four stations within a quarter mile, then Atlantic Av's lines, its N either way, Red
    // Hook's nearest station as there's none close, and Prospect Av's one line straight to which way
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby),
                    nearby: .stations(Nearby.stations(near: CLLocation(latitude: 40.7125, longitude: -74.0080), limit: 4), since: nil))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearbyLine, nearbyStationID: "R31", nearbyMeters: 120))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearbyLine, nearbyStationID: "R31", nearbyMeters: 120, nearbyRoute: "N"))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearbyLine, nearbyStationID: "F22", nearbyMeters: 1_380, nearbyOnly: true))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearbyLine, nearbyStationID: "R34", nearbyMeters: 90))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby), nearby: .noneClose)
    // Nearby's toggle draws this at once on a tap; the redraw shows it until you're found
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby), nearby: .finding)
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby), nearby: .locationOff(asked: false))
    // Trip: four saved widgets to pick from
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .trips), trips: DirectionsEntry.previewTrips)
    DirectionsEntry(date: .now, board: TrainEntry.toHeraldSq.shown(as: .quickTrip(to: "34 St-Herald Sq")))
    DirectionsEntry(date: .now, board: TrainEntry.transferPreview().shown(as: .quickTrip(to: "34 St-Herald Sq")))
    DirectionsEntry(date: .now, board: TrainEntry.preview.shown(as: .favorite))
    // Nearby's Both: Prospect Av's R both ways
    DirectionsEntry(date: .now, board: TrainEntry.bothWays().shown(as: .nearby))
    DirectionsEntry(date: .now, board: TrainEntry.toHeraldSq.shown(as: .maps(.apple)))
    DirectionsEntry(date: .now, board: TrainEntry.transferPreview(notice: TrainEntry.rDelays).shown(as: .maps(.google)))
}

#Preview("Transit Directions · Nearby buses", as: .systemMedium) {
    DirectionsWidget()
} timeline: {
    // Park Slope's stations, with the B67 each way on 7 Av; then just one station; no stop near,
    // Bus Time down, and what Nearby's toggle draws at once on a tap
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby, nearbyBuses: true), nearby: parkSlope(4),
                    buses: .places(NearbyBuses.preview()))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby, nearbyBuses: true), nearby: parkSlope(1),
                    buses: .places(NearbyBuses.preview()))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby, nearbyBuses: true), nearby: parkSlope(2), buses: .places([]))
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby, nearbyBuses: true), nearby: parkSlope(2), buses: .unavailable)
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby, nearbyBuses: true), nearby: parkSlope(2), buses: .finding)
    // Off: the stations as before, with "+ Bus"
    DirectionsEntry(date: .now, quickTrip: QuickTrip(screen: .nearby), nearby: parkSlope(2))
}

/// For previews: up to `count` stations near 7 Av and 9 St, Park Slope.
private func parkSlope(_ count: Int) -> NearbyList {
    .stations(Nearby.stations(near: CLLocation(latitude: 40.6661, longitude: -73.9802), limit: count), since: nil)
}
