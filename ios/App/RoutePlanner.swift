import SwiftUI

// MARK: - Planning

/// Where a route starts or goes: a station, or a bus stop.
enum RouteStart: Sendable {
    case station(Station)
    case stop(BusRoutes.Stop)
    case none

    /// The station's id or "stop " and the stop's code; nil for none.
    var id: String? {
        switch self {
        case .station(let station): station.id
        case .stop(let stop): "stop " + stop.code
        case .none: nil
        }
    }

    var name: String? {
        switch self {
        case .station(let station): station.name
        case .stop(let stop): BusNames.readable(stop.name)
        case .none: nil
        }
    }

    /// As the way finder has places: a station's complex, or a stop (`WayFinder.stopPlace`).
    var place: String? {
        switch self {
        case .station(let station): station.complex
        case .stop(let stop): WayFinder.stopPlace(stop.code)
        case .none: nil
        }
    }

    /// Its lines: a station's bullets, a stop's buses ("bus:B63").
    var marks: [String] {
        switch self {
        case .station(let station): Change.lines(at: station)
        case .stop(let stop):
            (BusRoutes.linesAtStop[stop.code] ?? []).map(\.line).reduce(into: [String]()) { lines, line in
                if !lines.contains(BusLeg.prefix + line) { lines.append(BusLeg.prefix + line) }
            }
        case .none: []
        }
    }

    /// `id` read back.
    init(id: String?) {
        guard let id else { self = .none; return }
        if id.hasPrefix("stop ") {
            self = BusRoutes.stopByCode[String(id.dropFirst(5))].map(RouteStart.stop) ?? .none
        } else {
            self = StationDirectory.station(id: id).map(RouteStart.station) ?? .none
        }
    }
}

extension SavedWidget {
    /// Where it starts: its bus's stop, or its train's station.
    var start: RouteStart {
        if kind == .bus {
            guard let code = bus?.stop.id, let stop = BusRoutes.stopByCode[code] else { return .none }
            return .stop(stop)
        }
        return selection.station.map(RouteStart.station) ?? .none
    }

    /// Where it goes, as planned: a station, or a bus stop ("stop " and its code in
    /// `destinationID` while planning; the trip's own once saved).
    var end: RouteStart {
        if let stop = trip?.destinationStop, let found = BusRoutes.stopByCode[stop.id] { return .stop(found) }
        return RouteStart(id: trip?.destinationID ?? change?.destinationID ?? destinationID)
    }

    /// From a bus stop: a bus route on its first line, until a way there is ticked.
    mutating func startAt(_ stop: BusRoutes.Stop) {
        guard let first = BusRoutes.linesAtStop[stop.code]?.first else { return }
        kind = .bus
        change = nil
        bus = BusChoice(line: first.line, stop: stop.busStop, destination: first.to)
    }

    /// From a station: its lines, and a way they run from there, for a countdown without To.
    mutating func startAt(_ station: Station) {
        kind = .subway
        bus = nil
        var selection = selection
        selection.stationID = station.id
        selection.routes = station.routes
        if !station.directions(of: station.routes).contains(selection.direction),
           let first = station.directions(of: station.routes).first {
            selection.direction = first
        }
        self.selection = selection
        change = nil
        if destinationID == station.id { destinationID = nil }
    }

    /// From `place`, a station or a stop.
    mutating func startAt(_ place: RouteStart) {
        switch place {
        case .station(let station): startAt(station)
        case .stop(let stop): startAt(stop)
        case .none: break
        }
    }

    /// To `place`: the planned trip dropped, to be found again.
    mutating func goTo(_ place: RouteStart) {
        guard let id = place.id else { return }
        if kind == .subway { change = nil } else { bus?.planned = nil }
        destinationID = id
    }

    /// No To: the route counts down at From, its trains or bus as they were.
    mutating func countdownOnly() {
        if kind == .subway { change = nil } else { bus?.planned = nil }
        destinationID = nil
        if case .station(let station) = start,
           !station.directions(of: selection.routes).contains(selection.direction),
           let first = station.directions(of: selection.routes).first {
            selection.direction = first
        }
    }

    /// From becomes To and To From.
    mutating func swapEnds() {
        let from = start
        let to = end
        guard to.id != nil else { return }
        startAt(to)
        goTo(from)
    }
}

/// Ways from a saved route's start to where it's going (`WayFinder`), which of them it takes, and
/// each change's places it takes, written to the route as a planned trip (`PlannedTrip`).
@Observable @MainActor
final class RoutePlan {
    private(set) var ways: [WayFinder.Way] = []
    /// Found but not listed, for See Other Ways.
    private(set) var more: [WayFinder.Way] = []
    /// Where the route's ways start: the first train or bus it counts down.
    private(set) var mainStart: WayFinder.Way.Start?
    /// Ways from another start that run when nothing from `mainStart` does, quickest first, all
    /// from one start: with no Manhattan-bound R at Prospect Av on weekends, the R the other way
    /// to 36 St and back on the D or N. Not among `ways` or `more`.
    private(set) var fallbacks: [WayFinder.Way] = []
    private(set) var finding = false
    /// No timetable to plan with yet.
    private(set) var noTimetable = false
    /// Ticked ways, by id.
    var ticked: Set<String> = []
    /// Counts ticking done here rather than read from the route, which is written back to it.
    private(set) var revision = 0
    /// Per way, per change, the ticked places.
    var stations: [String: [Set<String>]] = [:]
    /// The from and to places the ways are for (`RouteStart.place`): another station in the same
    /// complex has the same ways.
    private var planned: (from: String, to: String)?
    /// Counts `plan(for:)` calls, so an older one still finding doesn't write over a newer one's.
    private var calls = 0

    /// The finder for the timetable on the phone, made once per timetable.
    private static var finder: (made: Date, finder: WayFinder)?

    /// With `force`, downloads the timetable even if a download failed moments ago.
    static func finder(force: Bool = false) async -> WayFinder? {
        // Read off main: a multi-MB unzip on a cold cache
        var timetable = await Task.detached(priority: .userInitiated) { TimetableStore.load() }.value
        // Not downloaded yet (a fresh install): fetched now
        if timetable == nil {
            await TimetableStore.refresh(force: force)
            timetable = await Task.detached(priority: .userInitiated) { TimetableStore.load() }.value
        }
        guard let timetable else { return nil }
        if let cached = finder, cached.made == timetable.made { return cached.finder }
        let made = await Task.detached(priority: .userInitiated) { WayFinder(timetable: timetable) }.value
        finder = (timetable.made, made)
        return made
    }

    /// Places reachable from `start` in up to two changes, trains or buses: complexes and stops
    /// (`WayFinder.stopPlace`).
    static func reachable(from start: RouteStart) async -> Set<String>? {
        guard let finder = await finder(), let place = start.place else { return nil }
        return await Task.detached(priority: .userInitiated) { finder.reachable(from: place) }.value
    }

    /// Finds the ways for `widget`'s start and end, ticking those it takes already, or with
    /// `fresh` the quickest at each part of the week. With `retry`, downloads a timetable that
    /// failed to.
    func plan(for widget: SavedWidget, fresh: Bool, retry: Bool = false) async {
        calls += 1
        let call = calls
        let start = widget.start
        let end = widget.end
        guard start.id != nil, end.id != nil, let from = start.place, let to = end.place else {
            ways = []
            more = []
            fallbacks = []
            mainStart = nil
            planned = nil
            finding = false
            return
        }
        if let planned, planned.from == from, planned.to == to { return }
        // Not the last start's or end's ways while these are found
        ways = []
        more = []
        fallbacks = []
        mainStart = nil
        ticked = []
        planned = nil
        finding = true
        // Only the latest call's finding is over when it's done
        defer { if call == calls { finding = false } }
        guard let finder = await Self.finder(force: retry) else {
            if call == calls { noTimetable = true }
            return
        }
        guard call == calls else { return }
        noTimetable = false
        let found = await Task.detached(priority: .userInitiated) { finder.ways(from: from, to: to) }.value
        // Another start or end since: its ways, not these
        guard call == calls else { return }
        ways = found.listed
        more = found.more
        planned = (from, to)
        // From the saved route's first train or bus if it has one, else the quickest way's
        let saved = fresh ? nil : widget.trip?.start
        let all = found.listed + found.more
        let main = all.first { way in saved.map { Self.first(way).sameStart(as: $0) } ?? false }
            ?? all.min { $0.best < $1.best }
        split(around: main?.start)
        if fresh { tickDefaults() } else { tickMatching(widget) }
    }

    /// Makes `start` the main start, and sets apart as `fallbacks` the ways from the one other
    /// start whose quickest way runs where nothing from `start` does.
    private func split(around start: WayFinder.Way.Start?) {
        mainStart = start
        let all = ways + more + fallbacks
        // Listed as before; a fallback that's no longer one, listed
        let listed = Set((ways + fallbacks).map(\.id))
        let mainParts = Set(all.filter { $0.start == start }.flatMap(\.minutes.keys))
        let filling = all.filter { $0.start != start && !Set($0.minutes.keys).isSubset(of: mainParts) }
        let fallbackStart = filling.min { $0.best < $1.best }?.start
        fallbacks = all.filter { fallbackStart != nil && $0.start == fallbackStart && !Set($0.minutes.keys).isSubset(of: mainParts) }
            .sorted { $0.best < $1.best }
        let apart = Set(fallbacks.map(\.id))
        ways = all.filter { !apart.contains($0.id) && listed.contains($0.id) }
        more = all.filter { !apart.contains($0.id) && !listed.contains($0.id) }
    }

    /// Reads bus stops and their lines (a 1.1 MB file) off main, before a view needs them.
    static func warmBusRoutes() async {
        await Task.detached(priority: .userInitiated) {
            _ = BusRoutes.stopByCode
            _ = BusRoutes.linesAtStop
        }.value
    }

    /// The quickest way at each part of the week, from the main start (else where the quickest of
    /// all starts), then where none of those runs, the quickest fallback; each with all its places.
    /// With `allowed`, only among the ways it lets through (New Route's ways to go).
    func tickDefaults(allowed: (WayFinder.Way) -> Bool = { _ in true }) {
        ticked = []
        stations = [:]
        let start = ways.contains { $0.start == mainStart && allowed($0) } ? mainStart
            : ways.filter(allowed).min(by: { $0.best < $1.best })?.start
        guard let start else {
            revision += 1
            return
        }
        if start != mainStart { split(around: start) }
        for part in WayFinder.Part.allCases {
            let running = ways.filter { $0.minutes[part] != nil && $0.start == start && allowed($0) }
            if let fastest = running.min(by: { $0.minutes[part]! < $1.minutes[part]! }) { ticked.insert(fastest.id) }
        }
        for part in gaps {
            let running = fallbacks.filter { $0.minutes[part] != nil && allowed($0) }
            if let fastest = running.min(by: { $0.minutes[part]! < $1.minutes[part]! }) { ticked.insert(fastest.id) }
        }
        for way in ways + fallbacks { stations[way.id] = way.changes.map { Set($0.map(\.place)) } }
        revision += 1
    }

    /// Unticks the ways `allowed` rules out, as a way to go is turned off; with none left
    /// ticked, the quickest it allows at each part of the week.
    func limit(to allowed: (WayFinder.Way) -> Bool) {
        let kept = Set((ways + fallbacks).filter { ticked.contains($0.id) && allowed($0) }.map(\.id))
        if kept.isEmpty {
            tickDefaults(allowed: allowed)
        } else if kept != ticked {
            ticked = kept
            revision += 1
        }
    }

    /// Ticks the ways `widget`'s planned trip takes: the same lines in turn, changing at the same
    /// places. A route planned before trips were saved ticks nothing.
    private func tickMatching(_ widget: SavedWidget) {
        ticked = []
        stations = [:]
        let trip = widget.trip
        for way in ways + more + fallbacks {
            // A fallback against the saved fallback's ways, the rest against the main ones
            let saved = fallbacks.contains { $0.id == way.id } ? trip?.fallback?.ways ?? [] : trip?.ways ?? []
            stations[way.id] = way.changes.map { Set($0.map(\.place)) }
            guard let match = saved.first(where: { $0.rides.count == way.rides.count
                && zip($0.rides, way.rides).allSatisfy { options, lines in
                    options.contains { !Set($0.routes).isDisjoint(with: lines) }
                } }) else { continue }
            ticked.insert(way.id)
            stations[way.id] = way.changes.enumerated().map { index, options in
                let places = Set(match.rides[index + 1].map(\.place))
                let picked = Set(options.map(\.place).filter(places.contains))
                return picked.isEmpty ? Set(options.map(\.place)) : picked
            }
        }
        // Ticked from See Other Ways: listed with the rest
        for way in more where ticked.contains(way.id) {
            ways.append(way)
            more.removeAll { $0.id == way.id }
        }
    }

    /// Ticks or unticks `way`. A route has one first train or bus, and a fallback for when it
    /// doesn't run: ticking a fallback keeps the main ways; ticking a way that starts elsewhere
    /// makes that the main start, unticking the rest. The last main way ticked stays, as the
    /// route's planned trip is written from it.
    func toggle(_ way: WayFinder.Way) {
        let isFallback = fallbacks.contains { $0.id == way.id }
        if ticked.contains(way.id) {
            guard isFallback || takes.filter({ $0.start == mainStart }).count > 1 else { return }
            ticked.remove(way.id)
        } else if isFallback {
            ticked.insert(way.id)
        } else {
            if way.start != mainStart {
                ticked = []
                split(around: way.start)
            }
            ticked.insert(way.id)
        }
        revision += 1
    }

    /// Ticks or unticks a change's place; the last ticked stays.
    func toggle(_ option: WayFinder.Way.Option, change index: Int, of way: WayFinder.Way) {
        var picked = stations[way.id] ?? way.changes.map { Set($0.map(\.place)) }
        if picked[index].contains(option.place) {
            guard picked[index].count > 1 else { return }
            picked[index].remove(option.place)
        } else {
            picked[index].insert(option.place)
        }
        stations[way.id] = picked
        revision += 1
    }

    /// Adds a way from See Other Ways to those listed, ticked.
    func add(_ way: WayFinder.Way) {
        more.removeAll { $0.id == way.id }
        if !ways.contains(where: { $0.id == way.id }) { ways.append(way) }
        if !ticked.contains(way.id) { toggle(way) }
    }

    /// Whether `way`'s change at `index` is at `option`'s place.
    func isTicked(_ option: WayFinder.Way.Option, change index: Int, of way: WayFinder.Way) -> Bool {
        (stations[way.id] ?? []).indices.contains(index) ? stations[way.id]![index].contains(option.place) : true
    }

    /// The ticked ways, fallbacks last.
    var takes: [WayFinder.Way] { (ways + fallbacks).filter { ticked.contains($0.id) } }

    /// The ticked ways as a planned trip to `end`: each way's rides, each change its ticked places.
    private func trip(to end: RouteStart) -> PlannedTrip {
        var trip = PlannedTrip(ways: [])
        switch end {
        case .station(let station): trip.destinationID = station.id
        case .stop(let stop): trip.destinationStop = stop.busStop
        case .none: break
        }
        let start = mainStart ?? takes.first?.start
        trip.ways = takes.filter { $0.start == start }.map(planned)
        let backups = takes.filter { way in fallbacks.contains { $0.id == way.id } }
        if !backups.isEmpty, let when = mainTrainsName {
            trip.fallback = PlannedTrip.Fallback(ways: backups.map(planned), when: "No \(when)",
                                                 takes: backups[0].fallbackShort(from: start))
        }
        // Each bus's minutes on, so the widgets needn't load every bus route
        return trip.timingBuses()
    }

    /// `way` as the route saves it, each change its ticked places.
    private func planned(_ way: WayFinder.Way) -> PlannedWay {
        let picked = stations[way.id] ?? way.changes.map { Set($0.map(\.place)) }
        var rides: [[PlannedRide]] = [[Self.first(way)]]
        for (index, options) in way.changes.enumerated() {
            rides.append(options.filter { picked[index].contains($0.place) }.compactMap { Self.ride($0, lines: way.rides[index + 1]) })
        }
        return PlannedWay(rides: rides, endStop: way.end.stop?.busStop, endWalk: way.end.walk, endStationID: way.end.stationID)
    }

    /// The main start's trains or buses, as "When … aren't running" names them: "Manhattan-bound
    /// R trains", "Northbound R or W trains", "B63 buses toward Bay Ridge"; nil without a main start.
    var mainTrainsName: String? {
        guard let start = mainStart else { return nil }
        let lines = (ways + more).filter { $0.start == start }.flatMap { $0.rides[0] }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if start.stop != nil {
            let buses = lines.compactMap(BusLeg.line(of:))
            return "\(buses.joined(separator: " or ")) buses" + (start.headsign.map { " toward \(BusNames.readable($0))" } ?? "")
        }
        guard let station = start.stationID.flatMap(StationDirectory.station(id:)) else { return nil }
        let names = Station.directionNames(start.direction, on: station.platforms(serving: lines), routes: lines)
        let way = names.isEmpty ? start.direction.compassName : names.joined(separator: " or ") + "-bound"
        return "\(way) \(Lines.list(lines, joinedBy: "or")) trains"
    }

    /// A way's first ride: its train from the station, or its bus from the stop.
    private static func first(_ way: WayFinder.Way) -> PlannedRide {
        if let stop = way.start.stop, let line = way.rides[0].first.flatMap(BusLeg.line(of:)) {
            return PlannedRide(bus: BusLeg(line: line, stop: stop.busStop, destination: way.start.headsign, walkMinutes: 0))
        }
        let station = way.start.stationID.flatMap(StationDirectory.station(id:))
        let lines = station.map { Change.lines(at: $0).filter(way.rides[0].contains) } ?? way.rides[0]
        return PlannedRide(train: Selection(stationID: way.start.stationID ?? "", routes: lines.isEmpty ? way.rides[0] : lines,
                                            direction: way.start.direction))
    }

    /// A change's place as the ride on from it: a train or a bus, how it's changed to.
    private static func ride(_ option: WayFinder.Way.Option, lines: [String]) -> PlannedRide? {
        var ride = PlannedRide(walkMinutes: option.walkMinutes, offStationID: option.offStationID, offStop: option.offStop?.busStop)
        if let stop = option.boardStop, let line = lines.first.flatMap(BusLeg.line(of:)) {
            ride.bus = BusLeg(line: line, stop: stop.busStop, destination: option.headsign, walkMinutes: option.walkMinutes)
        } else if let id = option.boardStationID, let station = StationDirectory.station(id: id) {
            // The lines boarded here, not all the way's: the N and D at Atlantic Av, not the Q
            let lines = option.lines.isEmpty ? lines : lines.filter(option.lines.contains)
            let here = Change.lines(at: station).filter(lines.contains)
            ride.train = Selection(stationID: id, routes: here.isEmpty ? lines : here, direction: option.direction)
        } else {
            return nil
        }
        return ride
    }

    /// `widget` taking the ticked ways, as a planned trip: from a station, its train and a change
    /// carrying the trip (`Change.planned`); from a stop, its bus carrying it (`BusChoice.planned`).
    /// The first change's trains are kept as the change's stations, for alerts and the countdown.
    func applied(to widget: SavedWidget) -> SavedWidget {
        var widget = widget
        let end = widget.end
        guard end.id != nil, let lead = takes.first(where: { $0.start == mainStart }) ?? takes.first else { return widget }
        let trip = trip(to: end)
        widget.bothWays = false
        if let stop = lead.start.stop, let line = lead.rides[0].first.flatMap(BusLeg.line(of:)) {
            widget.kind = .bus
            widget.change = nil
            widget.bus = BusChoice(line: line, stop: stop.busStop, destination: lead.start.headsign, planned: trip)
        } else if let first = trip.start?.train {
            widget.kind = .subway
            widget.bus = nil
            var selection = widget.selection
            selection.stationID = first.stationID
            selection.routes = Array(Set(trip.ways.compactMap { $0.rides.first?.first?.train?.routes }.joined()))
                .sorted { (first.station?.routes.firstIndex(of: $0) ?? 99) < (first.station?.routes.firstIndex(of: $1) ?? 99) }
            selection.direction = first.direction
            widget.selection = selection
            // Trains changed to first, for alerts; else the start's own station
            let stops = trip.ways.compactMap { $0.rides.dropFirst().first }.joined().compactMap { ride -> Change? in
                guard let train = ride.train else { return nil }
                return Change(stationID: train.stationID, routes: train.routes, direction: train.direction)
            }
            var change = Change(stops: stops) ?? Change(stationID: first.stationID, routes: [])
            change.destinationID = trip.destinationID
            change.planned = trip
            widget.change = change
        }
        widget.destinationID = end.id
        return widget
    }

    /// Per part of the week, the quickest ticked way then, and its minutes; nil where none runs.
    func cover() -> [WayFinder.Part: (way: WayFinder.Way, minutes: Int)?] {
        var cover: [WayFinder.Part: (way: WayFinder.Way, minutes: Int)?] = [:]
        for part in WayFinder.Part.allCases {
            let quickest = takes.compactMap { way in way.minutes[part].map { (way, $0) } }.min { $0.1 < $1.1 }
            // Kept as nil where none runs: assigning nil through the subscript would drop the
            // part, and every week look covered
            cover.updateValue(quickest.map { (way: $0.0, minutes: $0.1) }, forKey: part)
        }
        return cover
    }

    /// The parts of the week no ticked way runs.
    var gaps: Set<WayFinder.Part> { Set(cover().filter { $0.value == nil }.keys) }

    /// The quickest unticked way that runs where no ticked one does, to suggest.
    func filling() -> (way: WayFinder.Way, time: WayFinder.Part.Time)? {
        let gaps = cover().filter { $0.value == nil }.map(\.key)
        guard !gaps.isEmpty, mainStart != nil else { return nil }
        // From the main start, else a fallback for when it doesn't run
        let candidates = ways.filter { !ticked.contains($0.id) && $0.start == mainStart }
            + fallbacks.filter { !ticked.contains($0.id) }
        for part in gaps.sorted() {
            if let way = candidates.filter({ $0.minutes[part] != nil }).min(by: { $0.minutes[part]! < $1.minutes[part]! }) {
                return (way, part.time)
            }
        }
        return nil
    }
}

extension PlannedRide {
    /// Where it's boarded, as the way finder has places: a station's complex, or a stop.
    var place: String {
        if let bus { return WayFinder.stopPlace(bus.stop.id) }
        return train?.station?.complex ?? ""
    }
}

extension WayFinder.Part {
    /// When `parts` of the week are, to follow "Not covered": "weekends", "late nights",
    /// "Saturdays", "weekdays at rush hour", "at times".
    static func named(_ parts: Set<WayFinder.Part>) -> String {
        let all = Set(allCases)
        let nights = all.filter { $0.time == .night }
        let weekends = all.filter { $0.day != .weekday }
        if parts == all { return "at any time" }
        if parts == nights { return "late nights" }
        if parts.isSubset(of: nights) { return "some late nights" }
        if parts == weekends || parts == weekends.subtracting(nights) { return "weekends" }
        for (day, name) in [(Day.saturday, "Saturdays"), (.sunday, "Sundays")] where parts.allSatisfy({ $0.day == day }) {
            return parts.count == Time.allCases.count ? name : "some \(name)"
        }
        if parts.isSubset(of: weekends) { return "some weekend times" }
        if parts.allSatisfy({ $0.day == .weekday }) {
            if parts.count == 1, let time = parts.first?.time {
                switch time {
                case .rush: return "weekdays at rush hour"
                case .day: return "weekdays in the day"
                case .evening: return "weekday evenings"
                case .night: return "weeknights"
                }
            }
            return "some weekday times"
        }
        return "at times"
    }
}

extension PlannedRide {
    /// Whether it's boarded where and as `other` is: a train at the same station going the same
    /// way, or a bus at the same stop toward the same place.
    func sameStart(as other: PlannedRide) -> Bool {
        if let train, let theirs = other.train {
            return train.station?.complex == theirs.station?.complex && train.direction == theirs.direction
        }
        if let bus, let theirs = other.bus { return bus.stop.id == theirs.stop.id && bus.destination == theirs.destination }
        return false
    }
}

extension WayFinder.Way {
    /// "R", "D or N", "B63 bus".
    private static func named(_ ride: [String]) -> String {
        let buses = ride.compactMap(BusLeg.line(of:))
        return buses.isEmpty ? Lines.list(ride, joinedBy: "or") : buses.joined(separator: " or ") + " bus"
    }

    /// As a fallback for `main`'s start, at length for New Route: "R the other way to 36 St,
    /// then back on the D or N", "F from 4 Av-9 St to Jay St-MetroTech, then the A or C".
    func fallbackDetail(from main: Start?) -> String {
        let station = start.stationID.flatMap(StationDirectory.station(id:))
        let mainStation = main?.stationID.flatMap(StationDirectory.station(id:))
        let otherWay = station != nil && station?.complex == mainStation?.complex && start.direction != main?.direction
        var text = Self.named(rides[0])
        if otherWay {
            text += " the other way"
        } else if let name = station?.name ?? start.stop.map({ BusNames.readable($0.name) }) {
            text += " from \(name)"
        }
        guard !changes.isEmpty else { return text }
        text += " to \(changes[0].first?.name ?? "")"
        for (index, options) in changes.enumerated() {
            // Back the main way: "back on"
            let back = otherWay && options.first?.direction == main?.direction
            text += ", then \(back ? "back on" : "") the \(Self.named(rides[index + 1]))".replacingOccurrences(of: "  ", with: " ")
        }
        return text
    }

    /// As a fallback, short for the widget: "R to 36 St, back on the D or N".
    func fallbackShort(from main: Start?) -> String {
        guard !changes.isEmpty else { return fallbackDetail(from: main) }
        let mainStation = main?.stationID.flatMap(StationDirectory.station(id:))
        let station = start.stationID.flatMap(StationDirectory.station(id:))
        let otherWay = station != nil && station?.complex == mainStation?.complex
        var text = (otherWay ? "" : "From \(station?.name ?? start.stop.map { BusNames.readable($0.name) } ?? ""): ")
            + "\(Self.named(rides[0])) to \(changes[0].first?.name ?? "")"
        for (index, options) in changes.enumerated() {
            let back = otherWay && options.first?.direction == main?.direction
            text += ", \(back ? "back on" : "then") the \(Self.named(rides[index + 1]))"
        }
        return text
    }

    /// Its quickest minutes at any part of the week.
    var best: Int { minutes.values.min() ?? .max }

    /// "All times", "Not late nights", "Late nights", "Weekdays", "Weekends", or the parts.
    var when: String {
        let parts = Set(minutes.keys)
        let all = Set(WayFinder.Part.allCases)
        let nights = Set(all.filter { $0.time == .night })
        let weekdays = Set(all.filter { $0.day == .weekday })
        if parts == all { return "All times" }
        if parts == all.subtracting(nights) { return "Not late nights" }
        if parts.isSubset(of: nights) { return "Late nights" }
        if parts.isSubset(of: weekdays) { return "Weekdays" }
        if parts.isDisjoint(with: weekdays) { return "Weekends" }
        if parts.isSuperset(of: all.subtracting(nights)) { return "All times, some late nights" }
        return "Some times"
    }

    var isLimited: Bool { minutes.count < WayFinder.Part.allCases.count }

    var whenSymbol: String {
        switch when {
        case "All times": "clock"
        case "Not late nights": "sun.max"
        case "Late nights": "moon.stars"
        case "Weekdays": "briefcase"
        case "Weekends": "calendar"
        default: "clock.badge.exclamationmark"
        }
    }

    /// "27–33 min", or one number.
    var minutesLabel: String {
        let low = minutes.values.min() ?? 0
        let high = minutes.values.max() ?? 0
        return low == high ? "\(low) min" : "\(low)–\(high) min"
    }

    /// "R and trains running on the local track", for rides that at times take another line's
    /// train on their stops (the N or D on the R); nil for none.
    var localTrackLabel: String? {
        let lines = localTrack.sorted().filter(rides.indices.contains).map { rides[$0].joined(separator: " or ") }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: ", ") + " and trains running on the local track"
    }

    /// "Straight there", "1 change", "2 changes".
    var changesLabel: String {
        changes.isEmpty ? "Straight there" : changes.count == 1 ? "1 change" : "\(changes.count) changes"
    }

    /// "Fastest", "Fastest daytime", "Fastest late nights", "Fastest weekends" among `ways`; nil
    /// if it's never the quickest.
    func fastest(among ways: [WayFinder.Way]) -> String? {
        let won = Set(minutes.keys.filter { part in
            ways.compactMap { $0.minutes[part] }.min() == minutes[part]
        })
        guard !won.isEmpty else { return nil }
        if won == Set(WayFinder.Part.allCases) || won == Set(minutes.keys) && !isLimited { return "Fastest" }
        if won.contains(where: { $0.day == .weekday && ($0.time == .rush || $0.time == .day) }) { return "Fastest daytime" }
        if won.allSatisfy({ $0.time == .night }) { return "Fastest late nights" }
        if won.allSatisfy({ $0.day != .weekday }) { return "Fastest weekends" }
        return "Fastest at times"
    }
}

// MARK: - The route's planning sections

/// A subway route's planning: its name, From and To, then the ways there to tick, when you're
/// covered.
struct RoutePlanSections: View {
    @Binding var widget: SavedWidget
    @State private var plan = RoutePlan()
    @State private var choosingFrom = false
    @State private var choosingTo = false
    @State private var addingWay = false
    /// Ways not yet looked for since the route came in: tick what it takes, not the defaults.
    @State private var matched = false
    /// Try Again taps, after the timetable didn't download.
    @State private var tries = 0

    var body: some View {
        Section {
            // The name as the card's title; empty, what it rides in grey
            HStack(spacing: 8) {
                TextField("Name", text: $widget.name, prompt: Text(widget.summary))
                    .font(.title3.weight(.semibold))
                    .accessibilityLabel("Name")
                Image(systemName: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            ends
        }
        // By place, not station: ticking a way from another station in the same complex moves
        // From there, and isn't found again
        .task(id: "\(widget.start.place ?? "") \(widget.end.place ?? "") \(tries)") {
            await RoutePlan.warmBusRoutes()
            await plan.plan(for: widget, fresh: matched, retry: tries > 0)
            matched = true
        }
        // Ticking here writes the route
        .onChange(of: plan.revision) { apply() }
        if widget.end.id != nil {
            waysSection
            if !plan.takes.isEmpty {
                coverSection
            }
        } else if widget.start.id != nil {
            countdownSection
        }
    }

    /// Writes the ticks to the route, once there's something ticked.
    private func apply() {
        guard !plan.takes.isEmpty else { return }
        widget = plan.applied(to: widget)
    }

    // MARK: From and To

    private var ends: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                Button { choosingFrom = true } label: {
                    endpoint("From", widget.start.name, lines: widget.start.marks,
                             symbol: "circle.circle.fill", tint: .accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Choose where you start")
                Divider().padding(.leading, 30)
                Button { choosingTo = true } label: {
                    endpoint("To", widget.end.name, lines: widget.end.marks,
                             symbol: "mappin.circle.fill", tint: .red)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Choose where you're going")
            }
            if widget.end.id != nil, widget.start.id != nil {
                Button(action: swap) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel("Swap From and To")
            }
        }
        .sheet(isPresented: $choosingFrom) {
            RouteEndSearch(title: "From", reachableFrom: nil) { picked, _ in
                switch picked {
                case .station(let station): setFrom(station)
                case .stop(let stop): setFrom(stop)
                case .none: break
                }
            }
        }
        .sheet(isPresented: $choosingTo) {
            RouteEndSearch(title: "To", reachableFrom: widget.start) { picked, _ in
                setTo(picked)
            }
        }
    }

    /// One line: the end's mark, its name, then its lines' bullets after it. The mark says which
    /// end, so there's no caption; VoiceOver reads `title` first.
    private func endpoint(_ title: String, _ name: String?, lines: [String], symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.body).foregroundStyle(tint).frame(width: 20)
            if let name {
                Text(name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 2) {
                    ForEach(lines.prefix(5), id: \.self) { RouteMark(route: $0, size: 16) }
                }
                .fixedSize()
            } else {
                Text("Choose \(title)").font(.body.weight(.medium)).foregroundStyle(.tint)
            }
            Spacer(minLength: 40)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(name ?? "not chosen")")
    }

    /// From a bus stop: a bus route on its first line, until a way there is ticked.
    private func setFrom(_ stop: BusRoutes.Stop) {
        let places = (widget.start.place, widget.end.place)
        widget.startAt(stop)
        matched = true
        reapply(ifStill: places)
    }

    private func setFrom(_ station: Station) {
        let places = (widget.start.place, widget.end.place)
        widget.startAt(station)
        matched = true
        reapply(ifStill: places)
    }

    private func setTo(_ place: RouteStart) {
        let places = (widget.start.place, widget.end.place)
        widget.goTo(place)
        matched = true
        reapply(ifStill: places)
    }

    /// Another station in the same complex, or the same stop: the same ways, which aren't found
    /// again (the plan goes by place), so their ticks are written to the route again.
    private func reapply(ifStill places: (String?, String?)) {
        if places == (widget.start.place, widget.end.place) { apply() }
    }

    /// From becomes To and To From; the ways are found again.
    private func swap() {
        let places = (widget.start.place, widget.end.place)
        widget.swapEnds()
        matched = true
        reapply(ifStill: places)
    }

    // MARK: Countdown only

    /// One way the lines go, or both.
    private enum CountdownWay: Hashable {
        case one(Direction)
        case both
    }

    /// Without To, which trains or bus the route counts down: a station's lines and which way,
    /// or a stop's bus.
    @ViewBuilder private var countdownSection: some View {
        switch widget.start {
        case .station(let station):
            Section {
                ChipFlow(spacing: 10) {
                    ForEach(station.routes, id: \.self) { route in
                        LineToggle(route: route, isOn: widget.selection.routes.contains(route)) {
                            toggleLine(route, at: station)
                        }
                    }
                }
                .padding(.vertical, 6)
                let directions = station.directions(of: widget.selection.routes)
                Picker("Direction", selection: countdownWay) {
                    ForEach(directions, id: \.self) { direction in
                        Text(station.directionLabel(direction, routes: widget.selection.routes))
                            .tag(CountdownWay.one(direction))
                    }
                    if directions.count == 2 {
                        Text("Both Ways").tag(CountdownWay.both)
                    }
                }
            } header: {
                Text("Countdown")
            } footer: {
                Text("With no To, the widget counts down these trains at \(station.name). Choose To for the ways there.")
            }
        case .stop(let stop):
            let lines = BusRoutes.linesAtStop[stop.code] ?? []
            Section {
                Picker("Bus", selection: busLine(lines)) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text("\(BusNames.label(lines[index].line)) to \(BusNames.destination(lines[index].to))").tag(index)
                    }
                }
            } header: {
                Text("Countdown")
            } footer: {
                Text("With no To, the widget counts down this bus at \(BusNames.readable(stop.name)). Choose To for the ways there.")
            }
        case .none:
            EmptyView()
        }
    }

    /// Adds or removes a line, keeping at least one and a way they run.
    private func toggleLine(_ route: String, at station: Station) {
        var routes = widget.selection.routes
        if routes.contains(route) {
            guard routes.count > 1 else { return }
            routes.removeAll { $0 == route }
        } else {
            routes.append(route)
        }
        widget.selection.routes = station.routes.filter(routes.contains)
        let directions = station.directions(of: widget.selection.routes)
        if !directions.contains(widget.selection.direction), let first = directions.first {
            widget.selection.direction = first
        }
        if directions.count < 2 { widget.bothWays = false }
    }

    private var countdownWay: Binding<CountdownWay> {
        Binding {
            widget.bothWays ? .both : .one(widget.selection.direction)
        } set: { way in
            switch way {
            case .one(let direction):
                widget.bothWays = false
                widget.selection.direction = direction
            case .both:
                widget.bothWays = true
            }
        }
    }

    /// The stop's line the route's bus is, by index in `lines`.
    private func busLine(_ lines: [(line: String, to: String)]) -> Binding<Int> {
        Binding {
            lines.firstIndex { $0.line == widget.bus?.line && $0.to == widget.bus?.destination } ?? 0
        } set: { index in
            guard lines.indices.contains(index), let stop = widget.bus?.stop else { return }
            widget.bus = BusChoice(line: lines[index].line, stop: stop, destination: lines[index].to)
        }
    }

    // MARK: Ways there

    @ViewBuilder private var waysSection: some View {
        Section {
            if plan.finding {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding every way there this week…").foregroundStyle(.secondary)
                }
            } else if plan.noTimetable {
                Text("The timetable hasn't downloaded yet.").foregroundStyle(.secondary)
                Button("Try Again", systemImage: "arrow.clockwise") { tries += 1 }
            } else if plan.ways.isEmpty {
                Text("No way there in up to two changes.").foregroundStyle(.secondary)
            }
            ForEach(plan.ways) { way in
                WayCard(way: way, plan: plan, fastest: way.fastest(among: plan.ways))
            }
            if !plan.more.isEmpty {
                Button("See Other Ways", systemImage: "ellipsis.circle.fill") { addingWay = true }
            }
        }
        .sheet(isPresented: $addingWay) {
            AddWaySheet(plan: plan)
        }
        // The ways for when the main start's don't run
        if !plan.fallbacks.isEmpty {
            Section {
                ForEach(plan.fallbacks) { way in
                    WayCard(way: way, plan: plan, fastest: nil, fallbackFrom: plan.mainStart)
                }
            } header: {
                Label("When \(plan.mainTrainsName ?? "they") aren't running", systemImage: "arrow.turn.down.right")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Cover

    private var coverSection: some View {
        let cover = plan.cover()
        return Section {
            CoverGrid(cover: cover)
            let gaps = plan.gaps
            if !gaps.isEmpty {
                // Where no ticked way runs, and the way to tick for it, if one from here does
                let gap = plan.filling()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: gaps.allSatisfy { $0.time == .night } ? "moon.stars.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not covered \(WayFinder.Part.named(gaps))").font(.subheadline.weight(.semibold))
                        Text(gap.map { "Tick \($0.way.rides.map { $0.map { BusLeg.line(of: $0) ?? $0 }.joined(separator: "/") }.joined(separator: " → ")) to cover them." }
                             ?? "No way from this station, going this way, runs then.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let gap {
                        Button("Tick") { plan.toggle(gap.way) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// A way there: its lines in turn, how many changes, when it runs, its minutes and a tick; ticked,
/// each change's stations as chips, any ticked of which will do.
private struct WayCard: View {
    let way: WayFinder.Way
    let plan: RoutePlan
    let fastest: String?
    /// As a fallback for this main start: what it is spelled out under its lines.
    var fallbackFrom: WayFinder.Way.Start?? = nil

    private var isTicked: Bool { plan.ticked.contains(way.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                plan.toggle(way)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        RideChain(rides: way.rides, size: 24)
                        if let main = fallbackFrom {
                            Text(way.fallbackDetail(from: main)).font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(way.changesLabel).font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        if let local = way.localTrackLabel {
                            Text(local).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: way.whenSymbol)
                            Text(way.when)
                        }
                        .font(.caption)
                        .foregroundStyle(way.isLimited ? Color.orange : Color.secondary)
                        if let fastest {
                            Text(fastest).font(.caption.weight(.semibold)).foregroundStyle(.green)
                                .fixedSize()
                        }
                    }
                    Spacer(minLength: 8)
                    Text(way.minutesLabel).font(.subheadline.weight(.semibold)).monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                    Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isTicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isTicked ? .isSelected : [])
            if isTicked {
                ForEach(Array(way.changes.enumerated()), id: \.offset) { index, options in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(way.changes.count > 1 ? "Change \(index + 1):" : "Change at:")
                            RideChain(rides: [way.rides[index], way.rides[index + 1]], size: 14)
                            if let how = how(options) { Text("· \(how)") }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        ChipFlow {
                            ForEach(options, id: \.place) { option in
                                let on = plan.isTicked(option, change: index, of: way)
                                Button {
                                    plan.toggle(option, change: index, of: way)
                                } label: {
                                    ChangeChip(name: option.name, on: on)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// "Across the platform", "3 min walk", or a range across the stations.
    private func how(_ options: [WayFinder.Way.Option]) -> String? {
        if options.allSatisfy(\.across) { return "Across the platform" }
        let walks = options.map { $0.across ? 0 : $0.walkMinutes }
        guard let low = walks.min(), let high = walks.max() else { return nil }
        if low == 0 { return "Across or \(high) min walk" }
        return low == high ? "\(low) min walk" : "\(low)–\(high) min walk"
    }
}

/// Lines ridden in turn: R → N Q → S.
struct RideChain: View {
    let rides: [[String]]
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(rides.enumerated()), id: \.offset) { index, ride in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 2) {
                    ForEach(ride, id: \.self) { RouteMark(route: $0, size: size) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rides.map(RouteMark.spoken).joined(separator: ", then "))
    }
}

/// A train's bullet, or a bus's badge for a route marked a bus's ("bus:B63", `BusLeg.prefix`).
struct RouteMark: View {
    let route: String
    let size: CGFloat

    var body: some View {
        if let line = BusLeg.line(of: route) {
            BusBadge(line: line, size: size * 0.85)
        } else {
            LineBullet(route: route, size: size)
        }
    }

    /// "R", "N or Q", "B63 bus", for VoiceOver.
    static func spoken(_ routes: [String]) -> String {
        let buses = routes.compactMap(BusLeg.line(of:))
        guard buses.isEmpty else { return buses.map(BusBadge.spokenName).joined(separator: " or ") }
        return Lines.spokenList(routes)
    }
}

/// A change's station: tinted with a tick when on.
struct ChangeChip: View {
    let name: String
    let on: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            Text(name).lineLimit(1)
        }
        .font(.subheadline.weight(on ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(on ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemFill)))
    }
}

/// Lays chips out in rows, wrapping as needed.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

/// The week in parts, each with the ticked way that's quickest then, or a warning where none runs.
struct CoverGrid: View {
    let cover: [WayFinder.Part: (way: WayFinder.Way, minutes: Int)?]

    private func name(_ day: WayFinder.Part.Day) -> String {
        switch day {
        case .weekday: "Weekdays"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }

    private func name(_ time: WayFinder.Part.Time) -> String {
        switch time {
        case .rush: "Rush"
        case .day: "Day"
        case .evening: "Evening"
        case .night: "Night"
        }
    }

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 8) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(WayFinder.Part.Time.allCases, id: \.self) { time in
                    Text(name(time)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            ForEach(WayFinder.Part.Day.allCases, id: \.self) { day in
                GridRow {
                    Text(name(day)).font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                    ForEach(WayFinder.Part.Time.allCases, id: \.self) { time in
                        cell(cover[WayFinder.Part(day: day, time: time)] ?? nil, label: "\(name(day)) \(name(time))")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func cell(_ quickest: (way: WayFinder.Way, minutes: Int)?, label: String) -> some View {
        Group {
            if let quickest {
                HStack(spacing: 2) {
                    ForEach(quickest.way.rides.map { $0[0] }.prefix(3), id: \.self) { RouteMark(route: $0, size: 15) }
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(quickest == nil ? Color.orange.opacity(0.15) : Color(.tertiarySystemFill)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(quickest.map { q in
            "\(q.way.rides.map(RouteMark.spoken).joined(separator: ", then ")), \(q.minutes) minutes"
        } ?? "No ticked way runs")
    }
}

// MARK: - Sheets

/// Bus stops by name, for the station and place searches.
enum BusStopSearch {
    /// Every bus stop with its name as shown, lowercased, and that name's words, made once off
    /// main: 13,000 stops are too many to name on each keystroke.
    private struct Named: Sendable {
        var stop: BusRoutes.Stop
        var name: String
        var words: [String]
    }

    private static let all = Task.detached(priority: .userInitiated) {
        // Their lines too, for the rows
        _ = BusRoutes.linesAtStop
        return BusRoutes.allStops.map { stop in
            let name = BusNames.readable(stop.name).lowercased()
            return Named(stop: stop, name: name,
                         words: name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        // Sorted once by name, so the results need only those starting as typed put first
        .sorted { $0.name < $1.name }
    }

    /// Stops whose name has every word typed, once there's enough typed to narrow them; with
    /// `reachable`, only those among its places (`WayFinder.stopPlace`).
    static func find(_ search: String, among reachable: Set<String>?, limit: Int = 40) async -> [BusRoutes.Stop] {
        guard search.count >= 2 else { return [] }
        let words = search.lowercased().split(separator: " ").map(String.init)
        let named = await all.value
        return await Task.detached(priority: .userInitiated) {
            let matching = named.filter { stop in
                guard reachable?.contains(WayFinder.stopPlace(stop.stop.code)) ?? true else { return false }
                return words.allSatisfy { word in stop.words.contains { $0.hasPrefix(word) } }
            }
            // Those starting as typed first: "4 av" finds 4 Av & 9 St before 1 Av & E 4 St
            let first = words.first ?? ""
            return (matching.filter { $0.name.hasPrefix(first) } + matching.filter { !$0.name.hasPrefix(first) })
                .prefix(limit).map(\.stop)
        }.value
    }
}

/// Picks a station by name, or with `offersStops` a bus stop too. For To, only stations
/// reachable from `reachableFrom`: from a station in up to two changes, from a bus stop by bus
/// or bus then train, at any time this week.
struct StationSearchSheet: View {
    let title: String
    let chosenID: String?
    let reachableFrom: RouteStart?
    var offersStops = false
    let pick: (RouteStart) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @State private var search = ""
    @State private var reachable: Set<String>?

    private var stations: [Station] {
        let query = StationSearch(search)
        let all = StationDirectory.all.filter { station in
            station.id != reachableFrom?.id && (reachable?.contains(station.complex) ?? true)
        }
        let shown = search.isEmpty ? all : all.filter(query.matches)
        return shown.sorted { $0.name < $1.name }
    }

    /// Bus stops whose name has every word typed, once there's enough typed to narrow them
    /// (`findStops`).
    @State private var stops: [BusRoutes.Stop] = []

    /// Works out `stops` for what's typed, off main.
    private func findStops() async {
        guard offersStops else {
            stops = []
            return
        }
        let found = await BusStopSearch.find(search, among: reachable)
        guard !Task.isCancelled else { return }
        stops = found
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty, reachableFrom == nil, let home = settings.defaultTrain.station {
                    Section {
                        stationRow(home, note: "Home Station")
                    }
                }
                Section {
                    if reachableFrom != nil && reachable == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Finding where you can get to…").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(stations) { stationRow($0, note: nil) }
                    }
                } header: {
                    if offersStops, !stops.isEmpty, !stations.isEmpty { Text("Stations") }
                } footer: {
                    if let from = reachableFrom, let name = from.name {
                        Text("Places you can't get to from \(name) in up to two changes, by train or bus, at any time this week, aren't listed.")
                    }
                }
                if !stops.isEmpty {
                    Section("Bus stops") {
                        ForEach(stops, id: \.code) { stopRow($0) }
                    }
                }
            }
            .searchable(text: $search, prompt: offersStops ? "Station, or street for a bus stop" : "Station")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
            }
            // Typing, or the places reachable found
            .task(id: "\(search)\u{0}\(reachable?.count ?? -1)") { await findStops() }
            .task {
                guard let from = reachableFrom else { return }
                // No timetable yet: every station
                reachable = await RoutePlan.reachable(from: from) ?? Set(StationDirectory.all.map(\.complex))
            }
        }
    }

    private func stationRow(_ station: Station, note: String?) -> some View {
        row(selected: station.id == chosenID, action: { pick(.station(station)) }) {
            Text(station.name).foregroundStyle(.primary)
            HStack(spacing: 3) {
                ForEach(station.routes, id: \.self) { LineBullet(route: $0, size: 18) }
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// A stop: its name, its buses, and which way they go from it (a stop is one side of the street).
    private func stopRow(_ stop: BusRoutes.Stop) -> some View {
        let lines = BusRoutes.linesAtStop[stop.code] ?? []
        return row(selected: "stop " + stop.code == chosenID, action: { pick(.stop(stop)) }) {
            Text(BusNames.readable(stop.name)).foregroundStyle(.primary)
            HStack(spacing: 3) {
                ForEach(Array(Set(lines.map(\.line))).sorted(), id: \.self) { BusBadge(line: $0, size: 16) }
            }
            if let to = lines.first?.to {
                Text("toward \(BusNames.destination(to))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) { label() }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The other ways there, found but not listed, to add to the route's.
struct AddWaySheet: View {
    let plan: RoutePlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(plan.more) { way in
                        Button {
                            plan.add(way)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    RideChain(rides: way.rides, size: 20)
                                    Text(way.changes.isEmpty ? "Straight there"
                                         : way.changes.map { $0.map(\.name).joined(separator: " or ") }.joined(separator: ", then "))
                                        .font(.subheadline)
                                    Text(way.when).font(.caption).foregroundStyle(way.isLimited ? Color.orange : Color.secondary)
                                }
                                Spacer()
                                Text(way.minutesLabel).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Other ways the timetable runs this week, slower or no better than those listed.")
                }
            }
            .navigationTitle("Other Ways")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
            }
        }
    }
}

