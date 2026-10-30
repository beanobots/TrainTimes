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
    private(set) var walks: WalkingDirections.TripWalks?
    /// Walking all the way: the walk, followed as walking out from a train is (`.fromTrain`).
    private(set) var plainWalk: Walk?
    let endName: String
    let end: CLLocation
    /// When Go was tapped: the walk's countdown ends `TrainActivityController.walkLifetime` on.
    let started: Date

    private(set) var stage = Stage.toTrain {
        didSet { if stage != oldValue { showOnWidget() } }
    }
    /// Your last location while walking; none from getting off the train until the next fix,
    /// the last being where you got on.
    private(set) var location: CLLocation?
    /// Where you are along the walk you're on.
    private(set) var progress: Walk.Progress?
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
    /// Metres a second walking, for what's left of a walk: Apple Maps' pace for it if known.
    private static let pace = 1.33

    /// Metres off the walk's path that count as having gone another way, twice in a row.
    private static let offRoute: Double = 40
    /// Seconds between re-routes, so GPS wandering can't keep asking Apple Maps.
    private static let rerouteGap: TimeInterval = 20
    /// Minutes sooner another trip must be to be offered: worth turning round for.
    nonisolated private static let worthSwitching = 3

    private var offFixes = 0
    private var lastReroute = Date.distantPast
    private var following: Task<Void, Never>?
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
    }

    /// Walking all the way to `end`, by `walk`: the walk out from a train, without the train.
    init(walk: Walk, endName: String, end: CLLocation) {
        plainWalk = walk
        self.endName = endName
        self.end = end
        stage = .fromTrain
        started = .now
    }

    /// Whether it's walking all the way, with no train.
    var isWalkOnly: Bool { trip == nil }

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
        guard let walk else { return nil }
        let index = progress?.step ?? 0
        return walk.steps.indices.contains(index) ? walk.steps[index] : walk.steps.last
    }

    /// What's left of the walk's path, from where you are along it.
    var pathLeft: [Walk.Point] {
        guard let walk else { return [] }
        guard let progress else { return walk.points }
        return walk.path(last: progress.left)
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

    /// On the train: "Get off at Times Sq-42 St", or "Change at DeKalb Av for the Q".
    var rideInstruction: String {
        isLastTrain ? "Get off at \(destinationName)" : "Change at \(getOffName) for the \(onwardLines)"
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
        unfollow()
        untrack()
        refreshing?.cancel()
        refreshing = nil
        if endingCountdown { Task { await TrainActivityController.endWalk() } }
    }

    /// On the train, at the station or the change: stops following you until you're off it.
    func boardedTrain() {
        Task { await board() }
    }

    /// `boardedTrain()`, waited for: from the Lock Screen's button, which iOS gives only so long.
    func board() async {
        // The train at the platform: due now, or just gone if the tap's late
        let atPlatform = { (trains: [Arrival]) in trains.first { $0.leaves >= .now.addingTimeInterval(-90) } }
        switch stage {
        case .toTrain, .atStation:
            boarded = atPlatform(trains) ?? catchable()
            stage = .riding
            progress = nil
            unfollow()
        case .changing:
            boardedOnward = atPlatform(onwardTrains) ?? catchable()
            stage = .ridingOn
        case .riding, .ridingOn, .fromTrain, .arrived:
            return
        }
        track()
        save()
        await postLive()
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
        following = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let self, !Task.isCancelled else { return }
                    if let location = update.location { self.moved(to: location) }
                }
            } catch {}
        }
    }

    private func unfollow() {
        following?.cancel()
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
        let ride = RideTracker(train: train, to: end, live: riding[train.trip], arrives: arrivals[train.trip])
        self.ride = ride
        checking = Task { [weak self] in
            await ride.build()
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
                let location = UIApplication.shared.applicationState == .active ? await RideTracker.fix() : nil
                guard !Task.isCancelled else { return }
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
        switch stage {
        case .toTrain where walks.map { isThere(location, at: $0.boarding.location) } ?? false:
            atStation()
        case .fromTrain where isThere(location, at: end):
            stage = .arrived
            unfollow()
            Saved.clear()
            Task { await TrainActivityController.endWalk() }
            return
        default:
            break
        }
        Task { await postLive() }
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
        save()
        // The train counted down to, again from here, as the walking screen has it
        Task { await postLive(trains: true) }
    }

    // MARK: When things change

    /// A new walk from `location`, gone off the path: to the nearest way in for the train from
    /// here (it may now be another corner's), or on to the end.
    private func reroute(from location: CLLocation) async {
        guard !isFinding, Date.now.timeIntervalSince(lastReroute) >= Self.rerouteGap else { return }
        isFinding = true
        lastReroute = .now
        defer { isFinding = false }
        switch stage {
        case .toTrain:
            guard let trip, let current = walks else { return }
            let boarding = StationWays.boarding(trip.selection, from: location) ?? current.boarding
            guard let walk = try? await WalkingDirections.walk(from: location, to: boarding), stage == .toTrain else { return }
            walks?.boarding = boarding
            walks?.toTrain = walk
        case .fromTrain:
            guard let walk = try? await WalkingDirections.walk(from: location, to: end), stage == .fromTrain else { return }
            // Walking out from a train, or all the way
            if walks != nil { walks?.fromTrain = walk } else { plainWalk = walk }
        case .atStation, .riding, .changing, .ridingOn, .arrived:
            return
        }
        offFixes = 0
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
        save()
        // The Magic Widget shows the new trip, as Go showed the old
        SharedTrip(option: SharedTrip.Option(selection: trip.selection, change: trip.change,
                                             destinationID: trip.destination.id),
                   app: nil, shared: .now, bothWays: nil).show()
        await refreshTrains()
        if onLockScreen, let live = liveState {
            try? await TrainActivityController.startWalk(for: trip.selection, trains: countdownTrains, walk: live)
            liveStarted = true
            posted = live
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
                             distance: Walk.distance(progress?.toTurn ?? step.meters), instruction: step.instruction,
                             detail: thenStep, spare: spare(), part: part, endName: endName, arrives: arrives,
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
                             instruction: step.instruction,
                             detail: thenStep,
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

    /// Starts `session`, in place of any walk already under way.
    func begin(_ session: WalkSession) {
        self.session?.stop(endingCountdown: false)
        self.session = session
        session.start()
    }

    /// Ends the walk: its location, its trains and its countdown, and the walking screen.
    func end() {
        session?.stop()
        session = nil
        WalkSession.Saved.clear()
        // The widget keeps the trip's board, as before Go
        SharedStore.saveWalkStage(nil)
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
