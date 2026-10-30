import AppIntents
import Foundation
import WidgetKit

/// Transit directions shared from a maps app (the Share extension), the trip picked from those
/// they could be, or a Quick Trip planned on the widget, which the Transit Directions widget shows
/// for an hour before going back to its Quick Trip and Favorite Stop buttons.
struct SharedTrip: Codable, Hashable, Sendable {
    var option: Option
    /// Nil for a Quick Trip.
    var app: MapsApp?
    var shared: Date
    /// True for a train picked from the stations nearest you; nil otherwise, as in older saves.
    var nearby: Bool? = nil
    /// The title of the saved widget picked as one of Trip's journeys; nil otherwise.
    var saved: String? = nil
    /// True for a nearby train shown going both ways, from Nearby's Both; nil otherwise.
    var bothWays: Bool? = nil

    /// A train from a station near the directions' start, and a change if it needs one.
    struct Option: Codable, Hashable, Sendable {
        var selection: Selection
        /// Where the trip changes trains, if it needs to.
        var change: Change?
        /// Where you're going: the station near the directions' end.
        var destinationID: String?

        /// Where Next train times its trains to, without a change.
        var directDestination: Station? {
            change == nil ? destinationID.flatMap(StationDirectory.station(id:)) : nil
        }

        /// Where it ends: its change's destination, or its own.
        var endStation: Station? {
            (change?.destinationID ?? destinationID).flatMap(StationDirectory.station(id:))
        }

        /// Checks the train and change against the station list; nil if the train's gone.
        func validated() -> Option? {
            guard let selection = selection.validatedIfKnown() else { return nil }
            return Option(selection: selection, change: change?.validated(for: selection), destinationID: destinationID)
        }
    }

    /// How long a shared trip shows.
    static let duration: TimeInterval = 60 * 60

    var expires: Date { shared.addingTimeInterval(Self.duration) }

    /// Whether it's showing at `date`: not before it was shared (clock set back), as it would
    /// otherwise show until then.
    func isActive(at date: Date) -> Bool {
        shared <= date && date < expires
    }

    /// Shows the trip on the Transit Directions widget for an hour from `shared`, replacing any
    /// other: from the Share sheet, or the app's New Trip tab.
    func show() {
        SharedStore.saveSharedTrip(self)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.directions)
    }

    /// Checks the trip against the station list; nil if its train's gone.
    func validated() -> SharedTrip? {
        option.validated().map { SharedTrip(option: $0, app: app, shared: shared, nearby: nearby, saved: saved, bothWays: bothWays) }
    }

    private enum CodingKeys: String, CodingKey {
        case option, app, shared, nearby, saved, bothWays
    }

    /// Where it came from, as the widget notes it.
    var source: TripSource {
        if let app { return .maps(app) }
        if nearby == true { return .nearby }
        if let saved { return .saved(saved) }
        return .quickTrip(to: option.destinationID.flatMap(StationDirectory.station(id:))?.name ?? "")
    }
}

// Older saves missing any field still load, with defaults (see `SharedStore`'s decoders)
extension SharedTrip {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        option = try container.decode(Option.self, forKey: .option)
        // An unknown app, from a later version, is taken as none
        app = try? container.decodeIfPresent(MapsApp.self, forKey: .app)
        shared = try container.decode(Date.self, forKey: .shared)
        nearby = try container.decodeIfPresent(Bool.self, forKey: .nearby)
        saved = try container.decodeIfPresent(String.self, forKey: .saved)
        bothWays = try container.decodeIfPresent(Bool.self, forKey: .bothWays)
    }
}

/// What Transit Directions shows in place of its Quick Trip and Favorite Stop buttons, noted along
/// its bottom, with a ✕ beside walk to go back to them.
enum TripSource: Hashable, Sendable {
    /// Directions shared from a maps app.
    case maps(MapsApp)
    /// A trip planned on the widget, to the named station.
    case quickTrip(to: String)
    /// Settings' default train.
    case favorite
    /// A train picked from the stations nearest you.
    case nearby
    /// One of Trip's journeys: the saved widget of that title.
    case saved(String)
}

/// The app directions were shared from, which the widget names.
enum MapsApp: String, Codable, Sendable {
    case apple, google

    /// "Apple Maps".
    var name: String {
        switch self {
        case .apple: "Apple Maps"
        case .google: "Google Maps"
        }
    }
}

extension SharedStore {
    private static let tripFile = url(named: "shared-trip.json")

    /// The shared trip, if it's still showing at `date`.
    static func loadSharedTrip(at date: Date = .now) -> SharedTrip? {
        guard let trip = read(SharedTrip.self, from: tripFile), trip.isActive(at: date) else { return nil }
        return trip.validated()
    }

    /// Replaces any shared trip, and any bus trip (`SharedBusTrip`), so the newest shows for an
    /// hour from now; nil ends both.
    static func saveSharedTrip(_ trip: SharedTrip?) {
        removeSharedBusTrip()
        guard let tripFile else { return }
        guard let trip, let data = try? JSONEncoder().encode(trip) else {
            try? FileManager.default.removeItem(at: tripFile)
            return
        }
        try? data.write(to: tripFile, options: .atomic)
    }
}

/// Where a walk from New Trip's Go is, for the Transit Directions widget to follow: on the train,
/// or walking out from it. Walking to a train, or at a change, there's none, and the widget shows
/// the trip's board for that train (the app shows the train changed to as the trip then).
struct WalkStage: Codable, Hashable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// On a train: getting off counted down, then what to do there.
        case riding
        /// Walking from the train to the end.
        case fromTrain
    }

    var phase: Phase
    /// The line you're on, or got off.
    var route: String
    /// "Times Sq-42 St"; "The Town Hall" walking out.
    var title: String
    /// "Ride in the front", "Change at DeKalb Av for the Q"; walking out, the first step.
    var instruction: String
    /// Riding, when it's due where you get off, and what to do then: "Up the stairs to the NE
    /// corner of Broadway & 41 St", "Across the platform to the Q".
    var getOff: Date? = nil
    var next: String? = nil
    var nextSymbol: String? = nil
    /// Where the walk ends, and when you'll be there.
    var endName: String
    var arrives: Date? = nil
    /// When the walk's countdown ends, at the latest: it's not shown after.
    var expires: Date

    /// The dates to draw it at: now, and on the train, getting off, when it says what to do there.
    func dates(from now: Date) -> [Date] {
        guard phase == .riding, let getOff, getOff > now else { return [now] }
        return [now, getOff]
    }
}

extension SharedStore {
    private static let walkStageFile = url(named: "walk-stage.json")

    /// The walk's stage, if one's on a train or walking out at `date`.
    static func loadWalkStage(at date: Date = .now) -> WalkStage? {
        guard let stage = read(WalkStage.self, from: walkStageFile), date < stage.expires else { return nil }
        return stage
    }

    /// Saves the walk's stage (nil for none: walking to a train, at a change, or ended), and
    /// redraws Transit Directions with it.
    static func saveWalkStage(_ stage: WalkStage?) {
        guard let walkStageFile else { return }
        if let stage, let data = try? JSONEncoder().encode(stage) {
            try? data.write(to: walkStageFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: walkStageFile)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.directions)
    }
}

/// The Transit Directions widget's ✕: ends the shared trip or Quick Trip, or leaves Favorite
/// Stop, so it goes back to its Quick Trip and Favorite Stop buttons.
struct EndSharedTripIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop showing directions"
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        SharedStore.saveSharedTrip(nil)
        SharedStore.saveWalkStage(nil)
        QuickTrip.update { $0.screen = .home }
        return .result()
    }
}
