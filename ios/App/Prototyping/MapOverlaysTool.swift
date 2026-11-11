import MapKit
import SwiftUI

/// Debug layers drawn on the app's maps: the safe walk router's graph, the city's sidewalks and
/// the holes in them the indoors start delay goes by, the baked bus lanes and DOT's bike lanes.
/// Each map adds `DebugOverlays(on:)` to its content and `.feedsOverlays(_:)` to itself; only
/// what's in view is read, capped, once the map's still. For this run of the app only.
struct MapOverlaysTool: View {
    @Bindable private var overlays = MapOverlays.shared

    var body: some View {
        Form {
            Section {
                Toggle("Walking Network", isOn: $overlays.layers.network)
                if overlays.layers.network {
                    Picker("Colour By", selection: $overlays.layers.colouring) {
                        Text("Kind").tag(OverlayLayers.Colouring.kind)
                        Text("Crime Now").tag(OverlayLayers.Colouring.crime)
                    }
                }
            } footer: {
                if overlays.layers.network {
                    OverlayLegend(styles: overlays.layers.colouring == .kind
                                  ? [.street, .path, .highway, .connector, .osmSidewalk, .crosswalkSignal,
                                     .crosswalkMarked, .crosswalkUnmarked, .island, .median, .steps, .signal]
                                  : [.crime(0), .crime(1), .crime(2), .crime(3), .signal])
                } else {
                    Text("walkgraph.sqlite's blocks, crosswalks and signals, within 2.5 km zoom.")
                }
            }

            Section {
                Toggle("Sidewalks", isOn: $overlays.layers.sidewalks)
                Toggle("Sidewalk Holes", isOn: $overlays.layers.holes)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if overlays.layers.sidewalks { OverlayLegend(styles: [.curb, .buildingLine]) }
                    if overlays.layers.holes { OverlayLegend(styles: [.countedHole, .skippedHole]) }
                    Text("Holes are what the indoors start delay goes by: GPS 3 m inside a counted one each way adds 2 min. Skipped: bigger than 30,000 m², or a sidewalk with over 5 holes (a park's).")
                }
            }

            Section {
                Toggle("Bus Lanes", isOn: $overlays.layers.busLanes)
                Toggle("Bike Lanes", isOn: $overlays.layers.bikeLanes)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if overlays.layers.busLanes { OverlayLegend(styles: [.bus(0), .busStop]) }
                    if overlays.layers.bikeLanes { OverlayLegend(styles: [.bikeBoth, .bikeAlong]) }
                    Text("bus_network.json's kerb lanes as baked, coloured by line, and bike_lanes.json, within 12 km zoom.")
                }
            }

            Section {
                ForEach(OverlayMap.allCases) { map in
                    LabeledContent(map.title) {
                        Text(overlays.drawn[map]?.summary ?? (overlays.layers.any ? "Not moved yet" : "Off"))
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Drawn")
            } footer: {
                Text("Read again once a map's still. Off again at the next launch.")
            }
        }
    }
}

/// A row of swatches and their names.
private struct OverlayLegend: View {
    let styles: [OverlayStyle]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(styles.indices, id: \.self) { index in
                let style = styles[index]
                HStack(spacing: 6) {
                    Capsule().fill(style.color).frame(width: 18, height: max(3, min(8, style.width)))
                    Text(style.name)
                }
            }
        }
    }
}

// MARK: The layers

/// The maps that draw the overlays.
enum OverlayMap: String, CaseIterable, Identifiable, Sendable {
    case nearby, newTrip, walking

    var id: Self { self }

    var title: String {
        switch self {
        case .nearby: "Nearby"
        case .newTrip: "New Trip"
        case .walking: "Walking"
        }
    }
}

/// Which overlays are on.
struct OverlayLayers: Equatable, Sendable {
    enum Colouring: Sendable { case kind, crime }

    var network = false
    var colouring = Colouring.kind
    var sidewalks = false
    var holes = false
    var busLanes = false
    var bikeLanes = false

    var any: Bool { network || sidewalks || holes || busLanes || bikeLanes }
}

/// How a line or dot's drawn.
enum OverlayStyle: Equatable, Sendable {
    case street, path, highway, connector, osmSidewalk, crosswalkSignal, crosswalkMarked, crosswalkUnmarked
    case island, median, steps, signal
    /// Crime over the neighbours' average, 0 none to 3 most.
    case crime(Int)
    case curb, buildingLine, countedHole, skippedHole
    /// A bus line's, by its hue.
    case bus(Double)
    case busStop, bikeBoth, bikeAlong

    var color: Color {
        switch self {
        case .street: .gray
        case .path: Color(red: 0.1, green: 0.6, blue: 0.2)
        case .highway: .red
        case .connector: .gray.opacity(0.6)
        case .osmSidewalk: .blue
        case .crosswalkSignal: .green
        case .crosswalkMarked: .yellow
        case .crosswalkUnmarked: .orange
        case .island, .median: .purple
        case .steps: .brown
        case .signal: Color(red: 1, green: 0.8, blue: 0)
        case .crime(let level): [Color.gray, .yellow, .orange, .red][max(0, min(3, level))]
        case .curb: .cyan
        case .buildingLine: .indigo
        case .countedHole: .green
        case .skippedHole: .orange
        case .bus(let hue): Color(hue: hue, saturation: 0.85, brightness: 0.8)
        case .busStop: .black
        case .bikeBoth: .green
        case .bikeAlong: .mint
        }
    }

    var width: CGFloat {
        switch self {
        case .crosswalkSignal, .crosswalkMarked, .crosswalkUnmarked: 4
        case .median, .bikeBoth, .bikeAlong: 3
        case .connector, .curb, .buildingLine: 1
        case .bus: 2.5
        default: 2
        }
    }

    var stroke: StrokeStyle {
        let dashed = [.connector, .island, .bikeAlong, .skippedHole].contains(self)
        return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dashed ? [4, 3] : [])
    }

    var name: String {
        switch self {
        case .street: "Street (centreline)"
        case .path: "Path, walkway, plaza"
        case .highway: "Highway, ramp: crossed, never walked"
        case .connector: "Built link, path to street"
        case .osmSidewalk: "OSM sidewalk"
        case .crosswalkSignal: "Crosswalk with signal"
        case .crosswalkMarked: "Marked crosswalk, no signal"
        case .crosswalkUnmarked: "Unmarked crossing"
        case .island: "Traffic island"
        case .median: "Median"
        case .steps: "Steps"
        case .signal: "Junction signal"
        case .crime(let level): ["No more crime than nearby", "A little more", "More", "Much more (3+ per 100 m)"][max(0, min(3, level))]
        case .curb: "Curb"
        case .buildingLine: "Building line"
        case .countedHole: "Hole counted as a block"
        case .skippedHole: "Hole skipped"
        case .bus: "Bus lane, a colour each line"
        case .busStop: "Bus stop"
        case .bikeBoth: "Protected lane, both ways"
        case .bikeAlong: "Protected lane, one way"
        }
    }
}

/// What a map has drawn: lines, holes and dots, in drawing order.
struct OverlayDrawing: Sendable {
    struct Line: Identifiable, Sendable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let style: OverlayStyle
    }

    struct Area: Identifiable, Sendable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let counted: Bool
    }

    struct Dot: Identifiable, Sendable {
        let id: Int
        let coordinate: CLLocationCoordinate2D
        let style: OverlayStyle
        let radius: Double
    }

    var lines: [Line] = []
    var areas: [Area] = []
    var dots: [Dot] = []
    /// What's drawn, for the tool's page.
    var summary = ""
}

/// The overlays that are on, and what each map has drawn of them. Kept in memory only.
@Observable @MainActor final class MapOverlays {
    static let shared = MapOverlays()

    var layers = OverlayLayers() {
        didSet { if layers != oldValue { reloadAll() } }
    }
    private(set) var drawn: [OverlayMap: OverlayDrawing] = [:]

    @ObservationIgnored private var regions: [OverlayMap: MKCoordinateRegion] = [:]
    @ObservationIgnored private var loaded: [OverlayMap: (box: OverlayBox, layers: OverlayLayers)] = [:]
    @ObservationIgnored private var loads: [OverlayMap: Task<Void, Never>] = [:]

    /// `map` now showing `region`: read again once it's been still a moment, unless what's read
    /// already covers it at about this zoom.
    func viewed(_ region: MKCoordinateRegion, on map: OverlayMap) {
        regions[map] = region
        guard layers.any else { return }
        let box = OverlayBox(region)
        if let was = loaded[map], was.layers == layers, was.box.contains(box), box.height * 3 >= was.box.height { return }
        load(map)
    }

    private func reloadAll() {
        for task in loads.values { task.cancel() }
        loads = [:]
        loaded = [:]
        guard layers.any else {
            drawn = [:]
            return
        }
        for map in regions.keys { load(map, after: .zero) }
    }

    private func load(_ map: OverlayMap, after wait: Duration = .milliseconds(300)) {
        guard let region = regions[map] else { return }
        loads[map]?.cancel()
        let layers = layers
        loads[map] = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            let seen = OverlayBox(region)
            // Read a little past what's in view, so a small pan's already drawn
            let box = seen.scaled(1.6)
            let drawing = await OverlayLoader.shared.drawing(of: box, seenHeight: seen.height, layers: layers)
            guard !Task.isCancelled, layers == self.layers else { return }
            drawn[map] = drawing
            loaded[map] = (box, layers)
        }
    }
}

/// A box of latitudes and longitudes.
struct OverlayBox: Equatable, Sendable {
    var south: Double, west: Double, north: Double, east: Double

    init(south: Double, west: Double, north: Double, east: Double) {
        (self.south, self.west, self.north, self.east) = (south, west, north, east)
    }

    init(_ region: MKCoordinateRegion) {
        let c = region.center, s = region.span
        self.init(south: c.latitude - s.latitudeDelta / 2, west: c.longitude - s.longitudeDelta / 2,
                  north: c.latitude + s.latitudeDelta / 2, east: c.longitude + s.longitudeDelta / 2)
    }

    init?(_ points: some Collection<CLLocationCoordinate2D>) {
        guard let first = points.first else { return nil }
        var box = OverlayBox(south: first.latitude, west: first.longitude, north: first.latitude, east: first.longitude)
        for p in points {
            box.south = min(box.south, p.latitude); box.north = max(box.north, p.latitude)
            box.west = min(box.west, p.longitude); box.east = max(box.east, p.longitude)
        }
        self = box
    }

    /// Metres south to north.
    var height: Double { (north - south) * Earth.metresPerDegree }

    func scaled(_ k: Double) -> OverlayBox {
        let lat = (north - south) * (k - 1) / 2, lon = (east - west) * (k - 1) / 2
        return OverlayBox(south: south - lat, west: west - lon, north: north + lat, east: east + lon)
    }

    func contains(_ other: OverlayBox) -> Bool {
        other.south >= south && other.north <= north && other.west >= west && other.east <= east
    }

    func contains(_ p: CLLocationCoordinate2D) -> Bool {
        (south...north).contains(p.latitude) && (west...east).contains(p.longitude)
    }

    func touches(_ other: OverlayBox) -> Bool {
        other.south <= north && other.north >= south && other.west <= east && other.east >= west
    }
}

// MARK: Reading

/// Reads the overlays' data for a box, off the main thread, on stores of its own so the walks'
/// caches aren't stirred.
private actor OverlayLoader {
    static let shared = OverlayLoader()

    private let walks = WalkGraphStore()
    private let sidewalkStore = SidewalkStore()
    /// The last graph read, by its tiles.
    private var graph: (tiles: [String], graph: WalkGraph?)?

    /// Metres of map, top to bottom, past which each kind isn't drawn.
    private static let walkZoom = 2_500.0, laneZoom = 12_000.0, stopZoom = 3_000.0
    /// Most of each drawn.
    private static let mostBlocks = 1_500, mostSignals = 400, mostSidewalks = 300, mostWays = 400,
                       mostStops = 400, mostBikeLanes = 800
    /// Most graph tiles (2 km) read.
    private static let mostTiles = 16

    func drawing(of box: OverlayBox, seenHeight: Double, layers: OverlayLayers) async -> OverlayDrawing {
        var drawing = OverlayDrawing()
        var id = 0
        var said: [String] = []
        func line(_ coordinates: [CLLocationCoordinate2D], _ style: OverlayStyle) {
            guard coordinates.count > 1 else { return }
            drawing.lines.append(.init(id: id, coordinates: coordinates, style: style))
            id += 1
        }
        let walkable = seenHeight <= Self.walkZoom
        let lanes = seenHeight <= Self.laneZoom

        // Sidewalks and their holes, under everything
        if layers.sidewalks || layers.holes {
            if walkable {
                let found = await sidewalkStore.sidewalks(south: box.south, west: box.west, north: box.north, east: box.east,
                                                          most: Self.mostSidewalks)
                var counted = 0
                for (rings, blocks) in found {
                    let rings = rings.map { ring in ring.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
                    if layers.holes {
                        for (hole, isBlock) in zip(rings.dropFirst(), blocks) {
                            drawing.areas.append(.init(id: id, coordinates: hole, counted: isBlock))
                            id += 1
                            if isBlock { counted += 1 }
                        }
                    }
                    if layers.sidewalks {
                        for (index, ring) in rings.enumerated() {
                            line(ring + ring.prefix(1), index == 0 ? .curb : .buildingLine)
                        }
                    }
                }
                said.append("\(found.count) sidewalks" + (layers.holes ? ", \(counted)/\(drawing.areas.count) holes counted" : ""))
            } else {
                said.append("zoom in for sidewalks")
            }
        }

        if layers.bikeLanes {
            if lanes {
                var count = 0
                for shape in OverlayData.bikeLanes where box.touches(shape.box) {
                    line(shape.coordinates, shape.oneWay ? .bikeAlong : .bikeBoth)
                    count += 1
                    if count >= Self.mostBikeLanes { break }
                }
                said.append("\(count) bike lanes")
            } else {
                said.append("zoom in for bike lanes")
            }
        }

        if layers.busLanes {
            if lanes {
                var count = 0
                for way in OverlayData.busWays where box.touches(way.box) {
                    line(way.coordinates, .bus(way.hue))
                    count += 1
                    if count >= Self.mostWays { break }
                }
                var stops = 0
                if seenHeight <= Self.stopZoom {
                    for stop in BusNetwork.stops where box.contains(stop.coordinate) {
                        drawing.dots.append(.init(id: id, coordinate: stop.coordinate, style: .busStop, radius: 3))
                        id += 1
                        stops += 1
                        if stops >= Self.mostStops { break }
                    }
                }
                said.append("\(count) bus ways, \(stops) stops")
            } else {
                said.append("zoom in for bus lanes")
            }
        }

        if layers.network {
            if walkable, let graph = await graph(of: box) {
                let band = WalkGraph.Band(hour: Calendar.current.component(.hour, from: .now))
                var streets: [(Int, OverlayStyle)] = [], crossings: [(Int, OverlayStyle)] = []
                for block in 0..<graph.blockCount {
                    let start = Int(graph.geomStart[block]), end = Int(graph.geomStart[block + 1])
                    guard end - start > 1 else { continue }
                    var lineBox = OverlayBox(south: .infinity, west: .infinity, north: -.infinity, east: -.infinity)
                    for g in start..<end {
                        let lat = Double(graph.geomLat[g]) / 1e6, lon = Double(graph.geomLon[g]) / 1e6
                        lineBox.south = min(lineBox.south, lat); lineBox.north = max(lineBox.north, lat)
                        lineBox.west = min(lineBox.west, lon); lineBox.east = max(lineBox.east, lon)
                    }
                    guard box.touches(lineBox) else { continue }
                    let flags = graph.flags(of: block)
                    let style: OverlayStyle
                    if layers.colouring == .crime {
                        let crime = graph.crime(of: block, in: band)
                        style = .crime(crime <= 0 ? 0 : crime <= 1 ? 1 : crime < 3 ? 2 : 3)
                    } else {
                        style = Self.style(of: block, in: graph, flags: flags)
                    }
                    if flags.contains(.crosswalk) { crossings.append((block, style)) } else { streets.append((block, style)) }
                    if streets.count + crossings.count >= Self.mostBlocks { break }
                }
                // Crosswalks over the streets they cross
                for (block, style) in streets + crossings {
                    line(graph.line(of: block).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }, style)
                }
                var signals = 0
                for node in 0..<graph.nodeCount where graph.nodeSignal[node] != 0 {
                    let at = CLLocationCoordinate2D(latitude: Double(graph.nodeLat[node]) / 1e6,
                                                    longitude: Double(graph.nodeLon[node]) / 1e6)
                    guard box.contains(at) else { continue }
                    drawing.dots.append(.init(id: id, coordinate: at, style: .signal, radius: 4))
                    id += 1
                    signals += 1
                    if signals >= Self.mostSignals { break }
                }
                said.append("\(streets.count) blocks, \(crossings.count) crosswalks, \(signals) signals")
            } else {
                said.append(walkable ? "no walking graph here" : "zoom in for the walking network")
            }
        }
        drawing.summary = said.joined(separator: "; ")
        return drawing
    }

    /// The graph of the tiles under `box`, the last one kept while it's still the same tiles.
    private func graph(of box: OverlayBox) async -> WalkGraph? {
        let corners = [Walk.Point(lat: box.south, lon: box.west), Walk.Point(lat: box.north, lon: box.east)]
        let tiles = WalkGraph.tiles(around: corners, metres: 0).map { "\($0.x),\($0.y)" }
        if let graph, graph.tiles == tiles { return graph.graph }
        let read = await walks.graph(around: corners, most: Self.mostTiles)
        graph = (tiles, read)
        return read
    }

    private static func style(of block: Int, in graph: WalkGraph, flags: WalkGraph.BlockFlags) -> OverlayStyle {
        if flags.contains(.crosswalk) {
            let crossing = graph.crossing(of: block)
            return crossing.contains(.signal) ? .crosswalkSignal : crossing.contains(.marked) ? .crosswalkMarked : .crosswalkUnmarked
        }
        if flags.contains(.island) { return .island }
        if flags.contains(.osmSidewalk) { return .osmSidewalk }
        if flags.contains(.steps) { return .steps }
        if flags.contains(.median) { return .median }
        if flags.contains(.connector) { return .connector }
        switch graph.crossingClass(of: block) {
        case .walk: return .street
        case .path: return .path
        case .arm: return .highway
        }
    }
}

/// The bus and bike lanes, each with its box, read the first time they're drawn.
private enum OverlayData {
    struct Shape {
        let coordinates: [CLLocationCoordinate2D]
        let box: OverlayBox
        let oneWay: Bool
        let hue: Double
    }

    /// Each bus way once, coloured by its first line.
    static let busWays: [Shape] = {
        var seen: Set<Int> = []
        return BusNetwork.byLine.keys.sorted().flatMap { BusNetwork.byLine[$0] ?? [] }.compactMap { way in
            guard seen.insert(way.index).inserted, let box = OverlayBox(way.coordinates) else { return nil }
            let name = way.lines.first ?? ""
            let hue = Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
            return Shape(coordinates: way.coordinates, box: box, oneWay: true, hue: hue)
        }
    }()

    /// bike_lanes.json's shapes, as `BikeLanes` reads them: "along" one way, "both" either.
    static let bikeLanes: [Shape] = {
        guard let url = Bundle.main.url(forResource: "bike_lanes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let encoded = try? JSONDecoder().decode([String: [[Int]]].self, from: data) else { return [] }
        return encoded.flatMap { kind, shapes in
            shapes.compactMap { flat -> Shape? in
                // Hundred-thousandths of a degree, each point a change from the one before
                var latitude = 0, longitude = 0
                let coordinates = stride(from: 0, to: flat.count - 1, by: 2).map { index in
                    latitude += flat[index]
                    longitude += flat[index + 1]
                    return CLLocationCoordinate2D(latitude: Double(latitude) / 1e5, longitude: Double(longitude) / 1e5)
                }
                guard coordinates.count > 1, let box = OverlayBox(coordinates) else { return nil }
                return Shape(coordinates: coordinates, box: box, oneWay: kind == "along", hue: 0)
            }
        }
    }()
}

// MARK: On the maps

/// The overlays `map` has drawn, for its map content: nothing while they're off.
struct DebugOverlays: MapContent {
    let map: OverlayMap

    init(on map: OverlayMap) {
        self.map = map
    }

    var body: some MapContent {
        let drawing = MapOverlays.shared.drawn[map] ?? OverlayDrawing()
        ForEach(drawing.areas) { area in
            let style: OverlayStyle = area.counted ? .countedHole : .skippedHole
            MapPolygon(coordinates: area.coordinates)
                .foregroundStyle(area.counted ? style.color.opacity(0.3) : .clear)
                .stroke(style.color, style: style.stroke)
        }
        ForEach(drawing.lines) { line in
            MapPolyline(coordinates: line.coordinates)
                .stroke(line.style.color, style: line.style.stroke)
        }
        ForEach(drawing.dots) { dot in
            MapCircle(center: dot.coordinate, radius: dot.radius)
                .foregroundStyle(dot.style.color)
        }
    }
}

extension View {
    /// Tells the map overlays where this map's come to rest, for `DebugOverlays(on: map)`.
    func feedsOverlays(_ map: OverlayMap) -> some View {
        onMapCameraChange(frequency: .onEnd) { context in
            MapOverlays.shared.viewed(context.region, on: map)
        }
    }
}

#Preview {
    NavigationStack { MapOverlaysTool() }
}
