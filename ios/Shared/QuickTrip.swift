import AppIntents
import Foundation

/// The Transit Directions widget without a shared trip: which of its screens shows. Saved in the
/// App Group, so every Transit Directions widget shows the same.
struct QuickTrip: Codable, Hashable, Sendable {
    enum Screen: String, Codable, Sendable {
        /// The Favorite Stop, Nearby and Trip buttons.
        case home
        /// Settings' default train, as Next train shows it, until its ✕.
        case favorite
        /// The stations nearest you, to show one of their trains.
        case nearby
        /// A nearby station's lines (`nearbyStationID`), then once one's picked (`nearbyRoute`),
        /// which way; a tap on a way shows that train.
        case nearbyLine
        /// A bus place near you picked from Nearby (`nearbyBusPlace`): its lines, then once one's
        /// picked (`nearbyBus`), or at once for a place with one line, which way; a tap on a way,
        /// or Both, shows it.
        case nearbyBus
        /// Trip: the journeys to pick from (`savedTrips`), fetched ahead so the one picked
        /// shows at once.
        case trips
    }

    var screen = Screen.home
    /// On `.nearbyLine`, the nearby station whose lines it shows.
    var nearbyStationID: String?
    /// On `.nearbyLine`, how far you were from it, in meters, for its distance and walk.
    var nearbyMeters: Double?
    /// On `.nearbyLine`, shown straight from Nearby as the only station: the one within
    /// range, or the nearest when none is. No list to go back to.
    var nearbyOnly: Bool?
    /// On `.nearbyLine`, the line picked, to show which way; nil for the station's lines.
    var nearbyRoute: String?
    /// Nearby's "Bus" switch: the closest bus stop each way too, under the stations. Kept for
    /// the next time; nil is off.
    var nearbyBuses: Bool?
    /// On `.nearbyBus`, the bus place picked from Nearby's grid, whose lines it shows.
    var nearbyBusPlace: NearbyBusPlace?
    /// On `.nearbyBus`, the bus line picked, with its stop and next buses each way, to show which
    /// way; nil for the place's lines.
    var nearbyBus: NearbyBusPick?

    /// Whether Nearby shows buses as well as stations.
    var includesBuses: Bool { nearbyBuses == true }
    /// The last tap, after which a screen goes back to the buttons (`planningExpires`).
    var touched = Date.distantPast

    /// How long Nearby or Trip stays up without a tap.
    static let planningDuration: TimeInterval = 60 * 60

    /// When Nearby or Trip goes back to the buttons; nil on other screens.
    var planningExpires: Date? {
        switch screen {
        case .nearby, .nearbyLine, .nearbyBus, .trips: touched.addingTimeInterval(Self.planningDuration)
        case .home, .favorite: nil
        }
    }

    /// As shown at `date`: back to the buttons once Nearby or Trip has been left long enough, or
    /// if last tapped after `date` (clock set back), as it would otherwise stay up until then.
    func shown(at date: Date) -> QuickTrip {
        guard let expires = planningExpires, date >= expires || date < touched else { return self }
        var shown = self
        shown.screen = .home
        return shown
    }

    // MARK: Trips

    /// The most journeys Trip offers, as many as fit the medium widget.
    static let tripLimit = 4

    /// Trip's journeys: for now the first saved widgets, in the Widgets tab's order, each as
    /// it shows at `date` (its commuting hours' train then).
    static func savedTrips(_ saved: SavedWidgets, at date: Date = .now) -> [SavedWidget] {
        saved.widgets.prefix(tripLimit).map { $0.shown(at: date) }
    }

    /// `widget` as a trip: its train, change and where it's going; nil if its train's gone.
    static func option(for widget: SavedWidget) -> SharedTrip.Option? {
        SharedTrip.Option(selection: widget.selection, change: widget.change,
                          destinationID: widget.change?.destinationID ?? widget.destinationID).validated()
    }

    // MARK: Store

    private static let file = SharedStore.url(named: "quick-trip.json")

    static func load() -> QuickTrip {
        SharedStore.read(QuickTrip.self, from: file) ?? QuickTrip()
    }

    /// Changes it for a tap now, atomically across processes: a tap on one widget can come as
    /// another reloads. A tap on the widget redraws it anyway.
    static func update(_ change: (inout QuickTrip) -> Void) {
        SharedStore.change(file, empty: QuickTrip()) { trip in
            // `now` is taken inside the lock, so a tap just saved isn't after it
            let now = Date.now
            trip = trip.shown(at: now)
            change(&trip)
            trip.touched = now
        }
    }

    /// A tap on a nearby station's train (`bothWays`: going both ways): shows it for an hour, as
    /// shared directions are (`SharedTrip`), going back to the buttons after.
    static func start(_ option: SharedTrip.Option, bothWays: Bool = false) {
        update { trip in
            SharedStore.saveSharedTrip(SharedTrip(option: option, app: nil, shared: .now, nearby: true,
                                                  bothWays: bothWays ? true : nil))
            trip.screen = .home
        }
    }

    private enum CodingKeys: String, CodingKey {
        case screen, nearbyStationID, nearbyMeters, nearbyOnly, nearbyRoute, nearbyBuses, nearbyBusPlace, nearbyBus,
             touched
    }
}

// Older saves missing any field still load, with defaults (see `SharedStore`'s decoders)
extension QuickTrip {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = QuickTrip()
        // An unknown screen, from a later version, falls back too
        screen = (try? container.decodeIfPresent(Screen.self, forKey: .screen)) ?? defaults.screen
        nearbyStationID = try container.decodeIfPresent(String.self, forKey: .nearbyStationID)
        nearbyMeters = try container.decodeIfPresent(Double.self, forKey: .nearbyMeters)
        nearbyOnly = try container.decodeIfPresent(Bool.self, forKey: .nearbyOnly)
        nearbyRoute = try container.decodeIfPresent(String.self, forKey: .nearbyRoute)
        nearbyBuses = try container.decodeIfPresent(Bool.self, forKey: .nearbyBuses)
        // Unreadable picks, from a later version, are dropped rather than the whole save
        nearbyBusPlace = try? container.decodeIfPresent(NearbyBusPlace.self, forKey: .nearbyBusPlace)
        nearbyBus = try? container.decodeIfPresent(NearbyBusPick.self, forKey: .nearbyBus)
        touched = try container.decodeIfPresent(Date.self, forKey: .touched) ?? defaults.touched
    }
}

// MARK: - Intents

/// Shows one of Transit Directions' screens: the buttons, Favorite Stop, Nearby or Trip.
struct ShowQuickTripScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Show a Quick Trip screen"
    static let isDiscoverable = false

    /// A `QuickTrip.Screen`.
    @Parameter(title: "Screen", default: "home")
    var screen: String

    /// The `QuickTrip.Screen` the button is drawn on, if a tap on it could come once that's gone;
    /// empty for any.
    @Parameter(title: "From", default: "")
    var from: String

    init() {}

    init(_ screen: QuickTrip.Screen, from: QuickTrip.Screen? = nil) {
        self.screen = screen.rawValue
        self.from = from?.rawValue ?? ""
    }

    func perform() async throws -> some IntentResult {
        let screen = QuickTrip.Screen(rawValue: screen) ?? .home
        let from = QuickTrip.Screen(rawValue: from)
        Signposts.interval("Quick Trip tap") {
            QuickTrip.update { trip in
                guard let from, trip.screen != from else {
                    trip.screen = screen
                    return
                }
                // A tap on a screen that's gone. Favorite Stop's and Nearby's taps draw their
                // screen at once, but the buttons stay under it until the redraw, and its ✕ is
                // over Trip's: so that ✕'s tap, going back. Otherwise (the journeys, which redraw
                // at once) nothing, rather than the wrong thing.
                if [.favorite, .nearby].contains(trip.screen) {
                    trip.screen = .home
                }
            }
        }
        return .result()
    }
}

/// Nearby's "Bus" switch: buses as well as stations, or (`include` false) the stations alone.
/// Back on Nearby's stations either way, as the only station's lines have the switch too.
struct IncludeNearbyBusesIntent: AppIntent {
    static let title: LocalizedStringResource = "Include buses nearby"
    static let isDiscoverable = false

    @Parameter(title: "Include", default: true)
    var include: Bool

    init() {}

    init(_ include: Bool) {
        self.include = include
    }

    func perform() async throws -> some IntentResult {
        Signposts.interval("Quick Trip tap") {
            QuickTrip.update { trip in
                trip.nearbyBuses = include ? true : nil
                trip.nearbyStationID = nil
                trip.nearbyMeters = nil
                trip.nearbyOnly = nil
                trip.nearbyRoute = nil
                trip.screen = .nearby
            }
        }
        return .result()
    }
}

/// Picks one of the stations nearest you, on to its lines.
struct PickNearbyStationIntent: AppIntent {
    static let title: LocalizedStringResource = "Pick a nearby station"
    static let isDiscoverable = false

    @Parameter(title: "Station", default: "")
    var stationID: String

    /// How far you were from it, in meters.
    @Parameter(title: "Meters", default: 0)
    var meters: Double

    init() {}

    init(_ result: Nearby.Result) {
        stationID = result.station.id
        meters = result.meters
    }

    func perform() async throws -> some IntentResult {
        Signposts.interval("Quick Trip tap") {
            QuickTrip.update { trip in
                trip.nearbyStationID = stationID
                trip.nearbyMeters = meters
                trip.nearbyOnly = nil
                trip.nearbyRoute = nil
                trip.screen = .nearbyLine
            }
        }
        return .result()
    }
}

/// Picks one of a nearby station's lines, on to which way; with none, back to its lines.
/// Carries the station it's drawn for, as the one saved can be another: Nearby with one station
/// near you shows its lines without saving it (`QuickTrip.only`), so a line picked there would
/// otherwise go with whichever station was picked last, such as the G at Prospect Av.
struct PickNearbyLineIntent: AppIntent {
    static let title: LocalizedStringResource = "Pick a nearby line"
    static let isDiscoverable = false

    /// A route, "A"; empty for back to the station's lines.
    @Parameter(title: "Line", default: "")
    var route: String

    /// The station whose line it is; empty in older widgets' taps, for the one saved.
    @Parameter(title: "Station", default: "")
    var stationID: String

    /// How far you were from it, in meters.
    @Parameter(title: "Meters", default: 0)
    var meters: Double

    /// Whether it's the only station near you, with no list to go back to.
    @Parameter(title: "Only", default: false)
    var only: Bool

    init() {}

    init(_ route: String?, at result: Nearby.Result, only: Bool) {
        self.route = route ?? ""
        stationID = result.station.id
        meters = result.meters
        self.only = only
    }

    func perform() async throws -> some IntentResult {
        Signposts.interval("Quick Trip tap") {
            QuickTrip.update { trip in
                if !stationID.isEmpty {
                    trip.nearbyStationID = stationID
                    trip.nearbyMeters = meters
                    trip.nearbyOnly = only ? true : nil
                }
                trip.nearbyRoute = route.isEmpty ? nil : route
                trip.screen = .nearbyLine
            }
        }
        return .result()
    }
}

/// One of Nearby's bus places picked: on to its lines, or for one line, which way it goes.
struct PickNearbyBusPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "Pick a nearby bus stop"
    static let isDiscoverable = false

    /// A `NearbyBusPlace`, encoded.
    @Parameter(title: "Stop", default: "")
    var place: String

    init() {}

    init(_ place: NearbyBusPlace) {
        self.place = place.encoded
    }

    func perform() async throws -> some IntentResult {
        Signposts.interval("Quick Trip tap") {
            guard let place = NearbyBusPlace(encoded: place) else { return }
            let lines = place.lines(at: .now)
            QuickTrip.update { trip in
                trip.nearbyBusPlace = place
                trip.nearbyBus = lines.count == 1 ? lines.first : nil
                trip.screen = .nearbyBus
            }
        }
        return .result()
    }
}

/// One of a nearby bus place's lines picked: on to which way it goes.
struct PickNearbyBusIntent: AppIntent {
    static let title: LocalizedStringResource = "Pick a nearby bus"
    static let isDiscoverable = false

    /// A `NearbyBusPick`, encoded.
    @Parameter(title: "Bus", default: "")
    var pick: String

    init() {}

    init(_ pick: NearbyBusPick) {
        self.pick = pick.encoded
    }

    func perform() async throws -> some IntentResult {
        Signposts.interval("Quick Trip tap") {
            guard let pick = NearbyBusPick(encoded: pick) else { return }
            QuickTrip.update { trip in
                trip.nearbyBus = pick
                trip.screen = .nearbyBus
            }
        }
        return .result()
    }
}

/// A nearby bus line one way, or with `both` both ways, tapped: shows its next buses for an
/// hour, as a nearby train's are shown.
struct ShowNearbyBusIntent: AppIntent {
    static let title: LocalizedStringResource = "Show a nearby bus"
    static let isDiscoverable = false

    /// A `NearbyBusPick`, encoded.
    @Parameter(title: "Bus", default: "")
    var pick: String

    /// Which of its ways.
    @Parameter(title: "Way", default: 0)
    var way: Int

    /// The other way too, beside it (Nearby's Both).
    @Parameter(title: "Both directions", default: false)
    var both: Bool

    init() {}

    init(_ pick: NearbyBusPick, way: Int, both: Bool = false) {
        self.pick = pick.encoded
        self.way = way
        self.both = both
    }

    func perform() async throws -> some IntentResult {
        Signposts.interval("Quick Trip tap") {
            guard let shown = NearbyBusPick(encoded: pick)?.shown(way: way, both: both) else { return }
            QuickTrip.update { trip in
                SharedStore.saveSharedBusTrip(shown)
                trip.screen = .home
            }
        }
        return .result()
    }
}

/// One of a nearby station's lines one way, or with `bothWays` both, tapped: shows its trains
/// for an hour.
struct ShowNearbyTrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Show a nearby train"
    static let isDiscoverable = false

    /// A `Selection.trainID`: "R34:N:R".
    @Parameter(title: "Train", default: "")
    var trainID: String

    /// Its trains the other way too, beside them (Nearby's Both).
    @Parameter(title: "Both directions", default: false)
    var bothWays: Bool

    init() {}

    init(_ selection: Selection, bothWays: Bool = false) {
        trainID = selection.trainID
        self.bothWays = bothWays
    }

    func perform() async throws -> some IntentResult {
        Signposts.interval("Quick Trip tap") {
            guard let stop = StopEntity(id: trainID),
                  let option = SharedTrip.Option(selection: Selection(stationID: stop.stationID, routes: stop.routes,
                                                                     direction: stop.direction)).validated() else { return }
            QuickTrip.start(option, bothWays: bothWays)
        }
        return .result()
    }
}

/// One of Trip's journeys, tapped: shows that saved widget's train for an hour, as it shows now.
struct StartSavedTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a saved trip"
    static let isDiscoverable = false

    /// A `SavedWidget.id`.
    @Parameter(title: "Widget", default: "")
    var widgetID: String

    init() {}

    init(_ widget: SavedWidget) {
        widgetID = widget.id.uuidString
    }

    func perform() async throws -> some IntentResult {
        Signposts.interval("Quick Trip tap") {
            // A tap on the journeys once they're gone: a journey's tap draws its board at once,
            // but the journeys stay under it until the redraw, and its ✕ is over one of them.
            // So that ✕'s tap, ending the trip, rather than starting another.
            guard QuickTrip.load().shown(at: .now).screen == .trips else {
                SharedStore.saveSharedTrip(nil)
                QuickTrip.update { $0.screen = .home }
                return
            }
            guard let id = UUID(uuidString: widgetID),
                  let widget = SharedStore.loadWidgets().widget(id)?.shown(at: .now),
                  let option = QuickTrip.option(for: widget) else { return }
            QuickTrip.update { trip in
                SharedStore.saveSharedTrip(SharedTrip(option: option, app: nil, shared: .now, saved: widget.title))
                trip.screen = .home
            }
        }
        return .result()
    }
}
