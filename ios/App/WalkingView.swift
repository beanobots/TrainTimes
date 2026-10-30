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
    @State private var turn = MapTurn.heading
    @State private var compass = CompassHeading()
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
    /// Where the train you're on is, while you're on it (`WalkSession.ride`).
    @State private var trainPlace: RideTracker.Place?

    /// Seconds between moving the train along.
    private static let trainTick: Double = 3
    /// Metres up the map is while following the train: a few stations either side.
    private static let rideDistance: Double = 4_000
    /// Metres up the map is as the walk starts: a block or two around you.
    private static let startDistance: Double = 450
    /// Degrees the map's tipped back while walking, as a sat nav: the street ahead, not overhead.
    private static let walkPitch: Double = 55
    /// How far ahead of you the map's centre is while walking, as a share of its distance up,
    /// so you're low on the screen with the way ahead above you, but clear of the bottom card.
    private static let walkLead: Double = 0.1
    /// Metres along the way left to look for which way it runs: past GPS's wobble, short of the
    /// next corner, so the map turns as you turn it, not before.
    private static let routeAhead: Double = 8
    /// Seconds between turning and moving the map while following.
    private static let followTick: Double = 0.25
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
            .overlay(alignment: .top) {
                topCard
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            }
            .overlay(alignment: .bottom) {
                // Countdowns tick over
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    bottomCard(now: context.date)
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
            } else if !isRiding, let location = session.location {
                // You walking, as the train's shown on the ride, facing the way the compass says
                Annotation("", coordinate: location.coordinate, anchor: .center) {
                    walker
                        .accessibilityLabel("You")
                }
            } else if !isRiding {
                // Until the walk's first fix, MapKit's own
                UserAnnotation()
            }
            if session.walk != nil {
                // What's left of it, from where you are
                let left = session.pathLeft.map(\.coordinate)
                MapPolyline(coordinates: left)
                    .stroke(Self.casing, style: StrokeStyle(lineWidth: Self.walkWidth + 4, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: left)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Self.walkWidth, lineCap: .round, lineJoin: .round))
            }
            if session.stage == .toTrain || session.stage == .atStation, let boarding = session.walks?.boarding {
                Annotation("", coordinate: boarding.location.coordinate) {
                    entrance(boarding, label: "Entrance")
                }
            }
            if session.stage == .fromTrain || session.stage == .arrived {
                // The way out of the station, unless walking all the way
                if let leaving = session.walks?.leaving {
                    Annotation("", coordinate: leaving.location.coordinate) {
                        entrance(leaving, label: "Exit")
                    }
                }
                Marker(session.endName, coordinate: session.end.coordinate)
            }
        }
        // Buildings standing up, as it's tipped back while walking
        .mapStyle(.standard(elevation: .realistic))
        // Its own buttons, not MapKit's: its compass only turns it north
        .mapControls {}
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                if !isRiding {
                    MapUserLocationButton(scope: mapScope)
                }
                turnButton
            }
            .padding(.trailing, 12)
            .padding(.top, 8)
        }
        .mapScope(mapScope)
        .onAppear { compass.start() }
        .onDisappear { compass.stop() }
        // Following you: turned a little at a time, so a phone glanced at as you walk doesn't
        // swing the map about
        .task {
            while !Task.isCancelled {
                // Walking a route, the way it runs, so the street you're on is up the screen
                // and its turns are left and right on it; the compass otherwise
                if let heading = routeHeading ?? compass.heading {
                    shownHeading = shownHeading.map {
                        MapHeading.smoothed($0, toward: heading, over: Self.followTick, turning: &turning)
                    } ?? heading
                }
                // Any fix, however old: standing still, none come. Off the train there's none
                // until the next (`WalkSession.location`), not the station you got on at
                if following, !gesturing, !isRiding, let location = session.location {
                    follow(location.coordinate, distance: walkDistance, over: Self.followTick)
                }
                try? await Task.sleep(for: .seconds(Self.followTick))
            }
        }
        // The train moved along every few seconds, the map following it unless moved by hand
        .task(id: session.ride.map(ObjectIdentifier.init)) {
            guard let ride = session.ride else {
                trainPlace = nil
                return
            }
            while !Task.isCancelled {
                if let place = ride.place() {
                    withAnimation(.linear(duration: Self.trainTick)) { trainPlace = place }
                    if following, !gesturing { follow(place.coordinate, distance: rideZoom, over: Self.trainTick) }
                }
                try? await Task.sleep(for: .seconds(Self.trainTick))
            }
        }
        // Being moved by hand: left to the fingers, not pulled back mid-pinch
        .onMapCameraChange(frequency: .continuous) {
            if camera.positionedByUser { gesturing = true }
        }
        // Moved by hand: zoomed, still on you, it keeps following at that zoom; moved off you,
        // it stops until the location or compass button
        .onMapCameraChange(frequency: .onEnd) { context in
            gesturing = false
            guard camera.positionedByUser else { return }
            let on = isRiding ? trainPlace?.coordinate : session.location?.coordinate
            guard let on else {
                following = false
                return
            }
            // Against where following would put the centre, ahead of you while walking
            let shown = context.camera.centerCoordinate
            let wanted = center(on: on, distance: context.camera.distance)
            let across = context.region.span.latitudeDelta * 111_000
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
        // The location button
        .onChange(of: camera.followsUserLocation) { _, follows in
            if follows { following = true }
        }
        // On and off the train: following it, then you
        .onChange(of: isRiding) {
            following = true
        }
    }

    private var isRiding: Bool { session.stage == .riding || session.stage == .ridingOn }

    /// Degrees from north the way left to walk runs from where you are, while walking it.
    private var routeHeading: Double? {
        guard session.stage == .toTrain || session.stage == .fromTrain else { return nil }
        let path = session.pathLeft.map { CLLocation(latitude: $0.lat, longitude: $0.lon) }
        guard let start = path.first else { return nil }
        // The first point far enough along to say which way, or the end if it's nearer
        guard let ahead = path.dropFirst().first(where: { $0.distance(from: start) >= Self.routeAhead })
                ?? path.last, ahead.distance(from: start) > 1 else { return nil }
        let from = start.coordinate, to = ahead.coordinate
        let north = to.latitude - from.latitude
        let east = (to.longitude - from.longitude) * cos(from.latitude * .pi / 180)
        return (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Which way up the map is, as `turn` has it.
    private var heading: Double {
        switch turn {
        case .heading: shownHeading ?? 0
        case .north: 0
        case .manhattan: MapTurn.manhattanNorth
        }
    }

    /// The map on `coordinate`, `distance` up, turned to `heading`; animated over `seconds`
    /// unless it's barely moved. Walking, it's tipped back with you low on it; riding, overhead.
    private func follow(_ coordinate: CLLocationCoordinate2D, distance: Double, over seconds: Double) {
        let center = center(on: coordinate, distance: distance)
        let next = MapCamera(centerCoordinate: center, distance: distance, heading: heading,
                             pitch: isRiding ? 0 : Self.walkPitch)
        if let now = camera.camera, !camera.positionedByUser,
           CLLocation(latitude: now.centerCoordinate.latitude, longitude: now.centerCoordinate.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude)) < 0.5,
           abs(now.heading - next.heading) < 0.5, abs(now.distance - distance) < 1,
           abs(now.pitch - next.pitch) < 0.5 { return }
        withAnimation(.linear(duration: seconds)) { camera = .camera(next) }
    }

    /// Where the map's centre goes to follow `coordinate`: ahead of it the way the map's turned
    /// while walking a route, so it's low on the screen with the way ahead; on it otherwise (on
    /// the train, or at the station, whose taller card would cover you low on the screen).
    private func center(on coordinate: CLLocationCoordinate2D, distance: Double) -> CLLocationCoordinate2D {
        guard session.stage == .toTrain || session.stage == .fromTrain else { return coordinate }
        let meters = distance * Self.walkLead
        let angle = heading * .pi / 180
        return CLLocationCoordinate2D(
            latitude: coordinate.latitude + meters * cos(angle) / 111_000,
            longitude: coordinate.longitude + meters * sin(angle) / (111_000 * cos(coordinate.latitude * .pi / 180)))
    }

    /// The compass button: your heading, north up, NY North, round again. Following you (or the
    /// train) again too, if the map's been moved off.
    private var turnButton: some View {
        Button {
            turn = turn.next
            following = true
        } label: {
            Group {
                switch turn {
                case .heading:
                    // Pointing north as the map's turned
                    Image(systemName: "location.north.line.fill")
                        .rotationEffect(.degrees(-heading))
                        .foregroundStyle(.red)
                case .north:
                    Text("N")
                        .font(.system(size: 17, weight: .bold))
                case .manhattan:
                    VStack(spacing: -2) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                        Text("NY")
                            .font(.system(size: 12, weight: .heavy))
                    }
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Map direction")
        .accessibilityValue(turn.label)
        .accessibilityHint("Changes which way up the map is")
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
            Image(systemName: "figure.walk")
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
    private func entrance(_ way: StationWays.Way, label: String) -> some View {
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
                         distance: up ? "Now" : Walk.distance(session.progress?.toTurn ?? step.meters),
                         instruction: step.instruction,
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
                if let next {
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
            Spacer(minLength: 0)
            endButton
        }
    }

    /// "You'll be on the platform in 4 · 2 min to spare", or the train you'll miss.
    @ViewBuilder private func spare(for train: Arrival, now: Date) -> some View {
        let ready = session.onPlatform(now: now)
        let spare = Int(train.leaves.timeIntervalSince(ready) / 60)
        if let missed = session.missed(now: now).first {
            Text("You'll miss the \(missed.leaves.formatted(date: .omitted, time: .shortened)) · next \(train.leaves.formatted(date: .omitted, time: .shortened))")
                .font(.footnote).foregroundStyle(.orange)
        } else if session.stage == .toTrain || (session.stage == .changing && ready > now) {
            Text("On the platform in \(Self.minutes(until: ready, now: now)) · \(spare) min to spare")
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
            Image(systemName: "figure.walk").foregroundStyle(.tint).frame(width: 20)
            Text("Then a \(Self.minutes(seconds: session.walks?.fromTrain.seconds ?? 0)) walk to \(session.endName)")
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

/// The next turn, big, over the top of the map.
private struct TurnCard: View {
    let icon: String
    let distance: String
    let instruction: String
    let then: String?
    var thenDistance: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(distance).font(.title.weight(.bold)).monospacedDigit()
                    Text(instruction).font(.title3.weight(.semibold)).lineLimit(3)
                }
                Spacer(minLength: 0)
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
