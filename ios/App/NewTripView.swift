import ContactsUI
import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

/// One end of a New Trip: where you are, a station, or a place found on the map.
struct TripPlace: Hashable, Identifiable, Codable {
    var name: String
    var detail: String?
    /// Nil for where you are, which is looked up when the trip's planned.
    var point: Point?

    struct Point: Hashable, Codable {
        var latitude: Double
        var longitude: Double
    }

    var id: String { point.map { "\($0.latitude),\($0.longitude)" } ?? "here" }
    var isHere: Bool { point == nil }
    var location: CLLocation? { point.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) } }

    static let here = TripPlace(name: "Current Location", point: nil)

    init(name: String, detail: String? = nil, point: Point?) {
        self.name = name
        self.detail = detail
        self.point = point
    }

    init(station: Station) {
        self.init(name: station.name, detail: station.borough,
                  point: Point(latitude: station.lat, longitude: station.lon))
    }
}

/// New Trip's picked trip, for its Show on Widget button.
@MainActor
@Observable
final class TripShowing {
    /// The picked trip, once there are trips.
    var option: ServerRoutes.Choice? {
        didSet {
            if option != oldValue { shown = nil }
        }
    }

    /// A train trip's trains the other way too, beside them (a Spotlight station's Both).
    var bothWays = false {
        didSet {
            if bothWays != oldValue { shown = nil }
        }
    }

    /// The picked trip once it's sent to the widget, until another's picked.
    private(set) var shown: ServerRoutes.Choice?

    /// Shows the picked trip on the Transit Directions widget for an hour: a train trip as a
    /// shared trip, a trip with a bus as a bus trip (`SharedBusTrip`).
    func show() {
        guard let option else { return }
        switch option {
        case .train(let train):
            SharedTrip(option: train, app: nil, shared: .now, bothWays: bothWays ? true : nil).show()
        case .bus(let trip):
            SharedBusTrip(trip: trip, shared: .now).show()
        case .walk:
            // The widget shows trains and buses; there's nothing to show of a walk
            return
        case .bike(let trip):
            // Its train, if it has one; nothing of a ride all the way
            guard let train = trip.train else { return }
            SharedTrip(option: train, app: nil, shared: .now, bothWays: bothWays ? true : nil).show()
        }
        shown = option
    }
}

/// Sends the picked trip to the Transit Directions widget: a glass capsule, grey until there's a
/// trip.
struct ShowOnWidgetButton: View {
    let showing: TripShowing

    private static let height: CGFloat = 56

    var body: some View {
        Button {
            showing.show()
        } label: {
            Label(showing.shown == nil ? "Show on Widget" : "Showing on Widget",
                  systemImage: showing.shown == nil ? "rectangle.on.rectangle" : "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(showing.option == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        .disabled(showing.option == nil)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// The New Trip tab: pick where from and where to, then the trips between them, Google's (through
/// the push server's `GET /routes`) and the app's own, as the Share sheet works them out from maps
/// directions. Go shows the one picked on the Transit Directions widget for an hour, as a shared
/// trip does (`SharedTrip.show()`).
///
/// The map fills the screen, From and To over its bottom above the tab bar, Home and Work over
/// them, From starting at where you are. A tap on either opens its search field at the top of the
/// screen, Home and Work under it until you type, then the places to pick; once planned they shrink to a line atop the trips, which
/// a tap opens again, and New Trip and Go take the tab bar's place under them.
struct NewTripView: View {
    /// The picked trip, which Go shows on the widget.
    let showing: TripShowing

    private enum End {
        case from, to
    }

    private enum PlanState: Equatable {
        case waiting
        case planning
        case ready
        case failed(title: String, message: String, fix: Fix)
    }

    /// What a failed plan offers: trying again, Settings to turn on Location Services, or
    /// nothing, fading after `fadeAfter` back to From and To to change the trip (No Trip Found).
    private enum Fix: Equatable {
        case retry, settings, fades
    }

    /// How long No Trip Found shows before fading back to From and To.
    private static let fadeAfter: Duration = .seconds(1.5)

    /// No Trip Found showing over the map, to fade (`Fix.fades`).
    private var fading: Bool {
        guard collapsed, case .failed(_, _, .fades) = state else { return false }
        return true
    }

    @State private var from: TripPlace? = .here
    @State private var to: TripPlace?
    /// The end being picked, its search field open at the top.
    @State private var picking: End?
    @State private var search = ""
    /// Where the cursor is in `search`, for the number row to type there (`numberRow`).
    @State private var searchSelection: TextSelection?
    /// Bumped by Return in the search field, for the list to pick its first result.
    @State private var submits = 0
    @FocusState private var searchFocused: Bool
    /// Where you are: the one `tripLocation`, not a new one each time the view's made again.
    @State private var location = NewTripView.tripLocation
    /// Made once, the first time New Trip is: a `@State`'s first value is made each time the
    /// view is, and those thrown away each had a location manager.
    private static let tripLocation = NearbyLocation()
    @State private var state = PlanState.waiting
    @State private var options: [ServerRoutes.Choice] = []
    @State private var picked = 0
    /// Each option's minutes door to door by the timetable; nil where it can't time one.
    @State private var minutes: [Int?] = []
    /// The train trips behind `options` (nil for one with a bus), for timing one again, and when
    /// they were planned for.
    @State private var trips: [TripPlanner.Trip?] = []
    @State private var plannedAt = Date.now
    /// For each option whose change is at more than one station, by its index: every station it
    /// can change at, those it does switched on, then others it could (`TripPlanner.otherChanges`).
    @State private var changeStations: [Int: [ChangeStation]] = [:]
    /// Whether the picked trip's change stations are open in the card, the other trips hidden.
    @State private var stationsOpen = false
    /// What the trips shown were planned for, so coming back to the tab keeps them.
    @State private var plannedKey: PlanKey?
    /// Where the trips were planned from and to, for the map.
    @State private var ends: (start: CLLocation, end: CLLocation)?
    /// The map before there are trips: around you, or the city until you're found.
    @State private var startPosition = MapCameraPosition.userLocation(fallback: .region(Self.cityRegion))
    /// The start map's size and safe area, to frame it turned NY North.
    @State private var startRoom = MapRoom()
    /// Where the start map last came to rest, for a new one to begin there (`holdStart`).
    @State private var startCamera: MapCamera?
    /// Started over with no fresh fix (`startOver`): the start map frames you once you're found.
    @State private var framesNextFix = false
    @AppStorage(MapNorth.key) private var nyNorth = false
    /// The lines round From on the map before there are trips (`findLines`), a count of each new
    /// set, and the map's height and map points a point is, as Nearby's.
    @State private var lines = NearbyLines.none
    @State private var linesVersion = 0
    @State private var mapHeight: CGFloat = 0
    @State private var mapPointsPerPoint: Double = 0
    @State private var linesCache = NearbyLinesLayer.Cache()
    private static let cityRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.73, longitude: -73.97),
                                                       latitudinalMeters: 8_000, longitudinalMeters: 8_000)
    /// Keeps the map before there are trips on the city, rather than out to the continent while
    /// it waits on your location or the trips.
    private static let cityBounds = MapCameraBounds(
        centerCoordinateBounds: MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.70, longitude: -73.95),
                                                   span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.6)),
        maximumDistance: 60_000)

    /// The picked trip's row: a faint tint in light mode, a stronger one in dark, where a faint
    /// one reads darker than the other rows.
    private static let pickedBackground = Color(UIColor { traits in
        UIColor.tintColor.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.28 : 0.08)
    })

    /// What a new plan waits on: both ends, your location if an end is where you are, and
    /// how you'll go (`TripModes`).
    private struct PlanKey: Equatable {
        var from: TripPlace?
        var to: TripPlace?
        var buses: Bool
        var subway: Bool
        var walkMinutes: Int
        var walkAll: Bool
        var bike: String
        var located: Bool
        var locateFailed: Bool
        var status: CLAuthorizationStatus
        var attempt: Int
        /// Bumped as you're found far from where the trips were planned from (`relocate`).
        var moved: Int
    }

    private var planKey: PlanKey {
        // Where you are only for an end that's there: trips between two places aren't planned
        // again, the picked one lost, as you're found
        let here = from?.isHere == true || to?.isHere == true
        return PlanKey(from: from, to: to, buses: settings.settings.includesBuses, subway: subway,
                       walkMinutes: walkMinutes, walkAll: walkAll,
                       bike: biking ? "\(bikeKinds.rawValue) \(ownBike.rawValue) \(bikeCarry.rawValue)" : "", located: here && location.location != nil,
                       locateFailed: here && location.failed, status: here ? location.status : .notDetermined,
                       attempt: attempt, moved: moved)
    }

    /// How you'll go, remembered: by subway, walking all the way, and how far you'll walk to and
    /// from a ride (minutes, one of `walkChoices`, picked in Settings). By bus is Settings'
    /// Include buses.
    @AppStorage(Self.subwayKey) private var subway = true
    @AppStorage(Self.walkAllKey) private var walkAll = true
    @AppStorage(Self.walkMinutesKey) private var walkMinutes = Self.defaultWalkMinutes

    private static let subwayKey = "tripSubway"
    private static let walkAllKey = "tripWalk"
    /// Where `walkMinutes` is kept, and what it is until picked, for Settings and first-run setup.
    static let walkMinutesKey = "tripWalkMinutes"
    static let defaultWalkMinutes = 15
    /// By Citi Bike too, on the bikes Settings picks. It was a menu, its kind's raw value kept
    /// in `BikeKinds.oldTripKey` or empty for off.
    @AppStorage(Self.bikeKey) private var bikeOn = !(UserDefaults.standard.string(forKey: BikeKinds.oldTripKey) ?? "").isEmpty
    @AppStorage(BikeKinds.key) private var bikeKinds = BikeKinds.saved
    /// Your own bike, ridden in place of a Citi Bike, and what it does with a train (Settings).
    @AppStorage(OwnBike.key) private var ownBike = OwnBike.none
    @AppStorage(BikeCarry.key) private var bikeCarry = BikeCarry.all
    @AppStorage(BikeKinds.offKey) private var citiBikeOff = false

    /// Whether Settings has any bike to ride: your own, or a Citi Bike. With none, there's no
    /// bike toggle and no bike trips.
    private var hasBike: Bool { ownBike != .none || !citiBikeOff }
    /// Whether trips are planned with a bike: the toggle's on, and there's one to ride.
    private var biking: Bool { bikeOn && hasBike }

    /// Where `bikeOn` is kept, for first-run setup.
    static let bikeKey = "tripCitiBike"

    private var bike: BikeKinds? { biking ? bikeKinds : nil }

    /// Whether any way to go is on: with none, Plan Trip is greyed and there's nothing to plan.
    private var hasMode: Bool { subway || settings.settings.includesBuses || biking || walkAll }

    /// How far you'll walk to and from a ride, as offered on Settings' slider: its minutes, the
    /// walk's miles at 20 minutes a mile, and meters as the crow flies a station (stop, dock) may
    /// be, as far as a walk the app times at those minutes (`reach`): a walk shown is never longer
    /// than the one picked. 15 to 45 minutes in fives, then No Limit (`noLimitMinutes`), which is
    /// what older versions' "60+" was saved as, and looks as far as the planner did then.
    static let walkChoices: [(minutes: Int, miles: String, meters: Double)] = {
        let walks: [(minutes: Int, miles: String)] = [
            (15, "¾ mi"), (20, "1 mi"), (25, "1¼ mi"), (30, "1½ mi"), (35, "1¾ mi"), (40, "2 mi"), (45, "2¼ mi"),
        ]
        let limited = walks.map { (minutes: $0.minutes, miles: $0.miles, meters: reach($0.minutes)) }
        return limited + [(minutes: noLimitMinutes, miles: "3½ mi", meters: noLimitReach)]
    }()

    /// The last choice, No Limit: walks to and from a ride as far as the planner looks
    /// (`noLimitReach`), and walking all the way however long.
    static let noLimitMinutes = 60

    /// Meters as the crow flies No Limit looks for a ride from each end: 3 miles, a walk of about
    /// 72 min (`noLimitWalk`).
    private static let noLimitReach: Double = 4_828

    /// Meters as the crow flies a walk of `minutes` reaches, as the app times walks
    /// (`TripPlanner.walkSeconds`): 1,000 for 15 min.
    private static func reach(_ minutes: Int) -> Double {
        Double(minutes) * 60 / TripPlanner.walkSeconds(1)
    }

    /// Minutes the longest walk to or from a ride is with No Limit, as shown.
    static let noLimitWalk = TripPlanner.walkMinutes(noLimitReach)

    /// A walk choice as shown: "15 min", the last "No Limit".
    static func walkLabel(_ minutes: Int) -> String {
        minutes == noLimitMinutes ? "No Limit" : "\(minutes) min"
    }

    /// The longest walk to or from a ride with walk choice `minutes`, as said: "15 min", or for
    /// No Limit, as far as it looks (`noLimitWalk`).
    static func longestWalkLabel(_ minutes: Int) -> String {
        "\(minutes == noLimitMinutes ? noLimitWalk : minutes) min"
    }

    /// "your 30 min walk", or with No Limit just "your walk".
    static func yourWalk(_ minutes: Int) -> String {
        minutes == noLimitMinutes ? "your walk" : "your \(minutes) min walk"
    }

    /// `walkMinutes`' place in `walkChoices`: the longest no longer than it, so a time saved that
    /// isn't offered now lands on the one below.
    private var walkIndex: Int {
        Self.walkChoices.lastIndex { $0.minutes <= walkMinutes } ?? 0
    }

    private var walkChoice: (minutes: Int, miles: String, meters: Double) { Self.walkChoices[walkIndex] }

    /// Bumped by Try Again, to plan again.
    @State private var attempt = 0
    /// Bumped by `relocate`, to plan again from where you are now.
    @State private var moved = 0
    /// Metres you may be from where trips were planned from, for an end that's where you are,
    /// before they're planned again: past a fix's wobble, a few blocks.
    private static let movedFar: CLLocationDistance = 250
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// On its side: the cards down the left over the map, as Nearby's (`Sideways`).
    @Environment(\.isSideways) private var sideways
    /// On its side, the room down the left for the trips and Go, for the trips to fill.
    @State private var sideRoom: CGFloat = 0
    @Environment(SettingsStore.self) private var settings

    /// The picked trip, once there are trips.
    private var pickedOption: ServerRoutes.Choice? {
        state == .ready && options.indices.contains(picked) ? options[picked] : nil
    }

    /// Whether From and To are shrunk to a line atop the trips, once both are picked.
    @State private var collapsed = false
    /// The tab bar and home indicator's room at the bottom of the screen, under the cards.
    @State private var bottomRoom: CGFloat = 94
    /// The height of what's over the map's bottom above the tab bar: From and To with Home and
    /// Work, or the trips with Go.
    @State private var bottomCardsHeight: CGFloat = 170
    /// Home, Work and places added, for a tap to go there.
    @State private var saved = SavedPlaces.shared
    /// The saved place being set by the end being picked, its place saved once it's picked.
    @State private var setting: SavedPlaces.Slot?
    /// A saved place set to Current Location before you were found, and its name: saved as soon
    /// as you are, rather than not at all.
    @State private var settingHere: (slot: SavedPlaces.Slot, name: String, detail: String?)?
    /// + asking for a new place's name, before its address.
    @State private var namingPlace = false
    /// A visitor's Sightseeing list is open.
    @State private var sightseeing = false
    @State private var newPlaceName = ""
    /// The saved place held down on, asking how to edit it.
    @State private var editingPlace: SavedPlaces.Slot?
    /// The added place being renamed, and its new name as typed.
    @State private var renamingPlace: SavedPlaces.Slot?
    @State private var newName = ""
    /// The trips' height, for the card's, which grows to `tripsHeight` with them.
    @State private var tripsContentHeight: CGFloat = 0
    /// `stationsOpen` as `tripsContentHeight` was last measured, to tell a height that follows them.
    @State private var heightStationsOpen = false
    /// From and To moving between their card and the line atop the trips.
    @Namespace private var endsSpace
    /// The longer walk to and from a ride the trips were planned with, there being none within
    /// yours (`walkChoice`); nil when they're within it.
    @State private var longerWalk: Int?
    /// Said over the walk all the way offered with Walk off, there being no trip the ways picked
    /// and the walk being within yours (`walkChoice`); nil otherwise.
    @State private var walkInstead: String?
    /// Go's walks being asked for.
    @State private var startingWalk = false
    /// Go waiting on its walks, let go (`cancelGo`) if the trip's changed or started over
    /// meanwhile, so an old trip's walk doesn't start over the new one.
    @State private var goTask: Task<Void, Never>?
    /// The picked trip's walks, asked for as it's picked so Go needn't wait on them.
    @State private var walksAhead: WalksAhead?
    /// Apple Maps couldn't give Go its walks.
    @State private var walkFailed = false
    /// Go's walks failed as a station has no entrance listed, not for Apple Maps: trying again
    /// won't help.
    @State private var walkNoEntrance = false

    /// The picked trip, if it's a train trip: Go walks those.
    private var pickedTrip: TripPlanner.Trip? {
        state == .ready && trips.indices.contains(picked) ? trips[picked] : nil
    }

    /// The picked trip, if it's walking all the way: Go walks it too.
    private var pickedWalk: Walk? {
        guard state == .ready, options.indices.contains(picked), case .walk(let walk) = options[picked] else { return nil }
        return walk
    }

    /// The picked trip, if it's with a Citi Bike: Go opens its ride in Apple Maps.
    private var pickedBike: BikeTrip? {
        guard state == .ready, options.indices.contains(picked), case .bike(let trip) = options[picked] else { return nil }
        return trip
    }

    /// Whether Go has a trip to take: by train, walking all the way, or by bike.
    private var canGo: Bool { pickedTrip != nil || pickedWalk != nil || pickedBike != nil }

    /// A trip's walks asked for ahead of Go, from `start`.
    private struct WalksAhead {
        let trip: TripPlanner.Trip
        let start: CLLocation
        let task: Task<WalkingDirections.TripWalks?, Error>
    }

    /// Where Go walks from: where you are now, if From's there and you're found, else where
    /// it was planned from.
    private var goStart: CLLocation? {
        guard let ends else { return nil }
        return from?.isHere == true ? freshHere ?? ends.start : ends.start
    }

    /// The picked trip's walks asked for now, for Go; those asked for before let go.
    private func askWalksAhead() {
        walksAhead?.task.cancel()
        walksAhead = nil
        guard let trip = pickedTrip, let start = goStart, let end = ends?.end else { return }
        walksAhead = WalksAhead(trip: trip, start: start, task: Task {
            try await WalkingDirections.walks(for: trip, from: start, to: end)
        })
    }

    /// Longest walk all the way offered beside the trains, unless it's as quick as they are.
    private static let walkOffered = 30
    /// Metres you may have moved from where a walk all the way was planned from before Go asks
    /// Apple Maps for it again.
    private static let walkMoved: CLLocationDistance = 40

    /// The trips card's most height, the From/To strip included, as Nearby's card.
    static let cardMax: CGFloat = 250
    /// The trips' room under the From/To strip (46) and its divider, the card no taller than `cardMax`.
    private static let tripsHeight: CGFloat = cardMax - 47
    /// From and To moving: slow enough to follow them.
    private static let endsAnimation = Animation.smooth(duration: 0.45)

    private var hasEnds: Bool { from != nil && to != nil }
    /// From and To open over the map's bottom: until both are picked, or once the line or New Trip's tapped.
    private var endsOpen: Bool { picking == nil && !(hasEnds && collapsed) }

    var body: some View {
        NavigationStack {
            Group {
                if picking != nil {
                    pickingPage
                } else if hasEnds {
                    tripPage
                } else {
                    startMap
                    // Its logo and Legal over From and To, clear of the screen's rounded corner;
                    // on its side, past the cards down the left
                    .safeAreaPadding(.bottom, attributionRoom)
                    .safeAreaPadding(.leading, mapLeading)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                    // Its size kept as the keyboard goes (`tripPage`)
                    .ignoresSafeArea(.keyboard)
                }
            }
            .overlay(alignment: sideways ? .bottomLeading : .bottom) {
                if endsOpen {
                    VStack(spacing: 10) {
                        if !hasMode {
                            noModeCallout
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if impreciseHere {
                            impreciseCallout
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        savedChips()
                        VStack(spacing: 0) {
                            endsCard
                            Divider()
                            modesRow
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                        .matchedGeometryEffect(id: "ends", in: endsSpace)
                        .padding(.horizontal, sideways ? 0 : Self.margin)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomCardsHeight = $0 }
                    .frame(width: sideways ? Sideways.width : nil)
                    .padding(.leading, sideways ? Sideways.inset : 0)
                    .padding(.bottom, 8)
                    .animation(.smooth(duration: 0.3), value: hasMode)
                    .animation(.smooth(duration: 0.3), value: impreciseHere)
                }
            }
            // The tab bar's room, but not the keyboard's, which would leave the map no room to
            // frame anything in
            .background {
                Color.clear
                    .ignoresSafeArea(.keyboard)
                    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottom in
                        if picking == nil { bottomRoom = bottom }
                    }
            }
            .background(Color(.systemGroupedBackground))
            // No title or toolbar: the tab says where you are, and swap is in the From and To card.
            // No tab bar while picking, or once planned, where New Trip and Go take its place.
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(endsOpen ? .visible : .hidden, for: .tabBar)
        }
        .onAppear {
            location.start()
            // Back on the tab, where you are now, for trips from or to it
            if hasEnds, from?.isHere == true || to?.isHere == true { location.find() }
        }
        // Back in the app, you may be somewhere else: found again, for an end that's where you are
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, location.isAllowed, from?.isHere == true || to?.isHere == true { location.find() }
        }
        .onChange(of: location.location) { _, here in
            saveHere(here)
            relocate(here)
            // Started over without a fresh fix: the map around you once you're found, unless
            // it's been moved or a trip's begun since
            if framesNextFix, let here, to == nil, ends == nil, picking == nil, !startPosition.positionedByUser {
                framesNextFix = false
                frameStart(on: [here], animated: true)
            }
        }
        // A walk over, you're likely somewhere else: found again, to plan from there if so
        .onChange(of: ActiveWalk.shared.session == nil) { _, ended in
            if ended, hasEnds, from?.isHere == true || to?.isHere == true { location.find() }
        }
        // Ended with End or Done: a clean New Trip from where you are, nothing in To
        .onChange(of: ActiveWalk.shared.endings) { startOver() }
        // Planned once both ends are picked, the fastest drawn on the map behind From and To, and
        // again as what it waits on changes, such as the ways you'll go
        .task(id: hasEnds ? planKey : nil) { await plan() }
        // No Trip Found fades after a moment, back to From and To to change the trip
        .task(id: fading) {
            guard fading else { return }
            try? await Task.sleep(for: Self.fadeAfter)
            guard !Task.isCancelled, fading else { return }
            withAnimation(Self.endsAnimation) { collapsed = false }
        }
        // Its walks routed ahead, for Go
        .onChange(of: pickedTrip, initial: true) { askWalksAhead() }
        // A walk isn't for the widget, nor a ride all the way. Go, still waiting on the trip
        // it was tapped for, let go
        .onChange(of: pickedOption, initial: true) { _, option in
            cancelGo()
            switch option {
            case .walk: showing.option = nil
            case .bike(let trip) where trip.train == nil: showing.option = nil
            default: showing.option = option
            }
        }
        // The dock nearest From, for the Bike menu's counts
        .alert("Couldn't Get Walking Directions", isPresented: $walkFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(walkNoEntrance
                 ? "A station on this trip has no entrance listed, so there's no walk to it."
                 : "Apple Maps couldn't find a walk for this trip. Check your connection and try again.")
        }
    }

    /// Picking an end: its search field at the top, everything under it the places to pick.
    /// Home and Work under the field until you type (Current Location too, for From), then the
    /// stations as chips in their place and the contacts and places below.
    private var pickingPage: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, Self.margin)
                .padding(.top, 8)
                .padding(.bottom, 6)
            if search.isEmpty {
                // Setting Home or Work picks its place; they're not offered as it
                if setting == nil {
                    savedChips(here: picking == .from)
                        .padding(.vertical, 6)
                }
                // Not on its side, where with the keyboard up there's no room for it
                VStack(spacing: 6) {
                    if !sideways {
                        Image(systemName: "magnifyingglass").font(.title2)
                        Text("Search for a station, address, place or person")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TripPlaceList(search: search, submits: submits, pick: pick)
            }
        }
        // Over the keyboard while it's up
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if searchFocused { numberRow }
        }
    }

    /// The end being picked: its name, its search field, and closing it.
    private var searchBar: some View {
        HStack(spacing: 12) {
            Text(picking == .from ? "From" : "To").fontWeight(.semibold)
            TextField(setting.map { "\(saved.name($0)) address" } ?? "Station, address or person",
                      text: $search, selection: $searchSelection)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { submits += 1 }
                // The keyboard opens with the field
                .onAppear { searchFocused = true }
            Button {
                searchFocused = false
                setting = nil
                holdStart()
                withAnimation(Self.endsAnimation) { picking = nil }
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(minHeight: 52)
        .glassEffect(.regular, in: Capsule())
    }

    /// Numbers over the letter keyboard, which has none on its letters, spread across its width,
    /// each typed where the cursor is: most stations are named by their street ("86 St").
    private static let digits: [String] = Array("1234567890").map(String.init)

    private var numberRow: some View {
        HStack(spacing: 0) {
            ForEach(Self.digits, id: \.self) { digit in
                Button { type(digit) } label: {
                    Text(digit)
                        .font(.title3.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 12)
        .glassEffect(.regular.interactive(), in: Capsule())
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Types `text` into the search at the cursor, over anything selected, the cursor after it.
    private func type(_ text: String) {
        var range = search.endIndex..<search.endIndex
        if case .selection(let selected) = searchSelection?.indices,
           selected.lowerBound >= search.startIndex, selected.upperBound <= search.endIndex {
            range = selected
        }
        let offset = search.distance(from: search.startIndex, to: range.lowerBound) + text.count
        search.replaceSubrange(range, with: text)
        searchSelection = TextSelection(insertionPoint: search.index(search.startIndex, offsetBy: offset))
    }

    /// Once From and To are picked: the map the whole screen, and over its bottom the trips with
    /// From and To shrunk to a line over them, and New Trip and Go in the tab bar's place. Opened
    /// again, From and To take the trips' place, the tab bar back under them.
    private var tripPage: some View {
        mapArea
            // The trips framed clear of the status bar, and of the cards and the bar under them;
            // reframed as From and To open and close. Its logo and Legal over the cards.
            .safeAreaPadding(.top, sideways ? Sideways.top : Self.statusBarRoom)
            .safeAreaPadding(.bottom, attributionRoom)
            .safeAreaPadding(.leading, mapLeading)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // The whole screen still while the keyboard's going after picking an end: shrunk
            // by it, the map had no room left to frame the trips in, and zoomed right out,
            // and growing back as it went, MapKit's drawing failed Metal's checks
            .ignoresSafeArea(.keyboard)
            .overlay(alignment: sideways ? .bottomLeading : .bottom) {
                if collapsed {
                    VStack(spacing: 10) {
                        list
                        goBar
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomCardsHeight = $0 }
                    // On its side, down the left, the trips as tall as there's room for
                    .frame(width: sideways ? Sideways.width : nil)
                    .frame(maxHeight: sideways ? .infinity : nil, alignment: .bottom)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sideRoom = $0 }
                    .padding(.leading, sideways ? Sideways.inset : 0)
                    .padding(.top, sideways ? Sideways.top : 0)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }

    /// In the tab bar's place once the trips are planned: New Trip, a tap to start over, and Go
    /// across the rest.
    private var goBar: some View {
        HStack(spacing: 10) {
            Button(action: startOver) {
                Label("New Trip", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: Self.barHeight, height: Self.barHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityHint("Clears this trip to plan another")
            goButton
        }
        .padding(.horizontal, sideways ? 0 : Self.barMargin)
    }

    /// The bar's height, as the tab bar's when it shrinks while scrolling: just its tab, in a circle.
    private static let barHeight: CGFloat = 48
    /// The bar's side margin, as the tab bar's.
    private static let barMargin: CGFloat = 21

    /// Points the map's logo and Legal stand in from the screen's rounded corner.
    private static let attributionInset: CGFloat = 12

    /// The status bar's room over the top of the map.
    private static let statusBarRoom: CGFloat = 70

    /// The trips' height: up to `tripsHeight`, or `openTripsHeight` with the change stations open.
    private var listHeight: CGFloat {
        // On its side, down to Go under them
        let side = sideRoom - Self.barHeight - 10 - (Self.cardMax - Self.tripsHeight)
        let most = sideways && sideRoom > 0 ? max(Self.tripsHeight / 2, side)
            : stationsOpen ? Self.openTripsHeight : Self.tripsHeight
        return min(most, tripsContentHeight)
    }

    /// The map's room on its left: its logo and Legal in from the screen's rounded corner, or on
    /// its side, past the cards down the left.
    private var mapLeading: CGFloat { sideways ? Sideways.mapLeading : Self.attributionInset }

    /// Under the map's logo and Legal: the tab bar and the cards over the map's bottom, so they
    /// show over the cards and the map frames what's left.
    private var attributionRoom: CGFloat { bottomRoom + (sideways ? 0 : bottomCardsHeight) + 12 }

    /// The trips on the map, or how planning's going.
    @ViewBuilder private var mapArea: some View {
        ZStack {
            if state == .ready {
                TripMap(options: options, picked: picked, start: ends?.start.coordinate,
                        end: ends?.end.coordinate, endName: to?.name ?? "")
            } else {
                // The map stays with both ends on it, how planning's going on a card over it
                startMap
                if collapsed {
                    Group {
                        switch state {
                        case .failed(let title, let message, let fix):
                            ContentUnavailableView {
                                Label(title, systemImage: "tram.fill")
                            } description: {
                                Text(message)
                            } actions: {
                                switch fix {
                                case .retry:
                                    Button("Try Again", action: retry)
                                case .settings:
                                    Button("Open Settings") {
                                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                    }
                                case .fades:
                                    EmptyView()
                                }
                            }
                        default:
                            // Full strength: the progress view's own grey is faint on glass
                            ProgressView {
                                Text("Finding your train…").foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(24)
                    .fixedSize(horizontal: false, vertical: true)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                    // On its side, past the cards already, in the map's safe area
                    .padding(.horizontal, sideways ? 16 : 40)
                    .transition(.opacity)
                }
            }
        }
        // A tap on the map shrinks From and To back to a line atop the trips, and closes the change stations
        .simultaneousGesture(TapGesture().onEnded {
            closeStations()
            collapse()
        })
    }

    /// The map before there are trips: you, both ends, and the lines round From (`NearbyLines`).
    private var startMap: some View {
        Map(position: $startPosition, bounds: Self.cityBounds) {
            NearbyLinesLayer(lines: lines, version: linesVersion, mapPointsPerPoint: mapPointsPerPoint, cache: linesCache)
            UserAnnotation()
            endPins
        }
        // Muted, as the trip's map: the standard map's yellow main roads read as N/Q/R/W lines
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .measuresRoom($startRoom)
        .turnsNorth($startPosition)
        // The lines' zoom followed as it moves, a step at a time (`LineScale`)
        .onMapCameraChange(frequency: .continuous) { context in
            guard mapHeight > 0 else { return }
            let scale = LineScale.step(MapNorth.mapPointsPerPoint(context, height: mapHeight), from: mapPointsPerPoint)
            if scale != mapPointsPerPoint { mapPointsPerPoint = scale }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            startCamera = context.camera
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mapHeight = $0 }
        .onChange(of: linesKey, initial: true) { findLines() }
    }

    /// Where the lines are drawn round: From, or you.
    private var linesCenter: CLLocation? { from?.location ?? location.location }

    /// What the lines are for: about where From is, to the nearest 100 m or so, and the ways
    /// you'll go.
    private var linesKey: [Double] {
        guard let center = linesCenter?.coordinate else { return [] }
        return [(center.latitude * 1000).rounded(), (center.longitude * 1000).rounded(),
                subway ? 1 : 0, settings.settings.includesBuses ? 1 : 0]
    }

    /// The lines of the stations nearest From, each its own colour, and of the buses stopping a
    /// few minutes' walk from it, pale; just those of the ways you'll go.
    private func findLines() {
        guard let center = linesCenter else {
            lines = .none
            linesVersion += 1
            return
        }
        let stations = subway ? Nearby.stations(near: center, limit: 3) : []
        let buses = settings.settings.includesBuses
            ? Array(NearbyLines.busLines(near: center.coordinate, within: Self.busLinesReach).prefix(Self.busLinesShown)) : []
        lines = NearbyLines(routes: stations.flatMap(\.station.routes), busLines: buses,
                            around: stations.map { $0.station.coordinate }
                                + [center.coordinate])
        linesVersion += 1
    }

    /// Meters from From a bus line must stop to be drawn, and how many are, nearest first.
    private static let busLinesReach: Double = 400
    private static let busLinesShown = 6

    /// From and To on the map before there are trips, as `TripMap` marks them: To's pin as soon as
    /// it's picked, From's dot unless it's where you are, which the map shows already.
    @MapContentBuilder private var endPins: some MapContent {
        if let start = from?.location {
            Annotation("", coordinate: start.coordinate) {
                Circle().fill(.blue).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(radius: 2)
            }
        }
        if let end = to?.location ?? (to?.isHere == true ? location.location : nil) {
            Marker(to?.name ?? "", systemImage: "mappin", coordinate: end.coordinate)
                .tint(.red)
                .annotationTitles(.hidden)
        }
    }

    /// Clears the trip and its map: From back to where you are, no To, the map around you again.
    private func startOver() {
        cancelGo()
        closeStations()
        withAnimation(Self.endsAnimation) {
            from = .here
            to = nil
            collapsed = false
            state = .waiting
            options = []
            trips = []
            minutes = []
            changeStations = [:]
            picked = 0
            plannedKey = nil
            ends = nil
            // Somewhere to begin for its new map, not following you (`holdStart`): where you
            // are if just found, else the city until you're found again (`framesNextFix`); the
            // last fix can be the trip's start, long ago
            frameStart(on: [freshHere].compactMap { $0 })
            framesNextFix = freshHere == nil
        }
        if framesNextFix { location.find() }
    }

    /// Opens From and To again in the trips' place.
    private func openEnds() {
        cancelGo()
        closeStations()
        withAnimation(Self.endsAnimation) { collapsed = false }
    }

    /// From and To shrunk to a line atop the trips; a tap opens them again.
    private var endsStrip: some View {
        Button(action: openEnds) {
            HStack(spacing: 8) {
                // Where from and where to, marked as on the map
                Image(systemName: from?.isHere == true ? "location.fill" : "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(from?.name ?? "")
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(to?.name ?? "")
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, Self.margin)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From \(from?.name ?? "") to \(to?.name ?? "")")
        .accessibilityHint("Change where from or where to")
        .accessibilityAddTraits(.isButton)
    }

    /// Go: walks the picked train trip turn by turn (`WalkingView`), and shows it on the widget.
    private var goButton: some View {
        Button(action: go) {
            Group {
                if startingWalk {
                    ProgressView()
                } else {
                    HStack(spacing: 10) {
                        goPhases
                        Text("Go")
                    }
                }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: Self.barHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(canGo ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .disabled(!canGo || startingWalk)
        .glassEffect(canGo ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Capsule())
        .accessibilityHint(pickedWalk != nil ? "Walks you to \(to?.name ?? "the end") turn by turn"
                           : "Walks you to the train turn by turn, and from it to \(to?.name ?? "the end")")
    }

    /// Go's icon: the picked trip's phases in order, joined by chevrons. A walk to the train, each
    /// train ridden (two with a change), and a walk from it; just a walk when it's walking all the way.
    private var goPhases: some View {
        let symbols: [String]
        if let bike = pickedBike {
            // The ride before or after its train, if it has one
            let trains = bike.train.map { Array(repeating: "tram.fill", count: $0.change == nil ? 1 : 2) } ?? []
            let rides = bike.bikeFirst ? ["bicycle"] + trains + (bike.rideAfter == nil ? [] : ["bicycle"])
                : trains + ["bicycle"]
            // Your own bike's from your door, and to the end unless it's left at the station
            let walkFrom = bike.owned && bike.bikeFirst ? [] : ["figure.walk"]
            let walkTo = bike.owned && (bike.train == nil || !bike.bikeFirst || bike.rideAfter != nil) ? [] : ["figure.walk"]
            symbols = walkFrom + rides + walkTo
        } else {
            let rides = pickedTrip.map { $0.change == nil ? 1 : 2 } ?? 0
            symbols = ["figure.walk"] + (rides > 0 ? Array(repeating: "tram.fill", count: rides) + ["figure.walk"] : [])
        }
        return HStack(spacing: 3) {
            ForEach(symbols.indices, id: \.self) { index in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.caption.weight(.bold))
                        .opacity(0.6)
                }
                Image(systemName: symbols[index])
            }
        }
        .accessibilityHidden(true)
    }

    /// Shows the picked trip on the widget, asks Apple Maps for its walks from where you are (or
    /// From), and opens them.
    private func go() {
        guard canGo, let ends, let start = goStart else { return }
        if from?.isHere == true, freshHere == nil { location.find() }
        // To's name now: by the time the walks come, To can be cleared or another place
        let endName = to?.name ?? ""
        // Walking all the way: its walk from where you are now, if you've moved since it was
        // planned, else as planned
        if let planned = pickedWalk {
            startingWalk = true
            goTask = Task {
                // Let go, `cancelGo` has already turned it off, maybe for another Go since
                defer { if !Task.isCancelled { startingWalk = false } }
                let moved = start.distance(from: ends.start) > Self.walkMoved
                let walk = moved ? (try? await WalkingDirections.walk(from: start, to: ends.end)) ?? planned : planned
                guard !Task.isCancelled else { return }
                ActiveWalk.shared.begin(WalkSession(walk: walk, endName: endName, end: ends.end))
            }
            return
        }
        // With a bike: its train on the widget, and its ride, dock to dock, in Apple Maps
        if let bike = pickedBike {
            showing.show()
            if let url = Self.cyclingURL(from: bike.pickup, to: bike.dropoff) { openURL(url) }
            return
        }
        guard let trip = pickedTrip else { return }
        showing.show()

        startingWalk = true
        // Those asked for as the trip was picked, done or under way, unless you've moved since
        let ahead = walksAhead.flatMap { $0.trip == trip && $0.start.distance(from: start) <= Self.walkMoved ? $0.task : nil }
        goTask = Task {
            defer { if !Task.isCancelled { startingWalk = false } }
            let walks: WalkingDirections.TripWalks
            do {
                let found = if let ahead, let walks = try? await ahead.value { walks }
                    else { try await WalkingDirections.walks(for: trip, from: start, to: ends.end) }
                // Let go meanwhile: no walk, and no alert for one that wasn't wanted
                guard !Task.isCancelled else { return }
                guard let found else {
                    walkNoEntrance = true
                    walkFailed = true
                    return
                }
                walks = found
            } catch {
                guard !Task.isCancelled else { return }
                walkNoEntrance = false
                walkFailed = true
                return
            }
            // Over the whole app (`AppTabs`), carried on if iOS closes it
            ActiveWalk.shared.begin(WalkSession(trip: trip, walks: walks, endName: endName, end: ends.end))
        }
    }

    /// Lets go of Go's walks still being asked for, for a trip changed or started over, and
    /// lights Go again for the new one.
    private func cancelGo() {
        goTask?.cancel()
        goTask = nil
        startingWalk = false
    }

    /// Apple Maps' cycling directions from one dock to another.
    private static func cyclingURL(from pickup: CitiBike.Dock, to dropoff: CitiBike.Dock) -> URL? {
        guard var components = URLComponents(string: "https://maps.apple.com/directions") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "source", value: String(format: "%.6f,%.6f", pickup.lat, pickup.lon)),
            URLQueryItem(name: "destination", value: String(format: "%.6f,%.6f", dropoff.lat, dropoff.lon)),
            URLQueryItem(name: "mode", value: "cycling"),
        ]
        return components.url
    }

    /// The trips once planned, best first, the picked one tinted, From and To over them: a card
    /// over the map above New Trip and Go, as tall as the trips up to `tripsHeight`, scrolling
    /// within it. A scroll view rather than a List, whose rows scroll out past the card's rounded
    /// corners. A tap on the picked trip, where it can change at more than one station, opens
    /// those stations under it in place of the other trips, each a switch, the card taller to fit them.
    private var list: some View {
        VStack(spacing: 0) {
            endsStrip
                .matchedGeometryEffect(id: "ends", in: endsSpace)
            if state == .ready {
                Divider()
            }
            tripRows
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .padding(.horizontal, sideways ? 0 : Self.margin)
    }

    /// The trips in `list`, scrolling within it.
    private var tripRows: some View {
        ScrollView {
            VStack(spacing: 0) {
                if state == .ready {
                    // With the picked trip's stations open, all but it roll up, and its stations
                    // unroll under it (`Unroll`); everything stays laid out so both move smoothly
                    if let note = walkInstead ?? longerWalk.map({
                        "No trip within \(Self.yourWalk(walkChoice.minutes)). These walk up to \(Self.longestWalkLabel($0))."
                    }) {
                        VStack(spacing: 0) {
                            Label(note, systemImage: "figure.walk")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Self.margin)
                                .padding(.vertical, 8)
                            Divider()
                        }
                        .modifier(Unroll(shown: !stationsOpen))
                    }
                    ForEach(options.indices, id: \.self) { index in
                        if index > 0 {
                            // Under the text, past the bullets
                            Divider().padding(.leading, Self.margin + 64)
                                .modifier(Unroll(shown: !stationsOpen))
                        }
                        Button {
                            if index == picked, changeStations[index] != nil || dockChoices(index) != nil {
                                withAnimation(Self.stationsAnimation) { stationsOpen.toggle() }
                            } else {
                                picked = index
                            }
                        } label: {
                            Group {
                                switch options[index] {
                                case .train(let option):
                                    TripOptionRow(option: option, picked: index == picked,
                                                  minutes: minutes.indices.contains(index) ? minutes[index] : nil,
                                                  checksPicked: false, describesChange: true,
                                                  stationsOpen: changeStations[index] == nil ? nil
                                                      : index == picked && stationsOpen)
                                case .bus(let trip):
                                    BusTripRow(trip: trip, picked: index == picked,
                                               minutes: minutes.indices.contains(index) ? minutes[index] : nil)
                                case .walk(let walk):
                                    WalkTripRow(walk: walk, endName: to?.name ?? "",
                                                minutes: minutes.indices.contains(index) ? minutes[index] : nil,
                                                picked: index == picked)
                                case .bike(let trip):
                                    BikeTripRow(trip: trip, picked: index == picked,
                                                docksOpen: trip.dockChoices.isEmpty ? nil : index == picked && stationsOpen)
                                }
                            }
                                .padding(.horizontal, Self.margin)
                                .padding(.vertical, 11)
                                .frame(minHeight: 44)
                                .background(index == picked ? Self.pickedBackground : .clear)
                        }
                        .buttonStyle(.plain)
                        .modifier(Unroll(shown: !stationsOpen || index == picked))
                    }
                    VStack(spacing: 0) {
                        changeStationList
                        dockChoiceList
                    }
                    .modifier(Unroll(shown: stationsOpen))
                }
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            // Measured after the stations open or close, so the card grows or shrinks with them
            if heightStationsOpen != stationsOpen {
                heightStationsOpen = stationsOpen
                withAnimation(Self.stationsAnimation) { tripsContentHeight = height }
            } else {
                tripsContentHeight = height
            }
        }
        .frame(height: listHeight)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The picked trip's change stations, under it: each station with the lines there and how
    /// it's changed to, a switch for whether the trip changes there.
    @ViewBuilder private var changeStationList: some View {
        if let stations = changeStations[picked], case .train(let option) = options[picked] {
            let onCount = stations.filter(\.on).count
            VStack(spacing: 0) {
                ForEach(stations.indices, id: \.self) { index in
                    if index > 0 {
                        Divider().padding(.leading, Self.margin)
                    }
                    let station = stations[index]
                    Toggle(isOn: Binding(get: { station.on }, set: { setChangeStation(index, on: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.change.station?.name ?? "")
                                .font(.subheadline)
                            ChangeKindLabel(change: station.change, selection: option.selection)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Always somewhere to change
                    .disabled(station.on && onCount == 1)
                    // The card's full width, for long names and how each's changed to
                    .padding(.leading, Self.margin)
                    .padding(.trailing, Self.margin)
                    .padding(.vertical, 8)
                }
            }
            .background(Self.pickedBackground)
        }
    }

    /// The bike trip at `index`'s docks to switch between (`BikeTrip.dockChoices`); nil for
    /// another trip, or one without.
    private func dockChoices(_ index: Int) -> [BikeTrip]? {
        guard options.indices.contains(index), case .bike(let trip) = options[index], !trip.dockChoices.isEmpty
        else { return nil }
        return trip.dockChoices
    }

    /// The picked bike trip's docks, under it, as `changeStationList` has a change's stations: a
    /// pick-one list headed by what's picked ("Take a bike from"), each the dock it rides from or
    /// to, its counts and walk, and the trip's minutes; a checkmark on the one it takes.
    @ViewBuilder private var dockChoiceList: some View {
        if let choices = dockChoices(picked), case .bike(let trip) = options[picked] {
            let pickups = Set(choices.map(\.pickup.id)).count > 1
            let dropoffs = Set(choices.map(\.dropoff.id)).count > 1
            VStack(alignment: .leading, spacing: 0) {
                Text(pickups && dropoffs ? "Docks" : pickups ? "Take a bike from" : "Leave it at")
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Self.margin)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                ForEach(choices.indices, id: \.self) { index in
                    if index > 0 {
                        Divider().padding(.leading, Self.margin)
                    }
                    let choice = choices[index]
                    let on = choice.sameDocks(as: trip)
                    Button {
                        setDockChoice(index)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text([pickups ? choice.pickup.name : nil, dropoffs ? choice.dropoff.name : nil]
                                    .compactMap { $0 }.joined(separator: " → "))
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                HStack(spacing: 4) {
                                    BikeDocksLabel(trip: choice)
                                    // The walk to or from the one dock that differs
                                    if pickups != dropoffs, let walk = dockWalk(choice, pickup: pickups) {
                                        Text("· \(walk) min walk")
                                    }
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text("\(choice.minutes) min")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                                .opacity(on ? 1 : 0)
                        }
                        .padding(.horizontal, Self.margin)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .background(Self.pickedBackground)
        }
    }

    /// Minutes' walk to `trip`'s pickup (or from its dropoff, with `pickup` false): from where it
    /// starts, or the station it's ridden from; to where it ends, or the station ridden to.
    private func dockWalk(_ trip: BikeTrip, pickup: Bool) -> Int? {
        let place: CLLocation?
        if pickup {
            place = trip.train == nil || trip.bikeFirst ? ends?.start : trip.train?.endStation.map(\.location)
        } else {
            place = trip.train == nil || !trip.bikeFirst ? ends?.end : trip.train?.selection.station.map(\.location)
        }
        guard let place else { return nil }
        let dock = pickup ? trip.pickup.location : trip.dropoff.location
        return TripPlanner.walkMinutes(place.distance(from: dock))
    }

    /// Switches the picked bike trip to its dock choice `index`: its minutes, the map and Go follow.
    private func setDockChoice(_ index: Int) {
        guard let choices = dockChoices(picked), choices.indices.contains(index) else { return }
        var trip = choices[index]
        trip.dockChoices = choices
        options[picked] = .bike(trip)
        minutes[picked] = trip.minutes
    }

    /// The trips' room with the picked trip's change stations open: taller, to fit them.
    private static let openTripsHeight: CGFloat = 420
    /// The change stations opening and closing.
    private static let stationsAnimation = Animation.smooth(duration: 0.3)

    /// The page's side margin, the list's and the cards' above it alike.
    private static let margin: CGFloat = 16
    private static let cornerRadius: CGFloat = 26

    /// From and To, each a tap to pick, and swapping them.
    private var endsCard: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                endRow("From", end: .from, place: from)
                Divider().padding(.leading, Self.margin)
                endRow("To", end: .to, place: to)
            }
            Button {
                swap(&from, &to)
            } label: {
                Label("Swap From and To", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(from == nil && to == nil)
            .padding(.trailing, Self.margin)
        }
    }

    private func endRow(_ title: String, end: End, place: TripPlace?) -> some View {
        Button {
            search = ""
            setting = nil
            withAnimation(Self.endsAnimation) { picking = end }
        } label: {
            HStack(spacing: 12) {
                Text(title)
                Spacer()
                if let place {
                    Label {
                        Text(place.name).foregroundStyle(.secondary)
                    } icon: {
                        if place.isHere { Image(systemName: "location.fill").foregroundStyle(.tint) }
                    }
                    .labelStyle(PlaceLabelStyle(showsIcon: place.isHere))
                    .lineLimit(1)
                } else {
                    Text(end == .from ? "Choose start" : "Choose destination")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Self.margin)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// How you'll go, one row: Subway, Bus, Citi Bike and Walk each a toggle, and Plan Trip as a
    /// round arrow at the end. Citi Bike rides the bikes Settings picks (`BikeKinds`); Walk
    /// offers walking all the way where it's worth it, and how far you'll walk to and from a
    /// ride is in Settings too. A long press on a toggle picks only that way.
    private var modesRow: some View {
        HStack(spacing: 8) {
            modeToggle("Subway", "tram.fill", on: $subway, hint: "Offers trips by subway")
            modeToggle("Bus", "bus.fill", on: Bindable(settings).settings.includesBuses, hint: "Offers trips by bus")
            // Your own bike in place of Citi Bike's, if Settings has one; none with every bike off
            if hasBike {
                modeToggle(ownBike == .none ? "Citi Bike" : "My Bike", "bicycle", on: $bikeOn,
                           hint: ownBike == .none ? "Offers trips with a Citi Bike" : "Offers trips on your own bike",
                           eBike: ownBike == .none ? bikeKinds == .eBike : ownBike == .eBike)
            }
            modeToggle("Walk", "figure.walk", on: $walkAll, hint: "Offers walking all the way")
            Spacer(minLength: 0)
            planTripButton
        }
        .padding(.leading, Self.margin)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .sensoryFeedback(.selection, trigger: onlyPicked)
    }

    /// Turns every way to go off but `on`, for a long press on it.
    private func pickOnly(_ on: Binding<Bool>) {
        subway = false
        settings.settings.includesBuses = false
        bikeOn = false
        walkAll = false
        on.wrappedValue = true
        onlyPicked += 1
    }

    /// Bumped by `pickOnly`, for its tap of feedback.
    @State private var onlyPicked = 0
    /// Set as a long press picks only one way, so letting go doesn't toggle it back off.
    @State private var heldMode = false

    /// A way to go, an icon tinted while it's on, a bolt badge on it for e-bikes only; a long
    /// press on it picks only it.
    private func modeToggle(_ name: String, _ symbol: String, on: Binding<Bool>, hint: String,
                            eBike: Bool = false) -> some View {
        Button {
            guard !heldMode else {
                heldMode = false
                return
            }
            on.wrappedValue.toggle()
        } label: {
            Label(name, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on.wrappedValue ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 48, height: 38)
                .background(on.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .eBikeBadge(eBike)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture().onEnded { _ in
            heldMode = true
            pickOnly(on)
        })
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
        .accessibilityHint(hint)
        .accessibilityAction(named: "Only \(name)") { pickOnly(on) }
    }

    /// Shrinks From and To to a line atop the trips, planned for them the ways picked as soon as
    /// both were. Greyed until both are, and while every way to go is off.
    private var planTripButton: some View {
        let canPlan = hasEnds && hasMode
        return Button {
            closeStations()
            // After No Trip Found, planned again: back online, or the timetable caught up
            if case .failed = state { retry() }
            withAnimation(Self.endsAnimation) { collapsed = true }
        } label: {
            Label("Plan Trip", systemImage: "arrow.right")
                .labelStyle(.iconOnly)
                .font(.body.weight(.bold))
                .foregroundStyle(canPlan ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 44, height: 44)
                .background(canPlan ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlan)
    }

    /// Over From and To while every way to go is off, gone as soon as one's back on.
    private var noModeCallout: some View {
        Label("Select a mode of transportation to continue", systemImage: "hand.tap.fill")
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, Self.margin)
    }

    /// An end is where you are, but Leeway may only know it to a few miles.
    private var impreciseHere: Bool {
        location.isAllowed && !location.isPrecise && (from?.isHere == true || to?.isHere == true)
    }

    /// Over From and To while an end is where you are and Precise Location is off.
    private var impreciseCallout: some View {
        Label("Precise Location is off", systemImage: "location.slash.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, Self.margin)
    }

    /// Sets the end being picked, then moves From and To back down, or to a line atop the trips once both
    /// are picked.
    private func pick(_ place: TripPlace) {
        guard let end = picking else { return }
        var place = place
        // Setting Home or Work: saved, where you are by where you're found
        if let slot = setting {
            let point = place.point ?? freshHere.map {
                TripPlace.Point(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            }
            if let point {
                let slot = saved.set(slot, to: TripPlace(name: place.name, detail: place.detail, point: point))
                place = saved.place(slot) ?? place
            } else {
                // Not found yet (or not allowed): saved once you are (`saveHere`)
                settingHere = (slot, place.name, place.detail)
                location.find()
            }
            setting = nil
        }
        if end == .from { from = place } else { to = place }
        frameEnds()
        // Where you are is looked up (asking permission the first time) once it's needed
        if hasEnds, from?.isHere == true || to?.isHere == true { location.find() }
        searchFocused = false
        withAnimation(Self.endsAnimation) { picking = nil }
    }

    /// Home, Work and places added as glass chips, a tap to go there (or from there, while From's
    /// picked); one not set yet asks for its place. Held down, it can be changed, renamed (one
    /// added) or forgotten. + after
    /// them adds another, asking its name and then its place. They scroll once past the screen.
    /// With `here`, where you are first.
    private func savedChips(here: Bool = false) -> some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if here { hereChip }
                    ForEach(saved.slots, id: \.self) { slot in
                        savedChip(slot)
                    }
                    addPlaceChip
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, Self.margin, for: .scrollContent)
        .sheet(isPresented: $sightseeing) {
            SightseeingList { place in use(place) }
        }
        .alert("New Place", isPresented: $namingPlace) {
            TextField("Name", text: $newPlaceName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Next") {
                let name = newPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { setSaved(.new(name)) }
            }
        } message: {
            Text("Name it, then pick where it is.")
        }
        .alert("Rename Place", isPresented: Binding(get: { renamingPlace != nil },
                                                    set: { if !$0 { renamingPlace = nil } })) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let slot = renamingPlace, !name.isEmpty { saved.rename(slot, to: name) }
            }
        }
    }

    /// Where you are, for From.
    private var hereChip: some View {
        Button {
            pick(.here)
        } label: {
            Label("Current Location", systemImage: "location.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private var addPlaceChip: some View {
        Button {
            newPlaceName = ""
            namingPlace = true
        } label: {
            Label("Add Place", systemImage: "plus")
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
    }

    private func savedChip(_ slot: SavedPlaces.Slot) -> some View {
        let place = saved.place(slot)
        let name = saved.name(slot)
        // Gestures rather than a Button with a context menu: the glass chip's button took a long
        // press as a tap, so the menu never showed
        return Label(name, systemImage: saved.symbol(slot))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(place == nil && slot != .sightseeing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .onTapGesture { useSaved(slot) }
            .onLongPressGesture { editSaved(slot) }
            .sensoryFeedback(.impact, trigger: editingPlace) { _, new in new == slot }
            // On each chip, so its popover points at the one held down
            .confirmationDialog(name, isPresented: Binding(get: { editingPlace == slot },
                                                           set: { if !$0 { editingPlace = nil } }),
                                titleVisibility: .visible) {
                Button("Change Address") { setSaved(slot) }
                if case .added = slot {
                    Button("Rename") {
                        newName = name
                        renamingPlace = slot
                    }
                }
                Button("Forget \(name)", role: .destructive) { saved.set(slot, to: nil) }
            } message: {
                if let detail = place?.detail { Text(detail) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { useSaved(slot) }
            .accessibilityAction(named: "Edit") { editSaved(slot) }
        .accessibilityHint(slot == .sightseeing ? "Choose a sight to go to"
                           : place == nil ? "Sets your \(name.lowercased()) address" : "")
    }

    /// Goes to a saved place, or from it while From's picked; asks for its place if it's not set.
    /// Sightseeing asks which sight.
    private func useSaved(_ slot: SavedPlaces.Slot) {
        if slot == .sightseeing {
            sightseeing = true
            return
        }
        guard let place = saved.place(slot) else {
            setSaved(slot)
            return
        }
        use(place)
    }

    /// Goes to `place`, or from it while From's picked.
    private func use(_ place: TripPlace) {
        guard picking == nil else {
            pick(place)
            return
        }
        to = place
        frameEnds()
        if hasEnds, from?.isHere == true { location.find() }
    }

    /// Frames the map on From and To once both are picked, before Plan Trip. Their page's map is a
    /// new one: left following you, it began at MapKit's own view of the country, held to the
    /// city's bounds at their far corner (Perth Amboy) until it found you. Just From picked, the
    /// map's made anew too: framed on From if it's a place, else held where it was (`holdStart`).
    private func frameEnds() {
        guard hasEnds else {
            if let start = from?.location { frameStart(on: [start]) } else { holdStart() }
            return
        }
        frameStart(on: [from?.location ?? location.location, to?.location ?? location.location].compactMap { $0 })
    }

    /// Gives the start map, about to be made anew (picking an end replaces it), somewhere to
    /// begin. Following you or moved by hand, its position says nowhere, and a new map began at
    /// MapKit's view of the country, held to the city's bounds at their far corner: Perth Amboy.
    private func holdStart() {
        guard startPosition.followsUserLocation || startPosition.positionedByUser else { return }
        if let startCamera {
            startPosition = .camera(startCamera)
        } else {
            frameStart(on: [location.location].compactMap { $0 })
        }
    }

    /// Held down: asks how to edit a saved place that's set; one not set asks for its place.
    private func editSaved(_ slot: SavedPlaces.Slot) {
        guard slot != .sightseeing else { return }
        if saved.place(slot) == nil {
            setSaved(slot)
        } else {
            editingPlace = slot
        }
    }

    /// Asks for a saved place's place: the end being picked's search field, or To's.
    private func setSaved(_ slot: SavedPlaces.Slot) {
        search = ""
        setting = slot
        if picking == nil {
            withAnimation(Self.endsAnimation) { picking = .to }
        }
    }

    /// Shrinks From and To, open over the map, back to a line atop the trips.
    /// Only once the trips for them are planned.
    private func collapse() {
        guard hasEnds, !collapsed, picking == nil, planKey == plannedKey, state == .ready else { return }
        withAnimation(Self.endsAnimation) { collapsed = true }
    }

    /// Plans again from `here` if an end is where you are and it's `movedFar` from where the
    /// trips were planned from: picking Current Location again, or back on the tab, elsewhere.
    /// The saved place waiting to be set to where you are (`settingHere`), now you're found.
    private func saveHere(_ here: CLLocation?) {
        guard let here, let pending = settingHere else { return }
        settingHere = nil
        let point = TripPlace.Point(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude)
        _ = saved.set(pending.slot, to: TripPlace(name: pending.name, detail: pending.detail, point: point))
    }

    /// Where you are, if found in the last `freshFor`: an older fix can be a ride away, from
    /// before the app was last in the background.
    private var freshHere: CLLocation? {
        guard let here = location.location, -here.timestamp.timeIntervalSinceNow < Self.freshFor else { return nil }
        return here
    }

    private static let freshFor: TimeInterval = 120

    private func relocate(_ here: CLLocation?) {
        guard let here, let ends else { return }
        let planned = from?.isHere == true ? ends.start : to?.isHere == true ? ends.end : nil
        guard let planned, here.distance(from: planned) > Self.movedFar else { return }
        moved += 1
    }

    /// Plans again after a failure, looking you up again first where an end is where you are.
    private func retry() {
        if from?.isHere == true || to?.isHere == true { location.find() }
        attempt += 1
    }

    /// Works out the trips between the ends, once both are picked (and you're found, for an end
    /// that's where you are).
    private func plan() async {
        // Once both ends are picked; back on the tab, the trips planned stay, with the one picked
        guard hasEnds, planKey != plannedKey || state != .ready else { return }
        options = []
        minutes = []
        trips = []
        changeStations = [:]
        stationsOpen = false
        picked = 0
        ends = nil
        longerWalk = nil
        walkInstead = nil
        // Every way to go off: nothing to plan, Plan Trip greyed and a word over From and To
        guard let from, let to, hasMode else {
            state = .waiting
            return
        }
        if from.isHere || to.isHere {
            guard location.isAllowed || location.status == .notDetermined else {
                state = .failed(title: "Location Is Off",
                                message: "Turn on Location Services for Leeway, or pick a station or address.",
                                fix: .settings)
                return
            }
            if location.failed {
                state = .failed(title: "Couldn't Find You", message: "Try again, or pick a station or address.",
                                fix: .retry)
                return
            }
        }
        guard let start = from.location ?? location.location, let end = to.location ?? location.location else {
            // Waits for your location; this runs again once it's found
            state = .planning
            frameStart(on: [from.location, to.location].compactMap { $0 })
            return
        }
        frameStart(on: [start, end])
        // From and To a few steps apart: no trip, rather than a 0 m walk of a minute
        guard start.distance(from: end) >= Self.samePlace else {
            state = .failed(title: "Same Place", message: "From and To are the same place.", fix: .fades)
            return
        }
        state = .planning
        // The timetable read in now, off the main thread, while the server plans: the first
        // time, it's a big file to unpack, which held the trips up as they came in
        Task.detached(priority: .userInitiated) { _ = TimetableStore.load() }
        let buses = settings.settings.includesBuses
        let subway = self.subway
        let walkRange = walkChoice.meters
        // Walking all the way, asked of Apple Maps while the trains are planned, and Citi Bike's trips
        let noLimit = walkChoice.minutes == Self.noLimitMinutes
        // Not waited on where it can't be offered (below): a walk across town takes seconds to route
        let walking = Task { await Self.walkAll(walkAll, noLimit: noLimit, from: start, to: end) }
        defer { walking.cancel() }
        async let biking = Self.bikeTrips(bike, own: biking ? ownBike.kind : nil, carry: bikeCarry, endName: to.name,
                                          from: start, to: end, subway: subway, walkRange: walkRange)
        // Google's routes, asked for once: each walk tried below picks from the same ones. Nil
        // if the server couldn't be reached, and whether it refused as over its daily limit
        let fetched: (routes: [ServerRoutes.Route]?, overLimit: Bool) = buses || subway
            ? await ServerRoutes.fetchRoutes(from: start, to: end, buses: buses, subway: subway) : ([], false)
        let routes = fetched.routes
        guard !Task.isCancelled else { return }
        var rides = await Self.rides(routes, buses: buses, subway: subway, from: start, to: end, walkRange: walkRange)
        guard !Task.isCancelled else { return }
        let biked = await biking
        let bikeTrips = biked.trips
        // Walking all the way now only if there's nothing else; else once the trips' minutes
        // say whether it could be offered beside them
        var walkedAll: (walk: Walk?, tooLong: Int?, trouble: MapsTrouble?) = (nil, nil, nil)
        let nothingElse = rides.planned.isEmpty && bikeTrips.isEmpty
        if nothingElse { walkedAll = await walking.value }
        var walk = walkedAll.walk
        guard !Task.isCancelled else { return }
        // Walk off, and no ride within your walk to and from it nor any bike trip: walking all
        // the way, where it's no longer than your walk, rather than a ride with a longer one
        var walkedInstead = false
        if !walkAll, rides.planned.isEmpty, bikeTrips.isEmpty,
           let found = await Self.walkAll(true, noLimit: noLimit, from: start, to: end).walk,
           noLimit || WalkTripRow.minutes(of: found) <= walkChoice.minutes {
            guard !Task.isCancelled else { return }
            walk = found
            walkedInstead = true
        }
        // A walk instead cut short comes back nil, as if there were none: superseded, this plan
        // mustn't put No Trip Found over the new one's planning
        guard !Task.isCancelled else { return }
        // No ride within your walk to and from it, nor any bike trip, nor a walk instead: the
        // trips of the shortest longer walk offered that has some, rather than none at all
        var walked = walkChoice.minutes
        if rides.planned.isEmpty, bikeTrips.isEmpty, !walkedInstead, buses || subway {
            // In fifteens, as many tries as before the slider's fives
            for choice in Self.walkChoices where choice.meters > walkRange && choice.minutes % 15 == 0 {
                rides = await Self.rides(routes, buses: buses, subway: subway, from: start, to: end,
                                         walkRange: choice.meters)
                guard !Task.isCancelled else { return }
                walked = choice.minutes
                if !rides.planned.isEmpty { break }
            }
        }
        let planned = rides.planned
        guard !planned.isEmpty || walk != nil || !bikeTrips.isEmpty else {
            state = noTripFound(from: start, to: end, buses: buses, subway: subway, none: rides.none, walked: walked,
                                offline: buses && routes == nil, overLimit: buses && fetched.overLimit,
                                walkTooLong: walkedAll.tooLong, walkTrouble: walkedAll.trouble, noBike: biked.none)
            return
        }
        // Trips with a bus aren't in the timetable: estimated by Google's times for the bus
        // (`BusTrip.arrival`). Read once for them all, and timed, off the main thread: the first
        // read unpacks a big file, which hitched New Trip as the trips came in. As
        // `minutes(of:by:)`, from these ends at this time
        let choices = planned.map(\.choice)
        let rideTrips = planned.map(\.trip)
        let at = Date.now
        let (timetable, timed) = await Task.detached(priority: .userInitiated) { () -> (Timetable?, [Int?]) in
            let timetable = TimetableStore.load(now: at)
            let timed = choices.indices.map { index -> Int? in
                if case .bus(let trip) = choices[index] {
                    return trip.minutes(from: start, to: end, at: at, timetable: timetable)
                }
                guard let trip = rideTrips[index], let timetable,
                      let arrival = TripPlanner.arrival(of: trip, from: start, to: end, at: at, timetable: timetable)
                else { return nil }
                return Int(arrival.timeIntervalSince(at) / 60)
            }
            return (timetable, timed)
        }.value
        // Set only now, after the wait, so a plan superseded meanwhile leaves the new one's be
        guard !Task.isCancelled else { return }
        options = choices
        trips = rideTrips
        plannedAt = at
        ends = (start, end)
        minutes = timed

        for (index, trip) in trips.enumerated() {
            guard let trip, let change = trip.change,
                  Set(change.stops.compactMap { $0.station?.complex }).count > 1 else { continue }
            let all = change.stops.map { ChangeStation(change: $0, on: true) }
                + TripPlanner.otherChanges(for: trip).map { ChangeStation(change: $0, on: false) }
            let kept = withoutNeedlessWalks(all, for: trip, by: timetable)
            // Stations to pick from only while there's more than one
            changeStations[index] = Set(kept.compactMap { $0.change.station?.complex }).count > 1 ? kept : nil
            // Changing only where it's still offered
            guard kept.filter(\.on).count < all.filter(\.on).count,
                  let fewer = Change(stops: kept.filter(\.on).map(\.change))?.validated(for: trip.selection),
                  case .train(var option) = options[index] else { continue }
            var changed = trip
            changed.change = fewer
            trips[index] = changed
            option.change = fewer
            options[index] = .train(option)
            minutes[index] = minutes(of: changed, by: timetable)
        }
        // Walking all the way, waited on unless even the straight line's too long to offer
        // beside the trips: over `walkOffered` and slower than the fastest
        if !nothingElse, walkAll {
            let soonest = Self.soonestWalk(from: start, to: end)
            let fastestTrip = minutes.compactMap { $0 }.min()
            if soonest <= Self.walkOffered || fastestTrip.map({ soonest <= $0 }) ?? true {
                walk = await walking.value.walk
                guard !Task.isCancelled else { return }
            }
        }
        // Walking all the way, if it's not far, as quick as the trains, or all there is
        let walkAllMinutes = walk.map(WalkTripRow.minutes(of:))
        if let walk, let walkMinutes = walkAllMinutes {
            dropTrips(slowerThan: walkMinutes)
            let fastest = minutes.compactMap { $0 }.min()
            if walkedInstead || walkMinutes <= Self.walkOffered || fastest.map({ walkMinutes <= $0 }) ?? true {
                options.append(.walk(walk))
                trips.append(nil)
                minutes.append(walkMinutes)
            }
        }
        // With a bike: to or from a train where it beats every trip without one, and riding all
        // the way; all the way where it's not long or beats them too. None slower than walking
        // all the way.
        let fastest = minutes.compactMap { $0 }.min()
        let soonestRide = bikeTrips.filter { $0.train == nil }.map(\.minutes).min()
        for trip in bikeTrips where walkAllMinutes.map({ trip.minutes < $0 }) ?? true {
            let beats = fastest.map { trip.minutes < $0 } ?? true
            guard trip.train == nil || soonestRide.map({ trip.minutes < $0 }) ?? true,
                  beats || (trip.train == nil && trip.minutes <= Self.rideOffered) else { continue }
            options.append(.bike(trip))
            trips.append(nil)
            minutes.append(trip.minutes)
        }
        sortByMinutes()
        // Said over the trips while a ride's among them that walks past your choice
        let riding = options.contains { if case .walk = $0 { false } else { true } }
        longerWalk = walked > walkChoice.minutes && riding ? walked : nil
        if walkedInstead {
            let by = Self.orList((subway ? ["subway"] : []) + (buses ? ["bus"] : []) + (self.biking ? ["bike"] : []))
            walkInstead = by.isEmpty ? nil
                : "No \(by) trip found. Walking there is within \(Self.yourWalk(walkChoice.minutes))."
        }
        plannedKey = planKey
        state = .ready
    }

    /// The rides by subway and bus from `start` to `end` with up to `walkRange` to and from them,
    /// of Google's `routes` (nil if the server couldn't be reached) and the app's own, and where
    /// there are none by subway, why. Off the main thread.
    private nonisolated static func rides(_ routes: [ServerRoutes.Route]?, buses: Bool, subway: Bool,
                                          from start: CLLocation, to end: CLLocation,
                                          walkRange: Double) async -> (planned: [ServerRoutes.Planned],
                                                                       none: TripPlanner.NoTrip?) {
        if buses {
            var planned = ServerRoutes.planWithBuses(routes ?? [], from: start, to: end, walkRange: walkRange)
            guard subway else {
                // By bus only: no train on the way
                planned.removeAll {
                    guard case .bus(let trip) = $0.choice else { return true }
                    return trip.train != nil
                }
                return (planned, nil)
            }
            // Why there's no subway trip either, as the app's planner finds it
            let none = planned.isEmpty ? TripPlanner.planned(from: start, to: end, walkRange: walkRange).none : nil
            return (planned, none)
        }
        guard subway else { return ([], nil) }
        let trains = ServerRoutes.planned(routes ?? [], from: start, to: end, walkRange: walkRange)
        return (trains.trips.map { ServerRoutes.Planned(choice: .train($0.option), trip: $0) }, trains.none)
    }

    /// No Trip Found, saying why: with only Walk on, no walk, or one too long (`walkTooLong`
    /// minutes); by subway, why the planner found none (`none`) with up to a `walked` minutes'
    /// walk, and that there's nothing by bus or bike either, and why not by bike (`noBike`);
    /// and, `offline`, that bus trips need the server, which couldn't be reached, or refused as
    /// over its daily limit (`overLimit`). Where Apple Maps was busy or out of reach for the walk
    /// all the way (`walkTrouble`) or the rides (`NoBike.maps`), that, with Try Again. Where an
    /// end is on Staten Island or at JFK, that the app doesn't plan its ferry, railway or
    /// AirTrain (`unplanned`).
    private func noTripFound(from start: CLLocation, to end: CLLocation, buses: Bool, subway: Bool,
                             none: TripPlanner.NoTrip?, walked: Int, offline: Bool, overLimit: Bool,
                             walkTooLong: Int?, walkTrouble: MapsTrouble?, noBike: BikePlanner.NoBike?) -> PlanState {
        let others = [buses ? "bus" : nil, bike != nil ? "bike" : nil].compactMap { $0 }
        let by = Self.orList((subway ? ["subway"] : []) + others)
        guard !by.isEmpty else {
            if let walkTrouble {
                return .failed(title: "No Trip Found", message: walkTrouble.message, fix: .retry)
            }
            guard let walkTooLong else {
                return .failed(title: "No Trip Found", message: "Leeway couldn't find a walk between these places.", fix: .fades)
            }
            let modes = ["Subway", "Bus"] + (hasBike ? [ownBike == .none ? "Citi Bike" : "My Bike"] : [])
            return .failed(title: "No Trip Found",
                           message: "Walking there takes about \(Self.hoursAndMinutes(walkTooLong)). To see it, set Comfortable Walk "
                               + "to No Limit in Settings, or turn on \(Self.orList(modes)).",
                           fix: .fades)
        }
        let unreachable = overLimit ? "Leeway's bus planner has hit its daily limit."
            : "Bus trips need a connection, and Leeway couldn't reach its server."
        // By bus alone, with no server: nothing to say but that
        if offline, by == "bus" {
            return .failed(title: "Couldn't Get Bus Trips",
                           message: "\(unreachable) \(overLimit ? "Try again later." : "Check your connection and try again.")",
                           fix: .fades)
        }
        let walk = Self.longestWalkLabel(walked)
        let whyNoBike = bike == nil ? nil : noBike.map { noBikeMessage($0) }
        // Apple Maps busy or out of reach: trying again may find one
        let bikeTrouble = if bike != nil, case .maps? = noBike { true } else { false }
        let fix: Fix = walkTrouble != nil || bikeTrouble ? .retry : .fades
        // By bike alone, why, where it's known: the ride, not the walk
        if let whyNoBike, by == "bike" {
            var message = whyNoBike
            if let walkTrouble, walkTrouble.message != whyNoBike { message += " \(walkTrouble.message)" }
            return .failed(title: "No Trip Found", message: message, fix: fix)
        }
        // By subway, why: an end the app can't plan to (Staten Island, JFK), or as the planner
        // found, no station a walk from an end, or none but across the water, or walking's as
        // quick; and that the other ways found none either
        let why = Self.unplanned(from: start, to: end) ?? (subway ? none?.message(walk: walk, walkOn: walkAll) : nil)
        var message = why.map { others.isEmpty ? $0 : "\($0) Leeway couldn't find a \(Self.orList(others)) trip either." }
            ?? "Leeway couldn't find a \(by) trip between these places with up to a \(walk) walk."
        if let whyNoBike { message += " \(whyNoBike)" }
        if let walkTrouble, walkTrouble.message != whyNoBike { message += " \(walkTrouble.message)" }
        if offline { message += " \(unreachable)" }
        return .failed(title: "No Trip Found", message: message, fix: fix)
    }

    /// Why a trip from `start` to `end` may not be found, where an end's somewhere the app
    /// doesn't plan the way to: Staten Island (its ferry and railway), or JFK's terminals (the
    /// AirTrain). Nil elsewhere.
    private static func unplanned(from start: CLLocation, to end: CLLocation) -> String? {
        if [start, end].contains(where: { WalkReach.land(at: $0.coordinate) == .statenIsland }) {
            return "Leeway doesn't plan the Staten Island Ferry or Railway yet."
        }
        let fromJFK = atJFK(start)
        guard fromJFK || atJFK(end) else { return nil }
        return "Leeway doesn't plan the AirTrain yet. Plan \(fromJFK ? "from" : "to") Howard Beach or Jamaica."
    }

    /// Whether `place` is at JFK: its terminals and Federal Circle, the AirTrain's stops short of
    /// Howard Beach and Jamaica.
    private static func atJFK(_ place: CLLocation) -> Bool {
        let lat = place.coordinate.latitude, lon = place.coordinate.longitude
        return (40.636...40.664).contains(lat) && (-73.810 ... -73.768).contains(lon)
    }

    /// Why there's no Citi Bike trip, said: the ride too long (and an e-bike's, if it'd do), or
    /// no dock within your walk.
    private func noBikeMessage(_ noBike: BikePlanner.NoBike) -> String {
        switch noBike {
        case .rideTooLong(let eBikeMinutes?):
            "A classic bike takes over an hour; an e-bike about \(eBikeMinutes) min."
        case .rideTooLong(nil):
            "Riding there takes over an hour."
        case .noDock(let atStart):
            "No Citi Bike dock within \(Self.yourWalk(walkChoice.minutes)) of the \(atStart ? "start has a bike" : "end has room for one")."
        case .maps(let trouble):
            trouble.message
        }
    }

    /// "subway", "subway or bus", "subway, bus or bike".
    private static func orList(_ words: [String]) -> String {
        guard let last = words.last, words.count > 1 else { return words.first ?? "" }
        return "\(words.dropLast().joined(separator: ", ")) or \(last)"
    }

    /// "3 hr 36 min", "2 hr", "45 min".
    private static func hoursAndMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60, left = minutes % 60
        guard hours > 0 else { return "\(left) min" }
        return left == 0 ? "\(hours) hr" : "\(hours) hr \(left) min"
    }

    /// Longest ride all the way offered beside quicker trips.
    private static let rideOffered = 45

    /// Longest walk all the way offered at all, even with nothing else: past it, No Trip Found
    /// rather than an eight-hour walk from Glen Oaks to Times Square. With No Limit, any.
    private static let longestWalk = 120

    /// Meters apart From and To are the same place: no trip planned between them.
    private static let samePlace: Double = 30

    /// Fewest minutes walking all the way from `start` to `end` could take: the straight line,
    /// at a brisker pace than any walk's timed at, as none's shorter.
    private static func soonestWalk(from start: CLLocation, to end: CLLocation) -> Int {
        Int(start.distance(from: end) / briskPace / 60)
    }

    /// Metres a second: quicker than walks are timed at (`WalkCosts.pace`, Apple Maps').
    private static let briskPace = 1.6

    /// Walking all the way, or none with Walk off or past `longestWalk` (unless `noLimit`), then
    /// with its minutes (`tooLong`) for No Trip Found to say; or none as Apple Maps was busy or
    /// out of reach (`trouble`), rather than having no walk.
    private static func walkAll(_ on: Bool, noLimit: Bool, from start: CLLocation,
                                to end: CLLocation) async -> (walk: Walk?, tooLong: Int?, trouble: MapsTrouble?) {
        guard on else { return (nil, nil, nil) }
        let walk: Walk
        do {
            walk = try await WalkingDirections.walk(from: start, to: end)
        } catch {
            return (nil, nil, MapsTrouble(error))
        }
        let minutes = WalkTripRow.minutes(of: walk)
        return noLimit || minutes <= longestWalk ? (walk, nil, nil) : (nil, minutes, nil)
    }

    /// Minutes sooner an e-bike's trip is to be kept over a classic bike's the same way: a
    /// classic costs members nothing more, and there are more of them.
    private static let eBikeSooner = 2

    /// Your own bike's trips if you've one (`own`, `BikePlanner.plannedOwn`), as `carry` says with a
    /// train; else Citi Bike's trips by `kind`, or none with Bike off (`BikePlanner`).
    /// With both kinds, each is planned and one kept of each trip (all the way, or with the same
    /// train before or after): the classic bike's, unless the e-bike's is more than
    /// `eBikeSooner` minutes sooner. Where its e-bikes are few and the classic's bikes aren't
    /// (`CitiBike.few`), by the e-bike's from its fuller dock instead (`dockChoices`), or the
    /// classic's with none: not a sure bike for one that may be gone. Where the classic's are few
    /// and the e-bike's aren't, the e-bike's if it's as soon. With no Citi Bike trip, why
    /// (`BikePlanner.NoBike`), where the kinds agree.
    private static func bikeTrips(_ kinds: BikeKinds?, own: CitiBike.Kind?, carry: BikeCarry, endName: String,
                                  from start: CLLocation, to end: CLLocation,
                                  subway: Bool, walkRange: Double) async -> (trips: [BikeTrip], none: BikePlanner.NoBike?) {
        if let own {
            return await BikePlanner.plannedOwn(from: start, to: end, endName: endName, kind: own, carry: carry,
                                                subway: subway, walkRange: walkRange)
        }
        guard let kinds else { return ([], nil) }
        let planned = await withTaskGroup(of: (trips: [BikeTrip], none: BikePlanner.NoBike?).self) { group in
            for kind in kinds.kinds {
                group.addTask { await BikePlanner.planned(from: start, to: end, kind: kind, subway: subway, walkRange: walkRange) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let found = planned.flatMap(\.trips)
        // Why none, where each kind says the same; both kinds' rides too long, even an e-bike's
        guard !found.isEmpty else {
            let reasons = planned.map(\.none)
            // Apple Maps busy or out of reach for either kind: trying again may find one
            if let maps = reasons.first(where: { if case .maps? = $0 { true } else { false } }) {
                return ([], maps)
            }
            if reasons.count > 1, reasons.allSatisfy({ if case .rideTooLong = $0 { true } else { false } }) {
                return ([], .rideTooLong(eBikeMinutes: nil))
            }
            return ([], Set(reasons).count == 1 ? reasons.first ?? nil : nil)
        }
        guard kinds.kinds.count > 1 else { return (found, nil) }
        var kept: [String: BikeTrip] = [:]
        for trip in found {
            let key = "\(trip.bikeFirst) \(trip.train.map { "\($0)" } ?? "")"
            guard let other = kept[key], other.kind != trip.kind else {
                if kept[key].map({ trip.minutes < $0.minutes }) ?? true { kept[key] = trip }
                continue
            }
            let (eBike, bike) = trip.kind == .eBike ? (trip, other) : (other, trip)
            // The classic's bikes few and the e-bike's not, as soon there: the e-bike's
            if bike.bikes < CitiBike.few, eBike.bikes >= CitiBike.few, eBike.minutes <= bike.minutes {
                kept[key] = eBike
                continue
            }
            let eBikeMinutes = eBike.bikes < CitiBike.few && bike.bikes >= CitiBike.few
                ? eBike.dockChoices.filter { $0.bikes >= CitiBike.few }.map(\.minutes).min()
                : eBike.minutes
            kept[key] = eBikeMinutes.map { $0 < bike.minutes - eBikeSooner } ?? false ? eBike : bike
        }
        return (kept.values.sorted { $0.minutes < $1.minutes }, nil)
    }

    /// Leaves out the trips timed to take longer than walking all the way (`walkMinutes`): a
    /// mile's walk away from where you are to ride one stop back toward it. A trip with a bus by
    /// its estimate; those it can't time stay.
    private func dropTrips(slowerThan walkMinutes: Int) {
        let kept = options.indices.filter { minutes[$0].map { $0 <= walkMinutes } ?? true }
        guard kept.count < options.count else { return }
        options = kept.map { options[$0] }
        trips = kept.map { trips[$0] }
        minutes = kept.map { minutes[$0] }
        changeStations = Dictionary(uniqueKeysWithValues: kept.enumerated().compactMap { slot, index in
            changeStations[index].map { (slot, $0) }
        })
    }

    /// The trips soonest there first, by the minutes each shows: the planner ranks a change as
    /// worse than its minutes, which put a slower trip without one first. A trip with a bus by
    /// its estimate. Trips it can't time keep their places, and those it can fill the others in
    /// order; ties keep theirs.
    private func sortByMinutes() {
        // The timed ones' places, and the timed ones soonest first (a stable sort, so ties keep
        // their order)
        let timed = minutes.indices.filter { minutes[$0] != nil }
        let sorted = timed.enumerated()
            .sorted { (minutes[$0.element] ?? 0, $0.offset) < (minutes[$1.element] ?? 0, $1.offset) }
            .map(\.element)
        var order = Array(options.indices)
        for (slot, index) in zip(timed, sorted) {
            order[slot] = index
        }
        if order != Array(options.indices) {
            options = order.map { options[$0] }
            trips = order.map { trips[$0] }
            minutes = order.map { minutes[$0] }
            changeStations = Dictionary(uniqueKeysWithValues: order.enumerated().compactMap { slot, index in
                changeStations[index].map { (slot, $0) }
            })
        }
    }

    /// Minutes a change across the platform may take to get there over a walk to another
    /// platform for the same lines, and the walk not be offered.
    private static let walkWorth: TimeInterval = 2 * 60

    /// `stations` (more than two of them) without walks to another platform for lines another
    /// of them has across the platform, which gets there no more than `walkWorth` later: not
    /// Atlantic Av-Barclays Ctr's walk to the B or Q, with them across the platform at DeKalb Av.
    /// At least one the trip changes at stays.
    private func withoutNeedlessWalks(_ stations: [ChangeStation], for trip: TripPlanner.Trip,
                                      by timetable: Timetable?) -> [ChangeStation] {
        guard stations.count > 2 else { return stations }
        let selection = trip.selection
        // When it gets there changing at just one of them
        func arrival(_ station: ChangeStation) -> Date? {
            guard let ends, let timetable,
                  let change = Change(stops: [station.change])?.validated(for: selection) else { return nil }
            var only = trip
            only.change = change
            return TripPlanner.arrival(of: only, from: ends.start, to: ends.end, at: plannedAt, timetable: timetable)
        }
        // Each timed once, as each is compared with several
        var timed: [Int: Date?] = [:]
        func timedArrival(_ index: Int) -> Date? {
            if let known = timed[index] { return known }
            let found = arrival(stations[index])
            timed[index] = found
            return found
        }
        var kept: [ChangeStation] = []
        for (index, station) in stations.enumerated() {
            let walks = station.change.routes.filter { !station.change.isAcross($0, from: selection) }
            let complex = station.change.station?.complex
            let across = walks.isEmpty ? [] : stations.indices.filter { other in
                stations[other].change.station?.complex != complex
                    && walks.allSatisfy { stations[other].change.routes.contains($0)
                        && stations[other].change.isAcross($0, from: selection) }
            }
            // Left out only if one across is known to get there no more than `walkWorth` later;
            // untimed (no timetable yet), it stays
            guard !across.isEmpty, let walking = timedArrival(index),
                  let soonest = across.compactMap(timedArrival).min(),
                  soonest.timeIntervalSince(walking) <= Self.walkWorth
            else {
                kept.append(station)
                continue
            }
        }
        if !kept.contains(where: \.on), let first = stations.first(where: \.on) {
            kept.insert(first, at: 0)
        }
        return kept
    }

    /// Frames the map while trips are found on `places` (From and To, as far as they're known), or
    /// on the city without them, rather than wherever the map was, which can be the continent.
    /// Animated only for a map already showing (`animated`): most callers make the map anew, and a
    /// new one animates from MapKit's start, the city bounds' far corner, sweeping past Bayonne.
    private func frameStart(on places: [CLLocation], animated: Bool = false) {
        let heading = MapNorth.heading(ny: nyNorth)
        // Called inside other animations too (`startOver`), so they're turned off here unless asked
        var transaction = Transaction(animation: animated ? .smooth : nil)
        transaction.disablesAnimations = !animated
        guard !places.isEmpty else {
            let position = MapNorth.position(fitting: MKMapRect(Self.cityRegion), heading: heading, in: startRoom)
                ?? .region(Self.cityRegion)
            withTransaction(transaction) { startPosition = position }
            return
        }
        var rect = MKMapRect.null
        for place in places {
            rect = rect.union(MKMapRect(origin: MKMapPoint(place.coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        // At least a couple of kilometers across, and a little beyond both
        let least = 2_000 * MKMapPointsPerMeterAtLatitude(places[0].coordinate.latitude)
        let dx = max(rect.width * 0.15, (least - rect.width) / 2, 0)
        let dy = max(rect.height * 0.15, (least - rect.height) / 2, 0)
        let framed = rect.insetBy(dx: -dx, dy: -dy)
        let position = MapNorth.position(fitting: framed, heading: heading, in: startRoom) ?? .rect(framed)
        withTransaction(transaction) { startPosition = position }
    }

    /// `trip`'s minutes door to door by the timetable (`timetable`, if already read), leaving when
    /// the trips were planned; nil without a timetable, or where it can't time it.
    private func minutes(of trip: TripPlanner.Trip, by timetable: Timetable? = nil) -> Int? {
        guard let ends, let timetable = timetable ?? TimetableStore.load(now: plannedAt),
              let arrival = TripPlanner.arrival(of: trip, from: ends.start, to: ends.end, at: plannedAt, timetable: timetable)
        else { return nil }
        return Int(arrival.timeIntervalSince(plannedAt) / 60)
    }

    /// Switches the picked trip's change station `index` on or off, and changes only at those on:
    /// its minutes, the map and what Show on Widget sends follow. The last one on stays on.
    private func setChangeStation(_ index: Int, on: Bool) {
        guard var stations = changeStations[picked], stations.indices.contains(index),
              trips.indices.contains(picked), var trip = trips[picked],
              case .train(var option) = options[picked] else { return }
        stations[index].on = on
        guard let change = Change(stops: stations.filter(\.on).map(\.change))?.validated(for: trip.selection)
        else { return }
        changeStations[picked] = stations
        trip.change = change
        trips[picked] = trip
        option.change = change
        options[picked] = .train(option)
        minutes[picked] = minutes(of: trip)
    }

    /// Closes the picked trip's change stations, back to all the trips.
    private func closeStations() {
        guard stationsOpen else { return }
        withAnimation(Self.stationsAnimation) { stationsOpen = false }
    }
}

/// One of the stations a New Trip trip can change at, and whether it does.
private struct ChangeStation: Hashable {
    var change: Change
    var on: Bool
}

/// One of New Trip's trips with a bus, as `TripOptionRow` draws a train trip: its first ride's
/// badge or bullet, where from and to, the ride after the first, and its minutes, marked as an
/// estimate (`BusTrip.arrival`), as Bus Time isn't asked.
private struct BusTripRow: View {
    let trip: BusTrip
    let picked: Bool
    let minutes: Int?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if trip.busFirst || trip.train == nil {
                    BusBadge(line: trip.bus.line, size: 24)
                } else if let train = trip.train {
                    LineBullets(routes: train.selection.routes, size: 24)
                }
            }
            .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(trip.startName) → \(trip.endName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    HStack(spacing: 4) {
                        if let train = trip.train {
                            if trip.busFirst {
                                Text("Bus to \(train.selection.station?.name ?? trip.bus.to.name), then")
                                LineBullets(routes: train.selection.routes, size: 14)
                            } else {
                                Text("Change at \(train.endStation?.name ?? trip.bus.from.name) to")
                                BusBadge(line: trip.bus.line, size: 14)
                            }
                        } else if let onward = trip.onward {
                            Text("Change at \(trip.bus.to.name) to")
                            BusBadge(line: onward.line, size: 14)
                        } else {
                            Text(trip.bus.headsign.map { "Bus to \($0)" } ?? "Bus")
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if let minutes {
                        Text("~\(minutes) min")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityLabel("About \(minutes) min")
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// Walking all the way: the walker, as the walking map shows you, how far, and how long.
private struct WalkTripRow: View {
    let walk: Walk
    let endName: String
    let minutes: Int?
    let picked: Bool

    /// Apple Maps' minutes for `walk`, rounded up, never under one.
    static func minutes(of walk: Walk) -> Int {
        max(1, Int((walk.seconds / 60).rounded(.up)))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.walk")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.tint))
                .frame(width: 52)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(endName.isEmpty ? "Walk" : "Walk to \(endName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("\(Walk.distance(walk.meters)), no train")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let minutes {
                        Text("\(minutes) min")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A place's name, with its icon only for where you are.
private struct PlaceLabelStyle: LabelStyle {
    let showsIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if showsIcon { configuration.icon }
            configuration.title
        }
    }
}

/// The places to pick for one end of a New Trip, under its search field: stations as chips,
/// then your contacts' addresses, then addresses and places in New York City (MapKit's search).
/// First-run setup's place search too. Return picks the first of them.
struct TripPlaceList: View {
    let search: String
    /// Bumped by Return in the search field, to pick the first result.
    var submits = 0
    let pick: (TripPlace) -> Void

    /// An address or place to look up before it's picked: MapKit's suggestion, or a contact's.
    /// Or one already found by MapKit's search, for a misspelling (`PlaceCompleter.found`).
    private enum Lookup: Hashable {
        case place(MKLocalSearchCompletion)
        case found(MKMapItem)
        case contact(ContactAddress)
    }

    /// Made once the list shows, not each time New Trip makes the list again.
    @State private var completer: PlaceCompleter?
    @State private var contacts: ContactSearch?
    /// What's being looked up after a tap.
    @State private var resolving: Lookup?
    /// Its lookup, stopped if the list goes, so it can't pick for the other end opened next.
    @State private var looking: Task<Void, Never>?
    /// What was looked up and found too far from the subway to plan from.
    @State private var tooFar: Set<Lookup> = []
    /// What was tapped but couldn't be looked up, as offline.
    @State private var notFound: Set<Lookup> = []

    private var stations: [Station] {
        let query = StationSearch(search)
        return Array(query.filter(StationDirectory.all).prefix(search.isEmpty ? 0 : 8))
    }

    /// Addresses and places for the search, from two letters, when they're for what's typed.
    private var places: [MKLocalSearchCompletion] {
        search.count < 2 ? [] : completer?.results(for: search) ?? []
    }

    /// What MapKit's search found when its suggestions were few, as for a misspelling.
    private var foundPlaces: [MKMapItem] {
        search.count < 2 ? [] : completer?.found(for: search) ?? []
    }

    private var contactAddresses: [ContactAddress] {
        search.count < 2 ? [] : contacts?.results(for: search) ?? []
    }

    /// Whether what's typed could be someone's name: two letters or more, not a street number.
    private var couldBeName: Bool {
        search.count >= 2 && search.contains(where: \.isLetter)
    }

    var body: some View {
        // Searched once each time, not again for the chips: it's every station, near spellings and all
        let stations = stations
        VStack(spacing: 0) {
            if !stations.isEmpty {
                stationChips(stations)
                    .padding(.vertical, 6)
            }
            list
        }
        // Looked up once typing pauses, so a search isn't overtaken by the next letter's
        .task(id: search) {
            let completer = completer ?? PlaceCompleter()
            self.completer = completer
            let contacts = contacts ?? ContactSearch()
            self.contacts = contacts
            if !search.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            completer.query = search
            contacts.query = search
        }
        .onChange(of: submits) { pickFirst() }
        .onDisappear { looking?.cancel() }
    }

    private var list: some View {
        List {
            if let contacts, !contactAddresses.isEmpty || (couldBeName && (contacts.mayAsk || contacts.mayShare)) {
                Section {
                    ForEach(contactAddresses) { address in
                        lookupButton(.contact(address)) {
                            ContactAddressRow(address: address, tooFar: tooFar.contains(.contact(address)),
                                              notFound: notFound.contains(.contact(address)))
                        }
                    }
                    if couldBeName {
                        // Asked the first time it's tapped; Apple's button then shares the
                        // contacts that match, while Leeway may see only some
                        if contacts.mayAsk {
                            Button {
                                Task { await contacts.ask() }
                            } label: {
                                Label("Search Your Contacts", systemImage: "person.crop.circle")
                            }
                        } else if contacts.mayShare {
                            ContactAccessButton(queryString: search) { _ in contacts.refresh() }
                        }
                    }
                } header: {
                    if !contactAddresses.isEmpty { Text("Contacts") }
                }
            }

            if !places.isEmpty || !foundPlaces.isEmpty {
                Section("Places") {
                    ForEach(places, id: \.self) { result in
                        lookupButton(.place(result)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).foregroundStyle(.primary)
                                if tooFar.contains(.place(result)) {
                                    Text("More than 5 miles from the subway").font(.caption).foregroundStyle(.red)
                                } else if notFound.contains(.place(result)) {
                                    Text("Couldn't look up this address").font(.caption).foregroundStyle(.red)
                                } else if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    ForEach(foundPlaces, id: \.self) { item in
                        lookupButton(.found(item)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "").foregroundStyle(.primary)
                                if let address = item.address?.shortAddress {
                                    Text(address).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
    }

    /// The stations for the search as a row of chips, Home and Work's in New Trip, scrolling
    /// past the screen.
    private func stationChips(_ stations: [Station]) -> some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(stations) { station in
                        Button {
                            pick(TripPlace(station: station))
                        } label: {
                            StationChip(station: station)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 16, for: .scrollContent)
    }

    private func lookupButton(_ lookup: Lookup, @ViewBuilder label: () -> some View) -> some View {
        Button {
            lookUp(lookup)
        } label: {
            HStack {
                label()
                Spacer()
                if resolving == lookup { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolving != nil)
    }

    /// Return: the first station, else the first contact, else the first place.
    private func pickFirst() {
        // A place tapped is still being looked up: that's the pick, not cancelled for the first
        guard resolving == nil else { return }
        if let station = stations.first {
            pick(TripPlace(station: station))
        } else if let address = contactAddresses.first {
            lookUp(.contact(address))
        } else if let place = places.first {
            lookUp(.place(place))
        } else if let item = foundPlaces.first {
            lookUp(.found(item))
        }
    }

    private func lookUp(_ lookup: Lookup) {
        looking?.cancel()
        looking = Task { await choose(lookup) }
    }

    /// Looks up where an address or place is, then picks it if it's within
    /// `PlaceCompleter.reach` of a station. The completer only suggests places in the box around
    /// them, so this catches the corners of it, such as Newark, and contacts anywhere.
    private func choose(_ lookup: Lookup) async {
        guard !tooFar.contains(lookup), resolving == nil else { return }
        resolving = lookup
        defer { resolving = nil }
        notFound.remove(lookup)
        let item: MKMapItem?
        let name: String
        let detail: String
        switch lookup {
        case .place(let result):
            let request = MKLocalSearch.Request(completion: result)
            request.region = PlaceCompleter.served
            request.regionPriority = .required
            item = try? await MKLocalSearch(request: request).start().mapItems.first
            name = result.title
            detail = result.subtitle
        case .found(let found):
            item = found
            name = found.name ?? ""
            detail = found.address?.shortAddress ?? ""
        case .contact(let address):
            let request = MKGeocodingRequest(addressString: address.address)
            request?.region = PlaceCompleter.served
            item = try? await request?.mapItems.first
            name = address.name
            detail = address.street
        }
        guard !Task.isCancelled else { return }
        guard let item else {
            // As offline: said on its row, rather than nothing happening
            notFound.insert(lookup)
            return
        }
        guard let nearest = Nearby.nearest(to: item.location), nearest.meters <= PlaceCompleter.reach else {
            tooFar.insert(lookup)
            return
        }
        let coordinate = item.location.coordinate
        pick(TripPlace(name: name, detail: detail,
                       point: TripPlace.Point(latitude: coordinate.latitude, longitude: coordinate.longitude)))
    }
}

/// A station as a chip: its lines' bullets, its name, and its borough short.
private struct StationChip: View {
    let station: Station
    @ScaledMetric(relativeTo: .subheadline) private var bulletSize: CGFloat = 18

    private static let boroughs = ["Manhattan": "Manh", "Brooklyn": "Bklyn", "Queens": "Qns",
                                   "Bronx": "Bx", "Staten Island": "SI"]

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(station.routes, id: \.self) { route in
                    LineBullet(route: route, size: min(bulletSize, 26))
                }
            }
            Text(station.name).font(.subheadline.weight(.semibold))
            Text(Self.boroughs[station.borough] ?? station.borough)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(station.name), \(station.borough)")
    }
}

/// One of a contact's addresses: their initials, name and which address it is, then its street.
private struct ContactAddressRow: View {
    let address: ContactAddress
    let tooFar: Bool
    /// Its address couldn't be looked up, as offline.
    var notFound = false

    var body: some View {
        HStack(spacing: 12) {
            Text(address.initials)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.gray.gradient, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(address.name).foregroundStyle(.primary)
                    if let label = address.label {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if tooFar {
                    Text("More than 5 miles from the subway").font(.caption).foregroundStyle(.red)
                } else if notFound {
                    Text("Couldn't look up this address").font(.caption).foregroundStyle(.red)
                } else {
                    Text(address.street).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// MapKit's suggestions for addresses and places in New York near the subway as you type, nearest you first
/// if Leeway knows where you are. Suggestions only finish words, so with few for what's typed
/// (as for "barclys center" or "brookyln museum"), MapKit's search looks too, which forgives
/// misspellings.
@MainActor
@Observable
private final class PlaceCompleter: NSObject, MKLocalSearchCompleterDelegate {
    /// How far from a station a place may be: 5 miles.
    static let reach: CLLocationDistance = 8_047

    /// Every station and `reach` around them, the only area places are suggested in.
    static let served: MKCoordinateRegion = {
        let stations = StationDirectory.all
        let latitudes = stations.map(\.lat)
        let longitudes = stations.map(\.lon)
        guard let south = latitudes.min(), let north = latitudes.max(),
              let west = longitudes.min(), let east = longitudes.max() else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.73, longitude: -73.94),
                                      latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        let center = CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2)
        // Meters per degree: about 111 km of latitude, and of longitude less by its cosine
        let latitudePad = reach / Earth.metresPerDegree
        let longitudePad = reach / (Earth.metresPerDegree * cos(center.latitude * .pi / 180))
        return MKCoordinateRegion(center: center,
                                  span: MKCoordinateSpan(latitudeDelta: north - south + latitudePad * 2,
                                                         longitudeDelta: east - west + longitudePad * 2))
    }()

    private(set) var results: [MKLocalSearchCompletion] = []
    /// What `results` were found for.
    private(set) var resultsQuery = ""

    /// The results for `query`, none while they're still for what was typed before it.
    func results(for query: String) -> [MKLocalSearchCompletion] {
        Self.withOrdinals(query) == resultsQuery ? results : []
    }
    /// MapKit's search's places when suggestions were few, those not suggested already.
    private(set) var found: [MKMapItem] = []
    /// What `found` was searched for.
    private(set) var foundQuery = ""

    /// The places searched for `query`, none while they're still for what was typed before it.
    func found(for query: String) -> [MKMapItem] {
        Self.withOrdinals(query) == foundQuery ? found : []
    }
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var searching: Task<Void, Never>?

    var query = "" {
        didSet { completer.queryFragment = Self.withOrdinals(query) }
    }

    /// What's typed with numbered streets made ordinal: "16 E 34" as "16 E 34th". MapKit
    /// doesn't take a bare number after E or W for a street, and suggests "16 E Park Ave".
    static func withOrdinals(_ query: String) -> String {
        let directions: Set<String> = ["e", "w", "n", "s", "east", "west", "north", "south"]
        var words = query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        for index in words.indices.dropFirst() {
            guard let number = Int(words[index]), number > 0,
                  directions.contains(words[index - 1].lowercased()) else { continue }
            let suffix = switch (number % 100, number % 10) {
            case (11...13, _): "th"
            case (_, 1): "st"
            case (_, 2): "nd"
            case (_, 3): "rd"
            default: "th"
            }
            words[index] += suffix
        }
        return words.joined(separator: " ")
    }

    /// Fewer suggestions than this, and MapKit's search looks too.
    private static let few = 3
    /// Around you, to put what's near you first: 10 km each way.
    private static let nearYou: CLLocationDistance = 20_000

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        // Near you if you're near the subway, still suggesting further away; else anywhere it
        // reaches. Ones too far are turned down when tapped.
        if let here = Self.lastLocation, let nearest = Nearby.nearest(to: here), nearest.meters <= Self.reach {
            completer.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: Self.nearYou,
                                                  longitudinalMeters: Self.nearYou)
            completer.regionPriority = .default
        } else {
            completer.region = Self.served
            completer.regionPriority = .required
        }
    }

    /// Where you last were, if Leeway may know: without asking or waiting for a new fix.
    private static var lastLocation: CLLocation? {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return manager.location
        default: return nil
        }
    }

    // The completer calls back on the main thread
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            results = completer.results.filter { Self.inNewYork($0.subtitle) }
            resultsQuery = completer.queryFragment
            searchIfFew()
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            results = []
            resultsQuery = completer.queryFragment
            searchIfFew()
        }
    }

    /// Whether an address is in New York: it names the state ("NY" or "New York"). Places in
    /// New Jersey and further, and those without a state, aren't offered.
    static func inNewYork(_ address: String) -> Bool {
        address.contains(/\bNY\b|New York/)
    }

    /// With few suggestions for three letters or more, MapKit's search for what's typed: up to
    /// six places it finds near the subway that weren't suggested.
    private func searchIfFew() {
        searching?.cancel()
        let query = resultsQuery
        guard results.count < Self.few, query.count >= 3 else {
            found = []
            foundQuery = query
            return
        }
        let suggested = Set(results.map { $0.title.lowercased() })
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = completer.region
        request.regionPriority = completer.regionPriority
        request.resultTypes = [.address, .pointOfInterest]
        searching = Task {
            let items = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
            guard !Task.isCancelled else { return }
            found = Array(items.filter { item in
                guard let name = item.name, !suggested.contains(name.lowercased()),
                      Self.inNewYork(item.address?.fullAddress ?? ""),
                      let nearest = Nearby.nearest(to: item.location) else { return false }
                return nearest.meters <= Self.reach
            }.prefix(6))
            foundQuery = query
        }
    }
}

#Preview {
    NewTripView(showing: TripShowing())
        .environment(SettingsStore())
}
