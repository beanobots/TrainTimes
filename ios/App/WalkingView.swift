import MapKit
import SwiftUI

/// A trip being walked, from New Trip's Go (`WalkSession`): the map following you, the next turn
/// on a card over its top, and the train under it. At the station, which stairs and which part
/// of the train; on the train, where to get off; then the turns to the end.
struct WalkingView: View {
    let session: WalkSession
    /// Ends the walk.
    let end: () -> Void

    /// Following you (or the train) by `follow()`, turned as `turn` says, until moved by hand.
    @State private var camera = MapCameraPosition.userLocation(fallback: .automatic)
    @State private var following = true
    @State private var turn = MapTurn.north
    /// Which north `turn`'s north is: Settings' Grid North.
    @AppStorage(MapNorth.key) private var nyNorth = false
    @State private var compass = CompassHeading()
    @AppStorage(WalkVoice.speaksKey) private var speaks = true
    @AppStorage(WalkSession.vibratesKey) private var vibrates = true
    /// The sound button opened into its Speak / Vibrate / Silent pill, and the closing a moment
    /// after a pick, put off by another.
    @State private var soundOpen = false
    @State private var soundClosing: Task<Void, Never>?
    /// The option under the finger while sliding on the pill, shown as picked until let go.
    @State private var soundHover: WalkSound?
    /// Whether the pill was already open when the touch on it began; nil between touches.
    @State private var soundTouchStartedOpen: Bool?
    /// The heading the map's turned to while following yours, smoothed from the compass's.
    @State private var shownHeading: Double?
    /// A big turn of yours under way, the map keeping up (`MapHeading.smoothed`).
    @State private var turning = false
    /// Metres up the map is while following you, from `startDistance` as zoomed since.
    @State private var walkDistance = Self.startDistance
    /// The same following the train, from `rideDistance`.
    @State private var rideZoom = Self.rideDistance
    /// The map's being pinched or dragged: following waits until it's let go.
    @State private var gesturing = false
    @Namespace private var mapScope
    /// How tall the top and bottom cards are, and the screen's own insets, so the map's buttons,
    /// and what it frames, are clear of them. By their heights, not where they are on screen:
    /// the map's padding can't change those, where it moved the cards it was worked out from,
    /// laying out again without end as the screen slid away.
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    @State private var insets = EdgeInsets()
    /// The whole map's height, under the cards too, for where you go on it.
    @State private var mapHeight: CGFloat = 0
    /// Where the train you're on is, while you're on it (`WalkSession.ride`).
    @State private var trainPlace: RideTracker.Place?
    /// Where you're drawn and followed while walking: eased toward `youOnMap` a tick at a time,
    /// carried on along the way at your pace between fixes (`glide()`), not jumping to each.
    @State private var shownSpot: CLLocationCoordinate2D?
    /// Metres along the way left you've likely walked since the last fix, for `drawnPath`.
    @State private var ahead: Double = 0
    /// The walk's crossings over streets ahead (`Walk.crossStreets`), for their signs: worked
    /// out once for each walk, not on every tick of the map.
    @State private var crossStreets: [[Walk.Point]] = []
    /// Metres up the map is now, however it got there, for whether the street signs show.
    @State private var mapDistance = Self.startDistance
    /// Open on screen: the map's loops and the compass run only then. A walk carries on in the
    /// background for its location and Lock Screen, but there's no map to see.
    @Environment(\.scenePhase) private var scenePhase
    private var isOnScreen: Bool { scenePhase == .active }
    /// Been in the background since last on screen, so the map snaps back onto you.
    @State private var wasInBackground = false

    /// Seconds between moving the train along.
    private static let trainTick: Double = 3
    /// Metres up the map is while following the train: a few stations either side.
    private static let rideDistance: Double = 4_000
    /// Metres up the map is as the walk starts: the block you're on and a couple ahead.
    private static let startDistance: Double = 450
    /// Metres up the map is, at most, for the cross streets' signs: zoomed out past it, the
    /// blocks too small for them, they'd crowd the way.
    private static let signsWithin: Double = 700
    /// Degrees the map's tipped back while walking: none, looking straight down, so no
    /// building, Midtown's towers included, stands in front of the way.
    private static let walkPitch: Double = 0
    /// Where you are between the cards while walking, as a share of the room between them up
    /// from the bottom card: low, with the way ahead above you.
    private static let walkLow: Double = 0.25
    /// Metres down the whole map's height, per metre the map's up, looking straight down: as
    /// MapKit draws it (measured, 215 m down the screen 400 m up).
    private static let metresDownPerUp: Double = 0.54
    /// Metres along the way left to look for which way it runs: past GPS's wobble, short of the
    /// next corner, so the map turns as you turn it, not before.
    private static let routeAhead: Double = 8
    /// Seconds between turning and moving the map while following.
    private static let followTick: Double = 0.25
    /// Metres you may be guessed on past the last fix: the walk's fixes come every 5 m
    /// (`WalkFollower`), so no further without one.
    private static let guessAhead: Double = 5
    /// Seconds held at `guessAhead` for the next fix before taking it you've stopped, as at a
    /// light, and easing back to the last.
    private static let guessHold: Double = 2
    /// Metres a second under which GPS's speed is taken as standing still.
    private static let stillSpeed: Double = 0.3
    /// Metres a second at most for the guess: a brisk walk or jog, not GPS's odd leap.
    private static let fastestWalk: Double = 3
    /// The same on a bike: a quick e-bike's.
    private static let fastestRide: Double = 9
    /// The share of the gap to where you're guessed to be closed each tick: corrections from a
    /// new fix taken in over a second or so, rather than jumped.
    private static let easing: Double = 0.5
    /// Metres off where you're shown past which it's a jump, not eased: a re-route, a new walk.
    private static let snapBeyond: Double = 30
    /// Seconds to ease back onto you after a pinch.
    private static let settle: Double = 0.4
    /// The ride's line, as wide as the trip map's zoomed out, with a casing as its.
    private static let rideWidth: CGFloat = 5
    private static let casing = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.black.withAlphaComponent(0.6) : .white
    })

    /// The way left to walk: solid, as a sat nav draws it, in the tint as it's yours to follow.
    private static let walkWidth: CGFloat = 8
    private static let cornerRadius: CGFloat = 26

    var body: some View {
        map
            .safeAreaPadding(.top, insets.top + topHeight + 8)
            .safeAreaPadding(.bottom, insets.bottom + bottomHeight + 8)
            .ignoresSafeArea()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mapHeight = $0 }
            .overlay(alignment: .top) {
                topCard
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            }
            .overlay(alignment: .bottom) {
                // Countdowns tick over: each minute, and often enough near a train's time for
                // its moment at the station, or the moment it's one you'll miss
                TimelineView(cardTick) { context in
                    bottomCard(now: AppClock.pretend(context.date))
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomHeight = $0 }
            }
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
            // Started and stopped by `ActiveWalk`, not by this showing: it carries on with the
            // app closed, and only End or Done ends it
            .animation(.snappy, value: session.stage)
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera, scope: mapScope) {
            DebugOverlays(on: .walking)
            // On the train, where the train is by its times: GPS can't tell underground
            if isRiding, let ride = session.ride, ride.path.count > 1 {
                // The ride's line under the train, as the trip map draws it, its stations on it
                let color = LineStyle.of(ride.train.route).swiftUIColor
                MapPolyline(coordinates: ride.path)
                    .stroke(Self.casing, style: StrokeStyle(lineWidth: Self.rideWidth + 3, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: ride.path)
                    .stroke(color, style: StrokeStyle(lineWidth: Self.rideWidth, lineCap: .round, lineJoin: .round))
                ForEach(ride.stops.indices, id: \.self) { index in
                    Annotation("", coordinate: ride.stops[index].coordinate) {
                        let ends = index == 0 || index == ride.stops.count - 1
                        Circle().fill(.white)
                            .overlay { if ends { Circle().stroke(.black.opacity(0.8), lineWidth: 2) } }
                            .frame(width: ends ? 8 : 4, height: ends ? 8 : 4)
                            .accessibilityHidden(true)
                    }
                }
            }
            if let trainPlace {
                Annotation("", coordinate: trainPlace.coordinate) {
                    trainCar
                        .accessibilityLabel("Your train, \(trainPlace.description)")
                }
            } else if !isRiding, let here = shownSpot ?? youOnMap {
                // You walking, as the train's shown on the ride, facing the way the compass says
                Annotation("", coordinate: here, anchor: .center) {
                    walker
                        .accessibilityLabel("You")
                }
            } else if isWalking || session.stage == .atStation {
                // Until the walk's first fix, MapKit's own; not at a change, underground, where
                // it'd keep GPS hunting for a fix
                UserAnnotation()
            }
            if session.walk != nil {
                // What's left of it, from where you are, in its two pieces (`drawnPieces`): each
                // kept by its place, so the rest's lines stay as they are while the lead's moves
                let pieces = drawnPieces
                ForEach(pieces.indices, id: \.self) { index in
                    MapPolyline(coordinates: pieces[index])
                        .stroke(Self.casing, style: StrokeStyle(lineWidth: Self.walkWidth + 4, lineCap: .round, lineJoin: .round))
                }
                ForEach(pieces.indices, id: \.self) { index in
                    MapPolyline(coordinates: pieces[index])
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Self.walkWidth, lineCap: .round, lineJoin: .round))
                }
                // Marks down its middle, so it reads as a way to go at street level
                ForEach(pieces.indices, id: \.self) { index in
                    MapPolyline(coordinates: pieces[index])
                        .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 9]))
                }
                // Where it crosses a street, once on the sidewalk: barred like the crosswalk
                ForEach(Array((session.walk?.crossings ?? []).enumerated()), id: \.offset) { _, crossing in
                    MapPolyline(coordinates: crossing.map(\.coordinate))
                        .stroke(.white, style: StrokeStyle(lineWidth: Self.walkWidth - 2, lineCap: .butt, dash: [2, 2.5]))
                }
                // Faintly over the buildings too, so the way round a corner shows through them
                ForEach(pieces.indices, id: \.self) { index in
                    MapPolyline(coordinates: pieces[index])
                        .stroke(Color.accentColor.opacity(0.3), style: StrokeStyle(lineWidth: Self.walkWidth, lineCap: .round, lineJoin: .round))
                        .mapOverlayLevel(level: .aboveLabels)
                }
            }
            // Where a bike's taken and left, ahead
            if isWalking {
                ForEach(docksAhead, id: \.self) { dock in
                    Annotation("", coordinate: dock.coordinate, anchor: .bottom) {
                        TurnSign(label: dock.name) {
                            BikeBullet(size: 24, own: dock.own)
                        }
                        .accessibilityLabel(dock.label)
                    }
                }
            }
            // The next turn, as a sign standing at its corner
            if isWalking, let turn = nextTurn {
                Annotation("", coordinate: turn.coordinate, anchor: .bottom) {
                    TurnSign(icon: turn.step.turn.systemImage, label: turn.street)
                        // The arrow's hidden, so say the turn itself: "Take a left onto 4th Ave"
                        .accessibilityLabel(turn.step.instruction)
                }
            }
            // The streets still to cross, each named on a green sign at its near curb, as the
            // city's own are; only zoomed in close enough to have room for them
            if isWalking, mapDistance <= Self.signsWithin {
                ForEach(crossingsAhead, id: \.middle) { crossing in
                    Annotation("", coordinate: crossing.curb.coordinate, anchor: .bottom) {
                        StreetSign(name: crossing.name, light: crossing.light)
                    }
                }
            }
            if session.stage == .toTrain || session.stage == .atStation, let boarding = session.walks?.boarding {
                Annotation("", coordinate: boarding.location.coordinate, anchor: session.stage == .toTrain ? .bottom : .center) {
                    if session.stage == .toTrain {
                        // Standing over the stairs as you walk up to them, with the side they're for
                        TurnSign(label: boarding.sideName.isEmpty ? nil : boarding.sideName) {
                            Self.entrance(boarding, label: "Entrance")
                        }
                    } else {
                        Self.entrance(boarding, label: "Entrance")
                    }
                }
            }
            if session.stage == .fromTrain || session.stage == .arrived {
                // The way out of the station, unless walking all the way
                if let leaving = session.walks?.leaving {
                    Annotation("", coordinate: leaving.location.coordinate) {
                        Self.entrance(leaving, label: "Exit")
                    }
                }
                Marker(session.endName, coordinate: session.end.coordinate)
            }
        }
        // Flat, looked straight down on: 3D buildings and trees stood in front of the way
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // Its own buttons, not MapKit's: its compass only turns it north
        .mapControls {}
        .overlay(alignment: .topTrailing) {
            // Trailing, so the sound pill's name tag stands out to its left without moving the rest
            VStack(alignment: .trailing, spacing: 8) {
                if !isRiding { locationButton }
                turnButton
                // Walking, speaking and vibrating; not on the train, where it's quiet anyway
                if !isRiding { soundButton }
            }
            .animation(.snappy, value: soundOpen)
            .padding(.trailing, 12)
            .padding(.top, 8)
        }
        .mapScope(mapScope)
        // The crossed streets' names, as the walk has them or the geocoder gives them: those
        // across the way, not the one you're on. Each as it comes, and none from a walk since replaced
        .task(id: session.walk?.crossings) {
            // Those of crossings still in the walk kept, so a re-route doesn't blank every sign
            // while they're found again
            let crossed = (session.walk?.crossings ?? []) + (session.walk?.steps.compactMap(\.crossing) ?? [])
            let middles = Set(crossed.compactMap(CrossStreets.middle(of:)))
            session.crossNames = session.crossNames.filter { middles.contains($0.key) }
            crossStreets = session.walk?.crossStreets ?? []
            // The crossings that are steps of their own, or after a turn, first, for their
            // cards: the geocoder's asked one at a time, and only so many
            guard let walk = session.walk else { return }
            var crossings = walk.steps.compactMap(\.crossing) + crossStreets
            // A walk the app routed knows its streets: only those it doesn't to ask
            if let streets = walk.streets, let all = walk.crossings {
                var known = Set<[Walk.Point]>()
                for (crossing, street) in zip(all, streets) where !street.isEmpty {
                    guard let middle = CrossStreets.middle(of: crossing) else { continue }
                    session.crossNames[middle] = street
                    known.insert(crossing)
                }
                crossings.removeAll(where: known.contains)
            }
            guard !crossings.isEmpty else { return }
            for await (middle, name) in CrossStreets.shared.names(for: crossings) {
                guard !Task.isCancelled else { break }
                session.crossNames[middle] = name
            }
        }
        .onAppear {
            // Not shown in the background (a walk restored as iOS relaunches the app for your
            // location): the compass waits until it's opened
            if scenePhase == .background { wasInBackground = true }
            if wantsCompass { compass.start() }
            startOver()
        }
        .onDisappear { compass.stop() }
        .onChange(of: wantsCompass) { _, wants in
            if wants { compass.start() } else { compass.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasInBackground = true
            case .active where wasInBackground:
                wasInBackground = false
                // Caught up at once, not eased across the blocks walked meanwhile
                if following { startOver() }
            default:
                break
            }
        }
        // At the station, no gliding: your dot as the rough fixes come, the map on it
        .onChange(of: session.location) {
            guard isOnScreen, !isWalking, !isRiding else { return }
            followStill()
        }
        // Following you: turned a little at a time, so a phone glanced at as you walk doesn't
        // swing the map about. Only walking, and not four times a second with the screen off:
        // on the train the train's loop follows it, at the station and the change it's still
        .task(id: FollowLoop(onScreen: isOnScreen, walking: isWalking)) {
            guard isOnScreen else { return }
            guard isWalking else {
                if shownSpot != nil { shownSpot = nil }
                ahead = 0
                if !isRiding { followStill() }
                return
            }
            while !Task.isCancelled {
                // Walking a route, the way it runs, so the street you're on is up the screen
                // and its turns are left and right on it; the compass otherwise
                if let heading = routeHeading ?? compass.heading {
                    let next = shownHeading.map {
                        MapHeading.smoothed($0, toward: heading, over: Self.followTick, turning: &turning)
                    } ?? heading
                    // Held still, the same: not the whole screen redrawn for it
                    if next != shownHeading { shownHeading = next }
                }
                // Any fix, however old: standing still, none come. Off the train there's none
                // until the next (`WalkSession.location`), not the station you got on at
                glide()
                if following, !gesturing, let here = shownSpot ?? youOnMap {
                    follow(here, distance: walkDistance, over: Self.followTick)
                }
                try? await Task.sleep(for: .seconds(Self.followTick))
            }
        }
        // The train moved along every few seconds, the map following it unless moved by hand
        .task(id: TrainLoop(ride: session.ride.map(ObjectIdentifier.init), onScreen: isOnScreen)) {
            guard let ride = session.ride else {
                trainPlace = nil
                return
            }
            guard isOnScreen else { return }
            while !Task.isCancelled {
                if let place = ride.place() {
                    withAnimation(.linear(duration: Self.trainTick)) { trainPlace = place }
                    if following, !gesturing { follow(place.coordinate, distance: rideZoom, over: Self.trainTick) }
                }
                try? await Task.sleep(for: .seconds(Self.trainTick))
            }
        }
        .feedsOverlays(.walking)
        // Being moved by hand: left to the fingers, not pulled back mid-pinch
        .onMapCameraChange(frequency: .continuous) {
            if camera.positionedByUser { gesturing = true }
        }
        // Moved by hand: zoomed, still on you, it keeps following at that zoom; moved off you,
        // it stops until the location or compass button
        .onMapCameraChange(frequency: .onEnd) { context in
            gesturing = false
            mapDistance = context.camera.distance
            guard camera.positionedByUser else { return }
            let on = isRiding ? trainPlace?.coordinate : shownSpot ?? youOnMap
            guard let on else {
                following = false
                return
            }
            // Against where following would put the centre, ahead of you while walking
            let shown = context.camera.centerCoordinate
            let wanted = center(on: on, distance: context.camera.distance)
            let across = context.region.span.latitudeDelta * Earth.metresPerDegree
            if CLLocation(latitude: shown.latitude, longitude: shown.longitude)
                .distance(from: CLLocation(latitude: wanted.latitude, longitude: wanted.longitude)) < across * 0.2 {
                if isRiding { rideZoom = context.camera.distance } else { walkDistance = context.camera.distance }
                following = true
                // Back on you gently, at the zoom left
                follow(on, distance: context.camera.distance, over: Self.settle)
            } else {
                following = false
            }
        }
        // Re-routed: a new walk, starting where you are. The map back on you and turned the new
        // way at once, not left as it was (moved off you, or still easing round from the old)
        .onChange(of: session.walk?.points.first) {
            guard isWalking else { return }
            following = true
            turning = false
            if let along = routeHeading { shownHeading = along }
            if let here = youOnMap { follow(here, distance: walkDistance, over: Self.settle) }
        }
        // The location button
        .onChange(of: camera.followsUserLocation) { _, follows in
            if follows { following = true }
        }
        // On and off the train: following it, then you
        .onChange(of: isRiding) {
            following = true
        }
        // Each new instruction said aloud for VoiceOver, as it reaches the turn card
        .onChange(of: topInstruction) { _, instruction in
            if let instruction { AccessibilityNotification.Announcement(instruction).post() }
        }
    }

    /// The turn card's instruction, as `topCard` has it.
    private var topInstruction: String? {
        switch session.stage {
        case .toTrain, .fromTrain: session.nextStep.map(session.instruction(of:))
        case .atStation: session.walks?.boarding.down.instruction
        case .riding, .ridingOn: session.rideInstruction
        case .changing: session.changeInstruction
        case .arrived: nil
        }
    }

    private var isRiding: Bool { session.stage == .riding || session.stage == .ridingOn }

    /// Walking a route, to the train or from it: the map turned the way you go, you low on it.
    private var isWalking: Bool { session.stage == .toTrain || session.stage == .fromTrain }

    /// The compass runs on screen while you're shown on the map, walking or at the station: for
    /// the map turned your way and your facing cone. Not on the train, at a change, or there.
    private var wantsCompass: Bool { isOnScreen && (isWalking || session.stage == .atStation) }

    /// The map back on you, not walking (at the station): no gliding, just where the fix is.
    private func followStill() {
        guard following, !gesturing, let here = youOnMap else { return }
        follow(here, distance: walkDistance, over: Self.settle)
    }

    /// The bottom card's ticks (`CardTick`): near the times of the trains counted down to, as
    /// each is due and as it's the last you can make.
    private var cardTick: CardTick {
        guard session.stage == .toTrain || session.stage == .atStation || session.stage == .changing else {
            return CardTick(near: [], minutes: [])
        }
        let now = AppClock.now
        // How long until you're on the platform: a train's no longer one to make that long before it goes
        let lead = session.onPlatform(now: now).timeIntervalSince(now)
        let trains = (session.isOnward ? session.onwardTrains : session.trains).prefix(4)
        // The train counted down to: its minutes, and its minutes to spare, turn over on its own
        // time's seconds, not the clock's
        let counted = session.catchable(now: now).map { [$0.time, $0.leaves.addingTimeInterval(-lead)] } ?? []
        // On the real clock, which `TimelineView` ticks by (`AppClock`)
        return CardTick(near: trains.flatMap { [$0.time, $0.leaves.addingTimeInterval(-lead)] }.map(AppClock.real),
                        minutes: counted.map(AppClock.real))
    }

    /// Where you're shown and followed: walking a route, your place along it while GPS puts you
    /// near enough (it drifts off by tall buildings), so the camera behind you stays over the
    /// street rather than in the block beside it, where 3D buildings would hide the way; where
    /// GPS puts you otherwise, or once you've gone another way.
    private var youOnMap: CLLocationCoordinate2D? {
        guard let location = session.location else { return nil }
        if isWalking, let progress = session.progress, progress.offPath <= WalkSession.offRoute,
           let onPath = session.pathLeft.first {
            return onPath.coordinate
        }
        return location.coordinate
    }

    /// Whether you're drawn on the walk's path, as `youOnMap` puts you while near enough to it.
    private var isOnPath: Bool {
        guard isWalking, let progress = session.progress else { return false }
        return progress.offPath <= WalkSession.offRoute && !session.pathLeft.isEmpty
    }

    /// What's left of the way from where you're guessed to be: the way left from the last fix,
    /// less what you've likely walked since (`ahead`).
    private var drawnPath: [Walk.Point] {
        isOnPath ? Self.path(session.pathLeft, from: ahead) : session.pathLeft
    }

    /// `drawnPath` for the map, in two: the rest from its second point on, which `ahead` gliding
    /// four times a second doesn't move (only a fix, or passing that point, does), and before it
    /// the short lead from where you're guessed to be up to it. Drawn as one, every tick remade the
    /// whole way left's lines; this way only the lead's are. One piece for a path of a point or two.
    private var drawnPieces: [[CLLocationCoordinate2D]] {
        let path = drawnPath.map(\.coordinate)
        guard path.count > 2 else { return path.count > 1 ? [path] : [] }
        return [Array(path.dropFirst()), Array(path.prefix(2))]
    }

    /// Moves where you're shown on a tick: along the way at GPS's speed since the last fix, up to
    /// `guessAhead`, then eased toward that, so you glide between fixes rather than jump to each.
    private func glide() {
        guard let fix = youOnMap else {
            shownSpot = nil
            ahead = 0
            return
        }
        var target = fix
        if isOnPath, let location = session.location {
            let fastest = session.nextStep?.isRidden == true ? Self.fastestRide : Self.fastestWalk
            let speed = location.speed >= Self.stillSpeed ? min(location.speed, fastest) : 0
            let guessed = speed * max(0, Date.now.timeIntervalSince(location.timestamp))
            // Held at the limit a moment for the next fix, then back to the last: stopped
            let next = guessed <= Self.guessAhead ? guessed
                : guessed <= Self.guessAhead + speed * Self.guessHold ? Self.guessAhead : 0
            if next != ahead { ahead = next }
            target = drawnPath.first?.coordinate ?? fix
        } else if ahead != 0 {
            ahead = 0
        }
        guard let shown = shownSpot,
              CLLocation(latitude: shown.latitude, longitude: shown.longitude)
                .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude)) < Self.snapBeyond
        else {
            shownSpot = target
            return
        }
        let eased = CLLocationCoordinate2D(latitude: shown.latitude + (target.latitude - shown.latitude) * Self.easing,
                                           longitude: shown.longitude + (target.longitude - shown.longitude) * Self.easing)
        guard abs(eased.latitude - shown.latitude) > 1e-7 || abs(eased.longitude - shown.longitude) > 1e-7 else { return }
        withAnimation(.linear(duration: Self.followTick)) { shownSpot = eased }
    }

    /// `path` from `metres` along it: the point there, then the rest. Its last point if shorter.
    private static func path(_ path: [Walk.Point], from metres: Double) -> [Walk.Point] {
        guard metres > 0 else { return path }
        var left = metres
        for index in path.indices.dropLast() {
            let from = path[index], to = path[index + 1]
            let piece = from.metres(to: to)
            if piece > left {
                let along = left / piece
                let start = Walk.Point(lat: from.lat + (to.lat - from.lat) * along, lon: from.lon + (to.lon - from.lon) * along)
                return [start] + path[(index + 1)...]
            }
            left -= piece
        }
        return path.last.map { [$0] } ?? []
    }

    /// The named cross streets not yet crossed: those whose far side is still on the way left.
    /// Not the street you're on, or have just turned off (`Walk.crossStreets`).
    private var crossingsAhead: [(middle: Walk.Point, curb: Walk.Point, name: String, light: Walk.Light?)] {
        guard let walk = session.walk, !session.crossNames.isEmpty else { return [] }
        let left = Set(session.pathLeft)
        return crossStreets.compactMap { crossing in
            guard let curb = crossing.first, let far = crossing.last, left.contains(far),
                  let middle = CrossStreets.middle(of: crossing), let name = session.crossNames[middle] else { return nil }
            return (middle, curb, name, walk.light(at: crossing))
        }
    }

    /// The next step that's a turn, or a crossing, where its instruction's done, and the street
    /// it's onto. Not the way down or up, or arriving: those have their own marks.
    private var nextTurn: (step: Walk.Step, coordinate: CLLocationCoordinate2D, street: String?)? {
        guard let step = session.nextStep, let end = step.points.last else { return nil }
        switch step.turn {
        case .stairsDown, .stairsUp, .elevatorDown, .elevatorUp, .arrive, .straight, .takeBike, .leaveBike: return nil
        case .cross: return (step, end.coordinate, nil)
        default: return (step, end.coordinate, Walk.street(in: step.instruction))
        }
    }

    /// A bike's dock ahead on the walk you're on, where it's taken or left.
    private struct DockMark: Hashable {
        let coordinate: CLLocationCoordinate2D
        let name: String?
        let label: String
        let own: Bool

        static func == (a: DockMark, b: DockMark) -> Bool {
            a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude && a.label == b.label
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(coordinate.latitude)
            hasher.combine(coordinate.longitude)
            hasher.combine(label)
        }
    }

    /// The walk's docks still ahead (`Walk.Turn.takeBike`, `.leaveBike`), named by the dock.
    private var docksAhead: [DockMark] {
        guard let walk = session.walk else { return [] }
        let at = session.progress?.step ?? 0
        return walk.steps.indices.filter { $0 >= at && walk.steps[$0].turn.isBikeDock }.compactMap { index in
            let step = walk.steps[index]
            guard let point = step.points.last else { return nil }
            // A Citi Bike dock's name after its "at"; your own bike's lock-up has none to show
            let own = step.instruction.hasPrefix("Lock your bike")
            let name = step.instruction.range(of: " at ").map { String(step.instruction[$0.upperBound...]) }
            return DockMark(coordinate: point.coordinate, name: own ? nil : name, label: step.instruction, own: own)
        }
    }

    /// Degrees from north the way left to walk runs from where you are, while walking it. None
    /// once you've gone off it: the old way's no longer yours, so the map turns as you face
    /// until the re-route's walk comes, not held along the street you left.
    private var routeHeading: Double? {
        guard isOnPath else { return nil }
        // Read four times a second: points as they are, not every one made a `CLLocation`
        let path = drawnPath
        guard let start = path.first else { return nil }
        // The first point far enough along to say which way, or the end if it's nearer
        guard let ahead = path.dropFirst().first(where: { $0.metres(to: start) >= Self.routeAhead })
                ?? path.last, ahead.metres(to: start) > 1 else { return nil }
        return start.heading(to: ahead)
    }

    /// Which way up the map is, as `turn` has it.
    private var heading: Double {
        switch turn {
        case .heading: shownHeading ?? 0
        case .north: MapNorth.heading(ny: nyNorth)
        }
    }

    /// The map on `coordinate`, `distance` up, turned to `heading`; animated over `seconds`
    /// unless it's barely moved. Walking, with you low on it; riding, on the train.
    private func follow(_ coordinate: CLLocationCoordinate2D, distance: Double, over seconds: Double) {
        let center = center(on: coordinate, distance: distance)
        let next = MapCamera(centerCoordinate: center, distance: distance, heading: heading,
                             pitch: isRiding ? 0 : Self.walkPitch)
        if let now = camera.camera, !camera.positionedByUser,
           CLLocation(latitude: now.centerCoordinate.latitude, longitude: now.centerCoordinate.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude)) < 0.5,
           abs(now.heading - next.heading) < 0.5, abs(now.distance - distance) < 1,
           abs(now.pitch - next.pitch) < 0.5 { return }
        if seconds > 0 {
            withAnimation(.linear(duration: seconds)) { camera = .camera(next) }
        } else {
            camera = .camera(next)
        }
    }

    /// Straight onto you as it opens, where the walk starts until GPS says: not MapKit's own
    /// following, flat and far out, swooping down onto you as the first fix comes in.
    private func startOver() {
        guard isWalking, let here = youOnMap ?? session.pathLeft.first?.coordinate else { return }
        ahead = 0
        shownSpot = here
        if let along = routeHeading { shownHeading = along }
        follow(here, distance: walkDistance, over: 0)
    }

    /// Where the map's centre goes to follow `coordinate`: ahead of it the way the map's turned
    /// while walking a route, so it's low on the screen with the way ahead; on it otherwise (on
    /// the train, or at the station, whose taller card would cover you low on the screen).
    private func center(on coordinate: CLLocationCoordinate2D, distance: Double) -> CLLocationCoordinate2D {
        guard session.stage == .toTrain || session.stage == .fromTrain, mapHeight > 0 else { return coordinate }
        // The map centres in the room between the cards; you go `walkLow` up from its bottom,
        // this many points below its middle, in metres at the map's scale
        let room = mapHeight - (insets.top + topHeight + 8) - (insets.bottom + bottomHeight + 8)
        let below = max(0, room * (0.5 - Self.walkLow))
        let meters = Double(below) * distance * Self.metresDownPerUp / Double(mapHeight)
        let angle = heading * .pi / 180
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + meters * cos(angle) / Earth.metresPerDegree,
            longitude: coordinate.longitude + meters * sin(angle) / (Earth.metresPerDegree * cos(coordinate.latitude * .pi / 180)))
    }

    /// Back on you, following again: MapKit's own location button, but as big as the others.
    private var locationButton: some View {
        Button {
            following = true
            if let here = youOnMap { follow(here, distance: walkDistance, over: Self.settle) }
        } label: {
            Image(systemName: following ? "location.fill" : "location")
                .font(.system(size: MapButton.icon, weight: .semibold))
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: MapButton.size, height: MapButton.size)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(following ? "Following your location" : "Show your location")
    }

    /// The compass button: your heading, or north up (Grid North, if Settings says), back again. Following you (or the
    /// train) again too, if the map's been moved off.
    private var turnButton: some View {
        Button {
            turn = turn.next
            following = true
        } label: {
            Group {
                switch turn {
                case .heading:
                    // Pointing north as the map's turned, or Manhattan as it lies with Grid North on
                    CompassNeedle(heading: heading, ny: nyNorth)
                case .north where nyNorth:
                    // Grid North: Manhattan upright, as Settings' icon
                    ManhattanIcon()
                        .fill(.primary)
                        .frame(width: 10, height: 26)
                case .north:
                    Text("N")
                        .font(.system(size: 22, weight: .bold))
                }
            }
            .font(.system(size: MapButton.icon, weight: .semibold))
            .frame(width: MapButton.size, height: MapButton.size)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map direction")
        .accessibilityValue(turn.label(ny: nyNorth))
        .accessibilityHint("Changes which way up the map is")
    }

    /// How the walk tells you its turns, kept for the next walk: one button showing which, growing
    /// into a pill of all three, Spoken Directions at the top. Tapped open, or slid down from and
    /// let go on one, like a menu. The pick's named beside it while open, and it shuts half a
    /// second after.
    private var sound: WalkSound { WalkSound(speaks: speaks, vibrates: vibrates) }

    /// The closed button's size, and each option's height on the open pill with the gap below it.
    private static let soundClosed: CGFloat = MapButton.size
    private static let soundOption: CGFloat = MapButton.size - 8
    private static let soundRow: CGFloat = soundOption + 4

    private var soundButton: some View {
        let options = WalkSound.allCases
        let shown = soundHover ?? sound
        let row = { (option: WalkSound) in CGFloat(options.firstIndex(of: option) ?? 0) * Self.soundRow }
        let openHeight = 8 + CGFloat(options.count) * Self.soundRow - 4
        return HStack(alignment: .top, spacing: 8) {
            if soundOpen {
                Text(shown.label)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .glassEffect(.regular, in: Capsule())
                    // Level with the pick on the pill
                    .padding(.top, 4 + (Self.soundOption - 36) / 2 + row(shown))
                    .contentTransition(.opacity)
                    .transition(.scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
            // One capsule throughout, so opening and closing is it growing down from the button
            // and the icons spreading out of it, not one view swapped for another
            ZStack(alignment: .top) {
                if soundOpen {
                    Circle()
                        .fill(.tint)
                        .frame(width: Self.soundOption, height: Self.soundOption)
                        .offset(y: 4 + row(shown))
                        .transition(.opacity)
                }
                ForEach(options, id: \.self) { option in
                    Image(systemName: option.symbol)
                        .font(.system(size: MapButton.icon, weight: .semibold))
                        .foregroundStyle(soundOpen
                            ? (option == shown ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            : (sound == .silent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)))
                        .frame(width: Self.soundOption, height: Self.soundOption)
                        .offset(y: 4 + (soundOpen ? row(option) : 0))
                        .opacity(soundOpen || option == sound ? 1 : 0)
                }
            }
            .frame(width: Self.soundClosed, height: soundOpen ? openHeight : Self.soundClosed, alignment: .top)
            .glassEffect(.regular.interactive(), in: Capsule())
            .contentShape(Capsule())
            .gesture(soundDrag)
            .sensoryFeedback(.selection, trigger: soundHover) { old, new in old != nil && new != nil }
            .accessibilityElement()
            .accessibilityLabel("Directions sound")
            .accessibilityValue(sound.label)
            .accessibilityAdjustableAction { direction in
                let index = options.firstIndex(of: sound) ?? 0
                let next = direction == .increment ? index + 1 : index - 1
                if options.indices.contains(next) { pick(options[next]) }
            }
        }
    }

    /// The option at a height down the pill, the nearest one above or below it.
    private func soundOption(at y: CGFloat) -> WalkSound {
        let options = WalkSound.allCases
        let index = Int(((y - 4) / Self.soundRow).rounded(.down))
        return options[min(max(index, 0), options.count - 1)]
    }

    /// A touch on the sound control: opens it if shut; slid, the option under the finger follows
    /// it and is picked on letting go; a tap on the open pill picks what's under it. Let go well
    /// off to the side, nothing's picked.
    private var soundDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                soundClosing?.cancel()
                if soundTouchStartedOpen == nil {
                    soundTouchStartedOpen = soundOpen
                    if !soundOpen { withAnimation(.snappy) { soundOpen = true } }
                }
                let slid = abs(value.translation.height) > 8 || abs(value.translation.width) > 8
                if slid || soundTouchStartedOpen == true {
                    withAnimation(.snappy) { soundHover = soundOption(at: value.location.y) }
                }
            }
            .onEnded { value in
                let startedOpen = soundTouchStartedOpen ?? false
                soundTouchStartedOpen = nil
                let slid = abs(value.translation.height) > 8 || abs(value.translation.width) > 8
                let offSide = value.location.x < -60 || value.location.x > Self.soundClosed + 60
                withAnimation(.snappy) { soundHover = nil }
                if (slid || startedOpen) && !offSide {
                    pick(soundOption(at: value.location.y))
                }
            }
    }

    /// Picks how turns are told, quietening the voice at once if it's no longer wanted, and shuts
    /// the pill half a second on, unless picked again meanwhile.
    private func pick(_ option: WalkSound) {
        withAnimation(.snappy) {
            speaks = option.speaks
            vibrates = option.vibrates
        }
        if option.speaks { VoicePack.ensure() } else { WalkVoice.shared.stop() }
        soundClosing?.cancel()
        soundClosing = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { soundOpen = false }
        }
    }

    /// The train you're on, in its line's colour.
    private var trainCar: some View {
        let style = LineStyle.of(session.currentRoute)
        return Image(systemName: "tram.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(style.textColor)
            .frame(width: 30, height: 30)
            .background(Circle().fill(style.swiftUIColor))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }

    /// You, walking: a figure in the tint, with a cone on the street the way you're facing.
    private var walker: some View {
        ZStack {
            if let facing = compass.heading {
                Self.facingCone
                    .fill(RadialGradient(colors: [Color.accentColor.opacity(0.5), Color.accentColor.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: Self.coneRadius))
                    .frame(width: Self.coneRadius * 2, height: Self.coneRadius * 2)
                    // Turned from the way the map's turned, then laid on the street as it's tipped back
                    .rotationEffect(.degrees(facing - heading))
                    .scaleEffect(x: 1, y: cos(Self.walkPitch * .pi / 180))
                    .allowsHitTesting(false)
            }
            Image(systemName: session.nextStep?.isRidden == true ? "bicycle" : "figure.walk")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.tint))
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
    }

    /// Points from you the facing cone reaches.
    private static let coneRadius: CGFloat = 46

    /// A wedge from the centre, up the way you face, 64° across.
    private static let facingCone = Path { path in
        let center = CGPoint(x: coneRadius, y: coneRadius)
        path.move(to: center)
        path.addArc(center: center, radius: coneRadius, startAngle: .degrees(-122), endAngle: .degrees(-58), clockwise: false)
        path.closeSubpath()
    }

    /// An entrance as a stair in its line's colour.
    static func entrance(_ way: StationWays.Way, label: String) -> some View {
        Image(systemName: way.entrance.isElevator ? "arrow.up.arrow.down" : "stairs")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(LineStyle.of(way.route).textColor)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(LineStyle.of(way.route).swiftUIColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white, lineWidth: 2))
            .shadow(radius: 1)
            .accessibilityLabel(way.entrance.address.map { "\(label), \($0)" } ?? label)
    }

    // MARK: Top

    @ViewBuilder private var topCard: some View {
        switch session.stage {
        case .toTrain, .fromTrain:
            if let step = session.nextStep {
                // The way up from the platform is where you are
                let up = step.turn == .stairsUp || step.turn == .elevatorUp
                // The step after, and how far it is from the turn
                let later = session.laterSteps.first
                TurnCard(icon: step.turn.systemImage,
                         distance: up ? "Now" : WalkSession.turnDistance(session.progress?.toTurn ?? step.meters),
                         instruction: session.instruction(of: step),
                         isCrossing: step.turn == .cross,
                         light: step.light,
                         lightNote: session.lightNote,
                         then: session.thenStep ?? step.detail,
                         thenDistance: later.flatMap { $0.meters > 0 ? Walk.distance($0.meters) : nil })
            }
        case .atStation:
            if let down = session.walks?.boarding.down {
                TurnCard(icon: down.turn.systemImage, distance: "Here", instruction: down.instruction, then: down.detail)
            }
        case .riding, .ridingOn:
            if let part = session.walks?.part, session.isLastTrain {
                TurnCard(icon: "tram.fill", distance: "Ride in the \(part.rawValue)",
                         instruction: session.rideInstruction,
                         then: session.walks?.leaving.up.instruction)
            } else if session.isLastTrain {
                TurnCard(icon: "tram.fill", distance: "On the train", instruction: session.rideInstruction,
                         then: session.walks?.leaving.up.instruction)
            } else {
                TurnCard(icon: "tram.fill", distance: "On the train", instruction: session.rideInstruction,
                         then: "Then get off at \(session.destinationName)")
            }
        case .changing:
            TurnCard(icon: session.changeSymbol, distance: "Change", instruction: session.changeInstruction,
                     then: session.platformName)
        case .arrived:
            EmptyView()
        }
    }

    // MARK: Bottom

    @ViewBuilder private func bottomCard(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Why turns and getting there go untold: Approximate Location, even for the walk
            if session.isApproximate && (session.stage == .toTrain || session.stage == .fromTrain) {
                Label("Precise Location is off", systemImage: "location.slash")
                    .font(.footnote).foregroundStyle(.orange)
            }
            switch session.stage {
            case .toTrain:
                if let faster = session.faster { fasterCard(faster) }
                trainHeader(now: now)
                // For when GPS can't tell you're there: next to tall buildings, or down the stairs
                Button("I'm at the station", systemImage: "stairs", action: session.atStation)
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
            case .atStation, .changing:
                trainHeader(now: now)
                if session.isLastTrain, let part = session.walks?.part {
                    boardAt(part)
                }
                Divider()
                endWalk
                Button("I'm on the train", systemImage: "tram.fill", action: session.boardedTrain)
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)
            case .riding, .ridingOn:
                rideHeader
                Divider()
                endWalk
                Button("I'm off the train", systemImage: "figure.walk") { session.gotOff() }
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)
            case .fromTrain:
                endHeader(now: now)
            case .arrived:
                endHeader(now: now)
                Button("Done") { end() }
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)
            }
            // Its countdown swiped away, or another in its place: back if wanted
            if !session.onLockScreen && session.stage != .arrived {
                Button("Show on Lock Screen", systemImage: "lock.iphone", action: session.showOnLockScreen)
                    .font(.footnote)
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    /// Another trip from here that's now sooner, and a button to take it.
    private func fasterCard(_ faster: WalkSession.Faster) -> some View {
        HStack(spacing: 10) {
            LineBullets(routes: faster.trip.selection.routes, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(faster.minutesSooner) min sooner").font(.subheadline.weight(.semibold))
                Text("\(faster.label) · arrive \(faster.arrives.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                Task { await session.switchToFaster() }
            } label: {
                if session.isFinding { ProgressView() } else { Text("Switch") }
            }
            .buttonStyle(.glassProminent)
            .disabled(session.isFinding)
        }
        .padding(10)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// The train to catch, the first or at the change: when the one you'd catch goes, and how
    /// much time you've got.
    private func trainHeader(now: Date) -> some View {
        let next = session.catchable(now: now)
        return HStack(spacing: 12) {
            LineBullet(route: session.currentRoute, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                if let here = session.trainAtStation(now: now) {
                    // As the Lock Screen has it, just due
                    Text("\(LineStyle.of(here.route).label) \(AtStation.label.lowercased())").font(.headline)
                    if let next, next.trip != here.trip { spare(for: next, now: now) }
                } else if let next {
                    // To its arrival, rounded down, as the Lock Screen and the boards count it
                    let minutes = MinutesToGo(until: next.time, from: now)
                    Text(minutes.isNow ? "\(LineStyle.of(next.route).label) now"
                         : "\(LineStyle.of(next.route).label) in \(minutes.label)")
                        .font(.headline)
                    spare(for: next, now: now)
                } else {
                    Text(session.platformName).font(.headline)
                    Text((session.isOnward ? session.onwardTrains : session.trains).isEmpty
                         ? "Finding the next trains…" : "No more trains soon")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 0)
            endButton
        }
    }

    /// "You can make it in 4 minutes, giving you 2 minutes of leeway", or the train you'll miss.
    @ViewBuilder private func spare(for train: Arrival, now: Date) -> some View {
        let ready = session.onPlatform(now: now)
        let spare = Int(train.leaves.timeIntervalSince(ready) / 60)
        if let missed = session.missed(now: now).first {
            Text("You'll miss the \(missed.leaves.formatted(date: .omitted, time: .shortened)) · next \(train.leaves.formatted(date: .omitted, time: .shortened))")
                .font(.footnote).foregroundStyle(.orange)
        } else if session.stage == .toTrain || (session.stage == .changing && ready > now) {
            let walk = max(1, Int((ready.timeIntervalSince(now) / 60).rounded(.up)))
            Text("You can make it in \(walk) \(walk == 1 ? "minute" : "minutes"), "
                 + (spare >= 1 ? "giving you \(Leeway.label(spare))" : "with no leeway"))
                .font(.footnote).foregroundStyle(spare >= 1 ? Color.liveText : .orange)
        } else {
            Text(session.platformName).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var rideHeader: some View {
        HStack(spacing: 12) {
            LineBullet(route: session.currentRoute, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("To \(session.getOffHere)").font(.headline)
                if let due = session.trainArrives {
                    Text("Due \(due.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            endButton
        }
    }

    private func endHeader(now: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white, .red)
                // Its name beside it says where; VoiceOver read the symbol as "Remove Map Pin"
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.endName).font(.headline)
                if session.stage == .arrived {
                    Text("You're here").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("\(Self.minutes(until: now.addingTimeInterval(session.secondsLeft), now: now)) · Arrive \(now.addingTimeInterval(session.secondsLeft).formatted(date: .omitted, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                    // After dark, where the night costs took it another way (`Walk.saferAtNight`)
                    if session.walk?.saferAtNight == true {
                        Text("Via safer streets").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if session.stage != .arrived { endButton }
        }
    }

    /// Which part of the train to board, for the exit at the other end.
    private func boardAt(_ part: Platform.TrainPart) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Board near the \(part.rawValue)").font(.subheadline.weight(.semibold))
            CarDiagram(route: session.walks?.boarding.route ?? session.currentRoute, part: part)
            Text("It stops by your stairs out at \(session.destinationName).")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The walk at the other end, to come.
    private var endWalk: some View {
        HStack(spacing: 10) {
            let out = session.walks?.fromTrain
            let biked = out?.hasRide == true
            Image(systemName: biked ? "bicycle" : "figure.walk").foregroundStyle(.tint).frame(width: 20)
            Text(biked ? "Then \(Self.minutes(seconds: out?.seconds ?? 0)) by bike to \(session.endName)"
                 : "Then a \(Self.minutes(seconds: out?.seconds ?? 0)) walk to \(session.endName)")
            Spacer()
            if let arrives = session.arrives {
                Text(arrives.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private var endButton: some View {
        Button("End", systemImage: "xmark") { end() }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .frame(width: 36, height: 36)
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("End Walk")
    }

    /// "4 min", "1 min" (never under one).
    static func minutes(until date: Date, now: Date) -> String {
        minutes(seconds: date.timeIntervalSince(now))
    }

    static func minutes(seconds: TimeInterval) -> String {
        "\(max(1, Int((seconds / 60).rounded(.up)))) min"
    }
}

/// What restarts the walking map's train loop: the ride, and whether it's on screen.
private struct TrainLoop: Equatable {
    var ride: ObjectIdentifier?
    var onScreen: Bool
}

/// What restarts the walking map's follow loop: whether it's on screen, and you're walking.
private struct FollowLoop: Equatable {
    var onScreen: Bool
    var walking: Bool
}

/// When the walking screen's bottom card redraws: once a minute, as each of `minutes` (the
/// train counted down to's time, and the last moment to make it) is a whole number of minutes
/// off, so its counts turn over on time; and every few seconds around each of `near` (each
/// train's, for its "now", its moment at the station, and "You'll miss").
private struct CardTick: TimelineSchedule {
    var near: [Date]
    var minutes: [Date]

    /// Seconds between ticks near a train's time, and otherwise.
    private static let fast: TimeInterval = 5
    private static let slow: TimeInterval = 60
    /// Seconds before and after each of `near` ticked fast.
    private static let before: TimeInterval = 90
    private static let after: TimeInterval = AtStation.seconds + 10

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        let near = near.sorted()
        return AnySequence(sequence(first: startDate) { date in
            // The always-on screen only once a minute
            if mode == .lowFrequency { return date.addingTimeInterval(Self.slow) }
            if near.contains(where: { date >= $0.addingTimeInterval(-Self.before) && date < $0.addingTimeInterval(Self.after) }) {
                return date.addingTimeInterval(Self.fast)
            }
            // The next whole minute off one of `minutes`, else a minute on; sooner where that's
            // the next one's fast ticks starting
            var next = date.addingTimeInterval(Self.slow)
            for time in minutes {
                // Half a second past it, as the count truncates: on it, it's still the last minute's
                let whole = time.addingTimeInterval(-((time.timeIntervalSince(date) / Self.slow).rounded(.down)) * Self.slow + 0.5)
                let turn = whole > date ? whole : whole.addingTimeInterval(Self.slow)
                if turn < next { next = turn }
            }
            let starts = near.map { $0.addingTimeInterval(-Self.before) }.first { $0 > date && $0 < next }
            return starts ?? next
        })
    }
}

/// A sign on a pole, standing on the map where something is: the next turn ("↰ 4th Ave"), or
/// the stairs with the side they're for. Its foot is the bottom of the view.
private struct TurnSign<Mark: View>: View {
    var label: String?
    @ViewBuilder var mark: Mark

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                mark
                if let label {
                    Text(label).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
            }
            .padding(.leading, 6).padding(.trailing, label == nil ? 6 : 12).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
            Rectangle()
                .fill(.secondary)
                .frame(width: 2, height: 34)
        }
        .accessibilityElement(children: .combine)
    }
}

extension TurnSign where Mark == TurnArrow {
    /// A turn's: its arrow, and the street.
    init(icon: String, label: String?) {
        self.label = label
        mark = TurnArrow(icon: icon)
    }
}

/// A street crossed, named on a pole at the curb as New York's signs are: white on green, with
/// a white rule inside the edge. Its foot is the bottom of the view.
private struct StreetSign: View {
    let name: String
    /// What's at the crossing: a warning tag under the sign where it's wide with no light,
    /// nothing otherwise.
    var light: Walk.Light? = nil

    /// The city's street-sign green.
    private static let green = Color(red: 0, green: 0.42, blue: 0.25)

    var body: some View {
        VStack(spacing: 0) {
            Text(name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Self.green, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 1.5).stroke(.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            if let light, light == .unsignalledWide {
                HStack(spacing: 4) {
                    WalkLight(light: light, size: 16, onYellow: true)
                    Text(light.tag).font(.caption2.weight(.bold)).lineLimit(1).fixedSize()
                }
                .padding(.leading, 3).padding(.trailing, 7).padding(.vertical, 3)
                .background(Color.yellow, in: Capsule())
                .foregroundStyle(Color.black)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .padding(.top, 3)
            }
            Rectangle()
                .fill(.secondary)
                .frame(width: 2, height: 24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(light == .unsignalledWide ? "Cross \(name), \(light?.note ?? "")" : "Cross \(name)")
    }
}

/// A crossing's light, as the walk signal on its pole: the lit figure, white on black; where
/// there's none, a warning, yellow where the street's wide.
private struct WalkLight: View {
    let light: Walk.Light
    var size: CGFloat = 20
    /// On a yellow tag already: the warning plain black.
    var onYellow = false

    var body: some View {
        Group {
            if light.hasSignal {
                Image(systemName: "figure.walk")
                    .foregroundStyle(.white)
            } else if onYellow {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.black)
            } else {
                // Where it's wide, black on yellow, as a road's warning signs
                let wide = light == .unsignalledWide
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(wide ? AnyShapeStyle(Color.black) : AnyShapeStyle(.background),
                                     wide ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.secondary))
            }
        }
        .font(.system(size: size * 0.62, weight: .bold))
        .frame(width: size, height: size)
        .background {
            if light.hasSignal { RoundedRectangle(cornerRadius: size * 0.22).fill(.black) }
        }
        .accessibilityHidden(true)
    }
}

/// A turn's arrow in the tint, for its sign.
/// How a walk tells you its turns, from the walking map's sound button: spoken and buzzed, buzzed
/// only, or neither. Kept as Speak Directions (`WalkVoice.speaksKey`) and Vibrate During
/// Navigation (`WalkSession.vibratesKey`); speaking without buzzing, left from when Settings had
/// both, counts as Speak.
enum WalkSound: CaseIterable {
    case speak, vibrate, silent

    init(speaks: Bool, vibrates: Bool) {
        self = speaks ? .speak : vibrates ? .vibrate : .silent
    }

    var speaks: Bool { self == .speak }
    var vibrates: Bool { self != .silent }

    var symbol: String {
        switch self {
        case .speak: "speaker.wave.2.fill"
        case .vibrate: "iphone.radiowaves.left.and.right"
        case .silent: "speaker.slash.fill"
        }
    }

    var label: String {
        switch self {
        case .speak: "Spoken Directions"
        case .vibrate: "Vibrate"
        case .silent: "Silent"
        }
    }
}

private struct TurnArrow: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.headline.weight(.heavy))
            .foregroundStyle(.tint)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

/// The next turn, big, over the top of the map.
private struct TurnCard: View {
    let icon: String
    let distance: String
    let instruction: String
    /// A crossing's own step (`Walk.Turn.cross`).
    var isCrossing = false
    /// A crossing's light, and its warning under the instruction where there's none
    /// (`WalkSession.lightNote`); nothing shown at a light.
    var light: Walk.Light? = nil
    var lightNote: String? = nil
    let then: String?
    var thenDistance: String? = nil

    /// A crossing step over a wide street with no light: its tile yellow, as a warning.
    private var warns: Bool { isCrossing && light == .unsignalledWide }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(warns ? .black : .white)
                    .frame(width: 64, height: 64)
                    .background(warns ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.tint),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(distance).font(.title.weight(.bold)).monospacedDigit()
                    Text(instruction).font(.title3.weight(.semibold)).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            if let light, let lightNote {
                HStack(spacing: 8) {
                    WalkLight(light: light, size: 22)
                    Text(lightNote)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let then {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(then)
                    Spacer(minLength: 8)
                    if let thenDistance { Text(thenDistance).monospacedDigit() }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The train car by car, its back on the left, the third to board in its line's colour.
struct CarDiagram: View {
    let route: String
    let part: Platform.TrainPart
    var height: CGFloat = 16

    /// 11 on the 7, 8 on the J, L, M and Z, 10 on the others.
    private var cars: Int {
        switch Lines.normalized(route) {
        case "7": 11
        case "J", "L", "M", "Z": 8
        default: 10
        }
    }

    private func lit(_ car: Int) -> Bool {
        let third = Double(car) / Double(cars) * 3
        switch part {
        case .back: return third < 1
        case .middle: return third >= 1 && third < 2
        case .front: return third >= 2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(0 ..< cars, id: \.self) { car in
                    let end: CGFloat = height / 2
                    UnevenRoundedRectangle(cornerRadii: .init(
                        topLeading: car == 0 ? end : 3, bottomLeading: car == 0 ? end : 3,
                        bottomTrailing: car == cars - 1 ? end : 3, topTrailing: car == cars - 1 ? end : 3))
                        .fill(lit(car) ? AnyShapeStyle(LineStyle.of(route).swiftUIColor) : AnyShapeStyle(.quaternary))
                        .frame(height: height)
                }
            }
            HStack {
                Text("Back")
                Spacer()
                Label("Front", systemImage: "arrow.right")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Board near the \(part.rawValue) of the train")
    }
}

// MARK: Previews

/// Park Slope to The Town Hall on the R: 7 St, left down 4 Av to the stairs at 9 St; up at Times
/// Sq-42 St, north on Broadway, right on W 43 St.
@MainActor
private func previewSession(_ stage: WalkSession.Stage, fasterFrom other: String? = nil,
                            changing: Bool = false) -> WalkSession? {
    let selection = Selection(stationID: "R33", routes: ["R"], direction: .north)
    guard let destination = StationDirectory.station(id: "R16") else { return nil }
    let start = CLLocation(latitude: 40.6725, longitude: -73.9840)
    let end = CLLocation(latitude: 40.7559, longitude: -73.9846)
    // Or the R to DeKalb Av, and the Q from there
    let change = changing ? Change(stationID: "R30", routes: ["Q"], direction: .north) : nil
    guard let boarding = StationWays.boarding(selection, from: start),
          let leaving = StationWays.leaving(selection, change: change, at: destination, toward: end) else { return nil }
    // As Apple Maps gives them: each step's instruction is at the end of its path
    let corner = Walk.Point(lat: 40.6725, lon: -73.9880)
    let entrance = Walk.Point(lat: boarding.entrance.lat, lon: boarding.entrance.lon)
    var down = boarding.down
    down.meters = 230
    down.points = [corner, entrance]
    let toTrain = Walk(steps: [
        Walk.Step(turn: .left, instruction: "Take a left onto 4th Ave", meters: 340,
                  points: [Walk.Point(start.coordinate), corner]),
        down,
    ], seconds: 420, meters: 570)
    let exit = Walk.Point(lat: leaving.entrance.lat, lon: leaving.entrance.lon)
    let broadway = Walk.Point(lat: 40.7563, lon: -73.9862)
    let fromTrain = Walk(steps: [
        leaving.up,
        Walk.Step(turn: .right, instruction: "Take a right onto W 43rd St", meters: 80, points: [exit, broadway]),
        Walk.Step(turn: .arrive, instruction: "Arrive at The Town Hall", meters: 120,
                  points: [broadway, Walk.Point(end.coordinate)]),
    ], seconds: 180, meters: 200)
    let trip = TripPlanner.Trip(selection: selection, change: change, destination: destination)
    let walks = WalkingDirections.TripWalks(boarding: boarding, toTrain: toTrain, leaving: leaving, fromTrain: fromTrain)
    let trains = [6, 14].map {
        Arrival(route: "R", time: .now.addingTimeInterval(Double($0) * 60), stop: "R33N", lastStop: "G08", isLive: true)
    }
    let onward = changing ? [4, 11].map {
        Arrival(route: "Q", time: .now.addingTimeInterval(Double($0) * 60), stop: "R30N", lastStop: "Q05", isLive: true)
    } : []
    // The B or Q from 7 Av, say, once the R's late
    let faster = other.flatMap(StationDirectory.station(id:)).map { station in
        WalkSession.Faster(trip: TripPlanner.Trip(selection: Selection(stationID: station.id, routes: ["B", "Q"], direction: .north),
                                                  change: nil, destination: destination),
                           minutesSooner: 6, arrives: .now.addingTimeInterval(31 * 60))
    }
    return WalkSession(trip: trip, walks: walks, endName: "The Town Hall", end: end, stage: stage, trains: trains,
                       onwardTrains: onward, faster: faster)
}

#Preview("Walking to the train") {
    if let session = previewSession(.toTrain) { WalkingView(session: session) {} }
}

#Preview("At the station") {
    if let session = previewSession(.atStation) { WalkingView(session: session) {} }
}

#Preview("On the train") {
    if let session = previewSession(.riding) { WalkingView(session: session) {} }
}

#Preview("At the change") {
    if let session = previewSession(.changing, changing: true) { WalkingView(session: session) {} }
}

#Preview("Walking out") {
    if let session = previewSession(.fromTrain) { WalkingView(session: session) {} }
}

#Preview("A faster trip") {
    if let session = previewSession(.toTrain, fasterFrom: "D25") { WalkingView(session: session) {} }
}

#Preview("Signs on the map") {
    // The turn's and the stairs', as they stand on the map walking (map tiles don't draw here)
    let selection = Selection(stationID: "R33", routes: ["R"], direction: .north)
    VStack(spacing: 40) {
        TurnSign(icon: "arrow.turn.up.left", label: "4th Ave")
        TurnSign(icon: "arrow.turn.up.right", label: nil)
        if let way = StationWays.boarding(selection, from: CLLocation(latitude: 40.6725, longitude: -73.9840)) {
            TurnSign(label: way.sideName) {
                WalkingView.entrance(way, label: "Entrance")
            }
        }
    }
    .padding(40)
    .background(Color(white: 0.9))
}

#Preview("Crossings") {
    // A crossing's own step, at a light and at none on a wide street; a turn with one after
    // it; and the street signs' tags
    ScrollView {
        VStack(spacing: 16) {
            TurnCard(icon: Walk.Turn.cross.systemImage, distance: "40 m", instruction: "Cross 4th Ave", isCrossing: true,
                     light: .leading, lightNote: nil,
                     then: "Then take a left onto 9th St", thenDistance: "120 m")
            TurnCard(icon: Walk.Turn.cross.systemImage, distance: "60 m", instruction: "Cross Queens Blvd", isCrossing: true,
                     light: .unsignalledWide, lightNote: Walk.Light.unsignalledWide.note, then: nil)
            TurnCard(icon: Walk.Turn.left.systemImage, distance: "90 m", instruction: "Take a left onto 37th Rd",
                     light: .unsignalledWide, lightNote: "Then cross 75th St · \(Walk.Light.unsignalledWide.note ?? "")",
                     then: "Then take a right onto 77th St", thenDistance: "150 m")
            HStack(alignment: .bottom, spacing: 8) {
                StreetSign(name: "4th Ave", light: .leading)
                StreetSign(name: "Broadway", light: .exclusive)
                StreetSign(name: "9th St", light: .signal)
            }
            HStack(alignment: .bottom, spacing: 8) {
                StreetSign(name: "Prospect Pl", light: .unsignalled)
                StreetSign(name: "Queens Blvd", light: .unsignalledWide)
            }
        }
        .padding(.vertical, 20)
    }
    .background(Color(white: 0.9))
}
