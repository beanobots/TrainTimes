import ContactsUI
import CoreLocation
import MapKit
import Observation
import SwiftUI
import Synchronization
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

/// The New Trip tab: pick where from and where to, then the trips between them, planned on the
/// phone (`LocalRoutes`, or the push server's `GET /routes` without the timetables) and the app's own, as the Share sheet works them out from maps
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
    /// Which way the start map's compass turned it, when not Settings' way: framed that way
    /// after. Shared with Nearby's map, and cleared as Settings changes.
    @Binding var startHeading: Double?

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
    /// nothing, fading after `fadeAfter(_:)` back to From and To to change the trip (No Trip Found).
    private enum Fix: Equatable {
        case retry, settings, fades
    }

    /// How long No Trip Found shows before fading back to From and To: time to read it, 1 s
    /// plus 0.2 s a word.
    private static func fadeAfter(_ message: String) -> Duration {
        let words = message.split(whereSeparator: \.isWhitespace).count
        return .seconds(1 + 0.2 * Double(words))
    }

    /// No Trip Found showing over the map, to fade (`Fix.fades`).
    private var fading: Bool {
        fadingMessage != nil
    }

    /// No Trip Found's message, while it's showing to fade.
    private var fadingMessage: String? {
        guard collapsed, case .failed(_, let message, .fades) = state else { return nil }
        return message
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
    /// Whether `picked` was tapped rather than the first trip by default: only then does it
    /// stay picked, and shown, once walking all the way comes in (`addWalkAll`).
    @State private var pickedByTap = false
    /// Each option's minutes door to door by the timetable; nil where it can't time one.
    @State private var minutes: [Int?] = []
    /// The train trips behind `options` (nil for one with a bus), for timing one again, and when
    /// they were planned for.
    @State private var trips: [TripPlanner.Trip?] = []
    @State private var plannedAt = AppClock.now
    /// For each option whose change is at more than one station, by its index: every station it
    /// can change at, those it does switched on, then others it could (`TripPlanner.otherChanges`).
    @State private var changeStations: [Int: [ChangeStation]] = [:]
    /// Whether the picked trip's change stations are open in the card, the other trips hidden.
    @State private var stationsOpen = false
    /// What the trips shown were planned for, so coming back to the tab keeps them.
    @State private var plannedKey: PlanKey?
    /// What Plan Trip was last tapped for: trips are planned as soon as both ends are picked, but
    /// kept off the map until it's tapped for them.
    @State private var shownKey: PlanKey?
    /// Walking all the way, with Walk on, added to the trips once it's routed: a walk across town
    /// takes seconds, which the trips mustn't wait on. Not cut short by leaving the tab.
    @State private var walkAllTask: Task<Void, Never>?
    /// The trips still to come once the others show (`Late`), each held a place in the list by
    /// a row with a spinner, and the tasks adding them when they're in.
    @State private var lateRows: [Late] = []
    @State private var lateTasks: [Task<Void, Never>] = []
    /// Where the trips were planned from and to, for the map.
    @State private var ends: (start: CLLocation, end: CLLocation)?
    /// The map: before there are trips, around you, or the city until you're found; then framed
    /// on the trips by `TripMap`. The city at first, framed on you by the app's own fix once
    /// it's in (`framesNextFix`): following you, MapKit kept best-accuracy GPS on.
    @State private var startPosition = MapCameraPosition.region(Self.cityRegion)
    /// The start map's size and safe area, to frame it turned Grid North.
    @State private var startRoom = MapRoom()
    /// Where the map last came to rest (`holdStart`).
    @State private var startCamera: MapCamera?
    /// Started over with no fresh fix (`startOver`): the start map frames you once you're found.
    /// At first too, until you're first found.
    @State private var framesNextFix = true
    @AppStorage(MapNorth.key) private var nyNorth = false
    /// The lines round From on the map before there are trips (`findLines`), a count of each new
    /// set, as Nearby's.
    @State private var lines = NearbyLines.none
    @State private var linesVersion = 0
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
                       walkMinutes: walkMinutes,
                       bike: biking ? "\(bikeKinds.rawValue) \(ownBike.rawValue) \(bikeCarry.rawValue)" : "", located: here && location.location != nil,
                       locateFailed: here && location.failed, status: here ? location.status : .notDetermined,
                       attempt: attempt, moved: moved)
    }

    /// How you'll go, remembered: by subway, and how far you'll walk to and from a ride (minutes,
    /// one of `walkChoices`, picked in Settings). By bus is Settings' Include buses. Walking all
    /// the way is always offered.
    @AppStorage(Self.subwayKey) private var subway = true
    @AppStorage(Self.walkMinutesKey) private var walkMinutes = Self.defaultWalkMinutes

    private static let subwayKey = "tripSubway"
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
    /// Go's walks being asked for.
    @State private var startingWalk = false
    /// Go waiting on its walks, let go (`cancelGo`) if the trip's changed or started over
    /// meanwhile, so an old trip's walk doesn't start over the new one.
    @State private var goTask: Task<Void, Never>?
    /// The picked trip's walks, asked for as it's picked so Go needn't wait on them.
    @State private var walksAhead: WalksAhead?
    /// Apple Maps couldn't give Go its walks.
    @State private var walkFailed = false
    /// The picked trip as a route, being planned and saved (`NewRouteView`).
    @State private var savingRoute: SavedWidget?
    /// Go's walks failed as a station has no entrance listed, not for Apple Maps: trying again
    /// won't help.
    @State private var walkNoEntrance = false
    /// Opened from a Saved Route's button (`PlanRouteTripIntent`): only the trips that take it,
    /// until Show All Trips, or To's changed.
    @State private var routeOnly: RouteFilter?
    /// Opened from a Saved Route: its trips shown as soon as they're planned, as if Plan Trip
    /// were tapped then. Not at once, as your being found after changes what they wait on.
    @State private var showsWhenPlanned = false

    /// A Saved Route whose trips alone are shown, and the To it was opened with.
    private struct RouteFilter {
        var widget: SavedWidget
        var to: TripPlace
    }

    /// With `routeOnly`, the trips that start as the route does (`takes(_:route:)`); nil without
    /// it, To changed since, or when none do.
    private var routeIndices: [Int]? {
        guard let routeOnly, routeOnly.to == to else { return nil }
        let found = options.indices.filter { Self.takes(options[$0], route: routeOnly.widget) }
        return found.isEmpty ? nil : found
    }

    /// The trips listed: the route's only, opened from one, else all.
    private var shownIndices: [Int] { routeIndices ?? Array(options.indices) }

    /// Whether `choice` starts as `route` does: from its station on one of its lines going its
    /// way, or for a bus route, on one of its buses from its stop.
    private static func takes(_ choice: ServerRoutes.Choice, route: SavedWidget) -> Bool {
        switch route.kind {
        case .subway:
            let train: SharedTrip.Option? = switch choice {
            case .train(let option): option
            case .bus(let trip): trip.busFirst ? nil : trip.train
            case .walk, .bike: nil
            }
            guard let train, let station = train.selection.station, let routeStation = route.selection.station,
                  station.complex == routeStation.complex else { return false }
            return train.selection.routes.contains { line in
                route.selection.routes.contains(line)
                    && train.selection.direction(of: line) == route.selection.direction(of: line)
            }
        case .bus:
            guard case .bus(let trip) = choice, trip.busFirst, let bus = route.bus,
                  let stop = BusRoutes.stopByCode[bus.stop.id] else { return false }
            let line = BusRoutes.key(trip.bus.line)
            return bus.allLines.contains { BusRoutes.key($0) == line }
                && trip.bus.from.location.distance(from: stop.location) <= Self.sameStop
        case .bike:
            return false
        }
    }

    /// Metres a trip's bus may board from a route's stop and be the same stop: the planner's
    /// stops and the route's are the same, give or take where each puts it.
    private static let sameStop: CLLocationDistance = 60

    /// Plans from where you are to Saved Route `id`'s end, showing only its trips (`routeOnly`):
    /// its button on a widget was tapped.
    private func planRoute(_ id: UUID) {
        guard let widget = SharedStore.loadWidgets().widget(id)?.shown(at: AppClock.now), widget.hasEnd else { return }
        let place: TripPlace
        switch widget.end {
        case .station(let station):
            place = TripPlace(station: station)
        case .stop(let stop):
            place = TripPlace(name: BusNames.readable(stop.name),
                              point: TripPlace.Point(latitude: stop.latitude, longitude: stop.longitude))
        case .none:
            return
        }
        cancelGo()
        closeStations()
        picking = nil
        search = ""
        from = .here
        to = place
        routeOnly = RouteFilter(widget: widget, to: place)
        showsWhenPlanned = true
        frameEnds()
        location.find()
        // The trips just planned for the same ends, shown now: nothing's planned again to show them
        if planKey == plannedKey, state == .ready { showPlanned() }
        withAnimation(Self.endsAnimation) { collapsed = true }
    }

    /// The trips planned shown, as Plan Trip shows them; a route's first trip picked.
    private func showPlanned() {
        showsWhenPlanned = false
        shownKey = planKey
        pickRouteTrip()
    }

    /// Opened from a route, its first trip picked, unless one was tapped.
    private func pickRouteTrip() {
        guard !pickedByTap, let first = routeIndices?.first else { return }
        picked = first
    }

    /// The route's header over its trips, opened from one (`routeOnly`): whose they are, or that
    /// none take it now; and Show All Trips under them.
    @ViewBuilder private var routeHeader: some View {
        if let routeOnly, routeOnly.to == to {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    if routeIndices == nil {
                        Text("No trip takes \(routeOnly.widget.title) now")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Your route")
                            .foregroundStyle(.secondary)
                        Text(routeOnly.widget.title)
                            .fontWeight(.semibold)
                    }
                    Spacer(minLength: 0)
                }
                .font(.footnote)
                .lineLimit(1)
                .padding(.horizontal, Self.margin)
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
                Divider()
            }
            .modifier(Unroll(shown: !stationsOpen))
        }
    }

    /// A trip's row in the list, known by the trip rather than its place.
    private struct ShownTrip: Hashable {
        let index: Int
        let option: ServerRoutes.Choice
    }

    /// Trips planned after the others show, rather than holding them up: bike trips, which ask
    /// Apple Maps for each ride, and, where the phone hasn't the bus timetable, the server's bus trips.
    enum Late: Hashable {
        case bikes, buses

        var finding: String { self == .bikes ? "Finding bike trips…" : "Finding bus trips…" }
    }

    /// A late trips' place in the list till they're in, with a spinner.
    private func lateRow(_ late: Late) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .frame(width: 52)
            Text(late.finding)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(late.finding)
    }

    @ViewBuilder private var showAllTripsRow: some View {
        if routeIndices != nil {
            VStack(spacing: 0) {
                Divider()
                Button {
                    withAnimation(.smooth(duration: 0.3)) { routeOnly = nil }
                } label: {
                    Label("Show All Trips", systemImage: "list.bullet")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Self.margin)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            .modifier(Unroll(shown: !stationsOpen))
        }
    }

    /// The picked trip, if it's a train trip: Go walks those.
    private var pickedTrip: TripPlanner.Trip? {
        state == .ready && trips.indices.contains(picked) ? trips[picked] : nil
    }

    /// The picked trip, if it's walking all the way: Go walks it too.
    private var pickedWalk: Walk? {
        guard state == .ready, options.indices.contains(picked), case .walk(let walk) = options[picked] else { return nil }
        return walk
    }

    /// The picked trip, if it's with a bike: Go follows its walks and rides turn by turn.
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

    /// Metres you may have moved from where a walk all the way was planned from before Go asks
    /// Apple Maps for it again; and from where trips were planned, before they're planned from
    /// where you are now.
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
            // One map all along, under the search page while picking: made anew for each page,
            // a new map began at MapKit's own view, held to the city's bounds at their far
            // corner, and jumped there (bottom left, Perth Amboy) as a destination was picked
            ZStack {
                tripPage
                if picking != nil {
                    pickingPage
                        .background(Color(.systemGroupedBackground))
                }
            }
            .overlay(alignment: sideways ? .bottomLeading : .bottom) {
                if endsOpen {
                    VStack(spacing: 10) {
                        if impreciseHere {
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
        // Save as Route: the trip planned as a route, every way across the week
        .fullScreenCover(item: $savingRoute) { widget in
            NewRouteView(starting: widget, fromNear: Self.near(from, widget.start), toNear: Self.near(to, widget.end))
        }
        .onAppear {
            location.start()
            // Made again with you already found (the one `tripLocation`): framed on you now, as
            // no new fix may come to do it
            if framesNextFix, let here = location.location, to == nil, ends == nil, picking == nil {
                framesNextFix = false
                frameStart(on: [here])
            }
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
        // A Saved Route's button on a widget: planned from where you are to where it goes. Also
        // when the tap launched the app, so it was set before this appeared; not under a walk
        .onChange(of: StationOpening.shared.route, initial: true) { _, route in
            guard let route, ActiveWalk.shared.session == nil else { return }
            StationOpening.shared.route = nil
            planRoute(route)
        }
        // Planned once both ends are picked, and again as what it waits on changes, such as the
        // ways you'll go; kept off the map until Plan Trip's tapped (`shownKey`)
        .task(id: hasEnds ? planKey : nil) { await plan() }
        // The network trips are planned on, built while From and To are picked, so the first
        // plan doesn't wait for it
        .task(id: settings.settings.includesBuses) { await LocalRoutes.prepare(buses: settings.settings.includesBuses) }
        // No Trip Found fades after a moment, back to From and To to change the trip
        // and timed afresh for each message, not cut short by the last one's
        .task(id: fadingMessage) {
            guard let message = fadingMessage else { return }
            try? await Task.sleep(for: Self.fadeAfter(message))
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
    /// Home and Work under the field until you type (Current Location too, for From), with your
    /// next event (for To) and recent addresses under them; then the stations as chips in their
    /// place and the contacts and places below.
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
                // Today's events for To, and the addresses picked lately; or what to search
                // for, but not on its side, where with the keyboard up there's no room for it
                TripSuggestions(showsCalendar: picking == .to && setting == nil, showsHint: !sideways,
                                pick: pick)
            } else {
                TripPlaceList(search: search, submits: submits, keepsRecents: setting == nil, pick: pick)
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
                .accessibilityLabel(picking == .from ? "From" : "To")
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

    /// The map the whole screen, From and To over its bottom. Once both are picked, over its
    /// bottom the trips with From and To shrunk to a line over them, and New Trip and Go in the
    /// tab bar's place. Opened again, From and To take the trips' place, the tab bar back under them.
    private var tripPage: some View {
        mapArea
            // The trips framed clear of the status bar, and of the cards and the bar under them;
            // reframed as From and To open and close. Its logo and Legal over the cards, clear of
            // the screen's rounded corner; on its side, past the cards down the left.
            .safeAreaPadding(.top, hasEnds ? (sideways ? Sideways.top : Self.statusBarRoom) : 0)
            .safeAreaPadding(.bottom, attributionRoom)
            .safeAreaPadding(.leading, mapLeading)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // The whole screen still while the keyboard's going after picking an end: shrunk
            // by it, the map had no room left to frame the trips in, and zoomed right out,
            // and growing back as it went, MapKit's drawing failed Metal's checks
            .ignoresSafeArea(.keyboard)
            .overlay(alignment: sideways ? .bottomLeading : .bottom) {
                if hasEnds && collapsed {
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
            // Lit like Go once there's a trip to save
            let canSave = routeFromTrip != nil
            Button {
                cancelGo()
                savingRoute = routeFromTrip
            } label: {
                Label("Save as Route", systemImage: "bookmark")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: Self.barHeight, height: Self.barHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(canSave ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .glassEffect(canSave ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Circle())
            .disabled(!canSave)
            .accessibilityHint("Plans this trip as a route for your widgets, every way across the week")
            goButton
        }
        .padding(.horizontal, sideways ? 0 : Self.barMargin)
    }

    /// The picked trip as a new route (`NewRouteView`): from its train's station or its bus's
    /// stop to where it gets off; walking or biking, or with no stop found, the stations nearest
    /// where it was planned from and to.
    private var routeFromTrip: SavedWidget? {
        guard let ends, state == .ready else { return nil }
        var start = RouteStart.none
        var end = RouteStart.none
        if let trip = pickedTrip {
            start = trip.selection.station.map(RouteStart.station) ?? .none
            end = .station(trip.destination)
        } else if options.indices.contains(picked), case .bus(let bus) = options[picked] {
            if bus.busFirst {
                start = Self.stop(near: bus.bus.from.location, line: bus.bus.line)
            } else {
                start = bus.train?.selection.station.map(RouteStart.station) ?? .none
            }
            if bus.busFirst, let station = bus.train?.endStation {
                end = .station(station)
            } else {
                let last = bus.onward ?? bus.bus
                end = Self.stop(near: last.to.location, line: last.line)
            }
        }
        if start.id == nil { start = Nearby.nearest(to: ends.start).map { .station($0.station) } ?? .none }
        if end.id == nil { end = Nearby.nearest(to: ends.end).map { .station($0.station) } ?? .none }
        guard start.id != nil, end.id != nil, start.place != end.place else { return nil }
        var widget = SavedWidget(selection: settings.defaultTrain)
        widget.startAt(start)
        widget.goTo(end)
        return widget
    }

    /// What `place` is called, if the route's `end` for it is a station or stop of another name.
    private static func near(_ place: TripPlace?, _ end: RouteStart) -> String? {
        guard let place, let name = end.name, place.name != name else { return nil }
        return place.name
    }

    /// The stop nearest `location` that `line` stops at, within a short walk.
    private static func stop(near location: CLLocation, line: String) -> RouteStart {
        let key = BusRoutes.key(line)
        let nearest = BusRoutes.allStops
            .filter { abs($0.latitude - location.coordinate.latitude) < 0.003 && abs($0.longitude - location.coordinate.longitude) < 0.004 }
            .filter { stop in (BusRoutes.linesAtStop[stop.code] ?? []).contains { BusRoutes.key($0.line) == key } }
            .min { $0.location.distance(from: location) < $1.location.distance(from: location) }
        return nearest.map(RouteStart.stop) ?? .none
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

    /// Whether the trips' map shows, over the start map.
    private var showsTrips: Bool { hasEnds && state == .ready && shownKey == planKey }

    /// The trips on the map, or how planning's going.
    @ViewBuilder private var mapArea: some View {
        ZStack {
            tripMap
            if !showsTrips {
                // The map stays with both ends on it, how planning's going on a card over it
                if hasEnds && collapsed {
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

    /// The one map, before there are trips and with them: before, you, both ends and Nearby's
    /// lines (`NearbyLines`); once planned, the picked trip (`TripMap`).
    private var tripMap: some View {
        TripMap(options: showsTrips ? options : [], picked: picked,
                start: showsTrips ? ends?.start.coordinate : from?.location?.coordinate,
                end: showsTrips ? ends?.end.coordinate : (to?.location ?? (to?.isHere == true ? location.location : nil))?.coordinate,
                endName: to?.name ?? "", position: $startPosition, keptHeading: $startHeading,
                before: TripMap.Before(lines: lines, version: linesVersion, cache: linesCache, bounds: Self.cityBounds,
                                       // Before both ends, nothing pads the map's top: clear of the status bar
                                       compassTop: hasEnds ? 0 : (sideways ? Sideways.top : Self.statusBarRoom),
                                       you: location.location?.coordinate),
                rested: { startCamera = $0 },
                // The picked train trip's walks Go will take, drawn too rather than asked for twice
                aheadWalks: walksAhead.flatMap { $0.trip == pickedTrip ? $0.task : nil },
                asksWalks: showsTrips && pickedTrip != nil)
            .measuresRoom($startRoom)
            // Each new key's lines dropped for the next's, if it comes before they're laid out
            .task(id: linesKey) { await findLines() }
    }

    /// Where the lines are drawn round: From, or you.
    private var linesCenter: CLLocation? { from?.location ?? location.location }

    /// What the lines are for: about where From is, to the nearest 100 m or so, and the ways
    /// you'll go.
    private var linesKey: [Double] {
        guard let center = linesCenter?.coordinate else { return [] }
        return [(center.latitude * 1000).rounded(), (center.longitude * 1000).rounded(),
                settings.settings.includesBuses ? 1 : 0]
    }

    /// The lines of the bus stops nearest From, pale, if buses are a way you'll go; not the
    /// subway, which Nearby draws whole but here only crowded the map before a trip. Off the main
    /// thread; not shown if the key's moved on meanwhile.
    private func findLines() async {
        guard let center = linesCenter else {
            lines = .none
            linesVersion += 1
            return
        }
        let includesBuses = settings.settings.includesBuses
        let found = await Task.detached(priority: .userInitiated) {
            let buses = includesBuses ? Array(NearbyLines.nearestStopsLines(near: center)) : []
            return NearbyLines(routes: [], busLines: buses, around: [center.coordinate])
        }.value
        guard !Task.isCancelled else { return }
        lines = found
        linesVersion += 1
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
            pickedByTap = false
            plannedKey = nil
            shownKey = nil
            routeOnly = nil
            showsWhenPlanned = false
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
        showsWhenPlanned = false
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
        // Said as Go even while it's only a spinner
        .accessibilityLabel("Go")
        .accessibilityValue(startingWalk ? "Loading directions" : "")
        .accessibilityHint(pickedWalk != nil ? "Walks you to \(to?.name ?? "the end") turn by turn"
                           : pickedBike != nil ? "Takes you to \(to?.name ?? "the end") turn by turn, riding and walking"
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
        // With a bike: its train on the widget, and the walks and rides turn by turn, the ride
        // joined into the walk before its train or after, or all the way
        if let bike = pickedBike {
            if bike.train != nil { showing.show() }
            startingWalk = true
            goTask = Task {
                defer { if !Task.isCancelled { startingWalk = false } }
                let found: WalkingDirections.BikeWalks?
                do {
                    found = try await WalkingDirections.walks(for: bike, from: start, to: ends.end)
                } catch {
                    guard !Task.isCancelled else { return }
                    walkNoEntrance = false
                    walkFailed = true
                    return
                }
                guard !Task.isCancelled else { return }
                switch found {
                case .allTheWay(let walk):
                    ActiveWalk.shared.begin(WalkSession(walk: walk, endName: endName, end: ends.end))
                case .withTrain(let trip, let walks):
                    ActiveWalk.shared.begin(WalkSession(trip: trip, walks: walks, endName: endName, end: ends.end))
                case nil:
                    walkNoEntrance = true
                    walkFailed = true
                }
            }
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
                    if let note = longerWalk.map({
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
                        .onAppear { AccessibilityNotification.Announcement(note).post() }
                    }
                    routeHeader
                    let shown = shownIndices
                    // By trip, not place, so a trip coming in late slides the others into order
                    ForEach(shown.map { ShownTrip(index: $0, option: options[$0]) }, id: \.option) { row in
                        let index = row.index
                        if index != shown.first {
                            // Under the text, past the bullets
                            Divider().padding(.leading, Self.margin + 64)
                                .modifier(Unroll(shown: !stationsOpen))
                        }
                        Button {
                            if index == picked, changeStations[index] != nil || dockChoices(index) != nil {
                                withAnimation(Self.stationsAnimation) { stationsOpen.toggle() }
                            } else {
                                picked = index
                                pickedByTap = true
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
                                                picked: index == picked, longer: walkIsLong(walk))
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
                        .accessibilityAddTraits(index == picked ? .isSelected : [])
                        .accessibilityHint(index == picked && changeStations[index] != nil
                                           ? stationsOpen ? "Hides change stations" : "Shows change stations" : "")
                        .modifier(Unroll(shown: !stationsOpen || index == picked))
                    }
                    ForEach(lateRows, id: \.self) { late in
                        if !shown.isEmpty || late != lateRows.first {
                            Divider().padding(.leading, Self.margin + 64)
                                .modifier(Unroll(shown: !stationsOpen))
                        }
                        lateRow(late)
                            .modifier(Unroll(shown: !stationsOpen))
                    }
                    showAllTripsRow
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
                    .accessibilityAddTraits(.isHeader)
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

    /// How you'll go, one row: Subway, Bus and Citi Bike each a toggle, and Plan Trip as a round
    /// arrow at the end. Citi Bike rides the bikes Settings picks (`BikeKinds`), and how far
    /// you'll walk to and from a ride is in Settings too. Walking all the way is always offered;
    /// with every toggle off, it's the only trip. A long press on a toggle picks only that way.
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
        .accessibilityValue(eBike ? "E-bikes only" : "")
        .accessibilityHint(hint)
        .accessibilityAction(named: "Only \(name)") { pickOnly(on) }
    }

    /// Shrinks From and To to a line atop the trips, planned for them the ways picked as soon as
    /// both were. Greyed until both are.
    private var planTripButton: some View {
        let canPlan = hasEnds
        return Button {
            closeStations()
            // After No Trip Found, planned again: back online, or the timetable caught up
            if case .failed = state { retry() }
            shownKey = planKey
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
            .onAppear { AccessibilityNotification.Announcement("Precise Location is off").post() }
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
        // The same ends picked again, their trips already drawn: left framed on the trips, as
        // nothing's planned again to frame them
        guard planKey != plannedKey || state != .ready else { return }
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
        guard hasEnds, !collapsed, picking == nil, planKey == plannedKey, planKey == shownKey, state == .ready else { return }
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
        // Where the last trips were planned from and to, for a new fix a few metres off to keep
        let lastEnds = ends
        walkAllTask?.cancel()
        walkAllTask = nil
        lateTasks.forEach { $0.cancel() }
        lateTasks = []
        lateRows = []
        options = []
        minutes = []
        trips = []
        changeStations = [:]
        stationsOpen = false
        picked = 0
        pickedByTap = false
        ends = nil
        longerWalk = nil
        guard let from, let to else {
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
        guard let found = from.location ?? location.location, let toward = to.location ?? location.location else {
            // Waits for your location; this runs again once it's found
            state = .planning
            frameStart(on: [from.location, to.location].compactMap { $0 })
            return
        }
        // Where you are, a new fix within `walkMoved` of where it was last planned from: that, as
        // Go keeps it, so the walks asked for again are those already found, not routed afresh
        let start = from.isHere ? lastEnds.flatMap { $0.start.distance(from: found) <= Self.walkMoved ? $0.start : nil } ?? found : found
        let end = to.isHere ? lastEnds.flatMap { $0.end.distance(from: toward) <= Self.walkMoved ? $0.end : nil } ?? toward : toward
        frameStart(on: [start, end])
        // From and To a few steps apart: no trip, rather than a 0 m walk of a minute
        guard start.distance(from: end) >= Self.samePlace else {
            state = .failed(title: "Same Place", message: "From and To are the same place.", fix: .fades)
            return
        }
        state = .planning
        let clock = PlanClock()
        // The timetable read in now, off the main thread, while the server plans: the first
        // time, it's a big file to unpack, which held the trips up as they came in
        Task.detached(priority: .userInitiated) { _ = TimetableStore.load() }
        let buses = settings.settings.includesBuses
        let subway = self.subway
        let walkRange = walkChoice.meters
        // Walking all the way, asked of Apple Maps while the trains are planned, and Citi Bike's trips
        let noLimit = walkChoice.minutes == Self.noLimitMinutes
        // Not waited on where it can't be offered (below): a walk across town takes seconds to route
        let walking = Task { await Self.walkAll(noLimit: noLimit, from: start, to: end) }
        // Unless it's handed on to be added once the trips show (`walkAllTask`)
        var walkingHandedOn = false
        defer { if !walkingHandedOn { walking.cancel() } }
        // Citi Bike's or your own bike's trips, waited on only till `bikesWait` after planning
        // starts: Apple Maps times each ride, which can take seconds; later, added once they're in
        let bikeKinds = bike, ownKind = biking ? ownBike.kind : nil, carry = bikeCarry, endName = to.name
        let bikesTask = Task {
            await Self.bikeTrips(bikeKinds, own: ownKind, carry: carry, endName: endName,
                                 from: start, to: end, subway: subway, walkRange: walkRange)
        }
        var bikesHandedOn = false
        defer { if !bikesHandedOn { bikesTask.cancel() } }
        let bikesBy = ContinuousClock.now + Self.bikesWait
        // The planned routes, asked for once: each walk tried below picks from the same ones. Nil
        // if they couldn't be planned on the phone and the server couldn't be reached, and whether
        // it refused as over its daily limit. Without the bus timetable on the phone (Low Data
        // Mode, or not yet downloaded), its subway trips first, and the server's bus trips added
        // once they're in, rather than waited on
        var fetched: (routes: [ServerRoutes.Route]?, overLimit: Bool) = ([], false)
        var ridesBuses = buses
        if buses || subway, let local = await LocalRoutes.routes(from: start, to: end, buses: buses, subway: subway) {
            fetched = (local, false)
        } else if buses, subway, let local = await LocalRoutes.routes(from: start, to: end, buses: false, subway: true) {
            fetched = (local, false)
            ridesBuses = false
        } else if buses || subway {
            fetched = await ServerRoutes.fetchRoutes(from: start, to: end, buses: buses, subway: subway)
        }
        clock.mark("server")
        guard !Task.isCancelled else { return }
        var rides = await Self.rides(fetched.routes, buses: ridesBuses, subway: subway, from: start, to: end,
                                     walkRange: walkRange)
        // No subway trip to show first: the server's waited on after all, as there'd be nothing else
        if buses, !ridesBuses, rides.planned.isEmpty {
            fetched = await ServerRoutes.fetchRoutes(from: start, to: end, buses: true, subway: true)
            guard !Task.isCancelled else { return }
            ridesBuses = true
            rides = await Self.rides(fetched.routes, buses: true, subway: true, from: start, to: end, walkRange: walkRange)
        }
        let routes = fetched.routes
        let busesLate = buses && !ridesBuses
        clock.mark("rides")
        guard !Task.isCancelled else { return }
        // Waited on in full only where there's no ride to show without them
        let biked = rides.planned.isEmpty ? await bikesTask.value : await Self.value(of: bikesTask, by: bikesBy)
        let bikesLate = biked == nil
        clock.mark(bikesLate ? "bikes later" : "bikes")
        let bikeTrips = biked?.trips ?? []
        // Walking all the way now only if there's nothing else; else once the trips' minutes
        // say whether it could be offered beside them
        var walkedAll: (walk: Walk?, tooLong: Int?, trouble: MapsTrouble?) = (nil, nil, nil)
        let nothingElse = rides.planned.isEmpty && bikeTrips.isEmpty
        if nothingElse { walkedAll = await walking.value }
        let walk = walkedAll.walk
        // A walk cut short comes back nil, as if there were none: superseded, this plan mustn't
        // put No Trip Found over the new one's planning
        guard !Task.isCancelled else { return }
        // No ride within your walk to and from it, nor any bike trip, nor a walk instead: the
        // trips of the shortest longer walk offered that has some, rather than none at all
        var walked = walkChoice.minutes
        if rides.planned.isEmpty, bikeTrips.isEmpty, buses || subway {
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
                                walkTooLong: walkedAll.tooLong, walkTrouble: walkedAll.trouble, noBike: biked?.none)
            return
        }
        let at = AppClock.now
        let rows = await timedRides(planned, from: start, to: end, at: at)
        clock.mark("timed")
        // Set only now, after the wait, so a plan superseded meanwhile leaves the new one's be
        guard !Task.isCancelled else { return }
        options = rows.options
        trips = rows.trips
        plannedAt = at
        ends = (start, end)
        minutes = rows.minutes
        changeStations = rows.changeStations
        // Walking all the way beside other trips: offered however slow (up to `longestWalk`), but
        // added once routed rather than waited on (`addWalkAll`)
        let walkPending = !nothingElse
        if let walk {
            let walkMinutes = WalkTripRow.minutes(of: walk)
            dropTrips(slowerThan: walkMinutes)
            options.append(.walk(walk))
            trips.append(nil)
            minutes.append(walkMinutes)
        }
        appendBikes(bikeTrips)
        sortByEffort()
        // Said over the trips while a ride's among them that walks past your choice
        let riding = options.contains { if case .walk = $0 { false } else { true } }
        longerWalk = walked > walkChoice.minutes && riding ? walked : nil
        lateRows = (bikesLate ? [Late.bikes] : []) + (busesLate ? [Late.buses] : [])
        plannedKey = planKey
        state = .ready
        // Opened from a Saved Route: shown now, its first trip picked
        if showsWhenPlanned { showPlanned() } else { pickRouteTrip() }
        clock.mark("ready")
        Self.log.info("Planned in \(clock.summary)")
        let key = planKey
        if bikesLate {
            bikesHandedOn = true
            lateTasks.append(Task {
                let biked = await withTaskCancellationHandler {
                    await bikesTask.value
                } onCancel: {
                    bikesTask.cancel()
                }
                // Not for trips planned since, or From and To cleared
                guard !Task.isCancelled, plannedKey == key else { return }
                Self.log.info("Bike trips added after \(clock.summary), \(biked.trips.count) found")
                withAnimation(.smooth) {
                    lateRows.removeAll { $0 == .bikes }
                    guard state == .ready else { return }
                    keepingPick {
                        appendBikes(biked.trips)
                        sortByEffort()
                    }
                }
            })
        }
        if busesLate {
            lateTasks.append(Task {
                let server = await ServerRoutes.fetchRoutes(from: start, to: end, at: at, buses: true, subway: true)
                guard !Task.isCancelled, plannedKey == key else { return }
                // Couldn't be reached: the subway's trips are all there are
                guard let routes = server.routes else {
                    Self.log.info("Bus trips not added after \(clock.summary): no server")
                    lateRows.removeAll { $0 == .buses }
                    return
                }
                let all = await Self.rides(routes, buses: true, subway: true, from: start, to: end, walkRange: walkRange)
                let rows = await timedRides(all.planned, from: start, to: end, at: at)
                guard !Task.isCancelled, plannedKey == key else { return }
                Self.log.info("Bus trips added after \(clock.summary), \(rows.options.count) rides")
                withAnimation(.smooth) {
                    lateRows.removeAll { $0 == .buses }
                    guard state == .ready, !rows.options.isEmpty else { return }
                    keepingPick { replaceRides(with: rows) }
                }
            })
        }
        guard walkPending else { return }
        walkingHandedOn = true
        walkAllTask = Task {
            let walked = await withTaskCancellationHandler {
                await walking.value
            } onCancel: {
                walking.cancel()
            }
            clock.mark("walk")
            guard let walk = walked.walk else {
                Self.log.info("Walk all the way not offered after \(clock.summary): "
                              + (walked.tooLong.map { "\($0) min" } ?? "none found"))
                return
            }
            // Not for trips planned since, or From and To cleared
            guard !Task.isCancelled, state == .ready, plannedKey == key else { return }
            Self.log.info("Walk all the way added after \(clock.summary)")
            withAnimation(.smooth) { addWalkAll(walk) }
        }
    }

    /// The trips by subway and bus as rows: each timed, and where a train trip can change at more
    /// than one station, those it's worth changing at (`changeStations`). Trips with a bus aren't
    /// in the timetable: estimated by the bus timetable's times (`BusTrip.arrival`). Read once for
    /// them all, and timed, off the main thread: the first read unpacks a big file, which hitched
    /// New Trip as the trips came in. As `minutes(of:by:)`, from these ends at `at`
    private func timedRides(_ planned: [ServerRoutes.Planned], from start: CLLocation, to end: CLLocation,
                            at: Date) async -> TimedRides {
        let choices = planned.map(\.choice)
        let rideTrips = planned.map(\.trip)
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
        var rows = TimedRides(options: choices, trips: rideTrips, minutes: timed)
        for (index, trip) in rows.trips.enumerated() {
            guard let trip, let change = trip.change,
                  Set(change.stops.compactMap { $0.station?.complex }).count > 1 else { continue }
            let all = change.stops.map { ChangeStation(change: $0, on: true) }
                + TripPlanner.otherChanges(for: trip).map { ChangeStation(change: $0, on: false) }
            let kept = withoutNeedlessWalks(all, for: trip, by: timetable)
            // Stations to pick from only while there's more than one
            rows.changeStations[index] = Set(kept.compactMap { $0.change.station?.complex }).count > 1 ? kept : nil
            // Changing only where it's still offered, to the lines still offered there
            guard kept.filter(\.on) != all.filter(\.on),
                  let fewer = Change(stops: kept.filter(\.on).map(\.change))?.validated(for: trip.selection),
                  case .train(var option) = rows.options[index] else { continue }
            var changed = trip
            changed.change = fewer
            rows.trips[index] = changed
            option.change = fewer
            rows.options[index] = .train(option)
            rows.minutes[index] = minutes(of: changed, by: timetable)
        }
        return rows
    }

    /// `timedRides`' trips, as the trip state holds them.
    private struct TimedRides {
        var options: [ServerRoutes.Choice]
        var trips: [TripPlanner.Trip?]
        var minutes: [Int?]
        var changeStations: [Int: [ChangeStation]] = [:]
    }

    /// The bike trips worth offering added: to or from a train where it beats every trip without
    /// one, and riding all the way; all the way where it's not long or beats them too. None slower
    /// than walking all the way, but with a bike on, its soonest trip always, however slow.
    private func appendBikes(_ bikeTrips: [BikeTrip]) {
        let walkAllMinutes = options.indices.first { if case .walk = options[$0] { true } else { false } }
            .flatMap { minutes[$0] }
        let fastest = minutes.compactMap { $0 }.min()
        let soonestRide = bikeTrips.filter { $0.train == nil }.map(\.minutes).min()
        var bikeShown = false
        for trip in bikeTrips where walkAllMinutes.map({ trip.minutes < $0 }) ?? true {
            let beats = fastest.map { trip.minutes < $0 } ?? true
            guard trip.train == nil || soonestRide.map({ trip.minutes < $0 }) ?? true,
                  beats || (trip.train == nil && trip.minutes <= Self.rideOffered) else { continue }
            options.append(.bike(trip))
            trips.append(nil)
            minutes.append(trip.minutes)
            bikeShown = true
        }
        if !bikeShown, let soonestBike = bikeTrips.min(by: { $0.minutes < $1.minutes }) {
            options.append(.bike(soonestBike))
            trips.append(nil)
            minutes.append(soonestBike.minutes)
        }
    }

    /// The subway's trips given way to `rows`, the server's with buses (which has them too); walking
    /// all the way and bike trips kept, and trips slower than walking dropped, as when planned with them.
    private func replaceRides(with rows: TimedRides) {
        let others = options.indices.filter {
            switch options[$0] {
            case .walk, .bike: true
            case .train, .bus: false
            }
        }
        let otherOptions = others.map { options[$0] }, otherMinutes = others.map { minutes[$0] }
        options = rows.options + otherOptions
        trips = rows.trips + others.map { _ in nil }
        minutes = rows.minutes + otherMinutes
        changeStations = rows.changeStations
        if let walk = otherOptions.firstIndex(where: { if case .walk = $0 { true } else { false } }),
           let walkMinutes = otherMinutes[walk] {
            dropTrips { index in
                switch options[index] {
                case .walk, .bike: true
                case .train, .bus: TripRanking.keeps(minutes: minutes[index], besideWalk: walkMinutes)
                }
            }
        }
        sortByEffort()
    }

    /// `change` made to the trips, the one tapped still picked where it's still offered, else the best.
    private func keepingPick(_ change: () -> Void) {
        let kept = pickedByTap ? pickedOption : nil
        change()
        picked = kept.flatMap { options.firstIndex(of: $0) } ?? 0
        pickRouteTrip()
    }

    /// Walking all the way, routed after the trips showed: trips and Citi Bike rides slower than
    /// it give way to it, as when it's planned with them, but for one tapped, which stays
    /// picked; the soonest ride stays if every one is slower. Then all in order again
    /// (`sortByEffort`), and the best picked unless one was tapped.
    private func addWalkAll(_ walk: Walk) {
        let kept = pickedByTap ? pickedOption : nil
        let walkMinutes = WalkTripRow.minutes(of: walk)
        let bikeRows = Set(options.indices.filter { if case .bike = options[$0] { true } else { false } })
        let staying = Set(TripRanking.keptBesideWalk(walkMinutes, minutes: minutes, bikes: bikeRows,
                                                     tapped: pickedByTap ? picked : nil))
        dropTrips { staying.contains($0) }
        options.append(.walk(walk))
        trips.append(nil)
        minutes.append(walkMinutes)
        sortByEffort()
        picked = kept.flatMap { options.firstIndex(of: $0) } ?? 0
        pickRouteTrip()
    }

    private static let log = AppLog(category: "NewTrip")

    /// The rides by subway and bus from `start` to `end` with up to `walkRange` to and from them,
    /// of the planned `routes` (nil if they couldn't be planned) and the app's own, and where
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
        let why = Self.unplanned(from: start, to: end) ?? (subway ? none?.message(walk: walk) : nil)
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

    /// The longest the trips wait for bike trips, from when planning starts: past it they show
    /// without them, a row held for them, and they're added once in.
    private static let bikesWait = Duration.milliseconds(800)

    /// `task`'s value if it's in by `deadline`, else nil, the task left to carry on.
    private static func value<T: Sendable>(of task: Task<T, Never>, by deadline: ContinuousClock.Instant) async -> T? {
        let first = FirstAnswer<T>()
        return await withCheckedContinuation { continuation in
            first.waiting(continuation)
            Task { first.answer(await task.value) }
            Task {
                try? await Task.sleep(until: deadline)
                first.answer(nil)
            }
        }
    }

    /// Longest walk all the way offered at all (`TripRanking.longestWalk`).
    private static let longestWalk = TripRanking.longestWalk

    /// Whether walking all the way is well past your comfortable walk (`TripRanking.walkIsLong`),
    /// for a word on its row. Never with No Limit.
    private func walkIsLong(_ walk: Walk) -> Bool {
        TripRanking.walkIsLong(minutes: WalkTripRow.minutes(of: walk), comfortable: walkChoice.minutes,
                               noLimit: walkChoice.minutes == Self.noLimitMinutes)
    }

    /// Meters apart From and To are the same place: no trip planned between them.
    private static let samePlace: Double = 30


    /// Walking all the way, or none past `longestWalk` (unless `noLimit`), then
    /// with its minutes (`tooLong`) for No Trip Found to say; or none as Apple Maps was busy or
    /// out of reach (`trouble`), rather than having no walk.
    private static func walkAll(noLimit: Bool, from start: CLLocation,
                                to end: CLLocation) async -> (walk: Walk?, tooLong: Int?, trouble: MapsTrouble?) {
        // Past `longestWalk` even straight there at a brisk pace: not routed, as a walk across the
        // city takes seconds to, and its minutes as the app times walks (`TripPlanner.walkMinutes`)
        if !noLimit, Self.ruledOut(from: start, to: end, within: longestWalk) {
            return (nil, TripPlanner.walkMinutes(start.distance(from: end)), nil)
        }
        let walk: Walk
        do {
            walk = try await WalkingDirections.walk(from: start, to: end)
        } catch {
            return (nil, nil, MapsTrouble(error))
        }
        let minutes = WalkTripRow.minutes(of: walk)
        return TripRanking.offersWalk(minutes: minutes, noLimit: noLimit) ? (walk, nil, nil) : (nil, minutes, nil)
    }

    /// Whether a walk from `start` to `end` takes over `minutes` even straight there at
    /// `briskPace`, quicker than any walk routed: no need to route it to know.
    private static func ruledOut(from start: CLLocation, to end: CLLocation, within minutes: Int) -> Bool {
        start.distance(from: end) / briskPace / 60 > Double(minutes)
    }

    /// Metres a second, brisker than Apple Maps' walks or the app's own (`WalkCosts.pace`).
    private static let briskPace = 1.5

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
        dropTrips { TripRanking.keeps(minutes: minutes[$0], besideWalk: walkMinutes) }
    }

    /// The trips but those `keeping` says not to keep, by index.
    private func dropTrips(keeping: (Int) -> Bool) {
        let kept = options.indices.filter(keeping)
        guard kept.count < options.count else { return }
        options = kept.map { options[$0] }
        trips = kept.map { trips[$0] }
        minutes = kept.map { minutes[$0] }
        changeStations = Dictionary(uniqueKeysWithValues: kept.enumerated().compactMap { slot, index in
            changeStations[index].map { (slot, $0) }
        })
    }

    /// The trips best first, by `effort(at:timetable:)`: the minutes each shows, plus what its
    /// wait and changes count against it, with a short walk all the way ahead of a ride only a
    /// little quicker. The minutes shown stay as they are. Trips it can't time keep their places,
    /// and those it can fill the others in order; ties keep theirs, but for walking, which wins
    /// them (`TripRanking.order`).
    private func sortByEffort() {
        let timetable = TimetableStore.load(now: plannedAt)
        let efforts = options.indices.map { effort(at: $0, timetable: timetable) }
        let walkAll = options.map { if case .walk = $0 { true } else { false } }
        let order = TripRanking.order(efforts: efforts, walkAll: walkAll)
        if order != Array(options.indices) {
            options = order.map { options[$0] }
            trips = order.map { trips[$0] }
            minutes = order.map { minutes[$0] }
            changeStations = Dictionary(uniqueKeysWithValues: order.enumerated().compactMap { slot, index in
                changeStations[index].map { (slot, $0) }
            })
        }
    }

    /// What option `index` is ranked by, in seconds: its minutes, plus for a ride what its first
    /// walks, bus wait and changes count against it (`TripPlanner.penalty`, `BusTrip.penalty`).
    /// Walking all the way short of `TripRanking.walkMarginUnder` minutes counts
    /// `TripRanking.walkMargin` less, so a ride has to beat it by that; only a ride's walks count
    /// `TripPlanner.walkWeight`. Nil where its minutes aren't known.
    private func effort(at index: Int, timetable: Timetable?) -> TimeInterval? {
        guard let shown = minutes[index] else { return nil }
        let penalty: TimeInterval
        switch options[index] {
        case .walk:
            return TripRanking.walkEffort(minutes: shown)
        case .bus(let trip):
            penalty = ends.map { trip.penalty(from: $0.start, to: $0.end, at: plannedAt, timetable: timetable) } ?? 0
        case .train:
            if let ends, let trip = trips[index], let timetable {
                penalty = TripPlanner.penalty(of: trip, from: ends.start, to: ends.end, at: plannedAt,
                                              timetable: timetable) ?? 0
            } else {
                penalty = 0
            }
        case .bike:
            penalty = 0
        }
        return TripRanking.rideEffort(minutes: shown, penalty: penalty)
    }

    /// Minutes a change across the platform may take to get there over a walk to another
    /// platform for the same lines, and the walk not be offered.
    private static let walkWorth: TimeInterval = 2 * 60

    /// `stations` without walks to another platform for lines another of them has across the
    /// platform, which gets there no more than `walkWorth` later: not Atlantic Av-Barclays Ctr's
    /// walk to the B or Q, with them across the platform at DeKalb Av. Each walked line is weighed
    /// on its own, so the D and N across the platform at Atlantic Av stay without the B walked to
    /// there. A station left with no lines goes. At least one the trip changes at stays.
    private func withoutNeedlessWalks(_ stations: [ChangeStation], for trip: TripPlanner.Trip,
                                      by timetable: Timetable?) -> [ChangeStation] {
        guard stations.count > 1 else { return stations }
        let selection = trip.selection
        // When it gets there changing at just `station`, to just `route`; each timed once, as
        // each is compared with several
        var timed: [String: Date?] = [:]
        func arrival(_ station: Change, on route: String) -> Date? {
            let key = station.stationID + " " + route
            if let known = timed[key] { return known }
            var stop = station
            stop.routes = [route]
            var found: Date?
            if let ends, let timetable, let change = Change(stops: [stop])?.validated(for: selection) {
                var only = trip
                only.change = change
                found = TripPlanner.arrival(of: only, from: ends.start, to: ends.end, at: plannedAt, timetable: timetable)
            }
            timed[key] = found
            return found
        }
        var kept: [ChangeStation] = []
        for station in stations {
            let complex = station.change.station?.complex
            let needless = station.change.routes.filter { route in
                guard !station.change.isAcross(route, from: selection) else { return false }
                let across = stations.map(\.change).filter { other in
                    other.station?.complex != complex && other.routes.contains(route)
                        && other.isAcross(route, from: selection)
                }
                // Left out only if one across is known to get there no more than `walkWorth`
                // later; untimed (no timetable yet), it stays
                guard !across.isEmpty, let walking = arrival(station.change, on: route),
                      let soonest = across.compactMap({ arrival($0, on: route) }).min() else { return false }
                return soonest.timeIntervalSince(walking) <= Self.walkWorth
            }
            var station = station
            station.change.routes.removeAll(where: needless.contains)
            if !station.change.routes.isEmpty { kept.append(station) }
        }
        if !kept.contains(where: \.on), let first = stations.first(where: \.on) {
            kept.insert(first, at: 0)
        }
        return kept
    }

    /// Frames the map while trips are found on `places` (From and To, as far as they're known), or
    /// on the city without them, rather than wherever the map was, which can be the continent.
    /// Animated only when asked (`animated`).
    private func frameStart(on places: [CLLocation], animated: Bool = false) {
        let heading = startHeading ?? MapNorth.heading(ny: nyNorth)
        // Always a camera for the room as measured, clear of the cards, as the trips are: a
        // `.rect` is fitted to the whole map, and left you under the cards, framed too close, till
        // the trips came in and zoomed it out again, loading its tiles twice
        let northUp = true
        // Called inside other animations too (`startOver`), so they're turned off here unless asked
        var transaction = Transaction(animation: animated ? .smooth : nil)
        transaction.disablesAnimations = !animated
        guard !places.isEmpty else {
            let position = MapNorth.position(fitting: MKMapRect(Self.cityRegion), heading: heading, in: startRoom,
                                             northUp: northUp) ?? .region(Self.cityRegion)
            withTransaction(transaction) { startPosition = position }
            return
        }
        var rect = MKMapRect.null
        for place in places {
            rect = rect.union(MKMapRect(origin: MKMapPoint(place.coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        // At least a couple of kilometers across, and a little beyond both; just one spot (you,
        // as it starts), as close as Nearby's map starts round you
        let across = rect.width == 0 && rect.height == 0 ? LiveView.framedMeters : 2_000
        let least = across * MKMapPointsPerMeterAtLatitude(places[0].coordinate.latitude)
        let dx = max(rect.width * 0.15, (least - rect.width) / 2, 0)
        let dy = max(rect.height * 0.15, (least - rect.height) / 2, 0)
        let framed = rect.insetBy(dx: -dx, dy: -dy)
        let position = MapNorth.position(fitting: framed, heading: heading, in: startRoom, northUp: northUp) ?? .rect(framed)
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
    /// Whether it's well past your comfortable walk, said under it.
    var longer = false

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
                    Text("\(Walk.distance(walk.meters)), no train\(walk.saferAtNight == true ? ", via safer streets" : "")")
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
                if longer {
                    Label("Longer than you typically walk", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
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
    /// Whether addresses picked are kept in Recents: New Trip's ends, not Home or first-run's.
    var keepsRecents = false
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
        let place = TripPlace(name: name, detail: detail,
                              point: TripPlace.Point(latitude: coordinate.latitude, longitude: coordinate.longitude))
        if keepsRecents { RecentPlaces.shared.add(place) }
        pick(place)
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

/// Under Home and Work before anything's typed: for To, your next event today with somewhere to
/// be (the rest of today's under it, once asked for), then the addresses picked lately. Before
/// Leeway may read your calendar, a row to allow it instead, until it's closed.
struct TripSuggestions: View {
    /// Today's events are offered: picking To.
    let showsCalendar: Bool
    /// What to search for, when there's nothing to suggest.
    let showsHint: Bool
    let pick: (TripPlace) -> Void

    @State private var events = TodayEvents()
    @AppStorage("calendarRowClosed") private var rowClosed = false
    /// The rest of today's events shown under the next.
    @State private var showsAll = false
    /// The event being looked up after a tap.
    @State private var resolving: CalendarEvent?
    @State private var looking: Task<Void, Never>?
    @State private var tooFar: Set<CalendarEvent> = []
    @State private var notFound: Set<CalendarEvent> = []

    private var recents: [TripPlace] { RecentPlaces.shared.places }
    private var asks: Bool { showsCalendar && events.mayAsk && !rowClosed }
    private var calendar: [CalendarEvent] { showsCalendar ? events.events : [] }

    var body: some View {
        Group {
            if calendar.isEmpty && recents.isEmpty && !asks {
                hint
            } else {
                list
            }
        }
        .task { await events.watch() }
        .onDisappear { looking?.cancel() }
    }

    private var hint: some View {
        // Not on its side, where with the keyboard up there's no room for it
        VStack(spacing: 6) {
            if showsHint {
                Image(systemName: "magnifyingglass").font(.title2)
                    .accessibilityHidden(true)
                Text("Search for a station, address, place or person")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            if asks {
                Section { askRow }
            } else if let next = calendar.first {
                Section {
                    nextCard(next, more: calendar.count - 1)
                    if showsAll {
                        ForEach(calendar.dropFirst()) { event in
                            eventButton(event) { EventRow(event: event, tooFar: tooFar.contains(event),
                                                          notFound: notFound.contains(event)) }
                        }
                    }
                }
            }
            if !recents.isEmpty {
                Section("Recents") {
                    ForEach(recents) { place in
                        Button {
                            RecentPlaces.shared.add(place)
                            pick(place)
                        } label: {
                            RecentRow(place: place)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                RecentPlaces.shared.remove(place)
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

    /// Asks for your calendar on a tap; closed, it's not offered here again (first-run setup and
    /// the Settings app still can).
    private var askRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await events.ask() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Today's Events").foregroundStyle(.tint)
                        Text("Where you're due today, from your calendar. It stays on your iPhone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                withAnimation { rowClosed = true }
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// The next event, large: what, when, where, and how soon. With others today, a button to show
    /// them under it.
    private func nextCard(_ event: CalendarEvent, more: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Next on Your Calendar", systemImage: "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if more > 0 {
                    Button(showsAll ? "Show Less" : "+\(more) More Today") {
                        withAnimation { showsAll.toggle() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            eventButton(event) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(event.title).font(.title3.weight(.semibold))
                        Spacer()
                        Text(event.start, format: .dateTime.hour().minute()).font(.headline)
                    }
                    if tooFar.contains(event) {
                        Text("More than 5 miles from the subway").font(.subheadline).foregroundStyle(.red)
                    } else if notFound.contains(event) {
                        Text("Couldn't look up this address").font(.subheadline).foregroundStyle(.red)
                    } else {
                        Text(event.placeLine).font(.subheadline).foregroundStyle(.secondary)
                    }
                    TimelineView(.everyMinute) { context in
                        Label(Self.starts(event.start, now: context.date), systemImage: "clock")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func eventButton(_ event: CalendarEvent, @ViewBuilder label: () -> some View) -> some View {
        Button {
            looking?.cancel()
            looking = Task { await choose(event) }
        } label: {
            HStack {
                label()
                if resolving == event { ProgressView() }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolving != nil)
    }

    /// "Starts in 1 hr 10 min", "Starts now", "Started 5 min ago".
    private static func starts(_ start: Date, now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded())
        let format = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated)
        if abs(minutes) < 1 { return "Starts now" }
        let span = Duration.seconds(abs(minutes) * 60).formatted(format)
        return minutes > 0 ? "Starts in \(span)" : "Started \(span) ago"
    }

    /// Picks an event's place: where Calendar has it on the map, else its address looked up;
    /// within `PlaceCompleter.reach` of a station, as places searched.
    private func choose(_ event: CalendarEvent) async {
        guard !tooFar.contains(event), resolving == nil else { return }
        resolving = event
        defer { resolving = nil }
        notFound.remove(event)
        let location: CLLocation?
        if let point = event.point {
            location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        } else {
            let request = MKGeocodingRequest(addressString: [event.placeName, event.address]
                .compactMap { $0 }.joined(separator: ", "))
            request?.region = PlaceCompleter.served
            location = try? await request?.mapItems.first?.location
        }
        guard !Task.isCancelled else { return }
        guard let location else {
            notFound.insert(event)
            return
        }
        guard let nearest = Nearby.nearest(to: location), nearest.meters <= PlaceCompleter.reach else {
            tooFar.insert(event)
            return
        }
        let place = TripPlace(name: event.title, detail: event.placeLine,
                              point: TripPlace.Point(latitude: location.coordinate.latitude,
                                                     longitude: location.coordinate.longitude))
        RecentPlaces.shared.add(place)
        pick(place)
    }
}

/// One of today's later events: its time, its calendar's colour, what and where.
private struct EventRow: View {
    let event: CalendarEvent
    let tooFar: Bool
    let notFound: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(event.start, format: .dateTime.hour().minute())
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2)
                .fill(event.color.map { Color(cgColor: $0) } ?? .accentColor)
                .frame(width: 4, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).foregroundStyle(.primary)
                Group {
                    if tooFar {
                        Text("More than 5 miles from the subway").foregroundStyle(.red)
                    } else if notFound {
                        Text("Couldn't look up this address").foregroundStyle(.red)
                    } else {
                        Text(event.placeLine).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An address picked lately: a pin, its name, and under it its street.
private struct RecentRow: View {
    let place: TripPlace

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.red.gradient, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.primary)
                if let detail = place.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
    /// What `searching` searches for, or found.
    @ObservationIgnored private var searchedQuery: String?
    /// How long after the last suggestions before MapKit's search looks.
    private static let searchPause: Duration = .milliseconds(400)

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
        if let pretend = PretendLocation.current { return pretend }
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
    /// six places it finds near the subway that weren't suggested. Once for what's typed, though
    /// the completer may say its suggestions for it more than once, and only once you've paused
    /// typing (`searchPause`).
    private func searchIfFew() {
        let query = resultsQuery
        let few = results.count < Self.few && query.count >= 3
        if few, query == searchedQuery { return }
        searching?.cancel()
        searchedQuery = nil
        guard few else {
            found = []
            foundQuery = query
            return
        }
        searchedQuery = query
        let suggested = Set(results.map { $0.title.lowercased() })
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = completer.region
        request.regionPriority = completer.regionPriority
        request.resultTypes = [.address, .pointOfInterest]
        searching = Task {
            try? await Task.sleep(for: Self.searchPause)
            guard !Task.isCancelled else { return }
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
    NewTripView(showing: TripShowing(), startHeading: .constant(nil))
        .environment(SettingsStore())
}

/// Times `plan()`'s steps for the log: "server 1840 ms, rides 120 ms, …", each since the last.
/// Whichever answer comes first, handed to the one waiting; any after, let go.
private final class FirstAnswer<T: Sendable>: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<T?, Never>?, answered: T??)>((nil, nil))

    func waiting(_ continuation: CheckedContinuation<T?, Never>) {
        let answered = state.withLock { state -> T?? in
            guard let answered = state.answered else {
                state.continuation = continuation
                return nil
            }
            return answered
        }
        if let answered { continuation.resume(returning: answered) }
    }

    func answer(_ value: T?) {
        let continuation = state.withLock { state -> CheckedContinuation<T?, Never>? in
            guard state.answered == nil else { return nil }
            state.answered = .some(value)
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: value)
    }
}

private final class PlanClock {
    private let clock = ContinuousClock()
    private var last: ContinuousClock.Instant
    private var steps: [String] = []

    init() { last = clock.now }

    func mark(_ step: String) {
        let now = clock.now
        let ms = (now - last).components.attoseconds / 1_000_000_000_000_000 + (now - last).components.seconds * 1000
        steps.append("\(step) \(ms) ms")
        last = now
    }

    var summary: String { steps.joined(separator: ", ") }
}
