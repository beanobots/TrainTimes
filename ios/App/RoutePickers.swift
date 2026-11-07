import CoreLocation
import MapKit
import SwiftUI

/// New Widget: Subway, Bus or Citi Bike first, then that kind's steps (a train's Station →
/// Lines → Direction; a bus's Stop → Route → Direction; a dock), which hand `done` the widget to
/// name. With `kind`, straight to that kind's steps, to change a widget's bus or dock.
struct NewWidgetPicker: View {
    var kind: SavedRouteKind? = nil
    let done: (SavedWidget) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @State private var path: [Step] = []

    enum Step: Hashable {
        case station
        case lines(Station, chosen: [String])
        case direction(Station, routes: [String])
        case busStop
        case busRoute(NearbyBusPlace)
        case busDirection(NearbyBusPick, stopName: String)
        case dock
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
                case .subway: path.append(.station)
                case .bus: path.append(.busStop)
                case .bike: path.append(.dock)
                }
            }
        case .subway: stationStep
        case .bus: busStopStep
        case .bike: dockStep
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
            DirectionStep(station: station, routes: routes, current: nil, offersBoth: true, bothCurrent: false) { direction, both in
                var selection = settings.defaultTrain
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
        case .dock:
            dockStep
        }
    }

    private var stationStep: some View {
        StationStep(chosenID: nil) { station, filter in
            if station.routes.count == 1 {
                path.append(.direction(station, routes: station.routes))
            } else {
                let chosen = filter.map { label in station.routes.filter { LineStyle.of($0).label == label } } ?? []
                path.append(.lines(station, chosen: chosen))
            }
        }
    }

    private var busStopStep: some View {
        BusStopStep { place in
            // One line there: straight to its direction
            let lines = place.lines(at: .now)
            if lines.count == 1, let line = lines.first {
                path.append(.busDirection(line, stopName: place.name))
            } else {
                path.append(.busRoute(place))
            }
        }
    }

    private var dockStep: some View {
        DockStep { finish(.dock($0)) }
    }

    private func finish(_ widget: SavedWidget) {
        done(widget)
        dismiss()
    }
}

// MARK: - Kind

/// The first page: Subway, Bus and Citi Bike, each with a sample from where you are: your Home
/// Station's lines (else the nearest station's), the nearest stop's routes, the nearest dock's
/// counts. Without them, just the icon and name.
private struct KindStep: View {
    let pick: (SavedRouteKind) -> Void
    @Environment(SettingsStore.self) private var settings
    @State private var location = NearbyLocation()
    @State private var busLines: [String] = []
    @State private var dock: CitiBike.Dock?

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
                tile(.subway, tint: .black) {
                    if !subwayLines.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(subwayLines.prefix(5), id: \.self) { LineBullet(route: $0, size: 26) }
                        }
                    }
                }
                tile(.bus, tint: BusBadge.blue) {
                    if !busLines.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(busLines.prefix(3), id: \.self) { BusBadge(line: $0, size: 26) }
                        }
                    }
                }
                tile(.bike, tint: CitiBikeMark.blue) {
                    if let dock {
                        Text("\(CitiBike.Kind.bike.count(dock.available(.bike))) · \(CitiBike.Kind.eBike.count(dock.available(.eBike))) · \(dock.free) docks")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(CitiBikeMark.blue)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("New Widget")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            location.start()
            // Only where you've already allowed it: this page doesn't ask
            if location.isAllowed { location.find() }
        }
        .task(id: location.location.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }) {
            guard let here = location.location else { return }
            async let places = NearbyBuses.places(near: here, wait: NearbyBuses.appWait)
            async let docks = CitiBike.docks()
            dock = await docks?.min { $0.location.distance(from: here) < $1.location.distance(from: here) }
            busLines = await places?.first?.lines(at: .now).map(\.line) ?? []
        }
    }

    private func tile(_ kind: SavedRouteKind, tint: Color, @ViewBuilder sample: () -> some View) -> some View {
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
    }
}

// MARK: - Bus

/// "0.1 mi".
private func distance(_ meters: Double) -> String {
    Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
}

/// Where a search for a street or place is, in New York, for stops or docks near it.
private func searchedPlace(_ text: String) async -> CLLocation? {
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
                        location.find()
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
            Task { await find(near: searchedPlace(text), named: text) }
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
        .task(id: location.location.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }) {
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
        failed = found == nil
        places = found
    }

    private func row(_ place: NearbyBusPlace) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                HStack(spacing: 4) {
                    ForEach(place.lines(at: .now).prefix(5).map(\.line), id: \.self) { BusBadge(line: $0, size: 16) }
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
                    Text(place.name).font(.title2.bold())
                    Text("Pick the route to show").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 14) {
                    let lines = place.lines(at: .now)
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
            ToolbarItem(placement: .principal) { StepTitle(title: "Route", step: 1) }
        }
    }
}

/// Bus step 3: which way, as a train's Direction tiles in bus blue, with Both where it goes two.
private struct BusDirectionStep: View {
    let pick: NearbyBusPick
    let stopName: String
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
                    Text(stopName).font(.title2.bold())
                    Text("Which way are you going?").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    tiles {
                        ForEach(pick.ways.indices, id: \.self) { tile($0, now: context.date) }
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
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle.pickerCard)
                        .contentShape(RoundedRectangle.pickerCard)
                    }
                    .buttonStyle(.plain)
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
                disc(compass?.symbol ?? "arrow.forward")
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
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Citi Bike

/// Citi Bike's one step: a dock, nearest first (to you, or to a street or place searched for),
/// each with its bikes, e-bikes and free docks in columns. Typing filters by name too.
private struct DockStep: View {
    let pick: (DockChoice) -> Void
    @State private var location = NearbyLocation()
    @State private var search = ""
    @State private var docks: [CitiBike.Dock]?
    @State private var failed = false
    /// Where a submitted search found, to sort by; nil for near you.
    @State private var searchedPlace: (name: String, location: CLLocation)?

    private var origin: CLLocation? { searchedPlace?.location ?? location.location }

    private var shown: [CitiBike.Dock] {
        guard let docks else { return [] }
        let text = search.trimmingCharacters(in: .whitespaces)
        let named = text.isEmpty || searchedPlace != nil ? docks : docks.filter { $0.name.localizedCaseInsensitiveContains(text) }
        guard let origin else { return Array(named.sorted { $0.name < $1.name }.prefix(60)) }
        return Array(named.sorted { $0.location.distance(from: origin) < $1.location.distance(from: origin) }.prefix(30))
    }

    var body: some View {
        List {
            if search.isEmpty, !location.isAllowed {
                Section {
                    Button {
                        location.find()
                    } label: {
                        Label("Show docks near you", systemImage: "location")
                    }
                }
            }
            if docks != nil {
                Section {
                    ForEach(shown, id: \.id) { dock in
                        Button {
                            pick(DockChoice(dock))
                        } label: {
                            row(dock)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text(searchedPlace.map { "Near \($0.name)" } ?? (origin == nil ? "Docks" : "Near you"))
                } footer: {
                    if !search.isEmpty, searchedPlace == nil {
                        Text("Search to find docks near a street or place.")
                    }
                }
            } else if failed {
                Section { Text("Couldn't reach Citi Bike").foregroundStyle(.secondary) }
            } else {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Finding docks…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search docks or streets")
        .onSubmit(of: .search) {
            let text = search.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            Task {
                if let found = await RoutePickers.searchedPlace(text) { searchedPlace = (text, found) }
            }
        }
        .onChange(of: search) { _, text in
            if searchedPlace != nil, text != searchedPlace?.name { searchedPlace = nil }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Dock", step: 0, count: 1) }
        }
        .onAppear {
            location.start()
            if location.isAllowed { location.find() }
        }
        .task {
            let found = await CitiBike.docks()
            failed = found == nil
            docks = found
        }
    }

    private func row(_ dock: CitiBike.Dock) -> some View {
        HStack(spacing: 12) {
            CitiBikeMark(size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(dock.name).lineLimit(2)
                if let origin {
                    Text(distance(dock.location.distance(from: origin)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                column(dock.available(.bike), "Bikes")
                column(dock.available(.eBike), "E-Bikes")
                column(dock.free, "Docks")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func column(_ number: Int, _ name: String) -> some View {
        VStack(spacing: 0) {
            Text("\(number)")
                .font(.headline)
                .monospacedDigit()
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 38)
    }
}

/// For the steps' searches, by a name the views' own properties don't hide.
private enum RoutePickers {
    static func searchedPlace(_ text: String) async -> CLLocation? {
        await ios.searchedPlace(text)
    }
}
