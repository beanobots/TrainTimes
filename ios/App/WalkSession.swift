import AudioToolbox
import CoreLocation
import Observation
import UIKit

/// A trip being walked, from Go: the walk to the train turn by turn, the station, the ride, any
/// change, and the walk from the train; or walking all the way (`init(walk:endName:end:)`), as
/// the walk from the train is, with no train. Your location is followed only while walking, from Go to
/// the station and from getting off to the end, with the screen off too (a background activity
/// session, the blue location pill); not on the train, nor at a change. Saved as it goes
/// (`Saved`), so it carries on if iOS closes the app (`ActiveWalk.restore()`).
@MainActor
@Observable
final class WalkSession: Identifiable {
    enum Stage: String, Codable, Equatable {
        /// Walking to the entrance.
        case toTrain
        /// At the entrance: down to the platform and onto the train.
        case atStation
        /// On the train.
        case riding
        /// Off the first train where the trip changes: across the platform, or a walk, to the next.
        case changing
        /// On the train changed to.
        case ridingOn
        /// Walking from the exit to the end.
        case fromTrain
        /// There.
        case arrived
    }

    /// Changed by `switchToFaster()`, and `walks` by re-routes. Nil walking all the way.
    private(set) var trip: TripPlanner.Trip?
    private(set) var walks: WalkingDirections.TripWalks? {
        didSet { updatePathLeft() }
    }
    /// Walking all the way: the walk, followed as walking out from a train is (`.fromTrain`).
    private(set) var plainWalk: Walk? {
        didSet { updatePathLeft() }
    }
    let endName: String
    let end: CLLocation
    /// When Go was tapped: the walk's countdown ends `TrainActivityController.walkLifetime` on.
    let started: Date

    private(set) var stage = Stage.toTrain {
        didSet {
            if stage != oldValue { showOnWidget() }
            updatePathLeft()
        }
    }
    /// Your last location while walking; none from getting off the train until the next fix,
    /// the last being where you got on.
    private(set) var location: CLLocation?
    /// Where you are along the walk you're on.
    private(set) var progress: Walk.Progress? {
        didSet { updatePathLeft() }
    }
    /// The first train's next trains from its platform, soonest first.
    private(set) var trains: [Arrival] = []
    /// With a change, the next trains of the lines changed to, from the change, soonest first.
    private(set) var onwardTrains: [Arrival] = []
    /// When each of `trains` gets to where you get off it (the end's station, or the change), and
    /// each of `onwardTrains` to the end's station, by trip, where the feeds say.
    private(set) var arrivals: [String: Date] = [:]
    /// The train you're on, once you've boarded: the one you'd catch as you went down.
    private(set) var boarded: Arrival?
    /// The train changed to, once you're on it.
    private(set) var boardedOnward: Arrival?
    /// The trains of `trains` and `onwardTrains` seen lately, gone ones too, by trip: the train you
    /// say you're on may have left before the board's latest (`board()`).
    private var seen: [String: Arrival] = [:]
    /// Where you were as you said you were on the train, for `ride` to place it by.
    private var boardedAt: CLLocation?
    /// Where the train you're on is, for the map, while you're on it.
    private(set) var ride: RideTracker?
    /// Each trip's latest from the feeds at where you get off it, by trip: the train you're on
    /// among them, for `ride`.
    private var riding: [String: Arrival] = [:]
    /// When you got off the first train at the change.
    private(set) var changedAt: Date?
    /// A trip from where you are that now gets there sooner, while you walk to the train.
    private(set) var faster: Faster?
    /// Switching to `faster`, or re-routing.
    private(set) var isFinding = false
    /// Whether the walk is on the Lock Screen: off once its countdown's swiped away, or another
    /// takes its place (a widget's walk button), until `showOnLockScreen()`.
    private(set) var onLockScreen = true
    /// Precise Location is off, even after asking for it for the walk: turns and getting there
    /// mostly can't be told.
    private(set) var isApproximate = false

    /// Another trip from where you are, by the timetable as New Trip times them, and how much
    /// sooner than yours it gets there.
    struct Faster: Equatable {
        let trip: TripPlanner.Trip
        let minutesSooner: Int
        let arrives: Date

        /// "Q from 7 Av".
        var label: String {
            "\(Lines.list(trip.selection.routes, joinedBy: "or")) from \(trip.selection.station?.name ?? "another station")"
        }
    }

    /// Metres from the entrance or the end that count as there.
    private static let there: Double = 25
    /// Seconds from the entrance to the platform: the stairs, the turnstiles.
    static let downToPlatform: TimeInterval = 60
    /// Seconds a train seen at your platform is remembered after it's left (`seen`).
    private static let seenFor: TimeInterval = 20 * 60
    /// Metres from the station you got on at that count as having ridden on from it.
    private static let awayFromStation: CLLocationDistance = 300
    /// Metres a second faster than walking or running: on the train, away from the station.
    private static let trainSpeed: CLLocationSpeed = 8
    /// Metres from the change's station, the end's, or the end, that count as come up there off
    /// the train, having gone in by another entrance (`pastStation(_:)`): an exit a long block
    /// from the station's middle, and the first fix up the street from it.
    private static let cameUp: CLLocationDistance = 400
    /// Seconds a station check on the ride waits for a fix: one from Wi-Fi or cell comes in a
    /// few, and underground, waiting longer mostly gets none anyway.
    private static let ridingFixWait: TimeInterval = 8
    /// Station checks in a row without a fix before only every other one's tried.
    private static let ridingMisses = 2
    /// Metres a second walking, for what's left of a walk: Apple Maps' pace for it if known.
    private static let pace = 1.33

    /// Metres off the walk's path that count as having gone another way, twice in a row.
    /// About an avenue's width: past the far sidewalk, as GPS good to a few metres can tell.
    static let offRoute: Double = 25
    /// Seconds between re-routes, so GPS wandering can't keep asking Apple Maps.
    private static let rerouteGap: TimeInterval = 10
    /// Minutes sooner another trip must be to be offered: worth turning round for.
    nonisolated private static let worthSwitching = 3

    /// Metres off the path you may be on the street's other sidewalk: past the width of the
    /// sidewalk you're meant to be on, short of going another way (`offRoute`).
    private static let otherSide: ClosedRange<Double> = 8...offRoute
    /// Metres GPS must be good to, at most, to say which sidewalk you're on: less than a street's
    /// width, as on an avenue with a clear sky. Worse is left on the walk's side.
    private static let sidewalkAccuracy: Double = 10
    /// Fixes in a row on the other sidewalk before the walk's moved over to it.
    private static let otherSideFixes = 3

    private var offFixes = 0
    /// You've been within `awayFromStation` of the station walking to it: not, say, in a cab
    /// on the way, for `ridingOff(_:)`.
    private var nearedStation = false
    /// `board()` begun from `ridingOff(_:)`, so it's only once.
    private var autoBoarding = false
    /// Fast fixes away from the station in a row (`ridingOff`).
    private var fastFixes = 0
    /// Fixes in a row clearly on another sidewalk from the walk's.
    private var sideFixes = 0
    /// Each fix's sidewalk check, numbered, and the last counted or ruled out: one that comes
    /// back after a later one's, after a fix that wasn't checked, or after a new walk, isn't
    /// counted.
    private var sideChecks = 0
    private var sideCounted = 0
    private var lastReroute = Date.distantPast
    private var following: WalkFollower?
    private var refreshing: Task<Void, Never>?
    /// Taking a fix as the train should be at each station, while the app's open.
    private var checking: Task<Void, Never>?
    private var background: CLBackgroundActivitySession?
    /// `start()` has run, and not `stop()` since.
    private var isStarted = false
    /// Its countdown has been put up, by this session or (`resumed`) before iOS closed the app.
    private var liveStarted = false
    /// Made from a saved walk (`init(saved:)`), whose countdown may still be up.
    private var resumed = false

    /// `stage`, `trains`, `onwardTrains` and `faster` are for previews; a walk starts at
    /// `.toTrain` and finds its trains.
    init(trip: TripPlanner.Trip, walks: WalkingDirections.TripWalks, endName: String, end: CLLocation,
         stage: Stage = .toTrain, trains: [Arrival] = [], onwardTrains: [Arrival] = [], faster: Faster? = nil) {
        self.faster = faster
        self.trip = trip
        self.walks = walks
        self.endName = endName
        self.end = end
        self.stage = stage
        self.trains = trains
        self.onwardTrains = onwardTrains
        started = .now
        updatePathLeft()
    }

    /// Walking all the way to `end`, by `walk`: the walk out from a train, without the train.
    init(walk: Walk, endName: String, end: CLLocation) {
        plainWalk = walk
        self.endName = endName
        self.end = end
        stage = .fromTrain
        started = .now
        updatePathLeft()
    }

    /// The end's station, or walking all the way, the end.
    var destinationName: String { trip?.destination.name ?? endName }

    // MARK: Where you are

    /// The walk you're on, or nil on the train, at a change or once there.
    var walk: Walk? {
        switch stage {
        case .toTrain: walks?.toTrain
        case .fromTrain: walks?.fromTrain ?? plainWalk
        case .atStation, .riding, .changing, .ridingOn, .arrived: nil
        }
    }

    /// The step whose instruction is next: the one whose path you're on, at the end of it (the
    /// first until you're found on one).
    var nextStep: Walk.Step? {
        guard let walk, let index = nextIndex else { return nil }
        return walk.steps[index]
    }

    /// Where `nextStep` is in the walk's steps.
    private var nextIndex: Int? {
        guard let walk, !walk.steps.isEmpty else { return nil }
        let index = progress?.step ?? 0
        return walk.steps.indices.contains(index) ? index : walk.steps.count - 1
    }

    /// The streets the walk crosses, by each crossing's middle, as the geocoder names them
    /// (`CrossStreets`): asked for by the walking map, read by its signs, the turn card and
    /// the Lock Screen.
    var crossNames: [Walk.Point: String] = [:]

    /// A step's instruction, a crossing's with its street's name once the geocoder has it,
    /// where the turn before didn't say: "Cross 4th Ave".
    func instruction(of step: Walk.Step) -> String {
        guard step.turn == .cross, step.instruction == "Cross the street", let name = crossingName(of: step) else {
            return step.instruction
        }
        return "Cross \(name)"
    }

    /// The street a step's crossing is over, as the geocoder has it.
    private func crossingName(of step: Walk.Step) -> String? {
        step.crossing.flatMap(CrossStreets.middle(of:)).flatMap { crossNames[$0] }
    }

    /// The warning at `nextStep`'s crossing, under its instruction, where there's no light: for
    /// a crossing's own step, just that; for a turn with a street to cross straight after,
    /// that street too. Nothing at a light.
    var lightNote: String? {
        guard let step = nextStep, let note = step.light?.note, let index = nextIndex else { return nil }
        if step.turn == .cross { return note }
        let street = walk?.streetTurnedOff(at: index) ?? crossingName(of: step) ?? "the street"
        return "Then cross \(street) · \(note)"
    }

    /// What's left of the walk's path, from where you are along it. Kept, not worked out each
    /// time it's read: the walking screen reads it several times a redraw, a few times a second.
    private(set) var pathLeft: [Walk.Point] = []

    private func updatePathLeft() {
        let left: [Walk.Point]
        if let walk {
            left = progress.map { walk.path(last: $0.left) } ?? walk.points
        } else {
            left = []
        }
        // Not a redraw for the same path, as standing still
        if left != pathLeft { pathLeft = left }
        vibrateIfNewInstruction()
    }

    /// Settings' Vibrate During Navigation, on unless turned off.
    static let vibratesKey = "walkVibrates"

    /// The instruction last shown: the stage, and walking, what its step says. Nil until the first.
    @ObservationIgnored private var shownInstruction: String?
    /// Where the step last shown ends, where its instruction's done: with its words, which step
    /// it is, rather than its place in the walk's steps, as a re-route starts them over from the
    /// first, the same turn ahead and all.
    @ObservationIgnored private var shownStepEnd: CLLocation?
    /// Metres apart two steps' ends may be and still be the same turn: a re-route's walk puts its
    /// corner a little elsewhere, a crosswalk's width short of the next corner.
    private static let sameTurn: CLLocationDistance = 10
    /// The instruction's check, waiting for the change under way to finish: a re-route sets the
    /// walk, then where you are on it, and the walk with the old place on it isn't one to buzz for.
    @ObservationIgnored private var instructionCheck: Task<Void, Never>?

    /// A buzz as the instruction shown changes while walking (Settings' `vibratesKey`): a tap
    /// with the app open; with it closed, the phone's vibration, felt in a pocket. How strong the
    /// tap, and how many buzzes, are Settings' (`WalkVibration`).
    private func vibrateIfNewInstruction() {
        guard instructionCheck == nil else { return }
        instructionCheck = Task { [weak self] in
            self?.instructionCheck = nil
            self?.checkInstruction()
        }
    }

    private func checkInstruction() {
        // The step's own words: a crossing's street named later isn't a new one. Told apart from
        // another saying the same by where it ends, not its number: a re-route's walk numbers
        // from 0, and "Take a left onto 4th Ave" again, at the same corner, isn't new
        let step = nextStep
        let shown = "\(stage.rawValue) \(step?.instruction ?? "")"
        let end = step.flatMap { $0.points.last ?? $0.crossing?.first }
            .map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        let sameEnd = switch (end, shownStepEnd) {
        case (nil, nil): true
        case let (end?, shownEnd?): end.distance(from: shownEnd) <= Self.sameTurn
        default: false
        }
        guard shown != shownInstruction || !sameEnd else { return }
        // Not for the first, as Go's tapped, nor before or after the walk
        let first = shownInstruction == nil
        shownInstruction = shown
        shownStepEnd = end
        guard !first, isStarted, UserDefaults.standard.object(forKey: Self.vibratesKey) as? Bool ?? true else { return }
        if UIApplication.shared.applicationState == .active {
            WalkVibration.tap()
        } else {
            WalkVibration.buzz()
        }
    }

    /// The steps after `nextStep`, the first on the turn card under it.
    var laterSteps: [Walk.Step] {
        guard let walk else { return [] }
        let index = (progress?.step ?? 0) + 1
        return index < walk.steps.count ? Array(walk.steps[index...]) : []
    }

    /// The turn after `nextStep`: "Then take a right onto W 43rd St".
    var thenStep: String? {
        laterSteps.first.map { step in
            "Then \(step.instruction.prefix(1).lowercased() + step.instruction.dropFirst())"
        }
    }

    /// Under `nextStep` on the Lock Screen: the warning where its crossing has no light, as
    /// in the app (`lightNote`); or the step after.
    var liveDetail: String? {
        lightNote ?? thenStep
    }

    /// Seconds of walking left on the walk you're on, at its own pace.
    var secondsLeft: TimeInterval {
        guard let walk else { return 0 }
        let left = progress?.left ?? walk.meters
        let pace = walk.seconds > 0 && walk.meters > 0 ? walk.meters / walk.seconds : Self.pace
        return left / pace
    }

    // MARK: The change

    /// Whether you're at the change, or on the train changed to.
    var isOnward: Bool { stage == .changing || stage == .ridingOn }

    /// Whether the train you're on or about to catch is the one to the end's station: there's no
    /// change, or you've made it. Which part to ride in is for that train.
    var isLastTrain: Bool { trip?.change == nil || isOnward }

    /// The lines changed to: "Q", "B or Q".
    var onwardLines: String {
        Lines.list(trip?.change?.routes ?? [], joinedBy: "or")
    }

    /// The lines changed to, as trains from the change: one selection per station joined there.
    private var onwardSelections: [Selection] {
        guard let trip else { return [] }
        return trip.change?.departureSelections(for: trip.selection) ?? []
    }

    /// Whether the change is across the platform, every line changed to on your train's side.
    var isAcross: Bool {
        guard let trip else { return false }
        return trip.change?.isAllAcross(from: trip.selection) ?? false
    }

    /// Seconds from getting off the first train to the platform of the next: none across the
    /// platform, else the change's walk, or the MTA's where that's longer.
    var changeWalk: TimeInterval {
        guard let trip, let change = trip.change, !isAcross else { return 0 }
        var minutes = change.walkMinutes
        if let from = change.arrivalStops(for: trip.selection).first, let to = change.departureStops(for: trip.selection).first {
            minutes = Change.walkMinutes(from: from, to: to, else: change.walkMinutes)
        }
        return TimeInterval(minutes * 60)
    }

    /// At the change: "Across the platform to the Q", "Walk to the Q, 3 min".
    var changeInstruction: String {
        isAcross ? "Across the platform to the \(onwardLines)"
            : "Walk to the \(onwardLines), \(WalkingView.minutes(seconds: changeWalk))"
    }

    var changeSymbol: String { isAcross ? "arrow.left.arrow.right" : "figure.walk" }

    /// The platform you're catching from: "Manhattan-bound".
    var platformName: String {
        guard isOnward, let trip, let change = trip.change else { return walks?.boarding.sideName ?? "" }
        let heading = change.heading(for: trip.selection)
        return heading.isEmpty ? onwardLines : "\(heading)-bound"
    }

    /// Where to get off the first train: the end's station, or with a change, where to change.
    /// A trip that could change at several takes its first, as the change and its trains do.
    var getOffName: String {
        trip?.change?.station?.name ?? destinationName
    }

    /// Where to get off the train you're on: the change's station, or the end's.
    var getOffHere: String { isLastTrain ? destinationName : getOffName }

    /// On the train: "Get off at Times Sq-42 St", or "Change at DeKalb Av for the Q", or with a
    /// change a street walk away "Change at Livonia Av, walk to Junius St for the 3".
    var rideInstruction: String {
        guard !isLastTrain else { return "Get off at \(destinationName)" }
        let walk = trip?.change?.streetWalk.map { ", walk to \($0.station.name)" } ?? ""
        return "Change at \(getOffName)\(walk) for the \(onwardLines)"
    }

    /// The line of the train you're on or would catch.
    var currentRoute: String {
        let train = isOnward ? boardedOnward ?? catchable() : boarded ?? catchable()
        return train?.route ?? (isOnward ? trip?.change?.routes.first : nil) ?? walks?.boarding.route ?? ""
    }

    // MARK: Trains

    /// The trains of the leg you're on: the first train's, or the next's from the change.
    private var currentTrains: [Arrival] { isOnward ? onwardTrains : trains }

    /// When you'll be on the platform, walking on as you are; at the change, once over to it.
    func onPlatform(now: Date = .now) -> Date {
        switch stage {
        case .toTrain: now.addingTimeInterval(secondsLeft + Self.downToPlatform)
        case .changing: max(now, (changedAt ?? now).addingTimeInterval(changeWalk))
        default: now.addingTimeInterval(Self.downToPlatform)
        }
    }

    /// The first train you can catch, getting to the platform at `onPlatform(now:)`.
    func catchable(now: Date = .now) -> Arrival? {
        let ready = onPlatform(now: now)
        return currentTrains.first { $0.leaves >= ready }
    }

    /// The train in at the platform as you're at the station or the change: due a moment ago
    /// (`AtStation`).
    func trainAtStation(now: Date = .now) -> Arrival? {
        guard stage == .atStation || stage == .changing else { return nil }
        return currentTrains.first { AtStation.covers($0.time, at: now) }
    }

    /// Trains that will have gone by the time you're down, the soonest first: "You'll miss the 8:18".
    func missed(now: Date = .now) -> [Arrival] {
        let ready = onPlatform(now: now)
        return currentTrains.filter { $0.leaves >= now && $0.leaves < ready }
    }

    /// When the train you're on, or would catch, gets to where you get off it, if the feeds say.
    var trainArrives: Date? {
        (isOnward ? boardedOnward ?? catchable() : boarded ?? catchable()).flatMap { arrivals[$0.trip] }
    }

    /// When you'll be at the end's station: the train there, or before the change, the first
    /// train changed to you'd make off this one.
    private var lastTrainArrives: Date? {
        if isLastTrain { return trainArrives }
        guard let off = trainArrives else { return nil }
        let ready = off.addingTimeInterval(changeWalk)
        return onwardTrains.first { $0.leaves >= ready }.flatMap { arrivals[$0.trip] }
    }

    /// When you'll get there: the last train's arrival and the walk from it.
    var arrives: Date? {
        switch stage {
        case .fromTrain: .now.addingTimeInterval(secondsLeft)
        case .arrived: .now
        default: lastTrainArrives.map { $0.addingTimeInterval((walks?.fromTrain.seconds ?? 0) + Self.downToPlatform) }
        }
    }

    // MARK: Going

    /// Starts following you (if walking), the trains, and the Lock Screen's countdown; once,
    /// and not in previews, which have neither.
    func start() {
        guard !isStarted, ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        isStarted = true
        if resumed {
            // Up still unless swiped away or replaced while the app was closed: then left so
            liveStarted = TrainActivityController.isWalking
            if !liveStarted { onLockScreen = false }
        }
        if stage == .toTrain || stage == .fromTrain { follow() }
        if stage == .riding || stage == .ridingOn { track() }
        save()
        showOnWidget()
        refreshing = Task { [weak self] in
            var round = 0
            while !Task.isCancelled, let stage = self?.stage, stage != .arrived {
                // Past its countdown's time, never found there: ended, so it stops following you
                if let self, Date.now >= self.started.addingTimeInterval(TrainActivityController.walkLifetime) {
                    if ActiveWalk.shared.session === self { ActiveWalk.shared.end() } else { self.stop() }
                    return
                }
                // The trains matter until you're off the last of them
                if stage != .fromTrain {
                    await self?.refreshTrains()
                    // On the train, the widget's getting off moved with its times
                    if let self, self.stage == .riding || self.stage == .ridingOn,
                       self.trainArrives != self.widgetGetOff {
                        self.showOnWidget()
                    }
                }
                // Every other minute, whether another trip's now sooner
                if round % 2 == 1 { await self?.checkFaster() }
                round += 1
                // Watched on the train: off it once it's due, as from the Lock Screen
                if UIApplication.shared.applicationState == .active {
                    self?.resume()
                }
                await self?.keepLockScreen()
                // Every few minutes, walks cached over an hour ago dropped
                if round % 10 == 0 { await WalkingDirections.cleanupCache() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Stops everything: location, the trains, and unless `endingCountdown` is false (another
    /// walk's about to take its place), the Lock Screen's countdown.
    func stop(endingCountdown: Bool = true) {
        isStarted = false
        if endingCountdown { endCountdown() }
        unfollow()
        untrack()
        refreshing?.cancel()
        refreshing = nil
    }

    /// Ends the walk's countdown, in a background task begun before location stops: with the
    /// screen off, location was all that kept the app awake, and without it the app could be
    /// suspended before the countdown ended, leaving its turn arrow in the Dynamic Island.
    private func endCountdown() {
        let task = UIApplication.shared.beginBackgroundTask(withName: "End walk countdown")
        Task {
            await TrainActivityController.endWalk()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    /// On the train, at the station or the change: stops following you until you're off it.
    func boardedTrain() {
        Task { await board() }
    }

    /// `boardedTrain()`, waited for: from the Lock Screen's button, which iOS gives only so long.
    func board() async {
        // The leg's trains first if there are none yet, as when the Lock Screen's button has
        // relaunched the app, or with it open, the latest: the train you're on is picked from
        // them, and never again after
        let open = UIApplication.shared.applicationState == .active
        switch stage {
        case .toTrain where trains.isEmpty || open, .atStation where trains.isEmpty || open: await refreshTrains()
        case .changing where onwardTrains.isEmpty || open: await refreshTrains()
        default: break
        }
        // Where you are: the last fix walking if it's fresh, else with the app open, one now.
        // Underground there may be none
        let fresh = location.flatMap { $0.timestamp.timeIntervalSinceNow > -120 ? $0 : nil }
        var here = fresh
        if here == nil, open { here = await RideTracker.fix(within: 5) }
        boardedAt = here
        switch stage {
        case .toTrain, .atStation:
            boarded = onTrain(of: trains, from: Set(trip?.selection.stopIDs ?? []), at: trip?.selection.station,
                              here: here) ?? catchable()
            offFixes = 0
            stage = .riding
            progress = nil
            unfollow()
        case .changing:
            boardedOnward = onTrain(of: onwardTrains, from: Set(onwardSelections.flatMap(\.stopIDs)),
                                    at: trip?.change?.station, here: here) ?? catchable()
            stage = .ridingOn
        case .riding, .ridingOn, .fromTrain, .arrived:
            return
        }
        track()
        save()
        await postLive()
    }

    /// The train you're on, of the leg's `trains` from `stops` at `station`, said just now: the one at the
    /// platform by the feeds, due or just gone; else of that and the last of the leg's to have
    /// left (`seen`), the one away from your station if `here` is, or the one nearer now. As the
    /// feeds can have it minutes off when you're on it, one still to come is timed as now.
    private func onTrain(of trains: [Arrival], from stops: Set<String>, at station: Station?, here: CLLocation?,
                         now: Date = .now) -> Arrival? {
        let soon = trains.first { $0.leaves >= now.addingTimeInterval(-90) }
        let gone = seen.values
            .filter { stops.contains($0.stop) && $0.leaves < now.addingTimeInterval(-90) }
            .max { $0.leaves < $1.leaves }
        var train = soon
        if let soon, soon.time <= now.addingTimeInterval(90) {
            train = soon
        } else if let gone {
            let away = here.map { here in
                station.map { here.distance(from: $0.location)
                    > max(Self.awayFromStation, here.horizontalAccuracy) } ?? false
            } ?? false
            let goneNearer = soon.map { now.timeIntervalSince(gone.leaves) < $0.time.timeIntervalSince(now) } ?? true
            if away || goneNearer { train = gone }
        }
        guard let train, train.time > now else { return train }
        return Arrival(route: train.route, time: now, stop: train.stop, lastStop: train.lastStop, isLive: train.isLive,
                       trip: train.trip, approach: train.approach, position: train.position)
    }

    /// Off the train, at `time`: at the change, over to the next; else up from the exit to the
    /// end, following you again.
    func gotOff(at time: Date = .now) {
        switch stage {
        case .riding where trip?.change != nil:
            stage = .changing
            changedAt = time
            location = nil
        case .riding, .ridingOn:
            stage = .fromTrain
            progress = nil
            location = nil
            // Two fixes off the walk out from here, not one left over from the walk in
            offFixes = 0
            sideFixes = 0
            sideCounted = sideChecks
            follow()
        case .toTrain, .atStation, .changing, .fromTrain, .arrived:
            return
        }
        untrack()
        save()
        Task {
            // The countdown to the train changed to, from its times
            if stage == .changing, onwardTrains.isEmpty { await refreshTrains() }
            await postLive(trains: stage == .changing)
        }
    }

    /// Called as the app comes back: off the train by now if it's due where you get off, as the
    /// Lock Screen will have said (`WalkState.movedOn(at:)`).
    func resume(now: Date = .now) {
        // Not once stopped: a round of `start()`'s loop under way as it was could follow you again
        guard isStarted, stage == .riding || stage == .ridingOn, let due = trainArrives, now >= due else { return }
        gotOff(at: due)
    }

    private func follow() {
        guard following == nil else { return }
        background = CLBackgroundActivitySession()
        following = WalkFollower(moved: { [weak self] location in self?.moved(to: location) },
                                 approximate: { [weak self] approximate in self?.isApproximate = approximate })
    }

    private func unfollow() {
        following?.stop()
        following = nil
        background?.invalidate()
        background = nil
    }

    /// On a train: where it is, by its times (`RideTracker`), and while the app's open, a fix as
    /// it should be at each station to check them. No following you, nor while closed.
    private func track() {
        untrack()
        guard let trip, let train = isOnward ? boardedOnward : boarded,
              let end = isLastTrain ? trip.destination : trip.change?.station else { return }
        let ride = RideTracker(train: train, to: end, live: riding[train.trip], arrives: arrivals[train.trip],
                               boardedAt: boardedAt)
        // Only as you get on: once relaunched, the train's times have it
        boardedAt = nil
        self.ride = ride
        checking = Task { [weak self] in
            await ride.build()
            // Checks in a row that got no fix: deep underground, after a couple, only every other
            // station's tried, until one gets a fix again
            var misses = 0
            while !Task.isCancelled {
                guard let next = ride.nextCheck() else { return }
                // A while at a time, as the feeds' times move it
                let wait = next.time.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(min(wait, 30)))
                    continue
                }
                guard self != nil else { return }
                // Open, so the map shows it: closed, iOS gives no fix without following
                let open = UIApplication.shared.applicationState == .active
                let skips = misses >= Self.ridingMisses && misses % 2 == 0
                let location = open && !skips ? await RideTracker.fix(within: Self.ridingFixWait) : nil
                guard !Task.isCancelled else { return }
                if open { misses = location == nil ? misses + 1 : 0 }
                ride.check(location, for: next.index)
            }
        }
    }

    private func untrack() {
        checking?.cancel()
        checking = nil
        ride = nil
    }

    private func moved(to location: CLLocation) {
        // Guard against race conditions and invalid states
        guard isStarted && stage != .arrived else { return }
        
        self.location = location
        if ridingOff(location) { return }
        guard let walk else { return }
        let here = Walk.Point(location.coordinate)
        progress = walk.progress(at: here, after: progress?.step ?? 0)
        // Gone another way: a new walk from here, once GPS has said so twice
        if let progress, progress.offPath > max(Self.offRoute, location.horizontalAccuracy) {
            offFixes += 1
            if offFixes >= 2 { Task { await reroute(from: location) } }
        } else {
            offFixes = 0
        }
        // Over the street on the other sidewalk, with GPS good enough to tell: the walk's moved
        // over to your side, as a new one from here, once it's said so a few times running
        if let progress, walk.crossings != nil, Self.otherSide.contains(progress.offPath),
           location.horizontalAccuracy > 0, location.horizontalAccuracy <= Self.sidewalkAccuracy,
           let onPath = walk.path(last: progress.left).first {
            sideChecks += 1
            let check = sideChecks
            Task { await checkSide(location, against: onPath, check: check) }
        } else {
            sideFixes = 0
            sideCounted = sideChecks
        }
        switch stage {
        case .toTrain where walks.map { isThere(location, at: $0.boarding.location) } ?? false:
            atStation()
        case .fromTrain where isThere(location, at: end):
            stage = .arrived
            endCountdown()
            unfollow()
            Saved.clear()
            return
        default:
            break
        }
        Task { await postLive() }
    }

    /// Whether `location` is moving off from the station faster than walking, as on the train you
    /// never said you were on: if so it's boarded, as "I'm on the train" would, so you aren't
    /// followed at best accuracy, nor re-routed back, for the rest of the ride.
    private func ridingOff(_ location: CLLocation) -> Bool {
        guard stage == .toTrain || stage == .atStation, let station = trip?.selection.station else { return false }
        // Already boarding: the fixes meanwhile are the train's, not the walk's to reroute on
        if autoBoarding { return true }
        let away = location.distance(from: station.location) > max(Self.awayFromStation, location.horizontalAccuracy)
        if !away { nearedStation = true }
        // Two fast fixes in a row, each with a speed iOS is sure of (under 0 when it can't tell),
        // so one spiked fix doesn't put you on a train
        let fast = location.speed > Self.trainSpeed && location.speedAccuracy >= 0 && location.speedAccuracy < 3
        fastFixes = away && fast ? fastFixes + 1 : 0
        // Gone in by another entrance, never said, and a fix from up the line: underground there
        // were none to be fast, so it's where it is that says you rode
        if let past = pastStation(location) {
            autoBoarding = true
            Task {
                await rideOn(to: past)
                autoBoarding = false
            }
            return true
        }
        guard away, nearedStation || stage == .atStation, fastFixes >= 2 else { return false }
        autoBoarding = true
        Task {
            await board()
            autoBoarding = false
        }
        return true
    }

    /// Where a fix puts you that's far past the station you were walking to, nearer the change or
    /// the end than it: on the train still, or come up at the change, or at the end.
    private enum Past {
        case riding, atChange, atEnd
    }

    /// Where `location` puts you, walking to the station or at it, if it's past it: more than
    /// `awayFromStation` from it, having been near it (not, say, starting out on the far side of
    /// it for an express), and nearer the change's station or the end's (or the end) than it.
    /// Nil short of that, walking to it still.
    private func pastStation(_ location: CLLocation) -> Past? {
        guard stage == .toTrain || stage == .atStation, nearedStation || stage == .atStation,
              let trip, let station = trip.selection.station else { return nil }
        let fromStation = location.distance(from: station.location)
        guard fromStation > max(Self.awayFromStation, location.horizontalAccuracy) else { return nil }
        let toChange = trip.change?.station.map { location.distance(from: $0.location) } ?? .infinity
        let toEnd = min(location.distance(from: trip.destination.location), location.distance(from: end))
        guard min(toChange, toEnd) < fromStation else { return nil }
        let near = max(Self.cameUp, location.horizontalAccuracy)
        if toEnd <= near, toEnd <= toChange { return .atEnd }
        if toChange <= near { return .atChange }
        return .riding
    }

    /// On from the station by the train you never said you were on, to `past`: boarded, as "I'm
    /// on the train" would, and off at the change or the end if that's where you've come up, so
    /// the countdown moves through each and you're followed again, now walking out. Not once the
    /// walk's stopped meanwhile: off the train, it'd follow you again.
    private func rideOn(to past: Past) async {
        await board()
        guard isStarted, past != .riding, stage == .riding else { return }
        gotOff()
        // Past the change too: on the train changed to, and off that
        guard isStarted, past == .atEnd, stage == .changing else { return }
        await board()
        guard isStarted, stage == .ridingOn else { return }
        gotOff()
    }

    /// Whether `location` is at `place`: within `there`, or as near as GPS can tell by a
    /// building or a station's stairs (up to 60 m), or with less than `there` of the walk left
    /// while that near the path (not a block over, level with its end).
    private func isThere(_ location: CLLocation, at place: CLLocation) -> Bool {
        let near = max(Self.there, min(location.horizontalAccuracy, 60))
        if location.distance(from: place) <= near { return true }
        guard let progress else { return false }
        return progress.left <= Self.there && progress.offPath <= near
    }

    /// At the entrance, whether found there or told: the way down and onto the train.
    func atStation() {
        guard stage == .toTrain else { return }
        stage = .atStation
        progress = nil
        offFixes = 0
        // Going down to the platform, where GPS mostly can't reach: rough fixes, for your dot
        // and for which train you're on (`board()`), not best accuracy to no end
        following?.relax()
        save()
        // The train counted down to, again from here, as the walking screen has it
        Task { await postLive(trains: true) }
    }

    /// Counts `location` toward moving the walk to your side of the street if it's on another
    /// sidewalk from `onPath`, the walk's nearest point; re-routes from it once there are enough.
    private func checkSide(_ location: CLLocation, against onPath: Walk.Point, check: Int) async {
        let other = await SidewalkStore.shared.differentSidewalks(Walk.Point(location.coordinate), onPath)
        guard stage == .toTrain || stage == .fromTrain, check > sideCounted else { return }
        sideCounted = check
        guard other else {
            sideFixes = 0
            return
        }
        sideFixes += 1
        if sideFixes >= Self.otherSideFixes {
            sideFixes = 0
            await reroute(from: location)
        }
    }

    // MARK: When things change

    /// A new walk from `location`, gone off the path: to the nearest way in for the train from
    /// here (it may now be another corner's), or on to the end; back onto the way it was going
    /// where that's about as good.
    private func reroute(from location: CLLocation) async {
        guard !isFinding, Date.now.timeIntervalSince(lastReroute) >= Self.rerouteGap else { return }
        isFinding = true
        lastReroute = .now
        defer { isFinding = false }
        switch stage {
        case .toTrain:
            // Not back to the station once far past it, on toward where you get off: that's the
            // ride (`pastStation(_:)`), not a wrong turn
            guard let trip, let current = walks, pastStation(location) == nil else { return }
            let boarding = StationWays.boarding(trip.selection, from: location) ?? current.boarding
            guard let walk = try? await WalkingDirections.walk(from: location, to: boarding, along: pathLeft), stage == .toTrain else { return }
            walks?.boarding = boarding
            walks?.toTrain = walk
        case .fromTrain:
            guard let walk = try? await WalkingDirections.walk(from: location, to: end, along: pathLeft), stage == .fromTrain else { return }
            // Walking out from a train, or all the way
            if walks != nil { walks?.fromTrain = walk } else { plainWalk = walk }
        case .atStation, .riding, .changing, .ridingOn, .arrived:
            return
        }
        offFixes = 0
        sideFixes = 0
        sideCounted = sideChecks
        progress = self.walk?.progress(at: Walk.Point(location.coordinate))
        save()
        await postLive()
    }

    /// Looks for a trip from where you are that gets there `worthSwitching` minutes sooner than
    /// yours, by the timetable: another station's lines now the next train's gone, say.
    private func checkFaster() async {
        guard stage == .toTrain, let here = location, let trip else {
            faster = nil
            return
        }
        let end = self.end
        let found = await Task.detached(priority: .utility) { () -> Faster? in
            let now = Date.now
            guard let timetable = TimetableStore.load(now: now),
                  let yours = TripPlanner.arrival(of: trip, from: here, to: end, at: now, timetable: timetable)
            else { return nil }
            let others = TripPlanner.plan(from: here, to: end, at: now, timetable: timetable)
                .filter { $0.selection.trainID != trip.selection.trainID }
                .prefix(TripPlanner.maxOptions)
                .compactMap { other in
                    TripPlanner.arrival(of: other, from: here, to: end, at: now, timetable: timetable).map { (other, $0) }
                }
            guard let best = others.min(by: { $0.1 < $1.1 }) else { return nil }
            let sooner = Int(yours.timeIntervalSince(best.1) / 60)
            return sooner >= Self.worthSwitching ? Faster(trip: best.0, minutesSooner: sooner, arrives: best.1) : nil
        }.value
        // Not if you've switched meanwhile: it was found against the trip you were on
        guard stage == .toTrain, self.trip == trip else { return }
        if found != faster {
            faster = found
            await postLive()
        }
    }

    /// Takes the faster trip: its walk from here, its trains, and the widget and Lock Screen.
    func switchToFaster() async {
        guard let faster, let here = location, !isFinding else { return }
        isFinding = true
        defer { isFinding = false }
        // Not if the walk's ended or been replaced meanwhile: its countdown and widget aren't this one's
        guard let walks = try? await WalkingDirections.walks(for: faster.trip, from: here, to: end),
              isStarted, stage == .toTrain else { return }
        let trip = faster.trip
        self.trip = trip
        self.walks = walks
        self.faster = nil
        progress = walks.toTrain.progress(at: Walk.Point(here.coordinate))
        trains = []
        onwardTrains = []
        arrivals = [:]
        offFixes = 0
        nearedStation = false
        fastFixes = 0
        sideFixes = 0
        sideCounted = sideChecks
        save()
        // The Magic Widget shows the new trip, as Go showed the old
        SharedTrip(option: SharedTrip.Option(selection: trip.selection, change: trip.change,
                                             destinationID: trip.destination.id),
                   app: nil, shared: .now, bothWays: nil).show()
        await refreshTrains()
        // Not if the walk's been ended or switched again while the trains came
        guard isStarted, self.trip == trip else { return }
        if onLockScreen, let live = liveState {
            do {
                try await TrainActivityController.startWalk(for: trip.selection, trains: countdownTrains, walk: live)
                liveStarted = true
                posted = live
            } catch {
                // Not the old trip's countdown updated with this one's trains: put up again
                // each round, as before one's started (`keepLockScreen()`)
                liveStarted = false
            }
        }
    }

    // MARK: Magic Widget

    /// When the widget last had the train due where you get off.
    private var widgetGetOff: Date?

    /// The Magic Widget, following the walk: the trip's board for the train to catch (at a
    /// change, the train changed to, as the trip then), and on the train or walking out, what
    /// to do (`WalkStage`); once there, back to its buttons.
    private func showOnWidget() {
        guard isStarted else { return }
        let expires = started.addingTimeInterval(TrainActivityController.walkLifetime)
        widgetGetOff = nil
        switch stage {
        case .toTrain, .atStation:
            SharedStore.saveWalkStage(nil)
        case .changing:
            if let onward = onwardSelections.first, let trip {
                SharedTrip(option: SharedTrip.Option(selection: onward, change: nil, destinationID: trip.destination.id),
                           app: nil, shared: .now).show()
            }
            SharedStore.saveWalkStage(nil)
        case .riding, .ridingOn:
            guard let walks else { break }
            let part = isLastTrain ? walks.part : nil
            let up = walks.leaving.up
            widgetGetOff = trainArrives
            // Not "Get off at" under "To" the same station
            let instruction = part.map { "Ride in the \($0.rawValue)" }
                ?? (isLastTrain ? "On the \(LineStyle.of(currentRoute).label) train" : "Change there for the \(onwardLines)")
            SharedStore.saveWalkStage(WalkStage(
                phase: .riding, route: currentRoute, title: getOffHere,
                instruction: instruction, getOff: trainArrives,
                next: isLastTrain ? up.instruction : changeInstruction,
                nextSymbol: isLastTrain ? up.turn.systemImage : changeSymbol,
                endName: endName, arrives: arrives, expires: expires))
        case .fromTrain:
            SharedStore.saveWalkStage(WalkStage(
                phase: .fromTrain, route: currentRoute, title: endName,
                instruction: walk?.steps.first?.instruction ?? "Walk to \(endName)",
                endName: endName, arrives: arrives, expires: expires))
        case .arrived:
            SharedStore.saveWalkStage(nil)
            SharedStore.saveSharedTrip(nil)
        }
    }

    // MARK: Lock Screen

    /// What the Lock Screen's countdown last showed of the walk.
    private var posted: WalkState?

    /// The trains for the countdown: those of the leg you're on you can still catch, soonest first.
    private var countdownTrains: [Arrival] {
        let ready = onPlatform()
        return currentTrains.filter { $0.leaves >= ready }
    }

    /// Puts the walk back on the Lock Screen, after it was swiped away or replaced.
    func showOnLockScreen() {
        onLockScreen = true
        liveStarted = false
        save()
        Task { await keepLockScreen() }
    }

    /// Each round: puts up the countdown once there are trains for it (tried again each round
    /// until it starts: no trains yet, no connection, the app in the background), or updates it
    /// with the trains as they are; notices it's gone, and leaves it so.
    private func keepLockScreen() async {
        // Not once stopped (a round under way as it was): it'd put up, or overwrite, another
        // walk's countdown, or one for a walk that's ended
        guard isStarted, onLockScreen, stage != .arrived else { return }
        if liveStarted {
            guard TrainActivityController.isWalking else {
                onLockScreen = false
                liveStarted = false
                save()
                return
            }
            await postLive(trains: true)
        } else if let live = liveState {
            do {
                if let trip {
                    try await TrainActivityController.startWalk(for: trip.selection, trains: countdownTrains, walk: live)
                } else {
                    // No train to count down to: the turns and when you'll get there
                    try await TrainActivityController.startPlainWalk(live)
                }
                liveStarted = true
                posted = live
            } catch {}
        }
    }

    /// The walk as the Lock Screen and Dynamic Island show it, from what the walking screen does.
    var liveState: WalkState? {
        let part = isLastTrain ? walks?.part?.rawValue : nil
        // To the minute, as shown, so it only changes what's posted when that does: walking out
        // it's now plus what's left, new each fix
        let arrives = self.arrives.map { Date(timeIntervalSinceReferenceDate: ($0.timeIntervalSinceReferenceDate / 60).rounded() * 60) }
        // For the train counted down to: the first you can catch (`countdownTrains`), not one
        // you'll miss before it
        let spare = { () -> Int? in
            self.catchable().map { Int($0.leaves.timeIntervalSince(self.onPlatform()) / 60) }
        }
        switch stage {
        case .toTrain:
            guard let step = nextStep else { return nil }
            return WalkState(phase: .toTrain, symbol: step.turn.systemImage,
                             distance: Walk.distance(progress?.toTurn ?? step.meters), instruction: instruction(of: step),
                             detail: liveDetail, spare: spare(), part: part, endName: endName, arrives: arrives,
                             faster: faster.map { "Faster: \($0.label), \($0.minutesSooner) min sooner" })
        case .atStation:
            guard let walks else { return nil }
            let down = walks.boarding.down
            return WalkState(phase: .atStation, symbol: down.turn.systemImage, distance: "Here",
                             instruction: down.instruction, detail: down.detail ?? walks.boarding.sideName,
                             part: part, endName: endName, arrives: arrives)
        case .riding, .ridingOn:
            guard let walks else { return nil }
            let up = walks.leaving.up
            return WalkState(phase: .riding, symbol: "tram.fill", distance: "On the train",
                             instruction: rideInstruction,
                             detail: isLastTrain ? part.map { "Ride in the \($0)" } : "Then get off at \(destinationName)",
                             part: part, getOff: trainArrives, getOffAt: getOffHere, endName: endName, arrives: arrives,
                             next: isLastTrain ? up.instruction : changeInstruction,
                             nextSymbol: isLastTrain ? up.turn.systemImage : changeSymbol,
                             nextNote: isLastTrain ? "Tap for the turns to \(endName)" : "Tap for the next \(onwardLines) trains")
        case .changing:
            return WalkState(phase: .changing, symbol: changeSymbol, distance: "Change",
                             instruction: changeInstruction, detail: platformName,
                             spare: changeWalk > 0 ? spare() : nil, part: part, endName: endName, arrives: arrives)
        case .fromTrain:
            guard let step = nextStep else { return nil }
            let up = step.turn == .stairsUp || step.turn == .elevatorUp
            return WalkState(phase: .fromTrain, symbol: step.turn.systemImage,
                             distance: up ? "Now" : Walk.distance(progress?.toTurn ?? step.meters),
                             instruction: instruction(of: step),
                             detail: liveDetail,
                             endName: endName, arrives: arrives)
        case .arrived:
            return nil
        }
    }

    /// Updates the Lock Screen's countdown if what it shows of the walk has changed, or with the
    /// trains as they are if `trains`.
    private func postLive(trains: Bool = false) async {
        // Not once stopped: `updateWalk` updates whichever walk's countdown is up, maybe the next walk's
        guard isStarted, onLockScreen, liveStarted, let live = liveState, trains || live != posted else { return }
        posted = live
        let toCatch = stage == .toTrain || stage == .atStation || stage == .changing
        await TrainActivityController.updateWalk(live, trains: trains && toCatch ? countdownTrains : nil)
    }

    /// New times now, and the Lock Screen's countdown with them.
    func refreshNow() async {
        guard stage != .fromTrain, stage != .arrived else { return }
        await refreshTrains()
        await postLive(trains: true)
    }

    /// The first train's times, to where you get off it, until you're off it; and with a change,
    /// the next's from the change, until you're off that too.
    private func refreshTrains() async {
        guard let trip else { return }
        if stage == .toTrain || stage == .atStation || stage == .riding {
            let last = trip.change == nil ? trip.destination : trip.change?.station
            if let found = await Self.trains(for: trip.selection, to: last) {
                trains = found.trains
                remember(found.trains)
                // Kept, as the train you're on drops off the board once it's left your station
                arrivals.merge(found.arrivals) { $1 }
                riding.merge(found.riding) { $1 }
            }
        }
        defer { updateRide() }
        guard trip.change != nil, stage != .fromTrain, stage != .arrived else { return }
        var found: [Arrival] = []
        for selection in onwardSelections {
            guard let board = await Self.trains(for: selection, to: trip.destination) else { continue }
            found += board.trains
            arrivals.merge(board.arrivals) { $1 }
            riding.merge(board.riding) { $1 }
        }
        if !found.isEmpty { onwardTrains = found.sorted { $0.leaves < $1.leaves } }
        remember(found)
    }

    /// `trains` kept in `seen`, a while after they've gone.
    private func remember(_ trains: [Arrival]) {
        for train in trains where !train.trip.isEmpty { seen[train.trip] = train }
        seen = seen.filter { $0.value.leaves > .now.addingTimeInterval(-Self.seenFor) }
    }

    /// The train you're on, as the feeds now have it, to `ride`.
    private func updateRide() {
        guard let ride else { return }
        ride.update(live: riding[ride.train.trip], arrives: arrivals[ride.train.trip])
    }

    /// `selection`'s next trains, when each gets to `last`, and each trip's arrival there; nil if
    /// the feeds can't be read.
    private static func trains(for selection: Selection, to last: Station?) async
        -> (trains: [Arrival], arrivals: [String: Date], riding: [String: Arrival])? {
        guard let board = try? await TrainService.board(for: selection, arrivingAt: last, includingAlerts: false,
                                                        includingOutages: false, includingOtherLines: false)
        else { return nil }
        // Another line's train on yours counts if the feeds have it at the station: the N running
        // local on the R late at night, to Times Sq-42 St
        let reaching = board.trains.filter { last == nil || board.destinationTimes[$0.trip] != nil }
        let trains = (reaching.isEmpty ? board.trains : reaching).filter { $0.leaves >= .now.addingTimeInterval(-30) }
        return (trains, board.destinationTimes, board.destinationTrains)
    }

    // MARK: Saving

    /// What carries a walk over iOS closing the app: all but where you are along it, found again
    /// from the next fix, and the trains, fetched again.
    struct Saved: Codable {
        /// The trip's; none walking all the way.
        var selection: Selection?
        var change: Change?
        var destinationID: String?
        var walks: WalkingDirections.TripWalks?
        /// Walking all the way.
        var plainWalk: Walk?
        var endName: String
        var endLatitude: Double
        var endLongitude: Double
        var started: Date
        var stage: Stage
        var boarded: Arrival?
        var boardedOnward: Arrival?
        var changedAt: Date?
        var arrivals: [String: Date]
        var onLockScreen: Bool

        private static let key = "walkSession"

        static func load() -> Saved? {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        }

        func store() {
            guard let data = try? JSONEncoder().encode(self) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }

        static func clear() {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The walk as saved, carrying on from its stage; nil if its stations are gone.
    convenience init?(saved: Saved) {
        var trip: TripPlanner.Trip?
        if let selection = saved.selection, let id = saved.destinationID {
            guard let destination = StationDirectory.station(id: id), saved.walks != nil else { return nil }
            trip = TripPlanner.Trip(selection: selection, change: saved.change, destination: destination)
        } else if saved.plainWalk == nil {
            return nil
        }
        self.init(trip: trip, walks: saved.walks, plainWalk: saved.plainWalk, endName: saved.endName,
                  end: CLLocation(latitude: saved.endLatitude, longitude: saved.endLongitude),
                  stage: saved.stage, started: saved.started)
        boarded = saved.boarded
        boardedOnward = saved.boardedOnward
        changedAt = saved.changedAt
        arrivals = saved.arrivals
        onLockScreen = saved.onLockScreen
        resumed = true
    }

    private init(trip: TripPlanner.Trip?, walks: WalkingDirections.TripWalks?, plainWalk: Walk?, endName: String,
                 end: CLLocation, stage: Stage, started: Date) {
        self.trip = trip
        self.walks = walks
        self.plainWalk = plainWalk
        self.endName = endName
        self.end = end
        self.stage = stage
        self.started = started
        updatePathLeft()
    }

    /// Saves the walk as it is now, while it's under way.
    private func save() {
        guard isStarted, stage != .arrived else { return }
        Saved(selection: trip?.selection, change: trip?.change, destinationID: trip?.destination.id, walks: walks,
              plainWalk: plainWalk, endName: endName, endLatitude: end.coordinate.latitude, endLongitude: end.coordinate.longitude,
              started: started, stage: stage, boarded: boarded, boardedOnward: boardedOnward, changedAt: changedAt,
              arrivals: arrivals, onLockScreen: onLockScreen).store()
    }
}

/// The walk from New Trip's Go, if one's under way: shown over the whole app (`AppTabs`), and
/// carried on from where it was saved when iOS relaunches the app, in the background for your
/// location or a Lock Screen button, or when you open it.
@MainActor
@Observable
final class ActiveWalk {
    static let shared = ActiveWalk()

    var session: WalkSession?
    /// Counts walks ended with End or Done, for New Trip to start over clean after each.
    private(set) var endings = 0

    /// Starts `session`, in place of any walk already under way.
    func begin(_ session: WalkSession) {
        self.session?.stop(endingCountdown: false)
        self.session = session
        session.start()
    }

    /// Ends the walk: its location, its trains and its countdown, and the walking screen.
    func end() {
        if session != nil { endings += 1 }
        session?.stop()
        session = nil
        WalkSession.Saved.clear()
        // The widget keeps the trip's board, as before Go
        SharedStore.saveWalkStage(nil)
    }

    /// The app quit from the app switcher: the walk ended there and then, as with End, and not
    /// saved to carry on, so iOS has no location to relaunch the app for.
    func quit() {
        guard let session else { return }
        session.stop(endingCountdown: false)
        self.session = nil
        WalkSession.Saved.clear()
        SharedStore.saveWalkStage(nil)
        TrainActivityController.endWalkBeforeQuitting()
    }

    /// The saved walk, carried on if it's still under way, as iOS closed the app during it. A
    /// walk countdown with no walk left to follow it (or one past its time) is ended.
    func restore() {
        guard session == nil else { return }
        guard let saved = WalkSession.Saved.load(),
              Date.now < saved.started.addingTimeInterval(TrainActivityController.walkLifetime),
              let session = WalkSession(saved: saved)
        else {
            WalkSession.Saved.clear()
            if SharedStore.loadWalkStage() != nil { SharedStore.saveWalkStage(nil) }
            Task { await TrainActivityController.endWalk() }
            return
        }
        self.session = session
        session.start()
        // Opened, not relaunched in the background: caught up with the train as it is
        if UIApplication.shared.applicationState == .active { session.resume() }
    }

    /// The Lock Screen's "I'm on the train": the walk, restored if need be, on to the ride.
    static func boardFromLockScreen() async {
        shared.restore()
        await shared.session?.board()
    }

    /// New times for the walk's countdown: its ↻, opening the app, a background refresh.
    static func refreshFromLockScreen() async {
        shared.restore()
        await shared.session?.refreshNow()
    }
}

/// Your location for a walk, from a location manager rather than `CLLocationUpdate.liveUpdates`:
/// a cancelled live-updates loop waits for its next update to end, and standing still (as when
/// End's tapped) none comes, so location stayed on, the blue pill with it. `stop()` stops it there
/// and then.
@MainActor
private final class WalkFollower: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let moved: (CLLocation) -> Void
    /// Told whether Precise Location is off, as it starts and as it's changed.
    private let approximate: (Bool) -> Void
    /// When it started: iOS's first update is often its cached fix from before (on getting off,
    /// the station you got on at), which isn't where you are.
    nonisolated private let started = Date.now

    init(moved: @escaping (CLLocation) -> Void, approximate: @escaping (Bool) -> Void) {
        self.moved = moved
        self.approximate = approximate
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // A few steps at a time: enough for turns and for telling which side of the street
        // you're on, without a fix (and the walking screen redrawn) for every step or wobble
        manager.distanceFilter = Self.walkingFilter
        manager.pausesLocationUpdatesAutomatically = false
        // With the walk's background activity session, so it carries on with the screen off
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        // Approximate Location's fixes are a few hundred metres out: never at a turn or the
        // station, nor off the walk. Precise for now, if you'll allow it
        if manager.accuracyAuthorization == .reducedAccuracy {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "Walking")
        }
    }

    /// Metres moved between fixes while walking.
    private static let walkingFilter: CLLocationDistance = 5
    /// Metres moved between fixes once relaxed.
    private static let relaxedFilter: CLLocationDistance = 20

    func stop() {
        manager.stopUpdatingLocation()
        manager.delegate = nil
    }

    /// Rough fixes from here on, at the station: a block or so is near enough, and costs far
    /// less than GPS hunting for a fix underground.
    func relax() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = Self.relaxedFilter
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              location.timestamp > started.addingTimeInterval(-10) else { return }
        Task { @MainActor in
            // Not one already on its way when stopped
            guard self.manager.delegate != nil else { return }
            self.moved(location)
        }
    }

    /// As it starts, and when Precise Location's turned on or off.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let approximate = manager.accuracyAuthorization == .reducedAccuracy
        Task { @MainActor in
            guard self.manager.delegate != nil else { return }
            self.approximate(approximate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

/// How a walk's new instruction is felt. With the app open it's a haptic tap; with it closed only
/// the phone's own vibration plays, once.
enum WalkVibration {
    /// The tap, with the app open: the error pattern's taps, then a heavy thump.
    @MainActor static func tap() {
        let notice = UINotificationFeedbackGenerator()
        let thump = UIImpactFeedbackGenerator(style: .heavy)
        notice.prepare()
        thump.prepare()
        notice.notificationOccurred(.error)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            thump.impactOccurred(intensity: 1)
        }
    }

    /// The phone's vibration, with the app closed.
    static func buzz() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}
