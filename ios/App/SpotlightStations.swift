import AppIntents
import CoreSpotlight
import SwiftUI

/// A station in Spotlight: "Prospect Av", with its lines and borough. Tapping it opens the app
/// on the station's lines and direction, to show on the Magic Widget (`OpenStationIntent`).
struct SpotlightStation: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Station"
    static let defaultQuery = SpotlightStationQuery()

    /// A `Station.id`: "R34".
    let id: String

    var station: Station? { StationDirectory.station(id: id) }

    var displayRepresentation: DisplayRepresentation {
        guard let station else { return DisplayRepresentation(title: "\(id)") }
        let lines = station.routes.map(Lines.name(of:)).joined(separator: " ")
        return DisplayRepresentation(title: "\(station.name)", subtitle: "\(lines) · \(station.borough)")
    }

    /// Its lines ("R", "R train") and borough as keywords, so "R train brooklyn" finds it.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        guard let station else { return attributes }
        let lines = station.routes.map(Lines.name(of:))
        attributes.keywords = lines + lines.map { "\($0) train" } + [station.borough, "subway", "station"]
        attributes.latitude = NSNumber(value: station.lat)
        attributes.longitude = NSNumber(value: station.lon)
        return attributes
    }

    // MARK: Index

    private static let index = CSSearchableIndex(name: "Stations")
    private static let indexedKey = "spotlightStationsIndexed"

    /// Indexes every station once per build of the app, as its stations.json comes with it:
    /// dropping what's there first, so a station that's gone goes from Spotlight too.
    static func indexIfNeeded() async {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let version = "\(build):\(StationDirectory.all.count)"
        guard UserDefaults.standard.string(forKey: indexedKey) != version,
              CSSearchableIndex.isIndexingAvailable() else { return }
        do {
            try await index.deleteAppEntities(ofType: SpotlightStation.self)
            try await index.indexAppEntities(StationDirectory.all.map { SpotlightStation(id: $0.id) })
            UserDefaults.standard.set(version, forKey: indexedKey)
        } catch {
            // Tried again next launch
        }
    }
}

struct SpotlightStationQuery: EntityStringQuery {
    func entities(for identifiers: [SpotlightStation.ID]) async throws -> [SpotlightStation] {
        identifiers.filter { StationDirectory.station(id: $0) != nil }.map(SpotlightStation.init(id:))
    }

    /// Station and borough search, as in the app's picker, e.g. "86 st brooklyn".
    func entities(matching string: String) async throws -> [SpotlightStation] {
        let search = StationSearch(string)
        return search.filter(StationDirectory.all).prefix(60).map { SpotlightStation(id: $0.id) }
    }

    /// The default train's station.
    func suggestedEntities() async throws -> [SpotlightStation] {
        Selection.defaultTrain.station.map { [SpotlightStation(id: $0.id)] } ?? []
    }
}

/// A station tapped in Spotlight: opens the app on its lines and direction
/// (`StationWidgetPicker`), to show one on the Magic Widget.
struct OpenStationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Station"

    @Parameter(title: "Station")
    var target: SpotlightStation

    init() {}

    init(target: SpotlightStation) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        let station = target.station
        await MainActor.run { StationOpening.shared.station = station }
        return .result()
    }
}

/// The station a Spotlight tap opened, for `AppTabs` to show its picker; or the bus home stop,
/// for Nearby to open.
@MainActor
@Observable
final class StationOpening {
    static let shared = StationOpening()

    var station: Station?
    var busStop: BusChoice?
}

/// Settings' home stop in Spotlight when it's a bus: "5 Av & Union St", with its lines. Only that
/// stop, as bus stops are too many to list. Tapping it opens it on Nearby (`OpenBusStopIntent`).
struct SpotlightBusStop: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bus Stop"
    static let defaultQuery = SpotlightBusStopQuery()

    /// The MTA's stop code.
    let id: String

    /// The home stop, if it's this one.
    var bus: BusChoice? { SharedStore.defaultBus.flatMap { $0.stop.id == id ? $0 : nil } }

    var displayRepresentation: DisplayRepresentation {
        guard let bus else { return DisplayRepresentation(title: "Bus stop") }
        let lines = bus.allLines.map(BusNames.label).joined(separator: " ")
        return DisplayRepresentation(title: "\(bus.stopName)", subtitle: "\(lines) · Toward \(bus.shortWayName)")
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        guard let bus else { return attributes }
        let lines = bus.allLines.map(BusNames.label)
        attributes.keywords = lines + lines.map { "\($0) bus" } + ["bus", "bus stop", "home stop"]
        attributes.latitude = NSNumber(value: bus.stop.latitude)
        attributes.longitude = NSNumber(value: bus.stop.longitude)
        return attributes
    }

    private static let index = CSSearchableIndex(name: "Bus Stops")

    /// Lists the home stop if it's a bus, and drops any before it: at launch and once it changes.
    static func indexHome() async {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        try? await index.deleteAppEntities(ofType: SpotlightBusStop.self)
        if let bus = SharedStore.defaultBus {
            try? await index.indexAppEntities([SpotlightBusStop(id: bus.stop.id)])
        }
    }
}

struct SpotlightBusStopQuery: EntityStringQuery {
    func entities(for identifiers: [SpotlightBusStop.ID]) async throws -> [SpotlightBusStop] {
        identifiers.filter { $0 == SharedStore.defaultBus?.stop.id }.map(SpotlightBusStop.init(id:))
    }

    func entities(matching string: String) async throws -> [SpotlightBusStop] {
        guard let bus = SharedStore.defaultBus else { return [] }
        let words = ([bus.stopName] + bus.allLines).joined(separator: " ").lowercased()
        let typed = string.lowercased().split(separator: " ")
        return typed.allSatisfy { words.contains($0) } ? [SpotlightBusStop(id: bus.stop.id)] : []
    }

    func suggestedEntities() async throws -> [SpotlightBusStop] {
        SharedStore.defaultBus.map { [SpotlightBusStop(id: $0.stop.id)] } ?? []
    }
}

/// The bus home stop tapped in Spotlight: opens it on Nearby.
struct OpenBusStopIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Bus Stop"

    @Parameter(title: "Bus Stop")
    var target: SpotlightBusStop

    init() {}

    init(target: SpotlightBusStop) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        let bus = target.bus
        await MainActor.run { StationOpening.shared.busStop = bus }
        return .result()
    }
}

/// A Spotlight station's lines, then which way (straight to which way with one line), as the
/// train picker's steps; the way picked shows on the Magic Widget with New Trip's Show on Widget.
struct StationWidgetPicker: View {
    let station: Station
    @Environment(\.dismiss) private var dismiss
    /// The way picked, for Show on Widget.
    @State private var showing = TripShowing()
    @State private var picked: (routes: [String], direction: Direction)?
    /// The lines chosen, on to which way.
    @State private var lines: [String]?

    var body: some View {
        NavigationStack {
            Group {
                if station.routes.count == 1 {
                    directionStep(routes: station.routes)
                } else {
                    LinesStep(station: station, chosen: []) { routes in
                        lines = routes
                    }
                    .navigationDestination(item: $lines) { routes in
                        directionStep(routes: routes)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }

    private func directionStep(routes: [String]) -> some View {
        let chosen = picked.flatMap { $0.routes == routes ? $0.direction : nil }
        return DirectionStep(station: station, routes: routes, current: chosen, offersBoth: true,
                             bothCurrent: chosen != nil && showing.bothWays) { direction, both in
            pick(routes: routes, direction: direction, both: both)
        }
        .safeAreaBar(edge: .bottom) {
            ShowOnWidgetButton(showing: showing)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }

    private func pick(routes: [String], direction: Direction, both: Bool) {
        let selection = Selection(stationID: station.id, routes: routes, direction: direction)
        guard let option = SharedTrip.Option(selection: selection).validated() else { return }
        picked = (routes, direction)
        showing.option = .train(option)
        showing.bothWays = both
    }
}

#Preview("Spotlight station · one line") {
    if let station = StationDirectory.station(id: "R34") {
        StationWidgetPicker(station: station)
            .environment(SettingsStore())
    }
}
