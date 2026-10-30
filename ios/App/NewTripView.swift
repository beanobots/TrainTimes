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
/// them, From starting at where you are. A tap on either opens its search field over the
/// keyboard, the places to pick above it; once planned they shrink to a line atop the trips, which
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

    /// What a failed plan offers: trying again, or Settings to turn on Location Services.
    private enum Fix: Equatable {
        case retry, settings
    }

    @State private var from: TripPlace? = .here
    @State private var to: TripPlace?
    /// The end being picked, its search field open at the top.
    @State private var picking: End?
    @State private var search = ""
    /// Where the cursor is in `search`, for the number row to type there (`numberRow`).
    @State private var searchSelection: TextSelection?
    @FocusState private var searchFocused: Bool
    @State private var location = NearbyLocation()
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
                       walkMinutes: walkMinutes, bike: bikeKind, located: here && location.location != nil,
                       locateFailed: here && location.failed, status: here ? location.status : .notDetermined,
                       attempt: attempt, moved: moved)
    }

    /// How you'll go, remembered: by subway, and how far you'll walk
    /// to and from a ride (minutes, one of `walkChoices`). By bus is Settings' Include buses.
    @AppStorage("tripSubway") private var subway = true
    @AppStorage("tripWalkMinutes") private var walkMinutes = 15
    /// By Citi Bike too: a `CitiBike.Kind`'s raw value, or empty for off.
    @AppStorage("tripBike") private var bikeKind = ""

    private var bike: CitiBike.Kind? { CitiBike.Kind(rawValue: bikeKind) }
    /// The docks renting near From (`nearDockRange`), with their bikes and e-bikes, for the Bike
    /// menu; nil until they're known, or with none.
    @State private var nearDocks: [CitiBike.Dock]?

    /// How far you'll walk to and from a ride, as offered: its minutes, miles at 20 minutes a
    /// mile, and meters. 15 minutes first, as far as the planner looked before you could choose.
    static let walkChoices: [(minutes: Int, miles: String, meters: Double)] = [
        (15, "¾ mi", 1_207), (20, "1 mi", 1_609), (30, "1½ mi", 2_414), (45, "2¼ mi", 3_621), (60, "3+ mi", 4_828),
    ]

    /// A walk choice as shown: "15 min", the last "60+ min".
    static func walkLabel(_ minutes: Int) -> String {
        minutes == 60 ? "60+ min" : "\(minutes) min"
    }

    /// `walkMinutes`' place in `walkChoices`; the first if it's none of them.
    private var walkIndex: Int {
        Self.walkChoices.firstIndex { $0.minutes == walkMinutes } ?? 0
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
    /// + asking for a new place's name, before its address.
    @State private var namingPlace = false
    /// A visitor's Sightseeing list is open.
    @State private var sightseeing = false
    @State private var newPlaceName = ""
    /// The trips' height, for the card's, which grows to `tripsHeight` with them.
    @State private var tripsContentHeight: CGFloat = 0
    /// From and To moving between their card and the line atop the trips.
    @Namespace private var endsSpace
    /// Go's walks being asked for.
    @State private var startingWalk = false
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
                    Map(position: $startPosition, bounds: Self.cityBounds) {
                        UserAnnotation()
                        endPins
                    }
                    // Its logo and Legal over From and To, clear of the screen's rounded corner
                    .safeAreaPadding(.bottom, attributionRoom)
                    .safeAreaPadding(.leading, Self.attributionInset)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                    // Its size kept as the keyboard goes (`tripPage`)
                    .ignoresSafeArea(.keyboard)
                }
            }
            .overlay(alignment: .bottom) {
                if endsOpen {
                    VStack(spacing: 10) {
                        savedChips
                        VStack(spacing: 0) {
                            endsCard
                            Divider()
                            modesRow
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                        .matchedGeometryEffect(id: "ends", in: endsSpace)
                        .padding(.horizontal, Self.margin)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomCardsHeight = $0 }
                    .padding(.bottom, 8)
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
            if !subway && !settings.settings.includesBuses { subway = true }
            location.start()
            // Back on the tab, where you are now, for trips from or to it
            if hasEnds, from?.isHere == true || to?.isHere == true { location.find() }
        }
        .onChange(of: location.location) { _, here in relocate(here) }
        // A walk over, you're likely somewhere else: found again, to plan from there if so
        .onChange(of: ActiveWalk.shared.session == nil) { _, ended in
            if ended, hasEnds, from?.isHere == true || to?.isHere == true { location.find() }
        }
        // Planned once both ends are picked, the fastest drawn on the map behind From and To, and
        // again as what it waits on changes, such as the ways you'll go
        .task(id: hasEnds ? planKey : nil) { await plan() }
        // A walk isn't for the widget, nor a ride all the way
        .onChange(of: pickedOption, initial: true) { _, option in
            switch option {
            case .walk: showing.option = nil
            case .bike(let trip) where trip.train == nil: showing.option = nil
            default: showing.option = option
            }
        }
        // The dock nearest From, for the Bike menu's counts
        .task(id: nearDockKey) { await findNearDock() }
        .alert("Couldn't Get Walking Directions", isPresented: $walkFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(walkNoEntrance
                 ? "A station on this trip has no entrance listed, so there's no walk to it."
                 : "Apple Maps couldn't find a walk for this trip. Check your connection and try again.")
        }
    }

    /// Picking an end: From and To at the bottom over the keyboard, its search field focused,
    /// Home and Work over them, the places above.
    private var pickingPage: some View {
        VStack(spacing: 0) {
            TripPlaceList(search: search, location: location, pick: pick)
            // Setting Home or Work picks its place; they're not offered as it
            if setting == nil {
                savedChips
                    .padding(.bottom, 10)
            }
            endsCard
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .matchedGeometryEffect(id: "ends", in: endsSpace)
                .padding(.horizontal, Self.margin)
                .padding(.bottom, searchFocused ? 0 : 8)
        }
        // Over the keyboard while it's up
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if searchFocused { numberRow }
        }
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
            .safeAreaPadding(.top, Self.statusBarRoom)
            .safeAreaPadding(.bottom, attributionRoom)
            .safeAreaPadding(.leading, Self.attributionInset)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // The whole screen still while the keyboard's going after picking an end: shrunk
            // by it, the map had no room left to frame the trips in, and zoomed right out,
            // and growing back as it went, MapKit's drawing failed Metal's checks
            .ignoresSafeArea(.keyboard)
            .overlay(alignment: .bottom) {
                if collapsed {
                    VStack(spacing: 10) {
                        list
                        goBar
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bottomCardsHeight = $0 }
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
        .padding(.horizontal, Self.barMargin)
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
        min(stationsOpen ? Self.openTripsHeight : Self.tripsHeight, tripsContentHeight)
    }

    /// Under the map's logo and Legal: the tab bar and the cards over the map's bottom, so they
    /// show over the cards and the map frames what's left.
    private var attributionRoom: CGFloat { bottomRoom + bottomCardsHeight + 12 }

    /// The trips on the map, or how planning's going.
    @ViewBuilder private var mapArea: some View {
        ZStack {
            if state == .ready {
                TripMap(options: options, picked: picked, start: ends?.start.coordinate,
                        end: ends?.end.coordinate, endName: to?.name ?? "")
            } else {
                // The map stays with both ends on it, how planning's going on a card over it
                Map(position: $startPosition, bounds: Self.cityBounds) {
                    UserAnnotation()
                    endPins
                }
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
                    .padding(.horizontal, 40)
                }
            }
        }
        // A tap on the map shrinks From and To back to a line atop the trips, and closes the change stations
        .simultaneousGesture(TapGesture().onEnded {
            closeStations()
            collapse()
        })
    }

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
            startPosition = .userLocation(fallback: .region(Self.cityRegion))
        }
    }

    /// Opens From and To again in the trips' place.
    private func openEnds() {
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
            let rides = bike.bikeFirst ? ["bicycle"] + trains : trains + ["bicycle"]
            symbols = ["figure.walk"] + rides + ["figure.walk"]
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
        guard canGo, let ends else { return }
        // From where you are now, if From's there and you're found, else where it was planned from
        let start = from?.isHere == true ? location.location ?? ends.start : ends.start
        // Walking all the way: its walk from where you are now, if you've moved since it was
        // planned, else as planned
        if let planned = pickedWalk {
            startingWalk = true
            Task {
                defer { startingWalk = false }
                let moved = start.distance(from: ends.start) > Self.walkMoved
                let walk = moved ? (try? await WalkingDirections.walk(from: start, to: ends.end)) ?? planned : planned
                ActiveWalk.shared.begin(WalkSession(walk: walk, endName: to?.name ?? "", end: ends.end))
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
        Task {
            defer { startingWalk = false }
            let walks: WalkingDirections.TripWalks
            do {
                guard let found = try await WalkingDirections.walks(for: trip, from: start, to: ends.end) else {
                    walkNoEntrance = true
                    walkFailed = true
                    return
                }
                walks = found
            } catch {
                walkNoEntrance = false
                walkFailed = true
                return
            }
            // Over the whole app (`AppTabs`), carried on if iOS closes it
            ActiveWalk.shared.begin(WalkSession(trip: trip, walks: walks, endName: to?.name ?? "", end: ends.end))
        }
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
        .padding(.horizontal, Self.margin)
    }

    /// The trips in `list`, scrolling within it.
    private var tripRows: some View {
        ScrollView {
            VStack(spacing: 0) {
                if state == .ready {
                    ForEach(options.indices.filter { !stationsOpen || $0 == picked }, id: \.self) { index in
                        if index > 0, !stationsOpen {
                            // Under the text, past the bullets
                            Divider().padding(.leading, Self.margin + 64)
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
                                    BusTripRow(trip: trip, picked: index == picked)
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
                    }
                    if stationsOpen {
                        Group {
                            changeStationList
                            dockChoiceList
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            tripsContentHeight = height
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
            place = trip.train == nil || trip.bikeFirst ? ends?.start : trip.train?.endStation.map(Self.location(of:))
        } else {
            place = trip.train == nil || !trip.bikeFirst ? ends?.end : trip.train?.selection.station.map(Self.location(of:))
        }
        guard let place else { return nil }
        let dock = pickup ? trip.pickup.location : trip.dropoff.location
        return max(1, Int((TripPlanner.walkSeconds(place.distance(from: dock)) / 60).rounded()))
    }

    private static func location(of station: Station) -> CLLocation {
        CLLocation(latitude: station.lat, longitude: station.lon)
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

    /// From and To, each a tap to pick, and swapping them; while one's picked, its search field,
    /// and closing it in swap's place.
    private var endsCard: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                endRow("From", end: .from, place: from)
                Divider().padding(.leading, Self.margin)
                endRow("To", end: .to, place: to)
            }
            Group {
                if picking != nil {
                    Button {
                        searchFocused = false
                        setting = nil
                        withAnimation(Self.endsAnimation) { picking = nil }
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(.quaternary, in: Circle())
                    }
                } else {
                    Button {
                        swap(&from, &to)
                    } label: {
                        Label("Swap From and To", systemImage: "arrow.up.arrow.down")
                            .labelStyle(.iconOnly)
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(.quaternary, in: Circle())
                    }
                    .disabled(from == nil && to == nil)
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, Self.margin)
        }
    }

    @ViewBuilder
    private func endRow(_ title: String, end: End, place: TripPlace?) -> some View {
        if picking == end {
            HStack(spacing: 12) {
                Text(title)
                TextField(setting.map { "\(saved.name($0)) address" } ?? "Station or address",
                          text: $search, selection: $searchSelection)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    // The keyboard opens with the field
                    .onAppear { searchFocused = true }
            }
            .padding(.horizontal, Self.margin)
            .frame(minHeight: 52)
        } else {
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
    }

    /// How you'll go, one row: Subway and Bus each a toggle (one always on), Citi Bike a menu
    /// (off, bike or e-bike), how far you'll walk to and from a ride as a menu, and Plan Trip as a
    /// round arrow at the end. Walking all the way is always offered where it's worth it.
    private var modesRow: some View {
        HStack(spacing: 8) {
            modeToggle("Subway", "tram.fill", on: $subway)
            modeToggle("Bus", "bus.fill", on: Bindable(settings).settings.includesBuses)
            bikeMenu
            walkMenu
            Spacer(minLength: 0)
            planTripButton
        }
        .padding(.leading, Self.margin)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    /// A way to go, an icon tinted while it's on; the last one on can't be turned off.
    private func modeToggle(_ name: String, _ symbol: String, on: Binding<Bool>) -> some View {
        let onCount = [subway, settings.settings.includesBuses].filter { $0 }.count
        return Button {
            // Not disabled while it's the last on, which would fade it as if it were off
            guard !(on.wrappedValue && onCount == 1) else { return }
            on.wrappedValue.toggle()
        } label: {
            Label(name, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on.wrappedValue ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 48, height: 38)
                .background(on.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
        .accessibilityHint("Offers trips by \(name.lowercased())")
    }

    /// How far you'll walk to and from a ride, a pick of `walkChoices`.
    private var walkMenu: some View {
        Menu {
            Picker("Walk up to", selection: $walkMinutes) {
                ForEach(Self.walkChoices, id: \.minutes) { choice in
                    Text(Self.walkLabel(choice.minutes))
                        .badge(Text(choice.miles))
                        .tag(choice.minutes)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "figure.walk")
                Text(Self.walkLabel(walkChoice.minutes))
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Walk up to")
        .accessibilityValue(walkChoice.minutes == 60 ? "60 minutes or more, 3 miles or more"
                                                     : "\(walkChoice.minutes) minutes, \(walkChoice.miles)")
    }

    /// By Citi Bike too, a menu: off, by bike or by e-bike, each with how many there are at the
    /// docks near From. Tinted while on, a bolt badge on it for e-bikes.
    private var bikeMenu: some View {
        Menu {
            Picker("Citi Bike", selection: $bikeKind) {
                Text("Off").tag("")
                ForEach(CitiBike.Kind.allCases, id: \.self) { kind in
                    Label {
                        Text(kind.name)
                        if let nearDocks {
                            Text(Self.nearby(kind, at: nearDocks))
                        }
                    } icon: {
                        Image(systemName: kind == .eBike ? "bolt.fill" : "bicycle")
                    }
                    .tag(kind.rawValue)
                }
            }
        } label: {
            Image(systemName: "bicycle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(bike != nil ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 48, height: 38)
                .background(bike != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if bike == .eBike {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(.yellow))
                            .offset(x: 3, y: -3)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Citi Bike")
        .accessibilityValue(bike?.name ?? "Off")
        .accessibilityHint("Offers trips with a Citi Bike")
    }

    /// How many of `kind` there are at `docks`: "5 at Bergen St & 5 Av" where one has any,
    /// "23 at 3 docks nearby" where several do.
    private static func nearby(_ kind: CitiBike.Kind, at docks: [CitiBike.Dock]) -> String {
        let having = docks.filter { $0.available(kind) > 0 }
        let total = having.reduce(0) { $0 + $1.available(kind) }
        switch having.count {
        case 0: return "None nearby"
        case 1: return "\(total) at \(having[0].name)"
        default: return "\(total) at \(having.count) docks nearby"
        }
    }

    /// Where the Bike menu's docks are looked for near, to about a block: From, or where you are.
    private var nearDockKey: String? {
        guard let place = from?.location ?? location.location else { return nil }
        return String(format: "%.3f,%.3f", place.coordinate.latitude, place.coordinate.longitude)
    }

    /// Meters the Bike menu's docks may be from From.
    private static let nearDockRange: Double = 500

    /// Finds the docks near From with their counts now, for the Bike menu.
    private func findNearDock() async {
        guard let place = from?.location ?? location.location else {
            nearDocks = nil
            return
        }
        let docks = await CitiBike.docks()
        // Not over the docks for where From is now, as a cancelled fetch comes back with none
        guard !Task.isCancelled else { return }
        guard let docks else {
            nearDocks = nil
            return
        }
        let near = docks.filter { $0.renting && place.distance(from: $0.location) <= Self.nearDockRange }
        nearDocks = near.isEmpty ? nil : near
    }

    /// Shrinks From and To to a line atop the trips, planned for them the ways picked as soon as
    /// both were.
    private var planTripButton: some View {
        Button {
            closeStations()
            withAnimation(Self.endsAnimation) { collapsed = true }
        } label: {
            Label("Plan Trip", systemImage: "arrow.right")
                .labelStyle(.iconOnly)
                .font(.body.weight(.bold))
                .foregroundStyle(hasEnds ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 44, height: 44)
                .background(hasEnds ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!hasEnds)
    }

    /// Sets the end being picked, then moves From and To back down, or to a line atop the trips once both
    /// are picked.
    private func pick(_ place: TripPlace) {
        guard let end = picking else { return }
        var place = place
        // Setting Home or Work: saved, where you are by where you're found
        if let slot = setting {
            let point = place.point ?? location.location.map {
                TripPlace.Point(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            }
            if let point {
                let slot = saved.set(slot, to: TripPlace(name: place.name, detail: place.detail, point: point))
                place = saved.place(slot) ?? place
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
    /// picked); one not set yet asks for its place. A long press changes or forgets it. + after
    /// them adds another, asking its name and then its place. They scroll once past the screen.
    private var savedChips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
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
        return Button {
            useSaved(slot)
        } label: {
            Label(name, systemImage: saved.symbol(slot))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(place == nil && slot != .sightseeing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contextMenu {
            if place != nil {
                Button("Change \(name)…", systemImage: "pencil") { setSaved(slot) }
                Button("Forget \(name)", systemImage: "trash", role: .destructive) { saved.set(slot, to: nil) }
            }
        }
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
    /// city's bounds at their far corner (Perth Amboy) until it found you.
    private func frameEnds() {
        guard hasEnds else { return }
        frameStart(on: [from?.location ?? location.location, to?.location ?? location.location].compactMap { $0 })
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
        guard let start = from.location ?? location.location, let end = to.location ?? location.location else {
            // Waits for your location; this runs again once it's found
            state = .planning
            frameStart(on: [from.location, to.location].compactMap { $0 })
            return
        }
        state = .planning
        frameStart(on: [start, end])
        let buses = settings.settings.includesBuses
        // By subway too if Settings turned buses off with it off
        let subway = self.subway || !buses
        let walkRange = walkChoice.meters
        // Walking all the way, asked of Apple Maps while the trains are planned, and Citi Bike's trips
        async let walking = try? WalkingDirections.walk(from: start, to: end)
        async let biking = Self.bikeTrips(bike, from: start, to: end, subway: subway, walkRange: walkRange)
        var planned: [ServerRoutes.Planned] = []
        if buses {
            planned = await ServerRoutes.planWithBuses(from: start, to: end, walkRange: walkRange)
            // By bus only: no train on the way
            if !subway {
                planned.removeAll {
                    guard case .bus(let trip) = $0.choice else { return true }
                    return trip.train != nil
                }
            }
        } else if subway {
            planned = await ServerRoutes.plan(from: start, to: end, walkRange: walkRange)
                .map { ServerRoutes.Planned(choice: .train($0.option), trip: $0) }
        }
        guard !Task.isCancelled else { return }
        let walk = await walking
        let bikeTrips = await biking
        guard !Task.isCancelled else { return }
        guard !planned.isEmpty || walk != nil || !bikeTrips.isEmpty else {
            let by = [subway ? "subway" : nil, buses ? "bus" : nil, bike != nil ? "bike" : nil].compactMap { $0 }
                .joined(separator: " or ")
            state = .failed(title: "No Trip Found",
                            message: "Leeway couldn't find a \(by) trip between these places with up to a \(walkChoice.minutes) min walk.",
                            fix: .retry)
            return
        }
        options = planned.map(\.choice)
        trips = planned.map(\.trip)
        plannedAt = .now
        ends = (start, end)
        // Trips with a bus aren't in the timetable
        minutes = trips.map { $0.flatMap(minutes(of:)) }

        for (index, trip) in trips.enumerated() {
            guard let trip, let change = trip.change,
                  Set(change.stops.compactMap { $0.station?.complex }).count > 1 else { continue }
            let all = change.stops.map { ChangeStation(change: $0, on: true) }
                + TripPlanner.otherChanges(for: trip).map { ChangeStation(change: $0, on: false) }
            let kept = withoutNeedlessWalks(all, for: trip)
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
            minutes[index] = minutes(of: changed)
        }
        // Walking all the way, if it's not far, as quick as the trains, or all there is
        let walkAllMinutes = walk.map(WalkTripRow.minutes(of:))
        if let walk, let walkMinutes = walkAllMinutes {
            dropTrips(slowerThan: walkMinutes)
            let fastest = minutes.compactMap { $0 }.min()
            if walkMinutes <= Self.walkOffered || fastest.map({ walkMinutes <= $0 }) ?? true {
                options.append(.walk(walk))
                trips.append(nil)
                minutes.append(walkMinutes)
            }
        }
        // With a bike: to or from a train where it beats every trip without one; all the way
        // where it's not long or beats them too. None slower than walking all the way.
        let fastest = minutes.compactMap { $0 }.min()
        for trip in bikeTrips where walkAllMinutes.map({ trip.minutes < $0 }) ?? true {
            let beats = fastest.map { trip.minutes < $0 } ?? true
            guard beats || (trip.train == nil && trip.minutes <= Self.rideOffered) else { continue }
            options.append(.bike(trip))
            trips.append(nil)
            minutes.append(trip.minutes)
        }
        sortByMinutes()
        plannedKey = planKey
        state = .ready
    }

    /// Longest ride all the way offered beside quicker trips.
    private static let rideOffered = 45

    /// Citi Bike's trips by `kind`, or none with Bike off (`BikePlanner`).
    private static func bikeTrips(_ kind: CitiBike.Kind?, from start: CLLocation, to end: CLLocation,
                                  subway: Bool, walkRange: Double) async -> [BikeTrip] {
        guard let kind else { return [] }
        return await BikePlanner.plan(from: start, to: end, kind: kind, subway: subway, walkRange: walkRange)
    }

    /// Leaves out the trips timed to take longer than walking all the way (`walkMinutes`): a
    /// mile's walk away from where you are to ride one stop back toward it. Trips it can't time
    /// (by bus) stay.
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
    /// worse than its minutes, which put a slower trip without one first. Trips it can't time (by
    /// bus) keep their places, and those it can fill the others in order; ties keep theirs.
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
    private func withoutNeedlessWalks(_ stations: [ChangeStation], for trip: TripPlanner.Trip) -> [ChangeStation] {
        guard stations.count > 2 else { return stations }
        let selection = trip.selection
        // When it gets there changing at just one of them
        func arrival(_ station: ChangeStation) -> Date? {
            guard let ends, let timetable = TimetableStore.load(now: plannedAt),
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
    private func frameStart(on places: [CLLocation]) {
        guard !places.isEmpty else {
            startPosition = .region(Self.cityRegion)
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
        withAnimation(.smooth) { startPosition = .rect(rect.insetBy(dx: -dx, dy: -dy)) }
    }

    /// `trip`'s minutes door to door by the timetable, leaving when the trips were planned; nil
    /// without a timetable, or where it can't time it.
    private func minutes(of trip: TripPlanner.Trip) -> Int? {
        guard let ends, let timetable = TimetableStore.load(now: plannedAt),
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
/// badge or bullet, where from and to, and the ride after the first.
private struct BusTripRow: View {
    let trip: BusTrip
    let picked: Bool

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
                HStack(spacing: 4) {
                    if let train = trip.train {
                        if trip.busFirst {
                            Text("Bus to \(train.selection.station?.name ?? trip.bus.to.name), then")
                            LineBullets(routes: train.selection.routes, size: 14)
                        } else {
                            Text("Change at \(train.endStation?.name ?? trip.bus.from.name) to")
                            BusBadge(line: trip.bus.line, size: 14)
                        }
                    } else {
                        Text(trip.bus.headsign.map { "Bus to \($0)" } ?? "Bus")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
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

/// The places to pick for one end of a New Trip, under its search field: where you are, a
/// station, or an address or place in New York City (MapKit's search). First-run setup's place
/// search too, without where you are.
struct TripPlaceList: View {
    let search: String
    let location: NearbyLocation
    /// Offers Current Location first.
    var offersHere = true
    let pick: (TripPlace) -> Void

    /// Made once the list shows, not each time New Trip makes the list again.
    @State private var completer: PlaceCompleter?
    /// The place being looked up after a tap.
    @State private var resolving: MKLocalSearchCompletion?
    /// Places looked up and found too far from the subway to plan from.
    @State private var tooFar: Set<MKLocalSearchCompletion> = []

    private var stations: [Station] {
        let query = StationSearch(search)
        return Array(StationDirectory.all.filter { query.matches($0) }.prefix(search.isEmpty ? 0 : 8))
    }

    /// Addresses and places for the search, from two letters, when they're for what's typed.
    private var places: [MKLocalSearchCompletion] {
        search.count < 2 ? [] : completer?.results(for: search) ?? []
    }

    /// Closest stations, when there's no search.
    private var nearby: [Station] {
        guard search.isEmpty, let here = location.location else { return [] }
        return Nearby.stations(near: here, limit: 4).map(\.station)
    }

    var body: some View {
        List {
            if offersHere {
                Section {
                    Button {
                        pick(.here)
                    } label: {
                        Label("Current Location", systemImage: "location.fill")
                    }
                }
            }

            if !nearby.isEmpty {
                Section("Stations near you") {
                    ForEach(nearby) { station in
                        stationButton(station)
                    }
                }
            }

            if !stations.isEmpty {
                Section("Stations") {
                    ForEach(stations) { station in
                        stationButton(station)
                    }
                }
            }

            if !places.isEmpty {
                Section("Places") {
                    ForEach(places, id: \.self) { result in
                        Button {
                            Task { await choose(result) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title).foregroundStyle(.primary)
                                    if tooFar.contains(result) {
                                        Text("More than 5 miles from the subway").font(.caption).foregroundStyle(.red)
                                    } else if !result.subtitle.isEmpty {
                                        Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if resolving == result { ProgressView() }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(resolving != nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 12, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        // Looked up once typing pauses, so a search isn't overtaken by the next letter's
        .task(id: search) {
            let completer = completer ?? PlaceCompleter()
            self.completer = completer
            if !search.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            completer.query = search
        }
    }

    private func stationButton(_ station: Station) -> some View {
        Button {
            pick(TripPlace(station: station))
        } label: {
            StationRow(station: station, isSelected: false)
        }
    }

    /// Looks up where a search result is, then picks it if it's within `PlaceCompleter.reach` of
    /// a station. The completer only suggests places in the box around them, so this catches the
    /// corners of it, such as Newark.
    private func choose(_ result: MKLocalSearchCompletion) async {
        guard !tooFar.contains(result) else { return }
        resolving = result
        defer { resolving = nil }
        let request = MKLocalSearch.Request(completion: result)
        request.region = PlaceCompleter.served
        request.regionPriority = .required
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        guard let nearest = Nearby.nearest(to: item.location), nearest.meters <= PlaceCompleter.reach else {
            tooFar.insert(result)
            return
        }
        let coordinate = item.location.coordinate
        pick(TripPlace(name: result.title, detail: result.subtitle,
                       point: TripPlace.Point(latitude: coordinate.latitude, longitude: coordinate.longitude)))
    }
}

/// MapKit's suggestions for addresses and places near the subway as you type.
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
        let latitudePad = reach / 111_000
        let longitudePad = reach / (111_000 * cos(center.latitude * .pi / 180))
        return MKCoordinateRegion(center: center,
                                  span: MKCoordinateSpan(latitudeDelta: north - south + latitudePad * 2,
                                                         longitudeDelta: east - west + longitudePad * 2))
    }()

    private(set) var results: [MKLocalSearchCompletion] = []
    /// What `results` were found for.
    private(set) var resultsQuery = ""

    /// The results for `query`, none while they're still for what was typed before it.
    func results(for query: String) -> [MKLocalSearchCompletion] {
        query == resultsQuery ? results : []
    }
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    var query = "" {
        didSet { completer.queryFragment = query }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.region = Self.served
        completer.regionPriority = .required
        completer.resultTypes = [.address, .pointOfInterest]
    }

    // The completer calls back on the main thread
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            results = completer.results
            resultsQuery = completer.queryFragment
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            results = []
            resultsQuery = completer.queryFragment
        }
    }
}

#Preview {
    NewTripView(showing: TripShowing())
        .environment(SettingsStore())
}
