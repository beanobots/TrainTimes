import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct RTrainWidget: Widget {
    let kind = WidgetKind.train

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TrainWidgetIntent.self, provider: Provider()) { entry in
            TrainWidgetView(entry: entry)
                .containerBackground(Color.boardBackground, for: .widget)
        }
        .configurationDisplayName("Next train")
        .description("Live times for a widget set up in the app. Pick which one in its Edit menu. On medium, with a change, the fastest way on too.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        // For the edge-to-edge alert banner; TrainWidgetView adds margins elsewhere
        .contentMarginsDisabled()
        .pushHandler(TrainWidgetPushHandler.self)
    }
}

/// The ways on from your next train for a widget set up with a change (`WaysBoard`), timed to
/// the change's destination if it has one: every one that fits. Large only; medium Next train
/// shows the fastest, for a widget with a change.
struct TransfersWidget: Widget {
    let kind = WidgetKind.transfers

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TrainWidgetIntent.self, provider: Provider(transfers: true)) { entry in
            TrainWidgetView(entry: entry)
                .containerBackground(Color.boardBackground, for: .widget)
        }
        .configurationDisplayName("Transfers")
        .description("Your next train and the ways on to your destination, for a widget set up with a change in the app.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
        .pushHandler(TrainWidgetPushHandler.self)
    }
}

/// Lets the push server reload the Next train and Transfers widgets as it pushes the countdown
/// new times, so those for its train show the same (`CountdownLookup`). The app sends the
/// push token with the countdown's registration (`ActivityPush`), reading it from
/// `WidgetCenter.currentPushInfo`, as only the app can sign requests to the server.
struct TrainWidgetPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {}
}

// MARK: - Timeline

struct TrainEntry: TimelineEntry {
    var date: Date
    let selection: Selection
    /// Trains still to come at `date`, soonest first.
    var trains: [Arrival]
    /// The most important alert or elevator outage, if any.
    var notice: Notice? = nil
    var problem: String? = nil
    /// Whether the Lock Screen countdown is for this widget's train. Only the app can refresh
    /// it, so ↻ then goes through the app.
    var countingDown = false
    /// Lets the buttons act on only this widget; see `Provider.widgetID`.
    var widgetID = ""
    var settings = AppSettings()
    /// Transfers widget: catchable trains that reach the change, each with the train it
    /// meets; nil without a change.
    var connections: [Connection]? = nil
    /// The Transfers widget's change of trains, if its saved widget has one.
    var change: Change? = nil
    /// Whether this is drawn as the Transfers widget: Transfers, or medium Next train with a change.
    var transfers = false
    /// When stale times were fetched, after a reload couldn't reach the MTA; nil when fresh.
    var notUpdatedSince: Date? = nil
    /// When its times were fetched, fresh or not.
    var fetched: Date? = nil
    /// Whether some of the times are the timetable's, as the MTA couldn't be reached
    /// (`TimetableStore`).
    var fromTimetable = false
    /// Next train without a change: where it times trains to, and when each gets there, by trip.
    var destination: Station? = nil
    var destinationTimes: [String: Date] = [:]
    /// Transit Directions: what it's showing in place of its Quick Trip and Favorite Stop buttons,
    /// which its ✕ goes back to.
    var tripSource: TripSource? = nil
    /// The medium Next train widget showing both directions: the trains going the other way.
    var otherWay: OtherWay? = nil
    /// Next train and Transfers on the Home Screen: a card with no times (`StopCard`) until a
    /// tap opens the board, as Transit Directions' Favorite Stop (`OpenBoards`).
    var tapToOpen = false
    /// With `tapToOpen`, the board is open, with a ✕ back to the card.
    var opened = false

    var stationName: String { selection.station?.name ?? "Choose a station" }
    var heading: String { selection.heading }
    /// "R", or "N/R" with more than one line chosen.
    var lineLabel: String { selection.linesLabel }
    /// Whether the MTA couldn't be reached, so the times are old or the timetable's.
    var isOffline: Bool { notUpdatedSince != nil || fromTimetable }
    /// What VoiceOver says of the no-signal mark.
    var offlineLabel: String {
        notUpdatedSince == nil ? "Couldn't reach the MTA, so these times are the timetable's"
            : "Couldn't reach the MTA, so these times are old"
    }
    /// A ✕ beside walk on the boards: Transit Directions' while it shows a trip, or an open
    /// board's (`opened`), back to its card.
    var closes: Bool { tripSource != nil || opened }
}

/// The other direction on the medium Next train widget showing both (`SavedWidget.bothWays`).
struct OtherWay {
    /// The widget's train going the other way (`Selection.otherWay`).
    let selection: Selection
    /// Still to come at the entry's date, soonest first.
    var trains: [Arrival]
    /// Why there are none, when the MTA couldn't be reached.
    var problem: String? = nil
}

struct Provider: AppIntentTimelineProvider {
    var transfers = false
    /// Transit Directions: a shared trip or Quick Trip while there is one (`SharedTrip`), else
    /// Favorite Stop, Settings' default train. `DirectionsProvider` asks only when it shows one.
    var directions = false

    func placeholder(in context: Context) -> TrainEntry {
        transfers ? .transferPreview() : .preview
    }

    func snapshot(for configuration: TrainWidgetIntent, in context: Context) async -> TrainEntry {
        if context.isPreview { return placeholder(in: context) }
        let shown = choice(configuration, family: context.family)
        let thisWidget = widgetID(configuration, context)
        async let other = Self.otherWayPlan(shown, family: context.family, widgetID: thisWidget)
        let plan = await Self.plan(for: shown.selection, change: shown.change, destination: shown.destination,
                                   transfers: shown.transfers, tripSource: shown.tripSource,
                                   family: context.family, widgetID: thisWidget)
        let entries = Self.merging(await other, into: plan).entries
        return (taps(context) ? Self.withCards(entries, widgetID: thisWidget) : entries)[0]
    }

    /// Whether this widget shows a card until a tap opens its board (`TrainEntry.tapToOpen`):
    /// Next train and Transfers on the Home Screen, not Transit Directions or the Lock Screen.
    private func taps(_ context: Context) -> Bool {
        !directions && [.systemSmall, .systemMedium, .systemLarge].contains(context.family)
    }

    /// `entries` drawn as cards, but open (`TrainEntry.opened`) until `widgetID`'s board closes
    /// (`OpenBoards`), with an entry for then. That entry's trains are the last before it's,
    /// which they're still to come at until the next entry's.
    static func withCards(_ entries: [TrainEntry], widgetID: String, now: Date = .now) -> [TrainEntry] {
        let closes = OpenBoards.closes(widgetID, now: now)
        var cards = entries.map { entry in
            var card = entry
            card.tapToOpen = true
            card.opened = closes.map { entry.date < $0 } ?? false
            return card
        }
        if let closes, let last = cards.lastIndex(where: { $0.date < closes }), !cards.contains(where: { $0.date == closes }) {
            var closed = cards[last]
            closed.date = closes
            closed.opened = false
            cards.insert(closed, at: last + 1)
        }
        return cards
    }

    func timeline(for configuration: TrainWidgetIntent, in context: Context) async -> Timeline<TrainEntry> {
        let signpost = Signposts.widget.beginInterval("Train timeline", id: Signposts.widget.makeSignpostID())
        defer { Signposts.widget.endInterval("Train timeline", signpost) }
        // About once a day, a new timetable to fall back on, alongside the times. Not for
        // Transit Directions, whose taps would wait for it; the other widgets get it
        let timetable = directions ? nil : Task { await Signposts.interval("Timetable refresh") { await TimetableStore.refresh() } }
        // A slow download mustn't hold the widget past iOS's limit: a later reload's finishes it
        let timetableDeadline = Date.now.addingTimeInterval(Self.timetableWait)
        let shown = choice(configuration, family: context.family)
        let thisWidget = widgetID(configuration, context)
        async let other = Self.otherWayPlan(shown, family: context.family, widgetID: thisWidget,
                                            reuseWithin: quickTripReuse(shown.trip))
        let main = await Self.plan(for: shown.selection, change: shown.change, destination: shown.destination,
                                   transfers: shown.transfers, tripSource: shown.tripSource,
                                   family: context.family, widgetID: thisWidget,
                                   reuseWithin: quickTripReuse(shown.trip), reloadsOthers: !directions,
                                   // A tap on Transit Directions waits for this, and any tap after
                                   // it for the extension, which draws one widget at a time
                                   extrasWait: directions ? TimelinePlan.firstDrawWait : nil)
        let plan = Self.merging(await other, into: main)
        // iOS rations reloads, so this may come late; until then the entries step through
        // the known trains.
        var reload = TimelinePlan.reload(now: .now, fetched: plan.fetched, old: plan.old, failed: plan.failed,
                                         runsOut: plan.runsOut, switches: shown.switches, complete: plan.complete)
        // No trains now: not again until near the timetable's next, unless what it shows switches
        if let quiet = plan.quietUntil {
            reload = min(max(reload, quiet), shown.switches ?? .distantFuture)
        }
        // A shared trip's entries stop when it ends, so it isn't shown after, however late the reload
        var entries = shown.trip.map { trip in plan.entries.filter { $0.date < trip.expires } } ?? plan.entries
        // Transit Directions draws its board only `directionsAhead`, as a tap waits for every
        // entry to be drawn; then reloads for more
        if directions {
            let horizon = Date.now.addingTimeInterval(Self.directionsAhead)
            let near = entries.filter { $0.date < horizon }
            if !near.isEmpty, near.count < entries.count {
                entries = near
                reload = min(reload, horizon)
            }
        }
        if let timetable { _ = await TrainService.value(of: timetable, by: timetableDeadline) }
        if entries.isEmpty { entries = plan.entries }
        if taps(context) { entries = Self.withCards(entries, widgetID: thisWidget) }
        return Timeline(entries: entries, policy: .after(reload))
    }

    /// How long a timeline waits for a new timetable (`TimetableStore.refresh`), from its start.
    private static let timetableWait: TimeInterval = 5

    /// Transit Directions' Favorite Stop from saved times or the timetable's, without fetching,
    /// for its buttons to have ready before the tap (`QuickTripView`), up to `horizon`. Empty if
    /// neither has one.
    func savedEntries(in context: Context, until horizon: Date) async -> [TrainEntry] {
        let configuration = TrainWidgetIntent()
        let shown = choice(configuration, family: context.family)
        // Without either, `plan` would fetch live times, only for them to be thrown away
        guard Self.boardAtOnce(for: shown.selection, change: shown.change, destination: shown.destination,
                               now: .now, anyAge: true) != nil else { return [] }
        let plan = await Self.plan(for: shown.selection, change: shown.change, destination: shown.destination,
                                   transfers: shown.transfers, tripSource: shown.tripSource,
                                   family: context.family, widgetID: widgetID(configuration, context),
                                   atOnce: true, anyAge: true, until: horizon)
        return plan.drewAtOnce ? plan.entries : []
    }

    /// One of Transit Directions' Trip journeys from saved times or the timetable's, without
    /// fetching, as it shows once picked (`StartSavedTripIntent`): for its card's toggle to draw
    /// it at once on a tap, up to `horizon`. Empty if neither has one.
    func savedEntries(for option: SharedTrip.Option, title: String, in context: Context,
                      until horizon: Date) async -> [TrainEntry] {
        // Without either, `plan` would fetch live times, only for them to be thrown away
        guard Self.boardAtOnce(for: option.selection, change: option.change, destination: option.directDestination,
                               now: .now, anyAge: true) != nil else { return [] }
        let plan = await Self.plan(for: option.selection, change: option.change, destination: option.directDestination,
                                   transfers: option.change != nil, tripSource: .saved(title),
                                   family: context.family, widgetID: widgetID(TrainWidgetIntent(), context),
                                   atOnce: true, anyAge: true, until: horizon)
        return plan.drewAtOnce ? plan.entries : []
    }

    /// How far ahead Transit Directions' boards are drawn.
    static let directionsAhead: TimeInterval = 20 * 60

    /// For a Quick Trip just started, how old its saved times may be and still be drawn: those
    /// fetched while it was planned (`DirectionsProvider`'s prefetch).
    private func quickTripReuse(_ trip: SharedTrip?) -> TimeInterval? {
        guard let trip, trip.app == nil,
              trip.shared.isWithin(TimelinePlan.quickTripReuseWindow, before: .now) else { return nil }
        return TimelinePlan.quickTripReuseWindow
    }

    /// Fetches and saves `option`'s times unless saved within `window`, so a widget about to
    /// show them draws at once: Quick Trip's Go, from the planner, or its ways there. True if
    /// new times were saved.
    @discardableResult
    static func prefetch(_ option: SharedTrip.Option, within window: TimeInterval) async -> Bool {
        let destination = option.directDestination
        if let saved = SharedStore.loadBoard(for: option.selection, change: option.change, destinationID: destination?.id),
           saved.failed == nil, saved.fetched.isWithin(window, before: .now) { return false }
        return await Signposts.interval("Prefetch") {
            // Its trains are what's drawn from it; the rest come with the trip's own reload
            (try? await board(for: option.selection, change: option.change, destination: destination,
                              taps: SharedStore.Taps(), settings: SharedStore.loadSettings(),
                              extrasWait: TimelinePlan.firstDrawWait)) != nil
        }
    }

    /// A timeline's entries, plus what its reload time is based on.
    private struct Plan {
        var entries: [TrainEntry]
        /// When its times were fetched; nil if new ones couldn't be.
        var fetched: Date?
        /// Without new times, when the old ones shown were fetched.
        var old: Date? = nil
        /// When the fetch for newer ones failed (possibly before a tap redrew with old ones);
        /// nil for just now.
        var failed: Date? = nil
        /// The last entry's date, after which no train is known.
        var runsOut: Date?
        /// False when drawn without waiting for everything; see `TimelinePlan.firstDrawWait`.
        var complete = true
        /// Drawn from saved times or the timetable's without fetching (`atOnce`).
        var drewAtOnce = false
        /// With new times but no train, when to reload at the earliest (`quietReload`).
        var quietUntil: Date? = nil
    }

    /// See `TrainWidgetIntent.widgetID(kind:family:)`.
    private func widgetID(_ configuration: TrainWidgetIntent, _ context: Context) -> String {
        let kind = directions ? WidgetKind.directions : transfers ? WidgetKind.transfers : WidgetKind.train
        return configuration.widgetID(kind: kind, family: context.family)
    }

    /// What a widget shows now, and when that next switches so it can reload then.
    private struct Choice {
        var selection: Selection
        var change: Change?
        var destination: Station?
        var switches: Date?
        /// Drawn as the Transfers widget.
        var transfers: Bool
        /// Transit Directions' shared trip, while it shows one.
        var trip: SharedTrip? = nil
        /// Transit Directions: what it's showing, its trip's or else Favorite Stop.
        var tripSource: TripSource? = nil
        /// Next train showing both directions, on medium (`SavedWidget.bothWays`).
        var bothWays = false
    }

    /// What the widget shows now (for Transfers, its saved widget's selection and change, via
    /// `TrainWidgetIntent.transfersWidget`; for Next train, any destination without a change, and
    /// on `family` medium any change, drawn as Transfers; for Transit Directions, its shared trip
    /// until it ends, else Favorite Stop as Next train), using commute hours, and when they next
    /// switch.
    private func choice(_ configuration: TrainWidgetIntent, family: WidgetFamily) -> Choice {
        let now = Date.now
        if directions, let trip = SharedStore.loadSharedTrip(at: now) {
            let option = trip.option
            return Choice(selection: option.selection, change: option.change, destination: option.directDestination,
                          switches: trip.expires, transfers: option.change != nil, trip: trip, tripSource: trip.source,
                          bothWays: trip.bothWays == true && option.change == nil)
        }
        guard transfers else {
            let (selection, switches) = configuration.selection(at: now)
            // Medium Next train is also medium Transfers: with a change, its ways on
            if !directions, family == .systemMedium, let change = configuration.change(at: now) {
                return Choice(selection: selection, change: change, switches: switches, transfers: true)
            }
            return Choice(selection: selection, destination: configuration.destination(at: now), switches: switches,
                          transfers: false, tripSource: directions ? .favorite : nil,
                          bothWays: !directions && configuration.bothWays())
        }
        let widget = configuration.transfersWidget(in: SharedStore.loadWidgets())
        let shown = widget.shown(at: now)
        return Choice(selection: shown.selection, change: shown.change, switches: widget.commute?.nextSwitch(after: now),
                      transfers: true)
    }

    /// One entry for now, then one as each train's leave time passes (its arrival without a
    /// walking time), so the widget moves to the next catchable train without the network;
    /// with a change, the next that gets there. Medium and large also get one a minute, for
    /// minutes to go. If the MTA can't be reached, shows the last fetched times, marked old,
    /// while any is still catchable, then the timetable's (`timetableBoard`). Transfers without a
    /// change: as Next train, for its next two trains. `reuseWithin`, `atOnce` and `anyAge`: see
    /// `board` and `boardAtOnce`. `reloadsOthers`: with new times, redraws the other widgets
    /// showing the same train (`reloadWidgets(showing:drawing:)`). `extrasWait`: see `board`.
    /// `until`: entries only before it (but always one for now), for a caller showing no more.
    private static func plan(for selection: Selection, change: Change?, destination: Station?, transfers: Bool,
                             tripSource: TripSource? = nil, family: WidgetFamily, widgetID: String,
                             reuseWithin: TimeInterval? = nil, atOnce: Bool = false, anyAge: Bool = false,
                             reloadsOthers: Bool = true, extrasWait: TimeInterval? = nil,
                             until horizon: Date? = nil) async -> Plan {
        let countdown = SharedStore.loadCountdown().flatMap { $0.ends > .now ? $0 : nil }
        let countingDown = countdown?.isShown(onWidget: widgetID, for: selection.trainID) ?? false
        // Walk goes out as the countdown ends, which nothing reloads the widget for
        let countdownEnds = countingDown ? countdown?.ends : nil
        let settings = SharedStore.loadSettings()
        let taps = SharedStore.loadTaps(for: widgetID)
        var board: SharedStore.SavedBoard
        let updated: Bool
        var complete = true
        var fromTimetable = false
        let tried = Date.now
        var drewAtOnce = false
        let atOnceBoard = atOnce ? Self.boardAtOnce(for: selection, change: change, destination: destination, now: tried,
                                                    anyAge: anyAge) : nil
        // Fetched alongside the times, rather than after them; drawn at once, only the local copies
        async let countdownState = CountdownLookup.state(for: selection.trainID, localOnly: atOnceBoard != nil)
        if let shown = atOnceBoard {
            board = shown.board
            updated = !shown.old
            fromTimetable = shown.fromTimetable
            drewAtOnce = true
        } else {
            do {
                let got = try await Signposts.interval("Fetch times") {
                    try await Self.board(for: selection, change: change, destination: destination, taps: taps,
                                         settings: settings, reuseWithin: reuseWithin, widgetID: widgetID,
                                         extrasWait: extrasWait)
                }
                board = got.board
                updated = !got.old
                complete = got.complete
            } catch {
                SharedStore.markBoardFailed(for: selection, change: change, destinationID: destination?.id, tried: tried)
                let loaded = SharedStore.loadBoard(for: selection, change: change, destinationID: destination?.id)
                let saved = loaded.flatMap { Self.anyToCatch(in: $0, selection: selection, change: change, now: .now) ? $0 : nil }
                // Retried as old as the last times fetched, not every 2 minutes all night offline:
                // from those last fetched even if none is left to catch, and with none in the
                // hour boards are kept, a `reloadInterval` apart
                let lastFetched = loaded?.fetched ?? tried.addingTimeInterval(-TimelinePlan.reloadInterval(at: tried))
                if let filled = Self.timetableBoard(saved: saved, selection: selection, change: change,
                                                    destination: destination, now: .now) {
                    board = filled.board
                    fromTimetable = filled.used
                    if saved == nil { board.fetched = lastFetched }
                } else if let saved {
                    board = saved
                } else {
                    return Plan(entries: [TrainEntry(date: .now, selection: selection, trains: [], problem: "Couldn't reach the MTA",
                                                     countingDown: countingDown,
                                                     widgetID: widgetID, settings: settings, change: change, transfers: transfers,
                                                     tripSource: tripSource)],
                                old: lastFetched, failed: tried)
                }
                updated = false
            }
        }
        // After the fetch, so entries start when shown
        let now = Date.now
        // Just fetched: others showing this train redraw with the same, instead of their own. Not
        // for Transit Directions, as iOS draws one widget at a time, so its next tap waited for
        // them all; they get the new times on their own next reload
        if reloadsOthers, board.fetched >= tried {
            await WidgetCenter.shared.reloadWidgets(showing: selection.trainID, drawing: widgetID)
        }
        if let state = await countdownState {
            // The countdown's times, as the Lock Screen shows them, for its trains
            let aligned = CountdownSync.aligned(board.trains, to: state, selection: selection, now: now)
            board.trains = aligned.trains
            board.connections = board.connections.map(aligned.connections)
        }
        let trains = selection.catchable(board.trains, now: now)
        let connections = selection.catchable(board.connections ?? [], now: now)
        let entry = { (date: Date) -> TrainEntry in
            TrainEntry(date: date, selection: selection,
                       trains: TimelinePlan.trains(trains, at: date, selection: selection, fetched: board.fetched,
                                                   keepsStops: false),
                       notice: board.notice,
                       problem: updated ? nil : "Couldn't reach the MTA",
                       countingDown: countdownEnds.map { date < $0 } ?? false,
                       widgetID: widgetID, settings: settings,
                       connections: change == nil ? nil
                           : TimelinePlan.connections(connections, at: date, selection: selection, fetched: board.fetched,
                                                      keepsStops: false),
                       change: change, transfers: transfers,
                       // Not if they're all the timetable's
                       notUpdatedSince: updated || board.failed == nil ? nil : board.fetched,
                       fetched: board.fetched,
                       fromTimetable: fromTimetable,
                       destination: destination, destinationTimes: board.destinationTimes ?? [:],
                       tripSource: tripSource)
        }
        // With a change, the trains that get there are the ones to catch
        let toCatch = change == nil ? trains : connections.map(\.first)
        // The medium and large widgets' later trains' minutes, and the rectangular Lock Screen
        // widget's, change every minute
        let everyMinute = family == .systemMedium || family == .systemLarge || family == .accessoryRectangular
        // Each entry a whole board, so none past what the caller shows
        let dates = TimelinePlan.dates(after: now, toCatch: toCatch, selection: selection, everyMinute: everyMinute)
            + [countdownEnds].compactMap { $0 }.filter { $0 > now }
        let entries = [entry(now)]
            + Set(dates).sorted()
                .filter { date in horizon.map { date < $0 } ?? true }
                .map(entry)
        // Without new times, retry soon after the failure, then less often as the shown ones age
        return Plan(entries: entries, fetched: updated ? board.fetched : nil, old: updated ? nil : board.fetched,
                    failed: updated ? nil : board.failed, runsOut: TimelinePlan.runsOut(toCatch, selection: selection),
                    complete: complete, drewAtOnce: drewAtOnce,
                    quietUntil: updated && !drewAtOnce && toCatch.isEmpty
                        ? quietReload(for: selection, change: change, destination: destination, now: now) : nil)
    }

    /// The medium Next train widget showing both directions: the plan for its train going the
    /// other way, fetched alongside its own. Nil otherwise. Its own `widgetID`, so its taps and
    /// countdown are the widget's train's alone. `reuseWithin`: as for its own (`board`), for
    /// Nearby's Both, whose other way was fetched as its station showed.
    private static func otherWayPlan(_ shown: Choice, family: WidgetFamily, widgetID: String,
                                     reuseWithin: TimeInterval? = nil) async -> Plan? {
        guard shown.bothWays, family == .systemMedium else { return nil }
        // Planned as small, for entries only as its trains leave: the widget's own plan already
        // has one a minute, and a second set a few milliseconds off them would double them
        return await plan(for: shown.selection.otherWay, change: nil, destination: nil, transfers: false,
                          family: .systemSmall, widgetID: widgetID + " other way", reuseWithin: reuseWithin,
                          reloadsOthers: false)
    }

    /// `plan` with `other`'s trains on each entry (`TrainEntry.otherWay`), and an entry as each
    /// of them leaves too. It reloads by the sooner of the two running out of trains.
    private static func merging(_ other: Plan?, into plan: Plan) -> Plan {
        guard let other, let first = plan.entries.first, let otherFirst = other.entries.first else { return plan }
        let dates = Set(plan.entries.map(\.date) + other.entries.map(\.date).filter { $0 > first.date }).sorted()
        var merged = plan
        merged.entries = dates.map { date in
            var entry = plan.entries.last { $0.date <= date } ?? first
            let theirs = other.entries.last { $0.date <= date } ?? otherFirst
            let trains = theirs.selection.catchable(theirs.trains, now: date)
            entry.date = date
            entry.trains = entry.selection.catchable(entry.trains, now: date)
            entry.otherWay = OtherWay(selection: theirs.selection, trains: trains,
                                      problem: trains.isEmpty ? theirs.problem : nil)
            return entry
        }
        merged.runsOut = [plan.runsOut, other.runsOut].compactMap { $0 }.min()
        // Not quiet while the other way has trains
        if !other.entries.allSatisfy(\.trains.isEmpty) { merged.quietUntil = nil }
        return merged
    }

    /// For a line with no trains now (not running at night or weekends, or its service over for
    /// the day): rather than fetching every `reloadInterval` for an empty board, not until
    /// `quietLead` before the timetable's next train, but at least every `quietMax`, so an
    /// alert about it or service back early still shows. Nil without a timetable.
    private static func quietReload(for selection: Selection, change: Change?, destination: Station?,
                                    now: Date) -> Date? {
        guard let timetable = TimetableStore.load(now: now) else { return nil }
        let timed = change.map { TrainService.board(for: selection, change: $0, from: timetable, now: now) }
            ?? TrainService.board(for: selection, arrivingAt: destination, from: timetable, now: now)
        let next = change == nil ? timed.trains.map(\.time).min() : timed.connections.map(\.first.time).min()
        let latest = now.addingTimeInterval(quietMax)
        return next.map { min($0.addingTimeInterval(-quietLead), latest) } ?? latest
    }

    private static let quietLead: TimeInterval = 20 * 60
    private static let quietMax: TimeInterval = 30 * 60

    /// For a tap that shouldn't wait for the MTA (Transit Directions' Favorite Stop): saved times
    /// still to catch, else the timetable's. Nil if there are neither, or (unless `anyAge`) the
    /// saved ones are recent enough to be drawn at once anyway (`TimelinePlan.reuseWindow`).
    /// Saved times count as new (`old` only if a fetch since failed), as the fetch right after
    /// replaces them.
    private static func boardAtOnce(for selection: Selection, change: Change?, destination: Station?,
                                    now: Date, anyAge: Bool) -> (board: SharedStore.SavedBoard, old: Bool, fromTimetable: Bool)? {
        let saved = SharedStore.loadBoard(for: selection, change: change, destinationID: destination?.id)
        if !anyAge, let saved, saved.fetched.isWithin(TimelinePlan.reuseWindow, before: now) { return nil }
        if let saved, anyToCatch(in: saved, selection: selection, change: change, now: now) {
            return (saved, saved.failed != nil, false)
        }
        return timetableBoard(saved: nil, selection: selection, change: change, destination: destination, now: now)
            .map { ($0.board, false, $0.used) }
    }

    /// With the MTA unreachable: `saved`'s trains still to catch (if any), then the timetable's
    /// (`TimelinePlan.filling`), and whether any are the timetable's. Nil without a downloaded
    /// timetable for now, or if neither has a train to catch. One of only the timetable's
    /// has no `failed`, as no times were fetched.
    private static func timetableBoard(saved: SharedStore.SavedBoard?, selection: Selection, change: Change?,
                                       destination: Station?, now: Date) -> (board: SharedStore.SavedBoard, used: Bool)? {
        guard let timetable = TimetableStore.load(now: now) else { return nil }
        let timed = change.map { TrainService.board(for: selection, change: $0, from: timetable, now: now) }
            ?? TrainService.board(for: selection, arrivingAt: destination, from: timetable, now: now)
        var board = saved ?? SharedStore.SavedBoard(fetched: now, trains: [], notice: nil)
        board.trains = TimelinePlan.filling(saved?.trains ?? [], from: timed.trains, selection: selection, now: now)
        if change != nil {
            board.connections = TimelinePlan.filling(saved?.connections ?? [], from: timed.connections,
                                                     selection: selection, now: now)
        }
        if destination != nil {
            board.destinationTimes = (saved?.destinationTimes ?? [:]).merging(timed.destinationTimes) { saved, _ in saved }
        }
        guard anyToCatch(in: board, selection: selection, change: change, now: now) else { return nil }
        let savedTrips = Set((saved?.trains ?? []).map(\.trip) + (saved?.connections ?? []).map(\.first.trip))
        let used = board.trains.contains { !savedTrips.contains($0.trip) }
            || (board.connections ?? []).contains { !savedTrips.contains($0.first.trip) }
        return (board, used)
    }

    /// Whether any of `saved`'s trains (with `change`, those that get there) is still to catch.
    private static func anyToCatch(in saved: SharedStore.SavedBoard, selection: Selection, change: Change?,
                                   now: Date) -> Bool {
        change == nil
            ? !selection.catchable(saved.trains, now: now).isEmpty
            : !selection.catchable(saved.connections ?? [], now: now).isEmpty
    }

    /// The trains and alert for `selection` (and `change`), fetched; or saved ones to redraw
    /// at once, per `TimelinePlan.reuses`: after a tap on map, walk or the banner, whatever is
    /// shown, however old, with a reload a minute later. If the last fetch failed they're
    /// `old`, and retried as failed fetches are, timed from that failure, not the tap.
    /// Only alerts and outages `settings` can mention are fetched. With nothing saved (e.g.
    /// first added), it draws once its own lines' times arrive, waiting at most
    /// `TimelinePlan.firstDrawWait` for the rest, and isn't `complete` without them.
    /// `reuseWithin`, for a Quick Trip just started: also times saved that recently (fetched
    /// while it was planned), or without a destination's times, the train's own, fetched before
    /// TO was picked, drawn without them and not `complete`, so they come at the next reload.
    /// With saved times, it waits at most `extrasWait` (else `TimelinePlan.extrasWait`) for
    /// the rest, likewise. `widgetID`: for redrawing as a bystander (`Bystanders`).
    private static func board(for selection: Selection, change: Change?, destination: Station?,
                              taps: SharedStore.Taps, settings: AppSettings,
                              reuseWithin: TimeInterval? = nil, widgetID: String? = nil,
                              extrasWait: TimeInterval? = nil) async throws
        -> (board: SharedStore.SavedBoard, old: Bool, complete: Bool) {
        let now = Date.now
        let saved = SharedStore.loadBoard(for: selection, change: change, destinationID: destination?.id)
        if let window = reuseWithin {
            let fresh = { (board: SharedStore.SavedBoard?) -> SharedStore.SavedBoard? in
                guard let board, board.failed == nil, board.fetched.isWithin(window, before: now),
                      anyToCatch(in: board, selection: selection, change: change, now: now) else { return nil }
                return board
            }
            if let prefetched = fresh(saved) { return (prefetched, false, true) }
            if change == nil, destination != nil, let own = fresh(SharedStore.loadBoard(for: selection)) {
                return (own, false, false)
            }
        }
        if let saved,
           TimelinePlan.reuses(saved: saved.fetched, refreshed: taps.refreshed, toggled: taps.toggled,
                               synced: taps.synced, anyToCatch: { anyToCatch(in: saved, selection: selection, change: change, now: now) },
                               now: now) {
            return (saved, saved.failed != nil, true)
        }
        // Reloaded only as others of its kind were (`Bystanders`): its own saved times, up to a
        // `reloadInterval` old, rather than fetching and reloading others' kinds in turn
        if let saved, let widgetID,
           Bystanders.reuses(saved: saved.fetched, failed: saved.failed, refreshed: taps.refreshed,
                             widgetID: widgetID, now: now),
           anyToCatch(in: saved, selection: selection, change: change, now: now) {
            return (saved, false, true)
        }
        let alerts = selection.mentionsAlerts(with: settings)
        let wait = saved == nil ? TimelinePlan.firstDrawWait : extrasWait ?? TimelinePlan.extrasWait
        let board: Board
        if let change {
            board = try await TrainService.board(for: selection, change: change, includingAlerts: alerts,
                                                 includingOutages: selection.elevatorAlerts,
                                                 waitingAfterOwnLines: wait, now: now)
            // Its trains for Next train widgets showing the same, which redraw with them; only
            // their own alerts, not the changed-to lines'
            SharedStore.saveBoard(board.withoutChange, for: selection, fetched: .now)
        } else {
            board = try await TrainService.board(for: selection, arrivingAt: destination, includingAlerts: alerts,
                                                 includingOutages: selection.elevatorAlerts,
                                                 waitingAfterOwnLines: wait, now: now)
        }
        return (SharedStore.saveBoard(board, for: selection, change: change, destinationID: destination?.id,
                                      fetched: .now),
                false, board.complete)
    }
}

// MARK: - Views

/// Draws a toggle for its state, which iOS flips on tap before the widget reloads, so what it
/// draws changes at once. Anything in it besides its face doesn't take taps (see
/// `TrainWidgetView.body`), and there's no `Button` in it.
struct SwapToggleStyle<Content: View>: ToggleStyle {
    @ViewBuilder let content: (Binding<Bool>) -> Content

    func makeBody(configuration: Configuration) -> some View {
        content(configuration.$isOn)
    }
}

struct TrainWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.boardFamily) private var boardFamily
    @Environment(\.widgetContentMargins) private var widgetMargins
    @Environment(\.boardMargins) private var boardMargins
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.isLuminanceReduced) private var luminanceReduced
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: TrainEntry

    /// iOS's, or the app's Widgets tab's (`boardFamily`, `boardMargins`).
    private var family: WidgetFamily { boardFamily ?? widgetFamily }
    private var margins: EdgeInsets { boardMargins ?? widgetMargins }
    /// Just the picture under the controls, as the refresh toggle draws it.
    var picture = false
    /// All of it, as a picture with no buttons: the face of Transit Directions' Favorite Stop
    /// toggle, which draws it at once on a tap, as the redraw then will.
    var still = false
    /// A Home Screen widget was just tapped to refresh, so it shows ↻ until the new times.
    var refreshing = false

    /// Which times get a symbol. Live ones always do when drawn in one colour (tinted and
    /// clear Home Screens, StandBy at night), which loses the green.
    private var marks: TimeMarks { entry.settings.timeMarks(withoutColor: withoutColor, renderingMode: renderingMode) }

    private var next: Arrival? { entry.trains.first }
    private var later: ArraySlice<Arrival> { entry.trains.dropFirst() }
    /// With a walking time, the countdown is to when to leave.
    private var walking: Bool { entry.selection.walkMinutes > 0 }
    private var noTrains: String { entry.problem ?? "No \(entry.lineLabel) trains predicted" }

    /// The home screen widgets: a board (`NextTrainBoard` or `WaysBoard`) with walk top right.
    private var onHomeScreen: Bool { family == .systemSmall || family == .systemMedium || family == .systemLarge }


    /// What VoiceOver says for a time's status, shown visually by colour or mark.
    private func status(_ train: Arrival) -> String {
        train.isLive ? "Live" : "Scheduled"
    }

    /// Home screen widgets are a picture of the widget, whose whole face refreshes, with walk
    /// over it at the top right. The alert's banner is part of the picture and doesn't open,
    /// so a tap on it refreshes too. WidgetKit takes a tap anywhere on a toggle for the
    /// toggle, so all but its face is kept from taking taps.
    @ViewBuilder var body: some View {
        if family == .accessoryCircular || family == .accessoryRectangular {
            lockScreenRefresh
        } else if !onHomeScreen {
            content().padding(margins)
        } else if picture {
            board
        } else if entry.tapToOpen && !still {
            GeometryReader { proxy in
                if entry.opened {
                    homeScreenBoard
                        // The card its ✕ shows at once on a tap
                        .environment(\.endTripFace, EndTripFace(view: AnyView(card), size: proxy.size))
                } else {
                    openToggle(size: proxy.size)
                }
            }
            .coordinateSpace(.named(EndTripFace.space))
        } else {
            homeScreenBoard
        }
    }

    /// The board, then over it the controls, and on Transit Directions its trip note.
    private var homeScreenBoard: some View {
        ZStack(alignment: .top) {
            board
            if !still {
                refreshToggle
            }
            VStack(spacing: 0) {
                // Walk goes below the banner, as the board does
                if let notice = entry.notice {
                    bannerFace(notice).hidden()
                }
                // On a toggle's face, drawn as plain pills, so they're there from the tap
                // rather than coming in with the redraw. Until then, a tap on them flips the
                // toggle under them (Trip's, or another journey's), whose intent sees its
                // screen is gone and goes back to the buttons, as ✕ does
                controls
                    .padding(boardPadding)
            }
            // Over the trip note, as Transit Directions' ✕ draws over the whole widget on a tap
            .zIndex(1)
            if let source = entry.tripSource {
                tripNote(source)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .environment(\.stillControls, still)
    }

    // MARK: Card

    /// Until a tap (`TrainEntry.tapToOpen`): the banner, then the stop's card, with no times.
    private var card: some View {
        VStack(spacing: 0) {
            if let notice = entry.notice {
                bannerFace(notice)
            }
            StopCard(station: entry.selection.station?.cardName ?? entry.stationName, heading: cardHeading,
                     routes: entry.selection.routes, onward: entry.transfers ? entry.change?.allRoutes ?? [] : [],
                     style: entry.settings.favoriteCard)
                .padding(boardPadding)
        }
    }

    /// "to Manhattan", or "Northbound" where the MTA names neither way; for a change, where to
    /// and where it changes; showing both directions, so.
    private var cardHeading: String {
        if entry.transfers, let change = entry.change {
            let at = change.stationNames(for: entry.selection)
            let to = change.destination.map { "to \($0.name)" }
            return [to, at.isEmpty ? nil : "change at \(at)"].compactMap { $0 }.joined(separator: " · ")
        }
        if family == .systemMedium && entry.otherWay != nil { return "Both directions" }
        return entry.selection.cardHeading
    }

    /// The card as a toggle the size of the widget, which iOS flips on tap before its intent
    /// opens the board (`OpenBoardIntent`): its face is then the board, drawn at once, frozen as
    /// a toggle's face must be (`CountdownTimer`), until the redraw shows it counting down. Sized
    /// to the widget exactly, as WidgetKit takes taps on a toggle only over its label's own size.
    private func openToggle(size: CGSize) -> some View {
        var opened = entry
        opened.opened = true
        let leaves = entry.trains.first.map { entry.selection.leaveTime(for: $0) }
        let style = SwapToggleStyle { isOn in
            // Swapped, not crossfaded, which drew both at the start of the swap
            Group {
                if isOn.wrappedValue {
                    TrainWidgetView(entry: opened, still: true)
                        .transition(.pressed)
                } else {
                    card
                        .transition(.identity)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
        }
        return Toggle(isOn: false, intent: OpenBoardIntent(widgetID: entry.widgetID, leaves: leaves)) {
            Text("Show the times")
        }
        .toggleStyle(style)
        .accessibilityLabel("\(entry.stationName), \(cardHeading)")
        .accessibilityHint("Shows the next trains")
        .accessibilityAddTraits(.isButton)
    }

    /// Transit Directions' note of what it's showing, in the bottom margin: "Showing directions
    /// from Apple Maps", "Quick Trip · Prospect Av → 34 St-Herald Sq" or "Favorite Stop". Its ✕,
    /// back to the Quick Trip and Favorite Stop buttons, is beside walk.
    private func tripNote(_ source: TripSource) -> some View {
        HStack(spacing: 4) {
            switch source {
            case .maps(let app):
                Image(systemName: "map.fill")
                Text("Showing directions from \(app.name)")
            case .quickTrip(let to):
                Image(systemName: QuickTripSymbol.name)
                Text("Quick Trip · \(entry.stationName) → \(to)")
            case .favorite:
                Image(systemName: "star.fill")
                Text("Favorite Stop")
            case .nearby:
                Image(systemName: "location.fill")
                Text("Nearby · \(entry.stationName)")
            case .saved(let title):
                Image(systemName: QuickTripSymbol.name)
                Text("Trip · \(title)")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.boardGray)
        // Fits the bottom margin
        .dynamicTypeSize(...DynamicTypeSize.large)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    /// The circular and rectangular Lock Screen widgets, whose whole face is ↻: a tap gets new
    /// times, as the home screen's ↻ does. The inline one can't take buttons, so a tap opens the app.
    /// A toggle that's always off, as iOS flips it on tap before the intent runs: it shows ↻ at
    /// once, until the reload draws it off again.
    @ViewBuilder private var lockScreenRefresh: some View {
        let style = SwapToggleStyle { isOn in
            content(refreshing: isOn.wrappedValue)
                .padding(margins)
                .contentShape(Rectangle())
        }
        Group {
            if entry.countingDown {
                // The countdown is this widget's; only the app can refresh it
                Toggle(isOn: false, intent: RefreshIntent(widgetID: entry.widgetID)) { Text("Refresh") }
                    .toggleStyle(style)
            } else {
                Toggle(isOn: false, intent: RefreshWidgetsIntent(widgetID: entry.widgetID)) { Text("Refresh") }
                    .toggleStyle(style)
            }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Refreshes the times")
    }

    /// A Home Screen widget's picture, whose whole face is ↻ as on the Lock Screen: a toggle
    /// that's always off, so a tap shows ↻ at once, until the reload draws it off again.
    @ViewBuilder private var refreshToggle: some View {
        // Clear over the board, which is drawn under it, then drawn refreshing on a tap. Not the
        // board itself: a tap on its countdown, a live timer iOS draws in a layer of its own,
        // missed the toggle and opened the app. Sized to the widget exactly, as WidgetKit takes
        // taps on a toggle only over its label's own size
        GeometryReader { proxy in
            let style = SwapToggleStyle { isOn in
                Group {
                    if isOn.wrappedValue {
                        // Its countdown frozen, as a live timer on a toggle's face takes taps for
                        // itself, opening the app (`CountdownTimer`). Not crossfaded (`pressed`).
                        // On the board's background, hiding the live board under it, whose
                        // ticking seconds otherwise showed through over the frozen ones. Only in
                        // full colour, where tinted and clear Home Screens would draw it as a block
                        TrainWidgetView(entry: entry, picture: true, refreshing: true)
                            .environment(\.stillControls, true)
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                            .background(renderingMode == .fullColor ? Color.boardBackground : .clear)
                            .transition(.pressed)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .contentShape(Rectangle())
            }
            Group {
                if entry.countingDown {
                    // The countdown is this widget's; only the app can refresh it
                    Toggle(isOn: false, intent: RefreshIntent(widgetID: entry.widgetID)) { Text("Refresh") }
                        .toggleStyle(style)
                } else {
                    Toggle(isOn: false, intent: RefreshWidgetsIntent(widgetID: entry.widgetID)) { Text("Refresh") }
                        .toggleStyle(style)
                }
            }
            .accessibilityLabel("Refresh")
            .accessibilityHint("Refreshes the times")
        }
    }

    /// The Lock Screen's ↻, shown from a tap until the new times.
    private func refreshMark(size: CGFloat) -> some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: size, weight: .bold))
            .accessibilityHidden(true)
    }

    /// The walk button over the picture, where its board leaves room for it.
    @ViewBuilder private var controls: some View {
        if let change = entry.change, entry.transfers {
            WaysBoard(entry: entry, change: change, controls: true)
        } else {
            NextTrainBoard(entry: entry, controls: true)
        }
    }

    /// The picture under the controls: the banner, edge to edge, then the board.
    private var board: some View {
        VStack(spacing: 0) {
            if let notice = entry.notice {
                bannerFace(notice)
            }
            Group {
                if entry.transfers {
                    transfers
                } else {
                    NextTrainBoard(entry: entry, refreshing: refreshing)
                }
            }
            .padding(boardPadding)
        }
    }

    /// The margins around the picture's content; under an alert's banner, a little room instead.
    private var boardPadding: EdgeInsets {
        entry.notice == nil ? margins
            : EdgeInsets(top: 8, leading: margins.leading, bottom: margins.bottom, trailing: margins.trailing)
    }

    /// The Lock Screen widgets. `refreshing`: just tapped, so it shows ↻ until the new times.
    @ViewBuilder private func content(refreshing: Bool = false) -> some View {
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
                    HStack(spacing: 2) {
                        Text(next?.lineLabel ?? entry.lineLabel).font(.headline)
                        if refreshing {
                            refreshMark(size: 9)
                        } else if let next {
                            // The Lock Screen is one colour, losing a live time's green
                            statusMark(next, size: 9)
                        }
                    }
                    if let next {
                        lockScreenCountdown(to: next, alignment: .center, saysAt: true)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    } else {
                        Text("–")
                            .accessibilityLabel(noTrains)
                    }
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityValue(next.map { status($0) } ?? "")
            }
        default:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("\(entry.lineLabel) · \(entry.stationName)").font(.headline).lineLimit(1)
                    if refreshing {
                        Spacer(minLength: 0)
                        refreshMark(size: 12)
                    }
                }
                if let next {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if entry.selection.marksLine(of: next) { LineBullet(route: next.route, size: 16) }
                        // Dimmed, it shows a clock time, not a countdown
                        if walking {
                            Text(luminanceReduced ? "Leave at" : "Leave in").font(.caption)
                        } else if luminanceReduced {
                            Text("at").font(.caption)
                        }
                        lockScreenCountdown(to: next, alignment: .leading)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        // The Lock Screen is one colour, losing a live time's green
                        statusMark(next, size: 12)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(status(next))
                    if let since = entry.notUpdatedSince {
                        Label("Not updated since \(since.clock)", systemImage: "wifi.slash").font(.caption)
                    } else if entry.fromTimetable {
                        Label("Timetable times", systemImage: "wifi.slash").font(.caption)
                    } else if let notice = entry.notice {
                        Label(notice.label, systemImage: notice.symbol).font(.caption)
                    } else if !later.isEmpty {
                        markedTimes(Array(later.prefix(2))).font(.caption)
                    }
                } else {
                    Text(noTrains).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A train's live or timetable mark, per settings. Hidden from VoiceOver, which uses `status`.
    private func statusMark(_ train: Arrival, size: CGFloat) -> some View {
        StatusMark(isLive: train.isLive, marks: marks, size: size)
            .foregroundStyle(train.statusColor)
            .accessibilityHidden(true)
    }

    /// The Lock Screen's "then 9 min, 17 min" in whole minutes, as the countdown above counts:
    /// to each train, or to leave for it. Each after its mark if any, and followed by its line's
    /// letter when lines are marked ("9 min (N)"); VoiceOver always says live or scheduled.
    private func markedTimes(_ trains: [Arrival]) -> Text {
        let minutes = { (train: Arrival) in MinutesToGo(until: entry.selection.leaveTime(for: train), from: entry.date) }
        let line = { (train: Arrival, spoken: Bool) -> String in
            guard entry.selection.marksLine(of: train) else { return "" }
            return spoken ? ", \(Lines.name(of: train.route))" : " (\(train.lineLabel))"
        }
        var text = Text("then ")
        for (index, train) in trains.enumerated() {
            if index > 0 { text = Text("\(text)\(Text(verbatim: ", "))") }
            if let symbol = marks.symbol(isLive: train.isLive) {
                text = Text("\(text)\(Image(systemName: symbol)) ")
            }
            text = Text("\(text)\(Text(verbatim: minutes(train).label + line(train, false)))")
        }
        let spoken = trains.map { "\(minutes($0).spoken)\(line($0, true)), \(status($0).lowercased())" }
            .joined(separator: "; ")
        return text.accessibilityLabel("then \(spoken)")
    }

    /// "R 8:12 · 8:20 · 8:31", or with lines marked, "N 8:12 · R 8:20 · D 8:31".
    private func inlineTimes(_ trains: [Arrival]) -> String {
        if !trains.contains(where: entry.selection.marksLine) {
            return "\(entry.lineLabel) " + trains.map(\.time.clock).joined(separator: " · ")
        }
        return trains.map { "\($0.lineLabel) \($0.time.clock)" }.joined(separator: " · ")
    }

    // MARK: Transfers

    /// Transfers: the ways on (`WaysBoard`). Without a change (only large Transfers), Next train's
    /// board, saying none is selected.
    @ViewBuilder private var transfers: some View {
        if let change = entry.change {
            WaysBoard(entry: entry, change: change, refreshing: refreshing)
        } else {
            NextTrainBoard(entry: entry, refreshing: refreshing, noTransfer: true)
        }
    }

    // MARK: Alert banner

    /// The edge-to-edge alert banner, in its colour: which of your lines, what's wrong and which
    /// way, "(R) Delayed Manhattan-bound" (on medium and large, "(R) Manhattan-bound trains
    /// delayed"), then any line to take instead: "(C) Suspended · Take
    /// (A)". It doesn't open; the app has the whole alert. Tinted and clear Home Screens would
    /// fill it over its text, so there it's a faint band.
    private func bannerFace(_ notice: Notice) -> some View {
        let fullColor = renderingMode == .fullColor
        let brief = notice.brief
        let direction = brief?.direction
        let take = brief?.alternatives ?? []
        let phrase = bannerPhrase(notice, direction: direction)
        return HStack(spacing: 4) {
            ForEach(brief?.routes ?? [], id: \.self) { route in
                LineBullet(route: route, size: Self.bannerBulletHeight)
            }
            if let phrase {
                // As below, the direction goes before the line to take instead
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { Text(phrase).bold(); takeLabel(take) }
                    HStack(spacing: 4) { Text(phrase).bold().minimumScaleFactor(0.7); takeLabel(take) }
                    HStack(spacing: 4) { Text(notice.bannerLabel).bold(); bothWays(direction); takeLabel(take) }
                    HStack(spacing: 4) { Text(notice.bannerLabel).bold(); takeLabel(take, short: true) }
                    Text(notice.bannerLabel).bold()
                }
            } else {
                Text(notice.bannerLabel)
                    .bold()
                    .layoutPriority(1)
                // What doesn't fit goes: the direction before the line to take instead, which matters
                // more; "Both directions" becomes ⇅ first. A one-way direction is always yours, which
                // the header shows
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { directionText(direction); takeLabel(take) }
                    HStack(spacing: 4) { directionText(direction).minimumScaleFactor(0.7); takeLabel(take) }
                    HStack(spacing: 4) { bothWays(direction); takeLabel(take) }
                    takeLabel(take)
                    takeLabel(take, short: true)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        // A little lower, clear of the widget's rounded top
        .offset(y: 2)
        .font(.caption.weight(.medium))
        .foregroundStyle(fullColor ? notice.bannerForeground : Color.primary)
        .padding(.leading, margins.leading)
        .padding(.trailing, margins.trailing)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        // In a rectangle, which the widget's corners clip: a plain background would take the
        // container's shape, as the Widgets tab's card, and curve concentric with that
        .background(fullColor ? notice.tint : Color.primary.opacity(0.15), in: Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bannerSpoken(notice, phrase: phrase, direction: direction, take: take))
    }

    /// What VoiceOver says for the banner: its lines, what's wrong and which way, then any line
    /// to take instead. Apart from the banner, as one expression it took previews too long to
    /// type-check.
    private func bannerSpoken(_ notice: Notice, phrase: String?, direction: String?, take: [String]) -> String {
        let lines: [String] = (notice.brief?.routes ?? []).map(Lines.spokenName(of:))
        let what: [String] = phrase.map { [$0] } ?? [notice.label] + [direction].compactMap { $0 }
        let instead: [String] = take.isEmpty ? [] : ["take the \(Lines.list(take, joinedBy: "or")) instead"]
        return (lines + what + instead).joined(separator: ", ")
    }

    /// Medium and large, for a delay or suspension with a direction: one phrase, "Delayed in
    /// both directions", "Manhattan-bound trains delayed". Nil to show the kind and direction
    /// apart, as on small.
    private func bannerPhrase(_ notice: Notice, direction: String?) -> String? {
        guard family != .systemSmall, let direction else { return nil }
        switch notice.kind {
        case .alert(.delays), .alert(.suspended): break
        default: return nil
        }
        return direction == "Both directions" ? "\(notice.bannerLabel) in both directions"
            : "\(direction) trains \(notice.bannerLabel.lowercased())"
    }

    /// The banner's direction, if any.
    @ViewBuilder private func directionText(_ direction: String?) -> some View {
        if let direction { Text(direction) }
    }

    /// ⇅ for "Both directions"; nothing for one way.
    @ViewBuilder private func bothWays(_ direction: String?) -> some View {
        if direction == "Both directions" {
            Image(systemName: "arrow.up.arrow.down")
                .resizable()
                .scaledToFit()
                .frame(height: Self.bannerBulletHeight)
        }
    }

    /// "· Take (A)", the lines to take instead, or `short`, "→ (A)" as on a small widget; nothing
    /// without any.
    @ViewBuilder private func takeLabel(_ lines: [String], short: Bool = false) -> some View {
        if !lines.isEmpty {
            HStack(spacing: 3) {
                if short {
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.bold))
                } else {
                    Text("· Take").bold()
                }
                ForEach(lines, id: \.self) { route in
                    LineBullet(route: route, size: Self.bannerBulletHeight)
                }
            }
        }
    }

    /// Height of the banner's line bullets and its ⇅.
    private static let bannerBulletHeight: CGFloat = 14

    /// The Lock Screen countdown. Dimmed, iOS shows a timer as "3:--", so it shows the clock
    /// time instead, with `saysAt` prefixed by a small "at" (or a walker for a leave time).
    /// Otherwise the timer is sized by a hidden placeholder: left to size itself, it's
    /// re-laid out as the screen wakes and its first digit gets cut off.
    @ViewBuilder
    private func lockScreenCountdown(to train: Arrival, alignment: Alignment, saysAt: Bool = false) -> some View {
        let leave = entry.selection.leaveTime(for: train)
        if luminanceReduced {
            let time = Text(leave.clock)
            let walker = Text("\(Image(systemName: "figure.walk")) ").font(.caption2)
            let shown: Text = !saysAt ? time
                : walking ? Text("\(walker)\(time)").accessibilityLabel("Leave at \(Spoken.clock(leave))")
                : Text("\(Text("at ").font(.caption2))\(time)")
            shown
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        } else {
            Text(TimerText.placeholder(seconds: leave.timeIntervalSince(entry.date)))
                .monospacedDigit()
                .lineLimit(1)
                .hidden()
                .overlay(alignment: alignment) {
                    // A held train still shows after its leave time
                    Text(timerInterval: entry.date...max(entry.date, leave), countsDown: true)
                        .monospacedDigit()
                        .lineLimit(1)
                        .multilineTextAlignment(alignment == .center ? .center : .leading)
                }
        }
    }
}

extension Notice {
    /// What's wrong, first on the banner: "Delayed", "Suspended", "Service change".
    var bannerLabel: String {
        if case .alert(.delays) = kind { return "Delayed" }
        return label
    }

    /// "**Delays** · R trains are delayed…". The kind comes first so it survives truncation.
    var bannerText: Text {
        text.isEmpty ? Text(label).bold() : Text("\(Text(label).bold()) · \(text)")
    }

    /// Black on orange, white on the blue of a plain notice.
    var bannerForeground: Color {
        if case .alert(.notice) = kind { return .white }
        return .black
    }
}

extension UIColor {
    /// The station board's black.
    fileprivate static let boardBlack = UIColor(white: 0.07, alpha: 1)
}

extension Color {
    /// The Lock Screen countdown's background, dark in light mode too.
    static let boardBlack = Color(uiColor: .boardBlack)

    // Home screen widgets follow light/dark mode: white in light, the board's black in dark

    static let boardBackground = Color(light: UIColor.white, dark: .boardBlack)
    /// Station names and timetable times.
    static let boardText = Color(light: UIColor.black, dark: UIColor.white)
    /// Directions, labels and minutes to go.
    static let boardGray = Color(light: UIColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1), dark: UIColor(white: 0.62, alpha: 1))
    /// Stops the train has passed.
    static let boardDim = Color(light: UIColor(red: 0.63, green: 0.63, blue: 0.65, alpha: 1), dark: UIColor(white: 0.5, alpha: 1))
    /// A button's face when it isn't lit.
    static let boardButton = Color(light: UIColor(white: 0, alpha: 0.06), dark: UIColor(white: 1, alpha: 0.15))
}

extension Arrival {
    /// Green for a live prediction, white (black in light mode) for a timetable time.
    var statusColor: Color { statusColor(scheduled: .boardText) }
}

extension View {
    /// For a time with no live mark: in one-colour rendering (tinted and clear Home Screens),
    /// a live time uses the accent colour instead of green so it still stands out.
    func liveAccent(_ train: Arrival) -> some View {
        widgetAccentable(train.isLive)
    }

    /// `color` for a timer, fixed for the current light or dark mode first. iOS redraws a
    /// timer itself, and drops a colour that switches on its own (`Color(light:dark:)`), so a
    /// live countdown showed the plain text colour instead of green.
    func timerForeground(_ color: Color) -> some View {
        modifier(ResolvedForeground(color: color))
    }
}

/// See `View.timerForeground(_:)`.
private struct ResolvedForeground: ViewModifier {
    let color: Color
    @Environment(\.self) private var environment

    func body(content: Content) -> some View {
        content.foregroundStyle(Color(color.resolve(in: environment)))
    }
}

extension Date {
    /// "8:12", without AM/PM, for lists of times.
    var clock: String { Self.clockFormatter.string(from: self) }

    /// Hours and minutes in the phone's 12/24-hour setting, without AM/PM (Date.FormatStyle's
    /// `amPM: .omitted` writes "08:12"). Updates if locale or time zone change while running.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = Date.clockPattern()
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                formatter.locale = .autoupdatingCurrent
                formatter.timeZone = .autoupdatingCurrent
                formatter.dateFormat = Date.clockPattern()
            }
        }
        return formatter
    }()

    /// The phone's pattern for hours and minutes, "h:mm" or "HH:mm".
    private static func clockPattern() -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .autoupdatingCurrent) ?? "h:mm a"
        return ClockPattern.withoutDayPeriod(pattern)
    }
}

// MARK: - Previews

extension TrainEntry {
    static var preview: TrainEntry {
        let now = Date.now
        // First, an N running local on the R, stopped at 53 St, four stops away
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

    /// `preview`, timed to 34 St-Herald Sq without a change. Its trains have no trip ids, so
    /// the next one's time there stands for all.
    static var toHeraldSq: TrainEntry {
        var entry = preview
        entry.destination = StationDirectory.station(id: "R17")
        entry.destinationTimes = Dictionary(entry.trains.map { ($0.trip, $0.time.addingTimeInterval(22 * 60)) },
                                            uniquingKeysWith: min)
        return entry
    }

    /// `preview` showing both directions: timetable R trains toward Bay Ridge too.
    static func bothWays(notice: Notice? = nil, walkMinutes: Int = 0) -> TrainEntry {
        var entry = preview
        var selection = Selection.fallback
        selection.walkMinutes = walkMinutes
        let now = entry.date
        let other = [9.0, 18, 27].map {
            Arrival(route: "R", time: now.addingTimeInterval($0 * 60), stop: "R34S", lastStop: "R45S", isLive: false,
                    approach: [], position: nil)
        }
        entry = TrainEntry(date: now, selection: selection, trains: entry.trains, notice: notice)
        entry.otherWay = OtherWay(selection: selection.otherWay, trains: other)
        return entry
    }

    /// Mixed D, R and N trains on the R: rows with and without bullets, to check alignment.
    static var mixed: [Arrival] {
        let now = Date.now
        return [(1.1, "D"), (10, "R"), (17, "N"), (24, "R"), (45, "D")].map { minutes, route in
            Arrival(route: route, time: now.addingTimeInterval(minutes * 60), stop: "R34N",
                    lastStop: route == "R" ? "G08N" : route == "N" ? "R01N" : "D01N",
                    isLive: minutes < 20, approach: [], position: nil)
        }
    }

    /// The R from Prospect Av, changing at Atlantic Av-Barclays Ctr to the D or N: a quick
    /// change first, then a longer wait.
    static func transferPreview(notice: Notice? = nil, selection: Selection = .fallback) -> TrainEntry {
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
            var connection = Connection(first: first, arrival: arrival, next: next)
            // On to 34 St-Herald Sq: the express, the other express 6 min later, or staying on
            let other = lines[index] == "D" ? "N" : "D"
            let later = Arrival(route: other, time: meets.addingTimeInterval(6 * 60), stop: "R31N", lastStop: "R01N",
                                isLive: false, trip: "Y\(index)")
            var otherConnection = connection
            otherConnection.next = later
            let there = { (train: Arrival, minutes: Double) in
                Arrival(route: train.route, time: train.time.addingTimeInterval(minutes * 60), stop: "D17N",
                        lastStop: train.lastStop, isLive: train.isLive, trip: train.trip)
            }
            connection.ways = [
                Way(route: next.route, connection: connection, arrival: there(next, 14)),
                Way(route: other, connection: otherConnection, arrival: there(later, 14)),
                Way(route: "R", arrival: there(arrival, 28)),
            ]
            return connection
        }
        let herald = StationDirectory.all.first { $0.name == "34 St-Herald Sq" }?.id
        return TrainEntry(date: now, selection: selection, trains: connections.map(\.first), notice: notice,
                          connections: connections,
                          change: Change(stationID: "R31", routes: ["D", "N"], destinationID: herald), transfers: true)
    }

    /// Settings › Mark live times.
    static var accessible: AppSettings {
        var settings = AppSettings()
        settings.marksLiveTimes = true
        return settings
    }

    static let briefDelays = Notice(kind: .alert(.delays), label: "Delays",
                                    text: "2 and 5 trains are running with delays in both directions after we addressed a signal problem near 3 Av/149 St.",
                                    others: 0,
                                    brief: AlertBrief(header: "[2][5] trains are running with delays in both directions after we addressed a signal problem near 3 Av/149 St."),
                                    markedText: "[2][5] trains are running with delays in both directions after we addressed a signal problem near 3 Av/149 St.")

    /// A suspension naming the line, no direction and a line to take instead: "(R) Suspended · Take (N)".
    static let rSuspended = Notice(kind: .alert(.suspended), label: "Suspended",
                                   text: "No R between Atlantic Av-Barclays Ctr and 95 St - take the N instead", others: 0,
                                   brief: AlertBrief(header: "No [R] between Atlantic Av-Barclays Ctr and 95 St - take the [N] instead"),
                                   markedText: "No [R] between Atlantic Av-Barclays Ctr and 95 St - take the [N] instead")

    /// A delay on the preview's own train, which the banner shows as "(R) Manhattan-bound".
    static let rDelays = Notice(kind: .alert(.delays), label: "Delays",
                                text: "Manhattan-bound R trains are running with delays while we address a signal problem.",
                                others: 0,
                                brief: AlertBrief(header: "Manhattan-bound [R] trains are running with delays while we address a signal problem."),
                                markedText: "Manhattan-bound [R] trains are running with delays while we address a signal problem.")
}

#Preview(as: .systemSmall) {
    RTrainWidget()
} timeline: {
    // The card until a tap, then the board open
    TrainEntry.preview.asCard()
    TrainEntry.preview.asCard(opened: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, notice: TrainEntry.rDelays).asCard()
    TrainEntry.preview
    TrainEntry.toHeraldSq
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, notice: TrainEntry.rSuspended)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, notice: TrainEntry.rDelays,
               countingDown: true)
    // A banner for an alert naming no lines says just its kind
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed,
               notice: Notice(kind: .alert(.delays), label: "Delays", text: "", others: 0))
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.briefDelays)
    TrainEntry(date: .now, selection: .fallback, trains: [], problem: "Couldn't reach the MTA")
    // Marked live times
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, settings: TrainEntry.accessible)
    // Several lines, with just the next train's lit
    TrainEntry(date: .now, selection: Selection(stationID: "R34", routes: ["D", "N", "R"], direction: .north),
               trains: TrainEntry.mixed)
}

#Preview(as: .systemMedium) {
    RTrainWidget()
} timeline: {
    // The card until a tap, then the board open; the card under an alert, and for both directions
    TrainEntry.preview.asCard()
    TrainEntry.preview.asCard(opened: true)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, notice: TrainEntry.rDelays).asCard()
    TrainEntry.bothWays().asCard()
    TrainEntry.preview
    TrainEntry.toHeraldSq
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, notice: TrainEntry.rSuspended)
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, notice: TrainEntry.rDelays,
               countingDown: true)
    TrainEntry(date: .now, selection: .fallback, trains: [], problem: "Couldn't reach the MTA")
    // The last times, after a reload that couldn't reach the MTA
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, problem: "Couldn't reach the MTA",
               notUpdatedSince: Date.now.addingTimeInterval(-6 * 60))
    // A D, an R, then an N, all on the R's track
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, notice: TrainEntry.briefDelays)
    // Marked live times
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.mixed, settings: TrainEntry.accessible)
    // Several lines, with just the next train's lit
    TrainEntry(date: .now, selection: Selection(stationID: "R34", routes: ["D", "N", "R"], direction: .north),
               trains: TrainEntry.mixed)
    // Both directions; under a banner; with a walking time
    TrainEntry.bothWays()
    TrainEntry.bothWays(notice: TrainEntry.rDelays)
    TrainEntry.bothWays(walkMinutes: 2)
}

#Preview("With a change", as: .systemMedium) {
    RTrainWidget()
} timeline: {
    TrainEntry.transferPreview().asCard()
    TrainEntry.transferPreview().asCard(opened: true)
    TrainEntry.transferPreview()
    TrainEntry.transferPreview(notice: TrainEntry.rDelays)
}

#Preview("Transfers", as: .systemLarge) {
    TransfersWidget()
} timeline: {
    TrainEntry.transferPreview().asCard()
    TrainEntry.transferPreview().asCard(opened: true)
    TrainEntry.transferPreview()
    // Without a change: the next two trains
    TrainEntry(date: .now, selection: .fallback, trains: TrainEntry.preview.trains, transfers: true)
    TrainEntry.transferPreview(notice: TrainEntry.rDelays)
    // Several lines, with just your train's lit
    TrainEntry.transferPreview(selection: Selection(stationID: "R34", routes: ["D", "N", "R"], direction: .north))
}

extension TrainEntry {
    /// This entry on Transit Directions, showing what `source` notes.
    func shown(as source: TripSource) -> TrainEntry {
        var entry = self
        entry.tripSource = source
        return entry
    }

    /// This entry as a card until a tap (`tapToOpen`), or with its board open.
    func asCard(opened: Bool = false) -> TrainEntry {
        var entry = self
        entry.tapToOpen = true
        entry.opened = opened
        return entry
    }

    /// This entry at `date`, a little later, its countdowns counting from then: for a frozen one
    /// (`CountdownTimer`) to be near the real one. Its trains are as at its own date.
    func at(_ date: Date) -> TrainEntry {
        var entry = self
        entry.date = date
        return entry
    }
}

/// Quick Trip's symbol, on its button and its trips' note.
enum QuickTripSymbol {
    static let name = "point.topleft.down.to.point.bottomright.curvepath.fill"
}
