import Contacts
import CoreLocation
import MapKit
import SwiftUI
import UserNotifications

/// A sight a visitor can keep as a one-tap trip, under the neighborhood it's in.
struct Sight: Hashable, Identifiable {
    let name: String
    let area: String
    let symbol: String
    let lat: Double
    let lon: Double

    var id: String { name }

    var place: TripPlace {
        TripPlace(name: name, detail: area, point: TripPlace.Point(latitude: lat, longitude: lon))
    }
}

/// The sights offered, in sections, each with the short name its jump chip shows.
struct SightSection: Identifiable {
    let title: String
    let jump: String
    let sights: [Sight]

    var id: String { title }

    static let all: [SightSection] = [
        SightSection(title: "Landmarks", jump: "Landmarks", sights: [
            Sight(name: "Times Square", area: "Midtown", symbol: "sparkles", lat: 40.7580, lon: -73.9855),
            // The ferry leaves from Battery Park; the island's no place to plan a subway trip to
            Sight(name: "Statue of Liberty", area: "Ferry from Battery Park", symbol: "ferry.fill",
                  lat: 40.7033, lon: -74.0170),
            Sight(name: "Empire State Building", area: "Midtown", symbol: "building.2.fill", lat: 40.7484, lon: -73.9857),
            Sight(name: "Brooklyn Bridge", area: "Downtown", symbol: "road.lanes", lat: 40.7118, lon: -74.0036),
            Sight(name: "9/11 Memorial", area: "Downtown", symbol: "building.columns.fill", lat: 40.7115, lon: -74.0134),
            Sight(name: "Rockefeller Center", area: "Midtown", symbol: "snowflake", lat: 40.7587, lon: -73.9787),
        ]),
        SightSection(title: "Museums", jump: "Museums", sights: [
            Sight(name: "The Met", area: "Upper East Side", symbol: "paintpalette.fill", lat: 40.7794, lon: -73.9632),
            Sight(name: "MoMA", area: "Midtown", symbol: "photo.artframe", lat: 40.7614, lon: -73.9776),
            Sight(name: "Natural History", area: "Upper West Side", symbol: "fossil.shell.fill", lat: 40.7813, lon: -73.9740),
            Sight(name: "Guggenheim", area: "Upper East Side", symbol: "circle.circle", lat: 40.7830, lon: -73.9590),
        ]),
        SightSection(title: "Parks & views", jump: "Parks", sights: [
            Sight(name: "Central Park", area: "Bethesda Terrace", symbol: "leaf.fill", lat: 40.7740, lon: -73.9708),
            Sight(name: "High Line", area: "Chelsea", symbol: "figure.walk", lat: 40.7398, lon: -74.0080),
            Sight(name: "Top of the Rock", area: "Midtown", symbol: "binoculars.fill", lat: 40.7591, lon: -73.9794),
            Sight(name: "Brooklyn Bridge Park", area: "Brooklyn", symbol: "tree.fill", lat: 40.7024, lon: -73.9967),
        ]),
        SightSection(title: "Shows & nights out", jump: "Shows", sights: [
            Sight(name: "Broadway", area: "Theater District", symbol: "theatermasks.fill", lat: 40.7590, lon: -73.9870),
            Sight(name: "Lincoln Center", area: "Upper West Side", symbol: "music.note", lat: 40.7725, lon: -73.9835),
            Sight(name: "Madison Square Garden", area: "Midtown", symbol: "sportscourt.fill", lat: 40.7505, lon: -73.9934),
            Sight(name: "Yankee Stadium", area: "The Bronx", symbol: "baseball.fill", lat: 40.8296, lon: -73.9262),
        ]),
        SightSection(title: "Food & shopping", jump: "Food", sights: [
            Sight(name: "Chelsea Market", area: "Chelsea", symbol: "fork.knife", lat: 40.7424, lon: -74.0061),
            Sight(name: "Chinatown", area: "Downtown", symbol: "takeoutbag.and.cup.and.straw.fill", lat: 40.7158, lon: -73.9970),
            Sight(name: "SoHo", area: "Downtown", symbol: "bag.fill", lat: 40.7246, lon: -73.9978),
            Sight(name: "Williamsburg", area: "Brooklyn", symbol: "cup.and.saucer.fill", lat: 40.7178, lon: -73.9573),
        ]),
    ]
}

/// A visitor's stay: the day they leave, to clear the hotel and their picks once it's over
/// (`AppTabs` asks first), and the sights they picked, atop New Trip's Sightseeing.
enum VisitStay {
    private static let untilKey = "visitStayUntil"
    private static let picksKey = "visitSights"

    static func save(until: Date, picks: Set<String>) {
        UserDefaults.standard.set(until, forKey: untilKey)
        UserDefaults.standard.set(Array(picks), forKey: picksKey)
    }

    /// The sights picked in setup, by name (`Sight.id`).
    static var picks: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: picksKey) ?? [])
    }

    /// Past the end of the day you said you'd leave.
    static var isOver: Bool {
        guard let until = UserDefaults.standard.object(forKey: untilKey) as? Date,
              let after = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: until)) else {
            return false
        }
        return Date.now >= after
    }

    /// Forgets the hotel and the picks; Home and Work come back.
    @MainActor
    static func clear() {
        SavedPlaces.shared.setVisiting(false)
        UserDefaults.standard.removeObject(forKey: picksKey)
        forget()
    }

    /// Stops asking, keeping the hotel and the picks.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: untilKey)
    }
}

/// New Trip's Sightseeing: every sight in its sections, your picks from setup first; a tap goes there.
struct SightseeingList: View {
    let pick: (TripPlace) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let picks = VisitStay.picks
        let picked = SightSection.all.flatMap(\.sights).filter { picks.contains($0.id) }
        NavigationStack {
            List {
                if !picked.isEmpty {
                    Section("Your Picks") {
                        ForEach(picked) { row($0) }
                    }
                }
                ForEach(SightSection.all) { section in
                    Section(section.title) {
                        ForEach(section.sights) { row($0) }
                    }
                }
            }
            .navigationTitle("Sightseeing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func row(_ sight: Sight) -> some View {
        Button {
            pick(sight.place)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: sight.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(.tint.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(sight.name).foregroundStyle(.primary)
                    Text(sight.area).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A weekday reminder to leave, which first-run setup used to offer; tapping it starts the home
/// station's countdown. Setup no longer sets one, and running it again clears one from before.
final class LeaveReminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LeaveReminder()
    private static let prefix = "leaveReminder."

    /// Set at launch, so a tap that launched the app is handled.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: (2...6).map { "\(prefix)\($0)" })
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier.hasPrefix(Self.prefix),
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        _ = try? await TrainActivityController.start(for: SharedStore.defaultTrain)
    }
}

/// Home (or the hotel) as setup's just picked it, for Nearby, under setup's cover, to start
/// loading the trains, buses and docks near it at once, ready as setup closes. Nearby goes by it
/// only until your location's found; it's not kept past this run.
@MainActor
@Observable
final class SetupHome {
    static let shared = SetupHome()
    var location: CLLocation?
}

/// First-run setup's answers, kept until Start Riding saves them. Walking, biking and step-free
/// start as Settings has them, for setup run again.
@MainActor
@Observable
final class FirstRunAnswers {
    /// Home, or while `visiting`, the hotel.
    private(set) var home: TripPlace?
    /// Whether `home` is a hotel, as MapKit has it: a visit, until the end of `until`.
    var visiting = false
    var until = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
    /// The stations nearest Home, nearest first: the map's, the first suggested.
    private(set) var nearby: [Nearby.Result] = []
    /// The home station, as suggested or picked; nil before Home's set.
    var train: Selection?
    /// Whether the widget shows `train` both ways (`AppSettings.defaultBothWays`).
    var bothWays = false
    /// No primary stop: no default train.
    var noStop = false
    /// The stop's a bus (`bus`), not `train`: the page's Subway or Bus, Subway at first.
    var busPicked = false
    /// The bus stops nearest Home, nearest first, once fetched with Bus picked; nil before.
    private(set) var busPlaces: [NearbyBusPlace]?
    /// Bus Time couldn't be reached for `busPlaces`; tried again by Try Again or picking Bus again.
    private(set) var busPlacesFailed = false
    /// The home stop as a bus, as suggested or picked; nil before Bus's.
    var bus: BusChoice?
    var walkPreference = UserDefaults.standard.string(forKey: WalkRouting.preferenceKey)
        .flatMap(WalkPreference.init(rawValue:)) ?? .balanced
    var walkMinutes = UserDefaults.standard.object(forKey: NewTripView.walkMinutesKey) as? Int ?? NewTripView.defaultWalkMinutes
    var stepFree = SharedStore.loadSettings().stepFree
    var bikeKinds = UserDefaults.standard.string(forKey: BikeKinds.key).flatMap(BikeKinds.init(rawValue:)) ?? BikeKinds.saved
    var citiBikeOff = UserDefaults.standard.bool(forKey: BikeKinds.offKey)
    var ownBike = UserDefaults.standard.string(forKey: OwnBike.key).flatMap(OwnBike.init(rawValue:)) ?? OwnBike.none
    var bikeCarry = UserDefaults.standard.string(forKey: BikeCarry.key).flatMap(BikeCarry.init(rawValue:)) ?? BikeCarry.all

    /// Sets Home from setup's search, a hotel making it a visit, and suggests the station
    /// nearest it.
    func setHome(_ place: TripPlace, isHotel: Bool) {
        home = place
        visiting = isHotel
        SetupHome.shared.location = place.location
        nearby = place.location.map { Nearby.stations(near: $0, limit: 3) } ?? []
        train = nearby.first.map { Self.towardManhattan(at: $0.station) }
        bothWays = false
        noStop = false
        busPlaces = nil
        busPlacesFailed = false
        bus = nil
    }

    /// The bus stops nearest Home, and the nearest's lines suggested, the first way.
    func findBusPlaces() async {
        guard busPlaces == nil, let home, let from = home.location else { return }
        busPlacesFailed = false
        let fetched = await NearbyBuses.places(near: from, wait: NearbyBuses.appWait)
        // Home changed meanwhile (Back, another address): these are the old one's
        guard self.home == home, busPlaces == nil else { return }
        guard let found = fetched else {
            busPlacesFailed = true
            return
        }
        busPlaces = Array(found.prefix(3))
        if bus == nil, let first = found.first { choose(first) }
    }

    /// Picks `place`, every line there, its first way.
    func choose(_ place: NearbyBusPlace) {
        bus = place.choice(lines: place.lines(at: .now).map(\.line), way: 0, both: false)
        noStop = false
    }

    /// The place `bus` is at, if it's one of `busPlaces`.
    var busPlace: NearbyBusPlace? {
        guard let bus else { return nil }
        return busPlaces?.first { $0.ways.contains { $0.stop.id == bus.stop.id || $0.stop.id == bus.otherStop?.id } }
    }

    /// Picks `station`, all its lines, toward Manhattan.
    func choose(_ station: Station) {
        train = Self.towardManhattan(at: station)
        bothWays = false
        noStop = false
    }

    /// `station`'s lines the way named for Manhattan, else north (Uptown, in Manhattan).
    private static func towardManhattan(at station: Station) -> Selection {
        let direction = Direction.allCases.first {
            station.directionLabel($0, routes: station.routes).contains("Manhattan")
        } ?? .north
        return Selection(stationID: station.id, routes: station.routes, direction: direction)
    }

    /// The ways `train`'s lines go on from its station, as the train picker offers them: not one
    /// where they all end.
    var ways: [Direction] {
        guard let train, let station = train.station else { return [] }
        let onward = station.onwardDirections(of: train.routes)
        return station.directions(of: train.routes).filter { $0 == train.direction || onward.contains($0) }
    }

    /// Minutes walking from Home (or the hotel) to `station`: as Nearby walks it, if it's one of
    /// `nearby`.
    func walk(to station: Station) -> Int? {
        if let near = nearby.first(where: { $0.station.id == station.id }) { return near.walkMinutes }
        guard let from = home?.location else { return nil }
        return TripPlanner.walkMinutes(from.distance(from: station.location))
    }

    /// Saves it all where the app keeps it: Home or the hotel, your stop and which way, and how
    /// you walk and bike.
    func save(to settings: SettingsStore) {
        let saved = SavedPlaces.shared
        // Set up again (Settings' Run Setup Again): the places from before, and a visit's hotel
        // and sights, forgotten for these, only now it's finished, so setup left part way
        // through keeps them
        VisitStay.clear()
        saved.clear()
        if let home, visiting {
            saved.setVisiting(true, hotel: home)
            VisitStay.save(until: until, picks: [])
        } else if let home {
            saved.set(.home, to: home)
        }
        // Once, so the widgets reload once
        var app = settings.settings
        if noStop {
            app.defaultTrain = nil
            app.defaultBothWays = false
            app.defaultBus = nil
        } else if busPicked, let bus {
            app.defaultBus = bus
        } else if let train {
            app.defaultTrain = train
            app.defaultBothWays = bothWays
            app.defaultBus = nil
        }
        app.stepFree = stepFree
        // For the Citi Bike and Nearby widgets, which can't read the app's own defaults
        app.bikeKinds = bikeKinds.shared
        settings.settings = app
        let defaults = UserDefaults.standard
        defaults.set(walkPreference.rawValue, forKey: WalkRouting.preferenceKey)
        defaults.set(walkMinutes, forKey: NewTripView.walkMinutesKey)
        defaults.set(bikeKinds.rawValue, forKey: BikeKinds.key)
        defaults.set(citiBikeOff, forKey: BikeKinds.offKey)
        defaults.set(ownBike.rawValue, forKey: OwnBike.key)
        defaults.set(bikeCarry.rawValue, forKey: BikeCarry.key)
        // New Trip's bike toggle on while there's a bike to ride
        defaults.set(!citiBikeOff || ownBike != OwnBike.none, forKey: NewTripView.bikeKey)
        // Setup no longer offers a reminder to leave: one it set before goes with the rest
        LeaveReminder.cancel()
    }
}

/// Setup's search for Home: the addresses and places MapKit suggests near the subway, as New
/// Trip's search has them, without its stations and contacts.
@MainActor
@Observable
private final class HomeSearch: NSObject, MKLocalSearchCompleterDelegate {
    /// How far from a station Home may be: 5 miles, as New Trip's places.
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
        let latitudePad = reach / Earth.metresPerDegree
        let longitudePad = reach / (Earth.metresPerDegree * cos(center.latitude * .pi / 180))
        return MKCoordinateRegion(center: center,
                                  span: MKCoordinateSpan(latitudeDelta: north - south + 2 * latitudePad,
                                                         longitudeDelta: east - west + 2 * longitudePad))
    }()

    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            if isBlank { results = [] }
            finding = !isBlank
            failed = false
            completer.queryFragment = Self.searchable(query)
        }
    }

    /// Waiting on MapKit's suggestions for what's typed, which can take seconds.
    private(set) var finding = false
    /// The last suggestions couldn't be had (offline, or Apple Maps throttling), rather than
    /// there being none, so the page doesn't say no address was found.
    private(set) var failed = false

    /// Whether `typed` came in at once, longer than one word more than `before`: AutoFill or a
    /// paste, of what's most likely a whole address.
    static func arrivedWhole(_ typed: String, after before: String) -> Bool {
        typed.count - before.count >= 12 && typed.contains(where: \.isNumber) && typed.contains(" ")
    }

    /// The street types an address's unit may follow, for `searchable(_:)`.
    private static let streetTypes = "st|street|ave|avenue|av|rd|road|pl|place|blvd|boulevard|dr|drive|ln|lane|ct|court|"
        + "ter|terrace|pkwy|parkway|way|sq|square|hwy|broadway"

    /// What's typed as MapKit finds it best. AutoFill's address has its apartment, which MapKit
    /// doesn't know and then matches poorly: "Apt 4B", "#4B", "3rd Floor", or "St 4B," dropped.
    /// And a bare street number after the house number, as "181 18", which MapKit matches to
    /// anything with an 18 in it, made "181 18th".
    static func searchable(_ typed: String) -> String {
        var text = typed.replacingOccurrences(of: "\n", with: ", ")
        // (rule, what's kept): a unit after a street type keeps the street type
        let units: [(String, String)] = [
            (#"[,\s]*\b\d+(?:st|nd|rd|th)\s+(?:fl|floor)\b\.?"#, ""),
            (#"[,\s]*\b(?:apt|apartment|unit|suite|ste|fl|floor|rm|room|ph|penthouse|bldg|building)\b\.?\s*#?\s*(?:[\w-]*\d[\w-]*|[a-z]\b)"#, ""),
            (#"[,\s]*#\s*[\w-]+"#, ""),
            (#"(\b(?:"# + streetTypes + #")\b\.?)\s+(?:\d{1,4}[a-z]?|[a-z]\d{1,3}|\d{1,4}-[a-z])(?=\s*(?:,|$))"#, "$1"),
        ]
        for (rule, kept) in units {
            text = text.replacingOccurrences(of: rule, with: kept, options: [.regularExpression, .caseInsensitive])
        }
        var words = text.split(separator: " ").map(String.init)
        guard let first = words.first,
              first.range(of: #"^\d+(-\d+)?[a-z]?$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return text.trimmingCharacters(in: .whitespaces)
        }
        // Straight after the house number, or after E, W and so on
        let sides: Set<String> = ["e", "w", "n", "s", "e.", "w.", "n.", "s.", "east", "west", "north", "south"]
        for index in words.indices.dropFirst() where index == 1 || sides.contains(words[index - 1].lowercased()) {
            let comma = words[index].hasSuffix(",") ? "," : ""
            guard words[index].first?.isNumber == true, let number = Int(words[index].dropLast(comma.count)),
                  (1..<300).contains(number) else { continue }
            words[index] = ordinal(number) + comma
        }
        return words.joined(separator: " ")
    }

    /// 1st, 2nd, 3rd, 4th, 11th, 21st.
    private static func ordinal(_ number: Int) -> String {
        let suffix = (11...13).contains(number % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][number % 10] ?? "th"
        return "\(number)\(suffix)"
    }

    /// Only New York's: the area round the stations takes in New Jersey too.
    private static func inNewYork(_ result: MKLocalSearchCompletion) -> Bool {
        result.subtitle.range(of: #"\bNY\b"#, options: .regularExpression) != nil
    }

    /// The addresses starting as typed first ("181 18th St" for "181 18"), then those at the same
    /// house number, then the rest as MapKit has them. Once a house number's typed, only those
    /// with it: MapKit's slow to answer, and its places for "1", "18" and so on (1 WTC) would show
    /// meanwhile.
    private static func ranked(_ results: [MKLocalSearchCompletion], for query: String) -> [MKLocalSearchCompletion] {
        let words = searchable(query).lowercased().split(separator: " ")
        guard let house = words.first, house.first?.isNumber == true else { return results }
        let start = words.prefix(2).joined(separator: " ")
        let number = #"\b"# + NSRegularExpression.escapedPattern(for: String(house)) + #"\b"#
        func rank(_ result: MKLocalSearchCompletion) -> Int {
            let title = result.title.lowercased()
            return title.hasPrefix(start) ? 0 : title.hasPrefix(house + " ") ? 1 : 2
        }
        return results
            .filter { ($0.title + " " + $0.subtitle).range(of: number, options: .regularExpression) != nil }
            .enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// Nothing typed but spaces: no suggestions, and Home shows again.
    var isBlank: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = Self.served
        completer.regionPriority = .required
    }

    // The completer calls back on the main thread
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            results = isBlank ? [] : Self.ranked(completer.results.filter(Self.inNewYork), for: query)
            finding = false
            failed = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            results = []
            finding = false
            failed = MapsTrouble(error) != nil
        }
    }

    /// A whole address, as AutoFill gives it, looked up straight away rather than waiting on
    /// suggestions for it: in New York and within `reach` of a station, or nil.
    static func place(forAddress typed: String) async -> TripPlace? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchable(typed)
        request.resultTypes = .address
        request.region = served
        request.regionPriority = .required
        guard let items = try? await MKLocalSearch(request: request).start().mapItems,
              let item = items.first(where: { item in
                  item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)?
                      .range(of: #"\bNY\b"#, options: .regularExpression) != nil
              }),
              let name = item.name,
              let nearest = Nearby.nearest(to: item.location), nearest.meters <= reach else { return nil }
        // "181 18th St, Brooklyn, NY  11215" → "Brooklyn, NY 11215", as a suggestion's line under it
        let full = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true) ?? ""
        let detail = full.replacingOccurrences(of: name + ", ", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let coordinate = item.location.coordinate
        return TripPlace(name: name, detail: detail.isEmpty ? nil : detail,
                         point: TripPlace.Point(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    /// Where `result` is, and whether it's a hotel; nil if it can't be found, or is further than
    /// `reach` from a station. Throws if Apple Maps couldn't be asked (`MapsTrouble`): offline,
    /// it's not that the place isn't there.
    static func place(for result: MKLocalSearchCompletion) async throws -> (place: TripPlace, isHotel: Bool)? {
        let request = MKLocalSearch.Request(completion: result)
        request.region = served
        request.regionPriority = .required
        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch {
            if MapsTrouble(error) != nil { throw error }
            return nil
        }
        guard let item = items.first,
              let nearest = Nearby.nearest(to: item.location), nearest.meters <= reach else { return nil }
        let coordinate = item.location.coordinate
        let place = TripPlace(name: result.title, detail: shortened(result.subtitle),
                              point: TripPlace.Point(latitude: coordinate.latitude, longitude: coordinate.longitude))
        return (place, item.pointOfInterestCategory == .hotel)
    }

    /// A suggestion's line under its name, without the country: "Brooklyn, NY 11215".
    static func shortened(_ subtitle: String) -> String {
        subtitle.replacingOccurrences(of: ", United States", with: "")
    }
}

/// First-run setup, shown once on a new install: what stays on the phone and what's sent, then
/// Home's address, your stop and which way, walking, biking, and a look over it all with the
/// permissions.
struct FirstRunView: View {
    let done: () -> Void

    @Environment(SettingsStore.self) private var settings
    @State private var answers = FirstRunAnswers()
    /// 0 is the privacy page, before the numbered steps.
    @State private var step = 0
    @State private var location = NearbyLocation()
    @State private var contacts = ContactSearch()
    @State private var search = HomeSearch()
    @FocusState private var searching: Bool
    /// The suggestion being looked up after a tap.
    @State private var looking: MKLocalSearchCompletion?
    /// An address that came in whole (AutoFill) being looked up (`lookUp(_:)`).
    @State private var lookingUp = false
    /// Suggestions looked up and not found near the subway.
    @State private var notFound: Set<MKLocalSearchCompletion> = []
    /// Suggestions tapped that couldn't be looked up, as offline: said so, not as not found,
    /// and tried again on another tap.
    @State private var unreachable: Set<MKLocalSearchCompletion> = []
    /// A visit's last day picked past the three offered.
    @State private var laterDay = false
    @State private var choosingTrain = false
    /// The stops map: fitted round Home and its stations, then turned NY North if Settings says.
    @State private var stopsPosition = MapCameraPosition.automatic
    /// Each way's next trains from the stop shown, once fetched.
    @State private var trains: [Direction: [Arrival]] = [:]

    /// The numbered steps, after the privacy page.
    private static let steps = 5
    private static let card = RoundedRectangle(cornerRadius: 26, style: .continuous)
    private static let faint = Color.primary.opacity(0.05)

    var body: some View {
        VStack(spacing: 0) {
            if step > 0 {
                topBar
            }
            page
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .animation(.smooth, value: step)
        .background(Color(uiColor: .systemBackground))
        .onAppear { location.start() }
        .sheet(isPresented: $choosingTrain) {
            HomeStopPicker(train: Binding {
                answers.train ?? SharedStore.load()
            } set: {
                answers.train = $0
                answers.noStop = false
            }, bothWays: $answers.bothWays, bus: Binding {
                answers.busPicked ? answers.bus : nil
            } set: { bus in
                // Nil when a train's picked
                answers.busPicked = bus != nil
                if let bus { answers.bus = bus }
                answers.noStop = false
            })
        }
    }

    /// Back, the step dots, and Skip, which goes straight to the last screen.
    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                searching = false
                step -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            HStack(spacing: 6) {
                ForEach(1...Self.steps, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: index == step ? 22 : 8, height: 8)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step) of \(Self.steps)")
            Spacer()
            if step < Self.steps {
                Button("Skip") {
                    searching = false
                    step = Self.steps
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case 0: privacyPage
        case 1: homePage
        case 2: stopPage
        case 3: walkingPage
        case 4: bikingPage
        default: summary
        }
    }

    // MARK: - Pages

    private var privacyPage: some View {
        Page(title: "Your privacy", subtitle: "No account and no sign-in.", primary: "Get Started", opening: true,
             next: next) {
            VStack(spacing: 8) {
                cardLabel("Kept on this iPhone", symbol: "iphone")
                VStack(spacing: 0) {
                    infoRow("house.fill", "Saved places", "Home, Work, and any other saved locations")
                    Divider().padding(.leading, 52)
                    infoRow("location.fill", "Your location",
                            "Leeway looks up the address if it's used as the start or end point, but it doesn't "
                                + "know it's your current location")
                    Divider().padding(.leading, 52)
                    infoRow("person.crop.circle.fill", "Your contacts",
                            "Leeway looks up the address if it's used as the start or end point, but it doesn't "
                                + "see your contacts")
                }
                .background(Self.faint, in: Self.card)
                .padding(.bottom, 14)

                cardLabel("Sent off your iPhone", symbol: "icloud")
                VStack(spacing: 0) {
                    infoRow("server.rack", "Leeway's server",
                            "A trip's start and end, to find routes, and your countdown's train, to keep it current")
                    Divider().padding(.leading, 52)
                    infoRow("map.fill", "Apple Maps", "Addresses you search, and some walking and bike directions")
                    Divider().padding(.leading, 52)
                    infoRow("tram.fill", "Train, bus and bike times",
                            "From the MTA and Citi Bike, some through Leeway's server. Nothing about you")
                }
                .background(Self.faint, in: Self.card)
                footnote("Crash reports are sent only if you turn on Share Diagnostics in Settings.")
            }
        }
    }

    private var homePage: some View {
        Page(title: "Where's home?", subtitle: "Your address. Leeway finds the stops near it and times your walk to them.",
             primary: answers.home == nil || !search.isBlank ? nil : "Continue", next: next) {
            VStack(spacing: 8) {
                searchField
                    .padding(.bottom, 6)
                if !search.isBlank {
                    if !search.results.isEmpty {
                        results
                    } else if search.finding || lookingUp {
                        searchNote("Searching…", finding: true)
                    } else if search.failed {
                        searchNote("Couldn't reach Apple Maps", finding: false)
                    } else {
                        searchNote("No addresses found in New York", finding: false)
                    }
                } else if let home = answers.home {
                    placeCard(home)
                    if answers.visiting {
                        visitDays
                    }
                }
                if !answers.visiting {
                    footnote("Visiting? Search for your hotel by name.")
                }
            }
        }
        .task {
            // Once the page has slid in
            guard answers.home == nil else { return }
            try? await Task.sleep(for: .seconds(0.4))
            searching = true
        }
    }

    private var stopPage: some View {
        Page(title: "This your stop?", subtitle: "The closest to home. Siri, the countdown and your first widget show it.",
             next: next) {
            VStack(spacing: 8) {
                if answers.home != nil {
                    Picker("Kind", selection: $answers.busPicked) {
                        Label("Subway", systemImage: "tram.fill").tag(false)
                        Label("Bus", systemImage: "bus.fill").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 6)
                }
                if answers.busPicked {
                    if let places = answers.busPlaces, !places.isEmpty {
                        stopsMap
                            .padding(.bottom, 6)
                    } else if answers.busPlacesFailed {
                        Button {
                            Task { await answers.findBusPlaces() }
                        } label: {
                            Label("Couldn't reach Bus Time. Try again", systemImage: "arrow.clockwise")
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                    } else if answers.busPlaces == nil, answers.home != nil {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Finding bus stops…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    if let bus = answers.bus {
                        busCard(bus)
                            .padding(.bottom, 14)
                    }
                } else {
                    if !answers.nearby.isEmpty {
                        stopsMap
                            .padding(.bottom, 6)
                    }
                    if let train = answers.train, let station = train.station {
                        stopCard(train, at: station)
                            .padding(.bottom, 14)
                    }
                }
                VStack(spacing: 0) {
                    anotherStop
                    Divider().padding(.leading, 52)
                    choiceRow("mappin.slash", "No primary stop", "Nearby shows the stations closest to wherever you are",
                              on: answers.noStop) {
                        answers.noStop = true
                    }
                }
                .background(Self.faint, in: Self.card)
            }
        }
        // Again for another station or its lines, not for another way
        .task(id: answers.train.map { "\($0.stationID) \($0.routes)" }) { await fetchTrains() }
        // Bus stops looked for once Bus is picked
        .task(id: answers.busPicked) {
            if answers.busPicked { await answers.findBusPlaces() }
        }
        .animation(.default, value: answers.busPicked)
    }

    private var walkingPage: some View {
        Page(title: "Walking Preferences", subtitle: "How New Trip plans your walks to and from the train.", next: next) {
            VStack(spacing: 8) {
                cardLabel("Routes")
                VStack(spacing: 0) {
                    // Safest first, as Settings has them
                    ForEach(Array(WalkPreference.allCases.reversed().enumerated()), id: \.element) { index, preference in
                        if index > 0 { Divider().padding(.leading, 52) }
                        choiceRow(preference.symbol, preference.name, preference.detail,
                                  on: answers.walkPreference == preference) {
                            answers.walkPreference = preference
                        }
                    }
                }
                .background(Self.faint, in: Self.card)
                .padding(.bottom, 14)

                WalkSlider(minutes: $answers.walkMinutes)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Self.faint, in: Self.card)
                footnote("New Trip offers rides with a walk up to this long at each end.")
                    .padding(.bottom, 14)

                cardLabel("Accessibility")
                switchRow("figure.roll", "Step-Free Mode", "Only stations with working elevators", isOn: $answers.stepFree)
                    .background(Self.faint, in: Self.card)
            }
        }
    }

    private var bikingPage: some View {
        Page(title: "Biking Preferences",
             subtitle: "How New Trip fits a bike into your trips. Leave them all off for no biking.", next: next) {
            VStack(spacing: 8) {
                cardLabel("Citi Bike")
                HStack(spacing: 8) {
                    bikeTile("Citi Bike", electric: false, own: false, on: citiBikeOn(.bike)) { toggleCitiBike(.bike) }
                    bikeTile("Citi E-Bike", electric: true, own: false, on: citiBikeOn(.eBike)) { toggleCitiBike(.eBike) }
                }
                .padding(.vertical, 14)
                .background(Self.faint, in: Self.card)
                footnote("Rides from a dock with bikes to one with room, to the train or all the way.")
                    .padding(.bottom, 14)

                cardLabel("Your own bike")
                HStack(spacing: 8) {
                    bikeTile("None", symbol: "xmark", electric: false, own: true, on: answers.ownBike == OwnBike.none) {
                        answers.ownBike = OwnBike.none
                    }
                    bikeTile("My Bike", electric: false, own: true, on: answers.ownBike == .bike) { answers.ownBike = .bike }
                    bikeTile("My E-Bike", electric: true, own: true, on: answers.ownBike == .eBike) { answers.ownBike = .eBike }
                }
                .padding(.vertical, 14)
                .background(Self.faint, in: Self.card)
                if answers.citiBikeOff && answers.ownBike == OwnBike.none {
                    footnote("Biking won't be shown in New Trip.")
                }

                if answers.ownBike != OwnBike.none {
                    cardLabel("With a train")
                        .padding(.top, 14)
                    VStack(spacing: 0) {
                        ForEach(Array(BikeCarry.allCases.enumerated()), id: \.element) { index, carry in
                            if index > 0 { Divider().padding(.leading, 52) }
                            choiceRow(carry.symbol, carry.name, carry.detail, on: answers.bikeCarry == carry) {
                                answers.bikeCarry = carry
                            }
                        }
                    }
                    .background(Self.faint, in: Self.card)
                }
            }
            .animation(.default, value: answers.ownBike)
        }
    }

    private var summary: some View {
        Page(title: "You're set", subtitle: "Change any of these in Settings.", primary: "Start Riding", next: finish) {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(summaryRows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 56) }
                        HStack(spacing: 12) {
                            Image(systemName: row.symbol).foregroundStyle(.tint).frame(width: 30)
                            Text(row.title)
                            Spacer()
                            if let routes = row.routes {
                                if routes.first.flatMap(BusLeg.line(of:)) != nil {
                                    HStack(spacing: 2) {
                                        ForEach(routes.compactMap(BusLeg.line(of:)).prefix(3), id: \.self) {
                                            BusBadge(line: $0, size: 20)
                                        }
                                    }
                                } else {
                                    LineBullets(routes: routes, size: 20)
                                }
                            }
                            Text(row.value).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(Self.faint, in: Self.card)
                .padding(.bottom, 14)

                cardLabel("So Leeway can help")
                VStack(spacing: 0) {
                    askRow("location.fill", "Location", "Trains near you, and walking turns",
                           allowed: location.isAllowed, denied: location.status == .denied || location.status == .restricted) {
                        location.find()
                    }
                    Divider().padding(.leading, 56)
                    askRow("person.crop.circle.fill", "Contacts", "Their addresses in New Trip",
                           allowed: contacts.status == .authorized || contacts.status == .limited,
                           denied: contacts.status == .denied || contacts.status == .restricted) {
                        Task { await contacts.ask() }
                    }
                }
                .background(Self.faint, in: Self.card)
                footnote("You can allow either later in Settings.")
            }
        }
    }

    /// What's been set, with the stop's lines.
    private var summaryRows: [(symbol: String, title: String, value: String, routes: [String]?)] {
        var rows: [(String, String, String, [String]?)] = []
        if answers.visiting {
            rows.append(("bed.double.fill", "Hotel", answers.home?.name ?? "Not set", nil))
            rows.append(("calendar", "Until", answers.until.formatted(.dateTime.weekday().month().day()), nil))
        } else {
            rows.append(("house.fill", "Home", answers.home?.name ?? "Not set", nil))
        }
        if answers.noStop {
            rows.append(("tram.fill", "Your stop", "None", nil))
        } else if answers.busPicked, let bus = answers.bus {
            // Bus lines as routes marked a bus's, for their badges
            rows.append(("bus.fill", "Your stop", bus.stopName, bus.allLines.map { BusLeg.prefix + $0 }))
            rows.append(bus.bothWays && bus.otherStop != nil ? ("arrow.up.arrow.down", "Way", "Both ways", nil)
                                                             : ("arrow.up", "Way", "Toward \(bus.shortWayName)", nil))
        } else if let train = answers.train {
            rows.append(("tram.fill", "Your stop", train.station?.name ?? "", train.routes))
            rows.append(answers.bothWays ? ("arrow.up.arrow.down", "Way", "Both ways", nil)
                                         : (train.direction == .north ? "arrow.up" : "arrow.down", "Way",
                                            "Toward \(train.heading)", nil))
        } else {
            rows.append(("tram.fill", "Your stop", "Not set", nil))
        }
        rows.append(("figure.walk", "Walking",
                     "\(answers.walkPreference.name) · up to \(NewTripView.walkLabel(answers.walkMinutes))", nil))
        rows.append(("figure.roll", "Step-free", answers.stepFree ? "On" : "Off", nil))
        rows.append(("bicycle", "Biking", bikingSummary, nil))
        return rows
    }

    /// "Citi Bikes · My Bike", or "None".
    private var bikingSummary: String {
        var parts: [String] = []
        if !answers.citiBikeOff {
            switch answers.bikeKinds {
            case .both: parts.append("Citi Bikes")
            case .bike: parts.append("Citi Bike")
            case .eBike: parts.append("Citi E-Bike")
            }
        }
        switch answers.ownBike {
        case .none: break
        case .bike: parts.append("My Bike")
        case .eBike: parts.append("My E-Bike")
        }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    // MARK: - Steps

    private func next() {
        searching = false
        step = min(step + 1, Self.steps)
    }

    private func finish() {
        answers.save(to: settings)
        done()
    }

    /// Looks `result` up and makes it Home, or marks it as not found near the subway, or as
    /// unreachable if Apple Maps couldn't be asked.
    private func pick(_ result: MKLocalSearchCompletion) {
        guard looking == nil else { return }
        looking = result
        unreachable.remove(result)
        Task {
            defer { looking = nil }
            let found: (place: TripPlace, isHotel: Bool)?
            do {
                found = try await HomeSearch.place(for: result)
            } catch {
                unreachable.insert(result)
                return
            }
            guard let found else {
                notFound.insert(result)
                return
            }
            answers.setHome(found.place, isHotel: found.isHotel)
            laterDay = false
            search.query = ""
            searching = false
        }
    }

    /// AutoFill's (or a pasted) address made Home at once, if it's found in New York near the
    /// subway; otherwise left to the suggestions. Not once one's been tapped.
    private func lookUp(_ typed: String) {
        lookingUp = true
        Task {
            defer { lookingUp = false }
            guard let place = await HomeSearch.place(forAddress: typed),
                  search.query == typed, looking == nil else { return }
            answers.setHome(place, isHotel: false)
            laterDay = false
            search.query = ""
            searching = false
        }
    }

    /// The next trains each way from the stop shown, as the train picker's direction step
    /// fetches them.
    private func fetchTrains() async {
        trains = [:]
        guard let train = answers.train else { return }
        let ways = answers.ways.map { Selection(stationID: train.stationID, routes: train.routes, direction: $0) }
        await withTaskGroup(of: (Direction, [Arrival]?).self) { group in
            for way in ways {
                group.addTask {
                    let board = try? await TrainService.board(for: way, includingAlerts: false, includingOutages: false,
                                                              fillingFrom: { TimetableStore.load() })
                    return (way.direction, board.map { way.catchable($0.trains, now: .now) })
                }
            }
            for await (direction, found) in group {
                // Not the last station's, landing after another's picked
                if let found, !Task.isCancelled { trains[direction] = found }
            }
        }
    }

    /// "Next: 4 min, 11 min", once fetched.
    private func nextTrains(_ direction: Direction) -> String? {
        guard let found = trains[direction] else { return nil }
        guard !found.isEmpty else { return "No trains soon" }
        let times = found.prefix(2).map { arrival in
            let minutes = Int(arrival.time.timeIntervalSinceNow / 60)
            return minutes <= 0 ? "Now" : "\(minutes) min"
        }
        return "Next: " + times.joined(separator: ", ")
    }

    // MARK: - Parts

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search for your address", text: $search.query)
                .focused($searching)
                .textContentType(.fullStreetAddress)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    if let first = search.results.first { pick(first) }
                }
                .onChange(of: search.query) { before, typed in
                    if HomeSearch.arrivedWhole(typed, after: before) { lookUp(typed) }
                }
            if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Self.faint, in: Capsule())
    }

    /// In place of suggestions: still searching, or none found.
    private func searchNote(_ text: String, finding: Bool) -> some View {
        HStack(spacing: 12) {
            if finding { ProgressView() }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Self.faint, in: Self.card)
    }

    /// MapKit's suggestions for what's typed, each looked up when tapped.
    private var results: some View {
        VStack(spacing: 0) {
            ForEach(Array(search.results.prefix(6).enumerated()), id: \.offset) { index, result in
                if index > 0 { Divider().padding(.leading, 60) }
                Button {
                    pick(result)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.red, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.title).font(.headline)
                            Text(notFound.contains(result) ? "Not found near the subway"
                                 : unreachable.contains(result) ? "Couldn't reach Apple Maps"
                                 : HomeSearch.shortened(result.subtitle))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        if looking == result {
                            ProgressView()
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 64)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(looking != nil)
            }
        }
        .background(Self.faint, in: Self.card)
    }

    /// Home once it's picked; a tap searches again.
    private func placeCard(_ home: TripPlace) -> some View {
        Button {
            searching = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: answers.visiting ? "bed.double.fill" : "house.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.tint, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(home.name).font(.headline)
                    if let detail = home.detail, !detail.isEmpty {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
            .contentShape(Self.card)
        }
        .buttonStyle(.plain)
        .background(Self.faint, in: Self.card)
        .accessibilityHint("Search for another address")
    }

    /// A hotel's last day: the next three, or a later one picked; or not a visit after all.
    private var visitDays: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let days = (1...3).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        return VStack(spacing: 8) {
            cardLabel("Looks like a hotel. Here until…")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(days, id: \.self) { day in
                    dayChip(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                            on: !laterDay && Calendar.current.isDate(answers.until, inSameDayAs: day)) {
                        laterDay = false
                        answers.until = day
                    }
                }
                dayChip("Later", on: laterDay) {
                    laterDay = true
                    if let last = days.last, answers.until < Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last {
                        answers.until = Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last
                    }
                }
            }
            if laterDay {
                DatePicker(selection: $answers.until, in: Date.now..., displayedComponents: .date) {
                    Label {
                        Text("Leaving on")
                    } icon: {
                        Image(systemName: "calendar").foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(Self.faint, in: Self.card)
            }
            Button("I live here") {
                answers.visiting = false
                laterDay = false
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            footnote("Trips start and end at your hotel, and Leeway asks before clearing it once you've gone.")
        }
        .padding(.top, 14)
    }

    private func dayChip(_ title: String, on: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Home and the stations nearest it; a tap on one picks it.
    private var stopsMap: some View {
        Map(position: $stopsPosition, interactionModes: []) {
            if let point = answers.home?.point {
                Annotation(answers.visiting ? "Hotel" : "Home",
                           coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                    Image(systemName: answers.visiting ? "bed.double.fill" : "house.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.tint, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            if answers.busPicked {
                ForEach(answers.busPlaces ?? [], id: \.self) { place in
                    if let stop = place.ways.first?.stop {
                        let chosen = !answers.noStop && answers.busPlace == place
                        Annotation(place.name, coordinate: CLLocationCoordinate2D(latitude: stop.latitude,
                                                                                  longitude: stop.longitude)) {
                            Button {
                                answers.choose(place)
                            } label: {
                                HStack(spacing: 2) {
                                    ForEach(place.lines(at: .now).prefix(3).map(\.line), id: \.self) {
                                        BusBadge(line: $0, size: chosen ? 24 : 18)
                                    }
                                }
                                .padding(chosen ? 3 : 0)
                                .background(chosen ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .stroke(chosen ? Color.accentColor : Color.clear, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(place.name)
                        }
                    }
                }
            }
            ForEach(answers.busPicked ? [] : answers.nearby) { near in
                let chosen = !answers.noStop && answers.train?.station?.id == near.station.id
                Annotation(near.station.name, coordinate: near.station.coordinate) {
                    Button {
                        answers.choose(near.station)
                    } label: {
                        LineBullets(routes: near.station.routes, size: chosen ? 26 : 20)
                            .padding(chosen ? 3 : 0)
                            .background(chosen ? Color.white : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(chosen ? Color.accentColor : Color.clear, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(near.station.name)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // A little further out turned, for the corners of what it fitted
        .turnsNorth($stopsPosition, widening: 1.3)
        // Fitted again round new stations, or bus stops
        .onChange(of: answers.nearby.map(\.id)) { stopsPosition = .automatic }
        .onChange(of: answers.busPicked) { stopsPosition = .automatic }
        .onChange(of: answers.busPlaces?.count) { stopsPosition = .automatic }
        .frame(height: 140)
        .clipShape(Self.card)
    }

    /// The stop: its lines and name, the walk there, then which way you ride, or both.
    private func stopCard(_ train: Selection, at station: Station) -> some View {
        let picked = !answers.noStop
        let ways = answers.ways
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                LineBullets(routes: train.routes, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(station.name).font(.title3.weight(.semibold)).lineLimit(2)
                    if let minutes = answers.walk(to: station) {
                        Label("\(minutes) min walk from \(answers.visiting ? "your hotel" : "home")", systemImage: "figure.walk")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .accessibilityElement(children: .combine)
            Divider().padding(.leading, 16)
            cardLabel("Which way do you ride?")
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 2)
            ForEach(Array(ways.enumerated()), id: \.element) { index, direction in
                if index > 0 { Divider().padding(.leading, 52) }
                choiceRow(direction == .north ? "arrow.up" : "arrow.down",
                          "Toward \(station.directionLabel(direction, routes: train.routes))", nextTrains(direction),
                          on: picked && !answers.bothWays && train.direction == direction) {
                    var way = train
                    way.direction = direction
                    answers.train = way
                    answers.bothWays = false
                    answers.noStop = false
                }
            }
            if ways.count == 2 {
                Divider().padding(.leading, 52)
                choiceRow("arrow.up.arrow.down", "Both ways", "The medium widget shows the next train each way",
                          on: picked && answers.bothWays) {
                    answers.bothWays = true
                    answers.noStop = false
                }
            }
        }
        .glassEffect(.regular, in: Self.card)
        .overlay(Self.card.strokeBorder(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
    }

    /// A bus stop: its lines' badges, the walk, then with more than one line which you ride (any,
    /// ticked as tiles), then which way. Each way is its own stop, one each side of the street, so
    /// each says which side; Both ways keeps the two. A stop picked from Another stop, not among
    /// those found near Home, shows just its way.
    private func busCard(_ bus: BusChoice) -> some View {
        let picked = !answers.noStop
        let place = answers.busPlace
        let allLines = place?.lines(at: .now).map(\.line) ?? bus.allLines
        let lines = bus.allLines
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    ForEach(lines.prefix(3), id: \.self) { BusBadge(line: $0, size: lines.count > 1 ? 32 : 40) }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(bus.stopName).font(.title3.weight(.semibold)).lineLimit(2)
                    if let minutes = place?.walkMinutes {
                        Label("\(minutes) min walk from \(answers.visiting ? "your hotel" : "home")", systemImage: "figure.walk")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .accessibilityElement(children: .combine)
            if let place, allLines.count > 1 {
                Divider().padding(.leading, 16)
                cardLabel("Which lines do you ride? One or more")
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(place.lines(at: .now), id: \.line) { pick in
                        busLineTile(pick, on: lines.contains(pick.line)) {
                            var chosen = lines.contains(pick.line) ? lines.filter { $0 != pick.line } : lines + [pick.line]
                            // Never none; in the stop's order
                            guard !chosen.isEmpty else { return }
                            chosen = allLines.filter(chosen.contains)
                            // The same way, found among the new lines' ways, whose order can differ
                            let index = place.ways(for: chosen).firstIndex { $0.stop.id == bus.stop.id } ?? 0
                            answers.bus = place.choice(lines: chosen, way: index, both: bus.bothWays)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            Divider().padding(.leading, 16)
            cardLabel("Which way do you ride?")
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 2)
            if let place {
                let ways = place.ways(for: lines)
                ForEach(ways.indices, id: \.self) { index in
                    let way = ways[index]
                    if index > 0 { Divider().padding(.leading, 52) }
                    choiceRow(index == 0 ? "arrow.up" : "arrow.down", "Toward \(place.going(way, lines: lines))",
                              place.detail(way, index: index, lines: lines, now: .now),
                              on: picked && !bus.bothWays && bus.stop.id == way.stop.id) {
                        answers.bus = place.choice(lines: lines, way: index, both: false)
                        answers.noStop = false
                    }
                }
                if ways.count == 2 {
                    Divider().padding(.leading, 52)
                    choiceRow("arrow.up.arrow.down", "Both ways", "The medium widget shows the next bus each way",
                              on: picked && bus.bothWays) {
                        let index = ways.firstIndex { $0.stop.id == bus.stop.id } ?? 0
                        answers.bus = place.choice(lines: lines, way: index, both: true)
                        answers.noStop = false
                    }
                }
            } else {
                choiceRow("arrow.up", bus.bothWays && bus.otherStop != nil ? "Both ways" : "Toward \(bus.shortWayName)",
                          nil, on: picked) {
                    answers.noStop = false
                }
            }
        }
        .glassEffect(.regular, in: Self.card)
        .overlay(Self.card.strokeBorder(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
    }

    /// A line at the bus stop, ticked while it's ridden.
    private func busLineTile(_ pick: NearbyBusPick, on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                BusBadge(line: pick.line, size: 26)
                Text(pick.ways.map(\.name).joined(separator: " – "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(on ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(BusBadge.spokenName(pick.line))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The train picker, for a stop that isn't on the map.
    private var anotherStop: some View {
        let others = answers.busPicked
            ? (answers.busPlaces ?? []).filter { $0 != answers.busPlace }.map(\.name)
            : answers.nearby.map(\.station).filter { $0.id != answers.train?.stationID }.map(\.name)
        return Button {
            choosingTrain = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(answers.train == nil ? "Choose a stop" : "Another stop")
                    Text(answers.busPicked
                         ? (others.isEmpty ? "Any bus line or stop" : "\(others.joined(separator: ", ")), or any bus line")
                         : (others.isEmpty ? "Any station, line or direction" : "\(others.joined(separator: ", ")), or any station"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.tint)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One of a few choices, ticked while it's the one picked.
    private func choiceRow(_ symbol: String, _ title: String, _ detail: String?, on: Bool,
                           pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// A row of the privacy page: its icon, what it is, and what happens to it.
    private func infoRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    /// A bike as Settings' Biking draws it: Citi Bike blue while on for Citi Bike's, the tint for
    /// your own; a bolt on e-bikes; its name under it.
    private func bikeTile(_ name: String, symbol: String = "bicycle", electric: Bool, own: Bool, on: Bool,
                          tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 64, height: 46)
                    .background(on ? (own ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.citiBike)) : AnyShapeStyle(.quaternary),
                                in: Capsule())
                    .eBikeBadge(electric)
                Text(name)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(on ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Whether Citi Bike's `kind` is on, as Settings' tiles have it.
    private func citiBikeOn(_ kind: CitiBike.Kind) -> Bool {
        !answers.citiBikeOff && (answers.bikeKinds == .both || answers.bikeKinds.kinds == [kind])
    }

    /// As Settings' tiles: turning the last off turns Citi Bike off, the kinds kept as they were;
    /// turning one on again picks just it.
    private func toggleCitiBike(_ kind: CitiBike.Kind) {
        let this: BikeKinds = kind == .bike ? .bike : .eBike
        let other: BikeKinds = kind == .bike ? .eBike : .bike
        if !citiBikeOn(kind) {
            answers.bikeKinds = answers.citiBikeOff ? this : answers.bikeKinds == other ? .both : answers.bikeKinds
            answers.citiBikeOff = false
        } else if answers.bikeKinds == .both {
            answers.bikeKinds = other
        } else {
            answers.citiBikeOff = true
        }
    }

    private func switchRow(_ symbol: String, _ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
    }

    /// A permission to ask for: Allow, then Allowed once it is (or Off in Settings).
    private func askRow(_ symbol: String, _ title: String, _ detail: String, allowed: Bool, denied: Bool,
                        ask: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if allowed {
                Label("Allowed", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if denied {
                Text("Off in Settings").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Button("Allow", action: ask)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
    }

    private func cardLabel(_ title: String, symbol: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How each walk preference is offered: its name and icon, and how much it gives for safety.
private extension WalkPreference {
    var name: String {
        switch self {
        case .fastest: "Fastest"
        case .balanced: "Balanced"
        case .safest: "Safest"
        }
    }

    var symbol: String {
        switch self {
        case .fastest: "hare.fill"
        case .balanced: "scale.3d"
        case .safest: "checkmark.shield.fill"
        }
    }

    var detail: String {
        switch self {
        case .fastest: "The quickest way"
        case .balanced: "A little longer, for safer crossings"
        case .safest: "Goes well out of its way for lights and quieter streets"
        }
    }
}

/// What your own bike does on a trip with a train, said in full.
private extension BikeCarry {
    var symbol: String {
        switch self {
        case .none: "nosign"
        case .bring: "tram.fill"
        case .leave: "lock.fill"
        case .all: "arrow.triangle.branch"
        }
    }

    var detail: String {
        switch self {
        case .none: "Ride it only on trips without a train"
        case .bring: "Take it on the train, and ride on after"
        case .leave: "Lock it at the station you ride to"
        case .all: "Any of these, whichever's sooner"
        }
    }
}

/// One setup page: a big title and line, its content, scrolling, and its button at the foot, if
/// it has one.
private struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    var primary: String? = "Continue"
    /// The privacy page, before the steps: no top bar over it, so its title sits lower.
    var opening = false
    let next: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            if let primary {
                Button(action: next) {
                    Text(primary)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.accentColor).interactive(), in: Capsule())
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, opening ? 40 : 12)
        .padding(.bottom, 20)
    }
}

#Preview {
    FirstRunView {}
        .environment(SettingsStore())
}
