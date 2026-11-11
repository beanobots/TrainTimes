import ActivityKit
import SwiftUI
import UIKit

/// Starts made-up countdowns on the Lock Screen and in the Dynamic Island, drawn by the real
/// widget, and steps them on: a train's, a bus's, a walk to a train and on from it, a walk with no
/// train. Kept up from here only (`TestActivity`).
struct LiveActivityTool: View {
    @State private var test = TestActivity.shared

    var body: some View {
        Form {
            Section {
                ForEach(TestActivity.Kind.allCases) { kind in
                    Button {
                        Task { await test.start(kind) }
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            } header: {
                Text("Start")
            } footer: {
                Text("Made up, but drawn as the real ones are. Updated only from here, never by the push server or the app's refreshes. Starting one ends any countdown that's up, real ones too.")
            }

            if let kind = test.kind, let state = test.state {
                Section {
                    LabeledContent("Showing", value: test.stepName ?? kind.title)
                    controls(kind, state: state)
                } header: {
                    Text("Step On")
                }
            }

            Section {
                Button("End All", role: .destructive) {
                    Task { await test.endAll() }
                }
            } footer: {
                Text("Ends every countdown, as its own Stop does.")
            }

            if let message = test.message {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { test.adopt() }
    }

    @ViewBuilder private func controls(_ kind: TestActivity.Kind, state: CountdownState) -> some View {
        if kind.isWalk {
            if let next = test.nextStepName {
                Button("Next: \(next)") { Task { await test.step(by: 1) } }
            }
            if test.step > 0 {
                Button("Back") { Task { await test.step(by: -1) } }
            }
        }
        if kind != .walkOnly {
            Button("A Minute Sooner") { Task { await test.minuteSooner() } }
        }
        if kind == .train || kind == .bus || [.toTrain, .atStation, .changing].contains(state.walk?.phase) {
            Button(kind == .bus ? "At Stop Now" : "At Station Now") { Task { await test.atStation() } }
        }
        if !kind.isWalk {
            Button(state.isLive ? "Make Scheduled" : "Make Live") { Task { await test.toggleLive() } }
            Button(state.notice == nil ? "Add an Alert" : "Clear the Alert") { Task { await test.toggleAlert() } }
        }
        if kind.isWalk {
            Button("Arrived") { Task { await test.endAll() } }
        }
    }
}

/// The Prototyping card's made-up countdown: real `TrainActivityAttributes` and states, so the
/// widget draws them as it would a trip, posted locally. Marked by its trip
/// (`CountdownState.isPrototype`) so the app's refreshes and walks leave it be. One at a time,
/// as the app has.
@MainActor @Observable
final class TestActivity {
    static let shared = TestActivity()

    enum Kind: String, CaseIterable, Identifiable {
        case train, bus, walk, walkOnly

        var id: Self { self }

        var title: String {
            switch self {
            case .train: "Train Countdown"
            case .bus: "Bus Countdown"
            case .walk: "Walk, Ride and Walk"
            case .walkOnly: "Walk All the Way"
            }
        }

        var symbol: String {
            switch self {
            case .train: "tram.fill"
            case .bus: "bus.fill"
            case .walk: "figure.walk"
            case .walkOnly: "figure.walk.motion"
            }
        }

        var isWalk: Bool { self == .walk || self == .walkOnly }

        /// Its walk's steps, by `Script` index: to the train and on from it, or only the walk out.
        var steps: [Int] {
            switch self {
            case .walk: Array(Script.steps.indices)
            case .walkOnly: [Script.walkingOut, Script.walkingOut + 1]
            case .train, .bus: []
            }
        }
    }

    /// `CountdownState.trip` of the made-up countdowns.
    nonisolated static let trip = "prototype"

    private(set) var kind: Kind?
    /// The state last posted.
    private(set) var state: CountdownState?
    /// Which of its kind's `steps` a walk's on.
    private(set) var step = 0
    /// What went wrong, or what to do.
    var message: String?
    /// When the change asked for (`change(in:)`) is due; nil with none waiting.
    private(set) var changesAt: Date?

    private var activity: Activity<TrainActivityAttributes>?
    private var pending: Task<Void, Never>?
    private var movingOn: Task<Void, Never>?

    var stepName: String? {
        guard let kind, kind.isWalk else { return nil }
        return Script.steps[kind.steps[step]].name
    }

    var nextStepName: String? {
        guard let kind, kind.isWalk, step + 1 < kind.steps.count else { return nil }
        return Script.steps[kind.steps[step + 1]].name
    }

    /// Picks up a made-up countdown still up from before, as a walk's first step.
    func adopt() {
        if let activity, [.active, .stale].contains(activity.activityState) { return }
        forget()
        guard let found = Activity<TrainActivityAttributes>.activities.first(where: {
            [.active, .stale].contains($0.activityState) && $0.content.state.isPrototype
        }) else { return }
        activity = found
        state = found.content.state
        step = 0
        kind = found.attributes.bus != nil ? .bus
            : found.content.state.walk == nil ? .train
            : found.attributes.selection.stationID.isEmpty ? .walkOnly : .walk
    }

    // MARK: Starting

    /// Puts up `kind`'s countdown, its train or bus `dueIn` seconds away (a walk's at its `step`),
    /// ending any other.
    func start(_ kind: Kind, dueIn: TimeInterval = 5 * 60, step: Int = 0) async {
        cancelPending()
        message = nil
        await TrainActivityController.endAll()
        forget()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            message = "Live Activities are off for Leeway in the Settings app."
            return
        }
        let now = Date.now
        let attributes: TrainActivityAttributes
        var state: CountdownState
        switch kind {
        case .train, .walk:
            let selection = Selection(stationID: "R33", routes: ["R"], direction: .north)
            let ends = now.addingTimeInterval(kind == .walk ? TrainActivityController.walkLifetime : CountdownState.lifetime)
            attributes = TrainActivityAttributes(selection: selection, stationName: selection.station?.name ?? "4 Av-9 St",
                                                 heading: selection.heading, ends: ends)
            state = Self.trains(route: "R", dueIn: dueIn, terminal: "Forest Hills-71 Av", now: now)
        case .bus:
            let bus = Script.bus
            let ends = now.addingTimeInterval(CountdownState.lifetime)
            attributes = TrainActivityAttributes(selection: Selection(stationID: "", routes: [], direction: .north),
                                                 stationName: bus.stopName, heading: "Toward \(bus.shortWayName)",
                                                 ends: ends, bus: bus)
            state = Self.trains(route: BusLeg.prefix + bus.line, dueIn: dueIn,
                                terminal: bus.destination.map(BusNames.destination), now: now)
        case .walkOnly:
            // As `startPlainWalk`: no station or line, "due" when it ends
            let ends = now.addingTimeInterval(TrainActivityController.walkLifetime)
            attributes = TrainActivityAttributes(selection: Selection(stationID: "", routes: [], direction: .north),
                                                 stationName: "", heading: "", ends: ends)
            state = CountdownState(train: ends, trip: Self.trip, isLive: false, terminal: nil, following: [],
                                   notice: nil, updated: now)
        }
        self.step = kind.isWalk ? min(max(step, 0), kind.steps.count - 1) : 0
        if kind.isWalk { state = Self.walking(state, step: kind.steps[self.step], now: now) }
        do {
            activity = try Activity.request(attributes: attributes, content: Self.content(state, ends: attributes.ends))
        } catch {
            message = "Couldn't start it: \(error.localizedDescription)"
            return
        }
        self.kind = kind
        self.state = state
        drawMap()
    }

    /// A train or bus `dueIn` seconds away, and two after it.
    private static func trains(route: String, dueIn: TimeInterval, terminal: String?, now: Date) -> CountdownState {
        let due = now.addingTimeInterval(dueIn)
        return CountdownState(train: due, trip: trip, isLive: true, terminal: terminal,
                              following: [due.addingTimeInterval(4 * 60), due.addingTimeInterval(12 * 60)],
                              notice: nil, updated: now, route: route, followingRoutes: [route, route])
    }

    // MARK: Stepping on

    /// A walk on to its next step (`by` 1) or back.
    func step(by offset: Int) async {
        guard let kind, kind.isWalk, var state = current() else { return }
        let step = step + offset
        guard kind.steps.indices.contains(step) else { return }
        self.step = step
        state = Self.walking(state, step: kind.steps[step], now: .now)
        await post(state)
        drawMap()
    }

    /// Everything a minute closer: the train, the train after, getting off, getting there.
    func minuteSooner() async {
        guard var state = current() else { return }
        let now = Date.now
        let sooner = { (date: Date) in max(date.addingTimeInterval(-60), now) }
        state.train = sooner(state.train)
        state.following = state.following.map(sooner)
        if var walk = state.walk {
            walk.getOff = walk.getOff.map(sooner)
            walk.arrives = walk.arrives.map(sooner)
            walk.turnAt = walk.turnAt.map(sooner)
            state.walk = walk
        }
        state.updated = now
        await post(state)
        if state.train <= now { moveOnLater(state) }
    }

    /// The train or bus due now: "At Station" (a bus's "At Stop") for its held seconds, then the
    /// next, as the app moves it on.
    func atStation() async {
        guard var state = current() else { return }
        let now = Date.now
        state.train = now
        state.following = state.following.map { max($0, now.addingTimeInterval(60)) }
        state.updated = now
        await post(state)
        moveOnLater(state)
    }

    func toggleLive() async {
        guard var state = current() else { return }
        state.isLive.toggle()
        await post(state)
    }

    func toggleAlert() async {
        guard var state = current() else { return }
        state.notice = state.notice == nil ? "Delays" : nil
        await post(state)
    }

    /// The next thing to happen to it: a walk's next step, else a minute sooner.
    func advance() async {
        if let kind, kind.isWalk, nextStepName != nil {
            await step(by: 1)
        } else {
            await minuteSooner()
        }
    }

    /// `advance()` in `seconds`, kept running with the phone locked (iOS gives a locked app
    /// about 30 seconds).
    func change(in seconds: Int) {
        cancelPending()
        changesAt = .now.addingTimeInterval(TimeInterval(seconds))
        endBackgroundTask()
        background = UIApplication.shared.beginBackgroundTask(withName: "Test Live Activity") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        pending = Task {
            try? await Task.sleep(for: .seconds(seconds))
            // Cancelled, `cancelPending` ends it, and another may have begun
            guard !Task.isCancelled else { return }
            await advance()
            changesAt = nil
            endBackgroundTask()
        }
    }

    /// Keeps the app running with the phone locked until a waiting change is made.
    @ObservationIgnored private var background = UIBackgroundTaskIdentifier.invalid

    private func endBackgroundTask() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    /// Ends every countdown, real ones too.
    func endAll() async {
        cancelPending()
        await TrainActivityController.endAll()
        // Any made-up one left from before
        for activity in Activity<TrainActivityAttributes>.activities where activity.content.state.isPrototype {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        forget()
    }

    // MARK: Posting

    /// The state as shown now (moved on past a train that's gone), marked as made up again; nil
    /// once its countdown's gone (swiped away, or ended elsewhere).
    private func current() -> CountdownState? {
        guard let activity, [.active, .stale].contains(activity.activityState), let state else {
            forget()
            message = "It's gone: start another."
            return nil
        }
        var shown = state.movedOn(at: .now, holding: state.heldSeconds)
        shown.trip = Self.trip
        return shown
    }

    private func post(_ state: CountdownState) async {
        guard let activity else { return }
        self.state = state
        await activity.update(Self.content(state, ends: activity.attributes.ends))
    }

    /// As `TrainActivityController.content`, not kept up by the push server: stale as its train's
    /// due, or a walk's when getting off.
    private static func content(_ state: CountdownState, ends: Date?) -> ActivityContent<CountdownState> {
        ActivityContent(state: state, staleDate: min(state.staleDate(pushedOn: false), ends ?? .distantFuture))
    }

    /// Posts it moved on to the next train once its own has been at the station, as
    /// `TrainActivityController.moveOnLater` does.
    private func moveOnLater(_ state: CountdownState) {
        movingOn?.cancel()
        let wait = state.train.addingTimeInterval(state.heldSeconds + 1).timeIntervalSinceNow
        movingOn = Task {
            try? await Task.sleep(for: .seconds(max(wait, 0)))
            guard !Task.isCancelled, var moved = current() else { return }
            moved.trip = Self.trip
            await post(moved)
        }
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
        changesAt = nil
        endBackgroundTask()
        movingOn?.cancel()
        movingOn = nil
    }

    private func forget() {
        activity = nil
        kind = nil
        state = nil
        step = 0
    }

    // MARK: Walks

    /// `state` with the walk at `Script.steps[index]`: changing, the Q's countdown in place of
    /// the R's.
    private static func walking(_ state: CountdownState, step index: Int, now: Date) -> CountdownState {
        var state = state
        let step = Script.steps[index]
        if step.walk(now).phase == .changing, state.route != "Q" {
            state = trains(route: "Q", dueIn: 4 * 60, terminal: "96 St", now: now)
        } else if step.walk(now).phase == .toTrain || step.walk(now).phase == .atStation, state.route == "Q" {
            state = trains(route: "R", dueIn: 5 * 60, terminal: "Forest Hills-71 Av", now: now)
        }
        state.walk = step.walk(now)
        state.updated = now
        return state
    }

    /// Draws the map round the walk's turn, as the app does, then shows it.
    private func drawMap() {
        guard let kind, kind.isWalk, let scene = Script.steps[kind.steps[step]].scene else { return }
        let step = step
        let previous = state?.walk?.map
        Task {
            guard let name = await TurnMap.draw(scene, keeping: previous) else {
                message = "Apple Maps couldn't draw the turn's map: no map on the Lock Screen."
                return
            }
            guard self.step == step, var state = current() else { return }
            state.walk?.map = name
            await post(state)
        }
    }
}

extension CountdownState {
    /// One of the Prototyping card's made-up countdowns (`TestActivity`), which the app leaves be.
    var isPrototype: Bool { trip == TestActivity.trip }
}

/// The made-up trip: Park Slope to The Town Hall on the R, changing to the Q at DeKalb Av, as
/// the widget's previews have it.
private enum Script {
    struct Step {
        var name: String
        /// Its walk, as of a time.
        var walk: (Date) -> WalkState
        /// The map round its turn, walking.
        var scene: TurnMap.Scene?
    }

    /// Where the walk out from the train starts.
    static let walkingOut = 5

    static let bus = BusChoice(line: "B63",
                               stop: BusStop(id: "308209", name: "5 AV/9 ST", latitude: 40.6694, longitude: -73.9844,
                                             direction: "SW"),
                               destination: "BAY RIDGE 95 ST via 5 AV")

    private static let home = Walk.Point(lat: 40.66895, lon: -73.98525)
    private static let corner = Walk.Point(lat: 40.67030, lon: -73.98810)
    private static let stairs = Walk.Point(lat: 40.67080, lon: -73.98778)
    private static let exit = Walk.Point(lat: 40.75470, lon: -73.98660)
    private static let turn43 = Walk.Point(lat: 40.75592, lon: -73.98575)
    private static let townHall = Walk.Point(lat: 40.75560, lon: -73.98460)

    private static func scene(_ path: [Walk.Point], turn: Walk.Point, atStairs: Bool) -> TurnMap.Scene {
        TurnMap.Scene(path: path, turn: turn, heading: TurnMap.heading(into: turn, along: path) ?? 0,
                      end: path.last ?? turn, endsAtStairs: atStairs)
    }

    static let steps: [Step] = [
        Step(name: "Walking to the Train",
             walk: { _ in WalkState(phase: .toTrain, symbol: "arrow.turn.up.right", distance: "250 ft",
                                    instruction: "Take a right onto 4th Ave",
                                    detail: "Then down the stairs at the NE corner of 4 Av & 9 St", spare: 2,
                                    part: "front", endName: "The Town Hall") },
             scene: scene([home, corner, stairs], turn: corner, atStairs: true)),
        Step(name: "Stairs Ahead",
             walk: { _ in WalkState(phase: .toTrain, symbol: "stairs", distance: "60 ft",
                                    instruction: "Down the stairs at the NE corner of 4 Av & 9 St",
                                    detail: "Then through the turnstiles to the Manhattan-bound platform", spare: 3,
                                    part: "front", endName: "The Town Hall") },
             scene: scene([Walk.Point(lat: 40.67040, lon: -73.98800), stairs], turn: stairs, atStairs: true)),
        Step(name: "At the Station",
             walk: { _ in WalkState(phase: .atStation, symbol: "stairs", distance: "Here",
                                    instruction: "Down the stairs at the NE corner of 4 Av & 9 St",
                                    detail: "Manhattan-bound", part: "front", endName: "The Town Hall") }),
        // Off by itself in a minute, as the app's asleep on the train
        Step(name: "On the Train (Off in 1 min)",
             walk: { now in WalkState(phase: .riding, symbol: "tram.fill", distance: "On the train",
                                      instruction: "Get off at DeKalb Av", detail: "Ride in the middle", part: "middle",
                                      getOff: now.addingTimeInterval(60), getOffAt: "DeKalb Av",
                                      endName: "The Town Hall", arrives: now.addingTimeInterval(30 * 60),
                                      next: "Across the platform to the Q", nextSymbol: "figure.walk",
                                      nextNote: "Tap for the way to the Q") }),
        Step(name: "Changing to the Q",
             walk: { _ in WalkState(phase: .changing, symbol: "figure.walk", distance: "Change",
                                    instruction: "Across the platform to the Q", detail: "Manhattan-bound", spare: 1,
                                    part: "front", endName: "The Town Hall") }),
        Step(name: "Walking Out",
             walk: { now in WalkState(phase: .fromTrain, symbol: "arrow.turn.up.right", distance: "230 ft",
                                      instruction: "Take a right onto W 43rd St", detail: "Then arrive at the destination",
                                      endName: "The Town Hall", arrives: now.addingTimeInterval(3 * 60),
                                      turnAt: now.addingTimeInterval(60)) },
             scene: scene([exit, turn43, townHall], turn: turn43, atStairs: false)),
        Step(name: "Nearly There",
             walk: { now in WalkState(phase: .fromTrain, symbol: "mappin.and.ellipse", distance: "300 ft",
                                      instruction: "Arrive at The Town Hall", detail: "On the right",
                                      endName: "The Town Hall", arrives: now.addingTimeInterval(80),
                                      turnAt: now.addingTimeInterval(80)) },
             scene: scene([turn43, townHall], turn: townHall, atStairs: false)),
    ]
}

#Preview {
    NavigationStack { LiveActivityTool() }
}
