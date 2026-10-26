import CoreLocation
import MapKit
import Observation
import SwiftUI

/// One end of a New Trip: where you are, a station, or a place found on the map.
struct TripPlace: Hashable, Identifiable {
    var name: String
    var detail: String?
    /// Nil for where you are, which is looked up when the trip's planned.
    var point: Point?

    struct Point: Hashable {
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
        }
        shown = option
    }
}

/// Sends New Trip's picked trip to the Transit Directions widget: a glass capsule the height of
/// the shrunk tab bar's button beside it, grey until there's a trip.
struct ShowOnWidgetButton: View {
    let showing: TripShowing

    var body: some View {
        Button {
            showing.show()
        } label: {
            Label(showing.shown == nil ? "Show on Widget" : "Showing on Widget",
                  systemImage: showing.shown == nil ? "rectangle.on.rectangle" : "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: NewTripView.barHeight)
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
/// directions. The one picked shows on the Transit Directions widget for an hour, as a shared
/// trip does (`SharedTrip.show()`).
///
/// The map fills the screen, From and To over its top, From starting at where you are. A tap on
/// either opens its search field, the places to pick under them; once both are picked they shrink
/// into a window over the map's top left, which a tap opens again, and the trips float over the
/// map above the bar.
struct NewTripView: View {
    /// The picked trip, for Show on Widget.
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
    /// whether to include buses.
    private struct PlanKey: Equatable {
        var from: TripPlace?
        var to: TripPlace?
        var buses: Bool
        var located: Bool
        var locateFailed: Bool
        var status: CLAuthorizationStatus
        var attempt: Int
    }

    private var planKey: PlanKey {
        PlanKey(from: from, to: to, buses: settings.settings.includesBuses, located: location.location != nil, locateFailed: location.failed,
                status: location.status, attempt: attempt)
    }

    /// Bumped by Try Again, to plan again.
    @State private var attempt = 0
    @Environment(\.openURL) private var openURL
    @Environment(SettingsStore.self) private var settings

    /// The picked trip, once there are trips.
    private var pickedOption: ServerRoutes.Choice? {
        state == .ready && options.indices.contains(picked) ? options[picked] : nil
    }

    /// Whether From and To are shrunk into the window over the map, once both are picked.
    @State private var collapsed = false
    /// Whether the full tab bar shows. Otherwise it's shrunk to New Trip's button beside Show on
    /// Widget, as if the page were scrolled: drawn here, with the real tab bar hidden, as SwiftUI
    /// only shrinks it on a scroll. Full while the tab isn't showing, so arriving from another
    /// tab always shrinks it the same way.
    @State private var showsTabs = true
    /// Whether Show on Widget is out beside the shrunk bar's button. It bubbles out of the button
    /// once the bar has shrunk, and back in before the bar grows.
    @State private var showsWidgetButton = false
    /// The bar's shrinking or growing, in steps; a new one cancels it.
    @State private var tabsChange: Task<Void, Never>?
    /// The shrunk bar's glass, Show on Widget's morphing out of the button's.
    @Namespace private var barSpace
    /// The shrunk bar and home indicator's room at the bottom of the screen, under the trips.
    @State private var bottomRoom: CGFloat = 94
    /// From and To's height while they're open over the map.
    @State private var endsHeight: CGFloat = 105
    /// The trips' height, for the card's, which grows to `tripsHeight` with them.
    @State private var tripsContentHeight: CGFloat = 0
    /// From and To moving between the top and the window.
    @Namespace private var endsSpace

    /// The shrunk tab bar's height, its New Trip button's and Show on Widget's.
    static let barHeight: CGFloat = 56
    /// The trips' room over the map, above the bar: about two trips.
    private static let tripsHeight: CGFloat = 200
    /// From and To moving: slow enough to follow them.
    private static let endsAnimation = Animation.smooth(duration: 0.45)
    /// The tab bar shrinking and growing, close to the system's own on a scroll.
    private static let tabsAnimation = Animation.smooth(duration: 0.35)
    /// Show on Widget bubbling out of the shrunk bar's button: a little bounce, as glass does.
    private static let widgetOutAnimation = Animation.bouncy(duration: 0.45, extraBounce: 0.05)
    /// Show on Widget going back in: quick, so the tabs aren't kept waiting.
    private static let widgetInAnimation = Animation.smooth(duration: 0.22)

    /// Shows the full tab bar or shrinks it, the real bar, the shrunk one, and the trips over the
    /// map moving together. Explicit, as the tab bar's visibility only animates in a transaction.
    /// Shrinking, the bar goes down to New Trip's button and then Show on Widget bubbles out of
    /// it; growing, Show on Widget goes back in first.
    private func setShowsTabs(_ shows: Bool) {
        tabsChange?.cancel()
        tabsChange = Task {
            if shows {
                if showsWidgetButton {
                    withAnimation(Self.widgetInAnimation) { showsWidgetButton = false }
                    do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                }
                guard !showsTabs else { return }
                withAnimation(Self.tabsAnimation) { showsTabs = true }
            } else {
                if showsTabs {
                    withAnimation(Self.tabsAnimation) { showsTabs = false }
                    do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
                }
                guard !showsWidgetButton else { return }
                withAnimation(Self.widgetOutAnimation) { showsWidgetButton = true }
            }
        }
    }

    private var hasEnds: Bool { from != nil && to != nil }
    /// From and To open over the map's top: until both are picked, or once the window's tapped.
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
                    }
                    // Under the bar, its logo and Legal above it
                    .safeAreaPadding(.bottom, bottomRoom)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                    // Its size kept as the keyboard goes (`tripPage`)
                    .ignoresSafeArea(.keyboard)
                }
            }
            .overlay(alignment: .top) {
                if endsOpen {
                    endsCard
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                        .matchedGeometryEffect(id: "ends", in: endsSpace)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { endsHeight = $0 }
                        .padding(.horizontal, Self.margin)
                        .padding(.top, 8)
                }
            }
            // Inside the shrunk bar's inset, so its room counts, but not the keyboard's, which
            // would leave the map no room to frame anything in
            .background {
                Color.clear
                    .ignoresSafeArea(.keyboard)
                    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottom in
                        if !showsTabs { bottomRoom = bottom }
                    }
            }
            .background(Color(.systemGroupedBackground))
            // No title or toolbar: the tab says where you are, and swap is in the From and To card
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(showsTabs && picking == nil ? .visible : .hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom) {
                if !showsTabs, picking == nil {
                    shrunkBar
                        .transition(.blurReplace)
                }
            }
        }
        .onAppear {
            location.start()
        }
        // Arriving from another tab, the full bar shrinks once the switch has drawn, as if the
        // page were scrolled, rather than vanishing in the switch
        .task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            setShowsTabs(false)
        }
        // Leaving with the bar shrunk (a widget link), it's full again for next time
        .onDisappear {
            tabsChange?.cancel()
            showsTabs = true
            showsWidgetButton = false
        }
        .task(id: planKey) { await plan() }
        .onChange(of: pickedOption, initial: true) { _, option in showing.option = option }
    }

    /// Picking an end: From and To at the top, its search field focused, the places under them.
    private var pickingPage: some View {
        VStack(spacing: 0) {
            endsCard
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
                .matchedGeometryEffect(id: "ends", in: endsSpace)
                .padding(.horizontal, Self.margin)
                .padding(.top, 8)
            TripPlaceList(search: search, location: location, pick: pick)
        }
    }

    /// Once From and To are picked: the map the whole screen, the trips over it above the bar, and
    /// From and To shrunk to a window over its top left.
    private var tripPage: some View {
        ZStack(alignment: .topLeading) {
            mapArea
                // The trips framed clear of the window, or From and To while they're open, and
                // of the trips and the bar over them; reframed as From and To open and close
                .safeAreaPadding(.top, collapsed ? Self.windowRoom : endsHeight + 16)
                .safeAreaPadding(.bottom, bottomRoom + Self.tripsHeight + tripsGap)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                // The whole screen still while the keyboard's going after picking an end: shrunk
                // by it, the map had no room left to frame the trips in, and zoomed right out,
                // and growing back as it went, MapKit's drawing failed Metal's checks
                .ignoresSafeArea(.keyboard)
            if collapsed {
                endsWindow
                    .matchedGeometryEffect(id: "ends", in: endsSpace)
                    .padding(.leading, Self.margin)
                    .padding(.top, 8)
            }
        }
        .overlay(alignment: .bottom) {
            list
                .padding(.bottom, tripsGap)
        }
    }

    /// The window's room over the top of the map, under the status bar.
    private static let windowRoom: CGFloat = 70
    /// Between the trips and the bar under them: the shrunk bar has room above its buttons
    /// already; the full tab bar hasn't.
    private var tripsGap: CGFloat { showsTabs ? 8 : 0 }

    /// The trips on the map, or how planning's going.
    @ViewBuilder private var mapArea: some View {
        ZStack {
            if state == .ready {
                TripMap(options: options, picked: picked, start: ends?.start.coordinate,
                        end: ends?.end.coordinate, endName: to?.name ?? "")
            } else {
                // The map stays, how planning's going on a card over it
                Map(position: $startPosition, bounds: Self.cityBounds) {
                    UserAnnotation()
                }
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
        // A tap on the map shrinks From and To back into the window, and closes the change stations
        .simultaneousGesture(TapGesture().onEnded {
            closeStations()
            collapse()
        })
    }

    /// From and To shrunk into a window over the map's top left; a tap opens them again.
    private var endsWindow: some View {
        Button {
            setShowsTabs(false)
            withAnimation(Self.endsAnimation) { collapsed = false }
        } label: {
            HStack(spacing: 10) {
                // Where from and where to, joined as on the map
                VStack(spacing: 3) {
                    Image(systemName: from?.isHere == true ? "location.fill" : "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                    Capsule().fill(.tertiary).frame(width: 2, height: 10)
                    Circle().fill(.red).frame(width: 9, height: 9)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(from?.name ?? "")
                    Text(to?.name ?? "")
                }
                .font(.subheadline)
                .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 230, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From \(from?.name ?? "") to \(to?.name ?? "")")
        .accessibilityHint("Change where from or where to")
        .accessibilityAddTraits(.isButton)
    }

    /// The tab bar as if shrunk by a scroll: New Trip's button, which brings back the full tab
    /// bar, beside Show on Widget.
    private var shrunkBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    setShowsTabs(true)
                } label: {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: Self.barHeight, height: Self.barHeight)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID("tabs", in: barSpace)
                .accessibilityLabel("Show Tabs")
                if showsWidgetButton {
                    // Its glass morphs out of the button's, within the container's spacing, and
                    // its label blurs in as it does
                    ShowOnWidgetButton(showing: showing)
                        .glassEffectID("widget", in: barSpace)
                        .glassEffectTransition(.matchedGeometry)
                        .transition(.blurReplace)
                }
            }
            // The button stays put at the left while Show on Widget comes and goes
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    /// The trips once planned, best first, the picked one tinted: a card over the map above the
    /// bar, as tall as the trips up to `tripsHeight`, scrolling within it. A scroll view rather
    /// than a List, whose rows scroll out past the card's rounded corners. A tap on the picked
    /// trip, where it can change at more than one station, opens those stations under it in
    /// place of the other trips, each a switch, the card taller to fit them.
    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                if state == .ready {
                    ForEach(options.indices.filter { !stationsOpen || $0 == picked }, id: \.self) { index in
                        if index > 0, !stationsOpen {
                            // Under the text, past the bullets
                            Divider().padding(.leading, Self.margin + 64)
                        }
                        Button {
                            if index == picked, changeStations[index] != nil {
                                withAnimation(Self.stationsAnimation) { stationsOpen.toggle() }
                            } else {
                                picked = index
                            }
                            setShowsTabs(false)
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
                        changeStationList
                            .transition(.opacity)
                    }
                }
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            tripsContentHeight = height
        }
        .frame(height: min(stationsOpen ? Self.openTripsHeight : Self.tripsHeight, tripsContentHeight))
        .scrollBounceBehavior(.basedOnSize)
        // Scrolling the trips shrinks the tab bar again, and From and To into the window (not the
        // change stations, which may need scrolling to reach)
        .onScrollPhaseChange { _, phase in
            guard phase == .interacting else { return }
            setShowsTabs(false)
            collapse()
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(tripsContentHeight > 0 ? 0.15 : 0), radius: 10, y: 2)
        .padding(.horizontal, Self.margin)
    }

    /// The picked trip's change stations, under it: each station with the lines there and how
    /// it's changed to, a switch for whether the trip changes there.
    @ViewBuilder private var changeStationList: some View {
        if let stations = changeStations[picked], case .train(let option) = options[picked] {
            let onCount = stations.filter(\.on).count
            VStack(spacing: 0) {
                ForEach(stations.indices, id: \.self) { index in
                    if index > 0 {
                        Divider().padding(.leading, Self.margin + 64)
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
                    .padding(.leading, Self.margin + 64)
                    .padding(.trailing, Self.margin)
                    .padding(.vertical, 8)
                }
            }
            .background(Self.pickedBackground)
        }
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
                        withAnimation(Self.endsAnimation) {
                            picking = nil
                            collapsed = hasEnds
                        }
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
                TextField("Station or address", text: $search)
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
                setShowsTabs(false)
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

    /// Sets the end being picked, then moves From and To back down, or into the window once both
    /// are picked.
    private func pick(_ place: TripPlace) {
        guard let end = picking else { return }
        if end == .from { from = place } else { to = place }
        // Where you are is looked up (asking permission the first time) once it's needed
        if hasEnds, from?.isHere == true || to?.isHere == true { location.find() }
        searchFocused = false
        withAnimation(Self.endsAnimation) {
            picking = nil
            collapsed = hasEnds
        }
    }

    /// Shrinks From and To, open over the map, back into the window.
    private func collapse() {
        guard hasEnds, !collapsed, picking == nil else { return }
        withAnimation(Self.endsAnimation) { collapsed = true }
    }

    /// Plans again after a failure, looking you up again first where an end is where you are.
    private func retry() {
        if from?.isHere == true || to?.isHere == true { location.find() }
        attempt += 1
    }

    /// Works out the trips between the ends, once both are picked (and you're found, for an end
    /// that's where you are).
    private func plan() async {
        // Back on the tab, the trips planned for these ends stay, with the one picked
        guard planKey != plannedKey || state != .ready else { return }
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
        let planned = buses ? await ServerRoutes.planWithBuses(from: start, to: end)
            : await ServerRoutes.plan(from: start, to: end).map { ServerRoutes.Planned(choice: .train($0.option), trip: $0) }
        guard !Task.isCancelled else { return }
        guard !planned.isEmpty else {
            state = buses
                ? .failed(title: "No Trip Found",
                          message: "Leeway couldn't find a subway or bus trip between these places.", fix: .retry)
                : .failed(title: "No Subway on This Trip",
                          message: "Leeway couldn't find a subway trip between these places.", fix: .retry)
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
            changeStations[index] = change.stops.map { ChangeStation(change: $0, on: true) }
                + TripPlanner.otherChanges(for: trip).map { ChangeStation(change: $0, on: false) }
        }
        plannedKey = planKey
        state = .ready
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
/// station, or an address or place in New York City (MapKit's search).
private struct TripPlaceList: View {
    let search: String
    let location: NearbyLocation
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
            Section {
                Button {
                    pick(.here)
                } label: {
                    Label("Current Location", systemImage: "location.fill")
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
