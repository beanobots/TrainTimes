import CoreLocation
import MapKit
import SwiftUI

/// New Widget: Subway or Bus first, then that kind's steps (a train's Station → Lines →
/// Direction; a bus's Stop → Route → Direction), which hand `done` the widget to name. With
/// `kind`, straight to that kind's steps, to change a widget's bus. Citi Bike docks are the
/// Citi Bike widget's, picked in its Edit menu.
struct NewWidgetPicker: View {
    var kind: SavedRouteKind? = nil
    /// The route whose departure is being changed: its train is ticked and kept as the start,
    /// and a subway or bus route can switch between Stations and Stops.
    var editing: SavedWidget? = nil
    let done: (SavedWidget) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @State private var path: [Step] = []
    /// Stations or Stops, once switched from `kind`'s.
    @State private var departure: SavedRouteKind?

    /// The train being changed, if `editing` is a subway route.
    private var editingTrain: Selection? {
        editing?.kind == .subway ? editing?.selection : nil
    }

    enum Step: Hashable {
        case station
        case lines(Station, chosen: [String])
        case direction(Station, routes: [String])
        case busStop
        case busRoute(NearbyBusPlace)
        case busDirection(NearbyBusPick, stopName: String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { dismiss() }
                    }
                }
                .navigationDestination(for: Step.self, destination: step)
        }
    }

    @ViewBuilder private var root: some View {
        switch kind {
        case nil:
            KindStep { kind in
                switch kind {
                // From your Home Station; From, To and the ways there are planned on the route's page
                case .subway, .bike: finish(SavedWidget(selection: subwayStart))
                case .bus: path.append(.busStop)
                }
            }
        case .subway, .bus, .bike:
            if editing != nil {
                departureStep
            } else if kind == .subway {
                stationStep
            } else {
                busStopStep
            }
        }
    }

    /// A route's departure: its stations or stops, with a switch between them at the top.
    @ViewBuilder private var departureStep: some View {
        let showing = Binding { departure ?? kind ?? .subway } set: { departure = $0 }
        Group {
            if showing.wrappedValue == .bus { busStopStep } else { stationStep }
        }
        .safeAreaBar(edge: .top) {
            Picker("Depart from", selection: showing) {
                Text("Stations").tag(SavedRouteKind.subway)
                Text("Stops").tag(SavedRouteKind.bus)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private func step(_ step: Step) -> some View {
        switch step {
        case .station:
            stationStep
        case .lines(let station, let chosen):
            LinesStep(station: station, chosen: chosen) { routes in
                path.append(.direction(station, routes: routes))
            }
        case .direction(let station, let routes):
            let same = station.id == editingTrain?.stationID && routes == editingTrain?.routes
            DirectionStep(station: station, routes: routes, current: same ? editingTrain?.direction : nil,
                          offersBoth: true, bothCurrent: same && editing?.bothWays == true) { direction, both in
                // The route's own train kept as the start, so its alert switches stay
                var selection = editingTrain ?? settings.defaultTrain
                selection.stationID = station.id
                selection.routes = routes
                selection.direction = direction
                finish(SavedWidget(selection: selection, bothWays: both))
            }
        case .busStop:
            busStopStep
        case .busRoute(let place):
            BusRouteStep(place: place) { pick in
                path.append(.busDirection(pick, stopName: place.name))
            }
        case .busDirection(let pick, let stopName):
            BusDirectionStep(pick: pick, stopName: stopName) { finish(.bus($0)) }
        }
    }

    private var stationStep: some View {
        StationStep(chosenID: editingTrain?.stationID) { station, filter in
            if station.routes.count == 1 {
                path.append(.direction(station, routes: station.routes))
            } else {
                let current = station.id == editingTrain?.stationID ? editingTrain?.routes ?? [] : []
                let chosen = filter.map { label in station.routes.filter { LineStyle.of($0).label == label } } ?? current
                path.append(.lines(station, chosen: chosen))
            }
        }
    }

    private var busStopStep: some View {
        BusStopStep { place in
            // One line there: straight to its direction
            let lines = place.lines(at: AppClock.now)
            if lines.count == 1, let line = lines.first {
                path.append(.busDirection(line, stopName: place.name))
            } else {
                path.append(.busRoute(place))
            }
        }
    }

    /// Where a new subway route starts: your Home Station, all its lines.
    private var subwayStart: Selection {
        var start = settings.defaultTrain
        if let station = start.station { start.routes = station.routes }
        return start
    }

    private func finish(_ widget: SavedWidget) {
        done(widget)
        dismiss()
    }
}

// MARK: - Kind

/// The first page: Subway and Bus, each with a sample from where you are: your Home Station's
/// lines (else the nearest station's), the nearest stop's routes. Without them, just the icon
/// and name.
private struct KindStep: View {
    let pick: (SavedRouteKind) -> Void
    @Environment(SettingsStore.self) private var settings
    @State private var location = NearbyLocation()
    @State private var busLines: [String] = []

    /// Home Station's lines, else the nearest station's.
    private var subwayLines: [String] {
        if let home = settings.defaultTrain.station, settings.defaultTrain.stationID != Selection.fallback.stationID {
            return home.routes
        }
        guard let here = location.location else { return [] }
        return Nearby.stations(near: here, among: StationDirectory.all).first?.station.routes ?? []
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                tile(.subway, tint: .black, value: Lines.spokenList(Array(subwayLines.prefix(5)))) {
                    if !subwayLines.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(subwayLines.prefix(5), id: \.self) { LineBullet(route: $0, size: 26) }
                        }
                    }
                }
                tile(.bus, tint: BusBadge.blue, value: Lines.joined(Array(busLines.prefix(3)))) {
                    if !busLines.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(busLines.prefix(3), id: \.self) { BusBadge(line: $0, size: 26) }
                        }
                    }
                }
                Text("Citi Bike docks are now their own widget. Add the Citi Bike widget from the Home Screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("New Route")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            location.start()
            // Only where you've already allowed it: this page doesn't ask
            if location.isAllowed { location.find() }
        }
        // Again once you've moved about 100 m, as the server keys its answers, not with each fix
        .task(id: location.location.map { String(format: "%.3f,%.3f", $0.coordinate.latitude, $0.coordinate.longitude) }) {
            guard let here = location.location else { return }
            let places = await NearbyBuses.places(near: here, wait: NearbyBuses.appWait)
            busLines = places?.first?.lines(at: AppClock.now).map(\.line) ?? []
        }
    }

    private func tile(_ kind: SavedRouteKind, tint: Color, value: String,
                      @ViewBuilder sample: () -> some View) -> some View {
        Button {
            pick(kind)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(tint))
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.name).font(.title3.bold())
                    sample()
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle.pickerCard)
            .contentShape(RoundedRectangle.pickerCard)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.name)
        // What the sample shows: the lines near you, or the dock's counts
        .accessibilityValue(value)
    }
}

// MARK: - Bus

/// "0.1 mi".
private func distance(_ meters: Double) -> String {
    Nearby.distance(meters)
}

/// Where a search for a street or place is, in New York, for stops or docks near it.
func findPlace(_ text: String) async -> CLLocation? {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = text
    request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 40.71, longitude: -73.95),
                                        latitudinalMeters: 50_000, longitudinalMeters: 50_000)
    guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
    return item.location
}

/// Bus step 1: the stops near you, or near a street or place searched for, each with its routes.
private struct BusStopStep: View {
    let pick: (NearbyBusPlace) -> Void
    @Environment(\.openURL) private var openURL
    @State private var location = NearbyLocation()
    @State private var search = ""
    @State private var places: [NearbyBusPlace]?
    @State private var failed = false
    /// Searched for, rather than near you.
    @State private var searched: String?

    var body: some View {
        List {
            if searched == nil, !location.isAllowed {
                Section {
                    Button {
                        // Denied: find() asks nothing, so Settings is where to turn it on
                        if location.status == .denied, let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        } else {
                            location.find()
                        }
                    } label: {
                        Label("Show stops near you", systemImage: "location")
                    }
                } footer: {
                    Text("Or search for a street or place.")
                }
            }
            if let places {
                Section {
                    if places.isEmpty {
                        Text("No bus stops within a quarter mile").foregroundStyle(.secondary)
                    }
                    ForEach(places, id: \.self) { place in
                        Button {
                            pick(place)
                        } label: {
                            row(place)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text(searched.map { "Near \($0)" } ?? "Near you")
                }
            } else if failed {
                Section {
                    Text("Couldn't reach Bus Time").foregroundStyle(.secondary)
                }
            } else if searched == nil, location.failed, location.location == nil {
                // Allowed, but no fix came: said so, as Nearby does, not "Finding stops…" forever
                Section {
                    Label("Couldn't Find You", systemImage: "location.slash").foregroundStyle(.secondary)
                    Button("Try Again") { location.find() }
                } footer: {
                    Text("Your location isn't available right now.")
                }
            } else if location.isAllowed || searched != nil {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Finding stops…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search streets or places")
        .onSubmit(of: .search) {
            let text = search.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            Task { await find(near: findPlace(text), named: text) }
        }
        .onChange(of: search) { _, text in
            // Cleared: back to near you
            if text.isEmpty, searched != nil {
                searched = nil
                places = nil
                Task { await find(near: location.location, named: nil) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Stop", step: 0) }
        }
        .onAppear {
            location.start()
            if location.isAllowed { location.find() }
        }
        // Again once you've moved about 100 m, as the server keys its answers, not with each fix
        .task(id: location.location.map { String(format: "%.3f,%.3f", $0.coordinate.latitude, $0.coordinate.longitude) }) {
            guard searched == nil, let here = location.location else { return }
            await find(near: here, named: nil)
        }
    }

    private func find(near place: CLLocation?, named name: String?) async {
        searched = name
        failed = false
        guard let place else {
            places = []
            return
        }
        places = nil
        let found = await NearbyBuses.places(near: place, wait: NearbyBuses.appWait)
        // Not stops near you landing after a search's, under its "Near …", or the other way round
        guard searched == name else { return }
        failed = found == nil
        places = found
    }

    private func row(_ place: NearbyBusPlace) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                HStack(spacing: 4) {
                    ForEach(place.lines(at: AppClock.now).prefix(5).map(\.line), id: \.self) { BusBadge(line: $0, size: 16) }
                }
            }
            Spacer()
            Text(distance(place.meters))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Bus step 2: the stop's routes, each with where it goes each way.
private struct BusRouteStep: View {
    let place: NearbyBusPlace
    let pick: (NearbyBusPick) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("Pick the bus to show").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 14) {
                    let lines = place.lines(at: AppClock.now)
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        if index > 0 { Divider() }
                        Button {
                            pick(line)
                        } label: {
                            HStack(spacing: 12) {
                                BusBadge(line: line.line, size: 32)
                                Text(line.ways.map(\.name).joined(separator: " – "))
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if lines.isEmpty {
                        Text("No buses predicted here now").foregroundStyle(.secondary)
                    }
                }
                .pickerCard()
            }
            .padding(.horizontal, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Bus", step: 1) }
        }
    }
}

/// Bus step 3: which way, as a train's Direction tiles in bus blue, with Both where it goes two.
struct BusDirectionStep: View {
    let pick: NearbyBusPick
    let stopName: String
    /// The way ticked, by index in `pick.ways`, and whether Both is; nil for none.
    var chosen: Int? = nil
    var bothChosen = false
    let done: (BusChoice) -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    private func choice(_ index: Int, both: Bool) -> BusChoice {
        let way = pick.ways[index]
        let other = pick.ways.indices.first { $0 != index }.map { pick.ways[$0] }
        return BusChoice(line: pick.line, stop: way.stop, destination: way.destination, otherStop: other?.stop,
                         otherDestination: other?.destination, bothWays: both && other != nil)
    }

    var body: some View {
        let tiles = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    BusBadge(line: pick.line, size: 44)
                    Text(stopName).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("Which way are you going?").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    tiles {
                        ForEach(pick.ways.indices, id: \.self) { tile($0, now: AppClock.pretend(context.date)) }
                    }
                }
                if pick.ways.count == 2 {
                    Button {
                        done(choice(0, both: true))
                    } label: {
                        HStack(spacing: 14) {
                            disc("arrow.up.arrow.down")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Both directions").font(.headline)
                                Text("Each way side by side on medium and large")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if chosen != nil || bothChosen { ChosenMark(chosen: bothChosen) }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle.pickerCard)
                        .overlay {
                            if bothChosen { RoundedRectangle.pickerCard.strokeBorder(Color.accentColor, lineWidth: 3) }
                        }
                        .contentShape(RoundedRectangle.pickerCard)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(bothChosen ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Direction", step: 2) }
        }
    }

    private func disc(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(BusBadge.blue))
            .accessibilityHidden(true)
    }

    /// "N" as "Northbound", with its arrow.
    private func compass(_ direction: String?) -> (name: String, symbol: String)? {
        switch direction?.uppercased() {
        case "N": ("Northbound", "arrow.up")
        case "S": ("Southbound", "arrow.down")
        case "E": ("Eastbound", "arrow.right")
        case "W": ("Westbound", "arrow.left")
        case "NE": ("Northeast", "arrow.up.right")
        case "NW": ("Northwest", "arrow.up.left")
        case "SE": ("Southeast", "arrow.down.right")
        case "SW": ("Southwest", "arrow.down.left")
        default: nil
        }
    }

    private func tile(_ index: Int, now: Date) -> some View {
        let way = pick.ways[index]
        let compass = compass(way.stop.direction)
        let coming = way.arrivals.compactMap(\.time).filter { $0 > now }
        return Button {
            done(choice(index, both: false))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    disc(compass?.symbol ?? "arrow.forward")
                    Spacer()
                    if chosen != nil || bothChosen { ChosenMark(chosen: chosen == index && !bothChosen) }
                }
                Spacer(minLength: 18)
                if let compass {
                    Text(compass.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(way.name).font(.title3.bold()).lineLimit(2, reservesSpace: true)
                Spacer(minLength: 10)
                if let next = coming.first {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(MinutesToGo(until: next, from: now).number)
                            .font(.system(.title, design: .rounded, weight: .bold))
                        Text("min").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Color.liveText)
                    let then = coming.dropFirst().prefix(2).map { "\(MinutesToGo(until: $0, from: now).count)" }
                    if !then.isEmpty {
                        Text("then \(then.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .chosenRing(chosen == index && !bothChosen)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen == index && !bothChosen ? .isSelected : [])
        // The minutes as one phrase, not "5, min, then 7, 12"
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([compass?.name, way.name].compactMap(\.self).joined(separator: ", "))
        .accessibilityValue(spokenMinutes(coming, now: now))
        .accessibilityAddTraits(.isButton)
    }

    /// "Next in 5 minutes, then 7 and 12 minutes".
    private func spokenMinutes(_ coming: [Date], now: Date) -> String {
        guard let next = coming.first else { return "" }
        let first = MinutesToGo(until: next, from: now)
        let lead = first.isNow ? "Next now" : "Next in \(first.spoken)"
        let then = coming.dropFirst().prefix(2).map { "\(MinutesToGo(until: $0, from: now).count)" }
        return then.isEmpty ? lead : "\(lead), then \(Lines.joined(then)) minutes"
    }
}

// MARK: - Fields

/// A bus widget's fields, for adding and editing it: its name, then its bus (a tap picks
/// another), and for a bus going two ways, Both directions.
struct RouteFields: View {
    @Binding var widget: SavedWidget
    @State private var choosing = false
    @State private var addingChange = false

    private var placeholder: String { widget.summary }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $widget.name)
                    .font(.headline)
                    .accessibilityLabel("Name")
            }
            .padding(.vertical, 4)
            Button {
                choosing = true
            } label: {
                HStack(spacing: 12) {
                    if let bus = widget.bus, widget.kind == .bus {
                        BusBadge(line: bus.line, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bus.stopName).font(.body)
                            Text(bus.bothWays ? "Both directions" : "to \(bus.wayName)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityHint("Picks another bus")
            if widget.kind == .bus, widget.bus?.otherStop != nil {
                Toggle("Both directions", isOn: Binding {
                    widget.bus?.bothWays ?? false
                } set: { both in
                    widget.bus?.bothWays = both
                    widget.bothWays = both
                })
            }
        }
        .sheet(isPresented: $choosing) {
            NewWidgetPicker(kind: widget.kind, editing: widget) { widget.takeDeparture($0) }
        }
        if widget.kind == .bus, let bus = widget.bus {
            changeSection(bus)
        }
    }

    /// A bus's changes to a train, each an alternative, and a button to add one.
    private func changeSection(_ bus: BusChoice) -> some View {
        Section {
            ForEach(Array((bus.changes ?? []).enumerated()), id: \.offset) { index, change in
                HStack(spacing: 12) {
                    LineBullets(routes: change.selection.routes, size: 30)
                        .frame(width: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(index == 0 ? "Then change at" : "Or change at")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(change.selection.station?.name ?? "Station").font(.headline)
                        Text("\(change.selection.heading) · off at \(BusNames.readable(change.stop.name)), \(change.walkMinutes) min walk")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .onDelete { offsets in
                widget.bus?.changes?.remove(atOffsets: offsets)
                if widget.bus?.changes?.isEmpty == true { widget.bus?.changes = nil }
            }
            Button(bus.changes?.isEmpty ?? true ? "Add a Change to the Subway" : "Add Another Change",
                   systemImage: "plus") {
                addingChange = true
            }
        } footer: {
            if !(bus.changes?.isEmpty ?? true) {
                Text("Medium and large show the trains each bus gets you to.")
            }
        }
        .sheet(isPresented: $addingChange) {
            BusChangePicker(bus: bus) { change in
                widget.bus?.changes = (widget.bus?.changes ?? []) + [change]
            }
        }
    }
}

extension SavedWidget {
    /// Takes the departure `NewWidgetPicker` picked for this route, which may turn a subway
    /// route into a bus one or back. The name and id stay.
    mutating func takeDeparture(_ picked: SavedWidget) {
        bothWays = picked.bothWays
        switch picked.kind {
        case .subway, .bike:
            // From a bus there's no train to keep a change or destination for
            if kind != .subway {
                change = nil
                destinationID = nil
            }
            setSelection(picked.selection)
            bus = nil
            dock = nil
        case .bus:
            // A train's change and destination mean nothing to a bus
            change = nil
            destinationID = nil
            bus = picked.bus
            dock = nil
        }
        kind = picked.kind == .bike ? .subway : picked.kind
    }
}

/// Picks a bus's change to a train: the stations along the ride, each at the stop with the
/// shortest walk to it (within `walk`), then the station's lines and way.
struct BusChangePicker: View {
    let bus: BusChoice
    let done: (BusChange) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []

    enum Step: Hashable {
        case lines(Place)
        case direction(Place, routes: [String])
    }

    /// A station to change to, where to get off for it, and the ride and walk there.
    struct Place: Hashable, Identifiable {
        var station: Station
        var stop: BusRoutes.Stop
        var minutes: Double
        var walkMinutes: Int

        var id: String { station.id }
    }

    /// The furthest walk from a stop to a station offered.
    nonisolated static let walk = 12

    var body: some View {
        NavigationStack(path: $path) {
            BusChangeAtStep(bus: bus) { place in
                if place.station.routes.count == 1 {
                    path.append(.direction(place, routes: place.station.routes))
                } else {
                    path.append(.lines(place))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .lines(let place):
                    LinesStep(station: place.station, chosen: []) { routes in
                        path.append(.direction(place, routes: routes))
                    }
                case .direction(let place, let routes):
                    DirectionStep(station: place.station, routes: routes, current: nil, offersBoth: false,
                                  bothCurrent: false) { direction, _ in
                        var selection = Selection.fallback
                        selection.stationID = place.station.id
                        selection.routes = routes
                        selection.direction = direction
                        done(BusChange(stop: place.stop.busStop, minutes: place.minutes, walkMinutes: place.walkMinutes,
                                       selection: selection))
                        dismiss()
                    }
                }
            }
        }
    }
}

/// The stations a bus ride passes near, in the ride's order: each once, at the stop with the
/// shortest walk to it, with the ride's minutes there by the timetable. Searchable by name.
private struct BusChangeAtStep: View {
    let bus: BusChoice
    let pick: (BusChangePicker.Place) -> Void
    @State private var places: [BusChangePicker.Place]?
    @State private var search = ""

    private var shown: [BusChangePicker.Place] {
        let query = StationSearch(search)
        guard !search.isEmpty else { return places ?? [] }
        let matched = Set(query.filter((places ?? []).map(\.station)).map(\.id))
        return (places ?? []).filter { matched.contains($0.station.id) }
    }

    var body: some View {
        List {
            if let places {
                Section {
                    if places.isEmpty {
                        Text("No stations near this ride's stops in the timetable")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shown) { place in
                        Button {
                            pick(place)
                        } label: {
                            row(place)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Along the \(BusNames.label(bus.line)) to \(bus.wayName)")
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding stations along the ride…").foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $search, prompt: "Search stations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Change At", step: 0) }
        }
        .task {
            let bus = bus
            places = await Task.detached { Self.places(for: bus) }.value
        }
    }

    private func row(_ place: BusChangePicker.Place) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.station.name)
                LineBullets(routes: place.station.routes, size: 18)
                Text("Off at \(BusNames.readable(place.stop.name)) · \(Int(place.minutes.rounded())) min ride")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // The walk in full, on the right
            Text("\(place.walkMinutes) min walk from the \(BusNames.label(bus.line))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// Along the ride from `bus`'s stop, each station within `BusChangePicker.walk` of a stop,
    /// at its shortest walk, in the order the ride reaches it.
    nonisolated static func places(for bus: BusChoice) -> [BusChangePicker.Place] {
        let ahead = BusRoutes.ahead(on: bus.line, from: bus.stop.id, toward: bus.destination)
        var best: [String: (place: BusChangePicker.Place, order: Int)] = [:]
        // A walk's never shorter than the crow flies: about 67 m a minute
        let reach = Double(BusChangePicker.walk) * 70
        for (order, stop) in ahead.enumerated() {
            for station in StationDirectory.all where station.location.distance(from: stop.stop.location) < reach {
                let walk = TripPlanner.walkMinutes(station.location.distance(from: stop.stop.location))
                guard walk <= BusChangePicker.walk else { continue }
                if best[station.id].map({ walk < $0.place.walkMinutes }) ?? true {
                    best[station.id] = (BusChangePicker.Place(station: station, stop: stop.stop, minutes: stop.minutes,
                                                              walkMinutes: walk), best[station.id]?.order ?? order)
                }
            }
        }
        return best.values.sorted { ($0.order, $0.place.walkMinutes) < ($1.order, $1.place.walkMinutes) }.map(\.place)
    }
}

#Preview("New Widget") {
    NewWidgetPicker { _ in }
        .environment(SettingsStore())
}
