import CoreLocation
import SwiftUI
import UserNotifications

/// How you use the subway: first-run setup's first question, which picks the screens after it.
enum RiderKind: Hashable {
    /// Mostly the same trip: Home and Work, one train toward Work, a reminder to leave.
    case commute
    /// All over the city: Home and the places you go, the lines you ride.
    case city
    /// Here for a few days: a hotel, the sights, and the day you leave.
    case visit
}

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
    var chipID: String { "chip \(title)" }

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

/// A commuter's weekday reminder to leave, from first-run setup; tapping it starts the home
/// station's countdown.
final class LeaveReminder: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LeaveReminder()
    private static let prefix = "leaveReminder."

    /// Set at launch, so a tap that launched the app is handled.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static var isAllowed: Bool {
        get async {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            return status == .authorized || status == .provisional
        }
    }

    /// Repeats Monday to Friday at `time`'s hour and minute, naming `train`.
    static func schedule(at time: Date, train: Selection) async {
        cancel()
        let center = UNUserNotificationCenter.current()
        let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
        let content = UNMutableNotificationContent()
        content.title = "Time to leave for work"
        content.body = "\(train.caption) from \(train.station?.name ?? "your station"). Tap to start your countdown."
        content.sound = .default
        // Sunday is 1
        for weekday in 2...6 {
            var when = clock
            when.weekday = weekday
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
            try? await center.add(UNNotificationRequest(identifier: "\(prefix)\(weekday)", content: content, trigger: trigger))
        }
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

/// First-run setup's answers, kept until Start Riding saves them.
@MainActor
@Observable
final class FirstRunAnswers {
    /// A place added beside Home on the city path; Work goes to its own slot.
    struct Added: Identifiable {
        let id = UUID()
        var name: String
        var place: TripPlace
        var isWork: Bool { name == "Work" }
    }

    private(set) var kind: RiderKind?
    var home: TripPlace?
    var work: TripPlace?
    var added: [Added] = []
    var remindsToLeave = true
    var leaveTime = Calendar.current.date(bySettingHour: 8, minute: 15, second: 0, of: .now) ?? .now
    /// The home station, as suggested or picked.
    var train: Selection?
    /// The commute's other suggestions, after `train`.
    private(set) var otherTrains: [Selection] = []
    var lines: Set<String> = []
    var hotel: TripPlace?
    var until = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
    var sights: Set<String> = []
    var walkMinutes = 15
    var bike: CitiBike.Kind?
    var buses = false
    var stepFree = false

    /// Picks the path, and its defaults for getting around: a commute's shortest walk, no bikes
    /// or buses; the city's 20 minutes, e-bikes and buses; a visitor's 30.
    func choose(_ kind: RiderKind) {
        guard kind != self.kind else { return }
        self.kind = kind
        walkMinutes = kind == .commute ? 15 : kind == .city ? 20 : 30
        bike = kind == .commute ? nil : .eBike
        buses = kind != .commute
    }

    /// The commute's trains: the trips planned from Home to Work, by their first station; or,
    /// with no Work or no trip, the stations nearest Home, toward Manhattan. The first is picked.
    func suggestCommute() {
        guard let start = home?.location else { return }
        var found: [Selection] = []
        if let end = work?.location {
            let range = NewTripView.walkChoices.first { $0.minutes == walkMinutes }?.meters ?? TripPlanner.walkRange
            found = TripPlanner.byWalking(from: start, to: end, walkRange: max(range, TripPlanner.walkRange)).map(\.selection)
        }
        if found.isEmpty {
            found = Nearby.stations(near: start, limit: 3).map { Self.towardManhattan(at: $0.station, routes: $0.station.routes) }
        }
        var seen = Set<String>()
        found = found.filter { seen.insert($0.stationID).inserted }
        train = found.first
        otherTrains = Array(found.dropFirst().prefix(2))
    }

    /// The city's home station: the nearest to Home with one of `lines` (any, with none picked),
    /// those of its lines, toward Manhattan.
    func suggestCityTrain() {
        guard let start = home?.location else { return }
        let near = Nearby.stations(near: start, limit: 60)
        guard let station = (near.first { lines.isEmpty || !lines.isDisjoint(with: $0.station.routes) } ?? near.first)?.station
        else { return }
        let routes = station.routes.filter { lines.isEmpty || lines.contains($0) }
        train = Self.towardManhattan(at: station, routes: routes.isEmpty ? station.routes : routes)
    }

    /// `routes` at `station` the way named for Manhattan, else north (Uptown, in Manhattan).
    private static func towardManhattan(at station: Station, routes: [String]) -> Selection {
        let direction = Direction.allCases.first { station.directionLabel($0, routes: routes).contains("Manhattan") } ?? .north
        return Selection(stationID: station.id, routes: routes, direction: direction)
    }

    /// Minutes walking from Home (or the hotel) to `selection`'s station.
    func walk(to selection: Selection) -> Int? {
        guard let from = (home ?? hotel)?.location, let station = selection.station else { return nil }
        let meters = from.distance(from: CLLocation(latitude: station.lat, longitude: station.lon))
        return max(1, Int((TripPlanner.walkSeconds(meters) / 60).rounded()))
    }

    /// Saves it all where the app keeps it: the places, the home station, how you'll go, the
    /// reminder, and a visit's stay.
    func save(to settings: SettingsStore) async {
        let saved = SavedPlaces.shared
        // Set up again, no longer visiting: Home and Work back
        if kind != .visit, saved.homeIsHotel { saved.setVisiting(false) }
        switch kind {
        case .commute:
            if let home { saved.set(.home, to: home) }
            if let work { saved.set(.work, to: work) }
        case .city:
            if let home { saved.set(.home, to: home) }
            for place in added {
                saved.set(place.isWork ? .work : .new(place.name), to: place.place)
            }
        case .visit:
            saved.setVisiting(true, hotel: hotel)
            VisitStay.save(until: until, picks: sights)
        case nil:
            break
        }
        if kind != .visit, let train { settings.settings.defaultTrain = train }
        settings.settings.includesBuses = buses
        settings.settings.stepFree = stepFree
        UserDefaults.standard.set(walkMinutes, forKey: "tripWalkMinutes")
        UserDefaults.standard.set(bike?.rawValue ?? "", forKey: "tripBike")
        if kind == .commute, remindsToLeave, let train, await LeaveReminder.isAllowed {
            await LeaveReminder.schedule(at: leaveTime, train: train)
        } else {
            LeaveReminder.cancel()
        }
    }
}

/// First-run setup, shown once on a new install: how you use the subway, then your places, your
/// station (or lines, or sights), how you'll get around, and permissions, each path its own.
struct FirstRunView: View {
    let done: () -> Void

    @Environment(SettingsStore.self) private var settings
    @State private var answers = FirstRunAnswers()
    @State private var step = 0
    @State private var location = NearbyLocation()
    /// The place being searched for, in a sheet.
    @State private var searching: Searching?
    @State private var choosingTrain = false
    @State private var namingPlace = false
    @State private var newPlaceName = ""
    @State private var notificationsAllowed = false
    @State private var saving = false

    private static let steps = 5
    private static let card = RoundedRectangle(cornerRadius: 26, style: .continuous)
    private static let faint = Color.primary.opacity(0.05)

    private enum Searching: Identifiable {
        case home, work, hotel, added(String)

        var id: String {
            switch self {
            case .home: "home"
            case .work: "work"
            case .hotel: "hotel"
            case .added(let name): "added \(name)"
            }
        }

        var title: String {
            switch self {
            case .home: "Home"
            case .work: "Work"
            case .hotel: "Your Hotel"
            case .added(let name): name
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            page
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .animation(.smooth, value: step)
        .background(Color(uiColor: .systemBackground))
        .onAppear { location.start() }
        .sheet(item: $searching) { searching in
            PlaceSearch(title: searching.title, location: location) { place in
                set(searching, to: place)
            }
        }
        .sheet(isPresented: $choosingTrain) {
            TrainPicker(selection: Binding {
                answers.train ?? SharedStore.load()
            } set: {
                answers.train = $0
            })
        }
        .alert("New Place", isPresented: $namingPlace) {
            TextField("Name", text: $newPlaceName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Next") {
                let name = newPlaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { searching = .added(name) }
            }
        } message: {
            Text("Name it, then pick where it is.")
        }
    }

    /// Back, the step dots, and Skip, which goes straight to the last screen.
    private var topBar: some View {
        HStack(spacing: 12) {
            // Its room kept on the first screen too, so the dots stay put
            Button {
                step -= 1
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .opacity(step > 0 ? 1 : 0)
            .disabled(step == 0)
            HStack(spacing: 6) {
                ForEach(0..<Self.steps, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: index == step ? 22 : 8, height: 8)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step + 1) of \(Self.steps)")
            Spacer()
            if step > 0 && step < Self.steps - 1 {
                Button("Skip") { step = Self.steps - 1 }
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
        switch (step, answers.kind) {
        case (0, _), (_, nil): usage
        case (1, .commute): commutePlaces
        case (1, .city): cityPlaces
        case (1, .visit): hotelPage
        case (2, .commute): commuteTrain
        case (2, .city): linesPage
        case (2, .visit): sightsPage
        case (3, _): gettingAround
        default: summary
        }
    }

    // MARK: - Pages

    private var usage: some View {
        Page(title: "How do you use the subway?", subtitle: "Leeway sets itself up around the trips you take.",
             canContinue: answers.kind != nil, next: next) {
            VStack(spacing: 10) {
                choiceCard(.commute, "briefcase.fill", "Getting to work or school", "Mostly the same trip, most days")
                choiceCard(.city, "map.fill", "Getting around the city", "I live here, I go all over")
                choiceCard(.visit, "suitcase.rolling.fill", "Just visiting", "Here for a few days")
            }
        }
    }

    private var commutePlaces: some View {
        Page(title: "Your commute", subtitle: "Where you start and where you're headed most days.", next: next) {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    placeRow("house.fill", "Home", answers.home) { searching = .home }
                    Divider().padding(.leading, 60)
                    placeRow("briefcase.fill", "Work", answers.work) { searching = .work }
                }
                .background(Self.faint, in: Self.card)
                .padding(.bottom, 14)

                cardLabel("Usually leave for work")
                VStack(spacing: 0) {
                    switchRow("bell.fill", "Remind me to leave", "Weekdays. Tap the reminder to start your countdown.",
                              isOn: $answers.remindsToLeave)
                    if answers.remindsToLeave {
                        Divider().padding(.leading, 52)
                        DatePicker(selection: $answers.leaveTime, displayedComponents: .hourAndMinute) {
                            Label {
                                Text("Leave at")
                            } icon: {
                                Image(systemName: "clock").foregroundStyle(.tint)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    }
                }
                .background(Self.faint, in: Self.card)
            }
        }
    }

    private var cityPlaces: some View {
        Page(title: "Where do you go?", subtitle: "Each becomes a one-tap trip in New Trip.", next: next) {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    placeRow("house.fill", "Home", answers.home) { searching = .home }
                    ForEach(answers.added) { added in
                        Divider().padding(.leading, 60)
                        placeRow(added.isWork ? "briefcase.fill" : "mappin", added.name, added.place,
                                 remove: { answers.added.removeAll { $0.id == added.id } }) {
                            searching = .added(added.name)
                        }
                    }
                }
                .background(Self.faint, in: Self.card)
                .padding(.bottom, 14)

                cardLabel("Add more")
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(["Work", "School", "Gym"].filter { name in !answers.added.contains { $0.name == name } },
                                id: \.self) { name in
                            Button {
                                searching = .added(name)
                            } label: {
                                chip(name, symbol: "plus")
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            newPlaceName = ""
                            namingPlace = true
                        } label: {
                            chip("Other", symbol: "plus")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    private var hotelPage: some View {
        Page(title: "Where are you staying?", subtitle: "Every trip can start or end at your hotel.", next: next) {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    placeRow("bed.double.fill", "Hotel", answers.hotel, prompt: "Search for your hotel or address") {
                        searching = .hotel
                    }
                }
                .background(Self.faint, in: Self.card)
                .padding(.bottom, 14)

                cardLabel("Here until")
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
                footnote("After that, Leeway asks before clearing your hotel and sights.")
            }
        }
    }

    private var commuteTrain: some View {
        Page(title: "Your train", subtitle: "Siri, the countdown and your first widget show it.", next: next) {
            VStack(spacing: 8) {
                if let train = answers.train {
                    cardLabel(answers.work == nil ? "Closest to Home" : "On your way to Work")
                    trainCard(train, picked: true)
                        .padding(.bottom, 14)
                }
                cardLabel(answers.train == nil ? "Pick a train" : "Or another")
                VStack(spacing: 0) {
                    ForEach(answers.otherTrains, id: \.trainID) { other in
                        Button {
                            answers.train = other
                        } label: {
                            stationRow(other)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 64)
                    }
                    Button {
                        choosingTrain = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass").frame(width: 36)
                            Text("Choose a station, line or direction")
                            Spacer()
                        }
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(Self.faint, in: Self.card)
            }
        }
        // Planned for Home and Work as they are now; changing either clears the train for this
        .onAppear { if answers.train == nil { answers.suggestCommute() } }
    }

    private var linesPage: some View {
        Page(title: "Lines you ride", subtitle: "Pick as many as you like. Your home station follows them.", next: next) {
            VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                    ForEach(Lines.filterRoutes, id: \.self) { line in
                        let on = answers.lines.contains(line)
                        Button {
                            if on { answers.lines.remove(line) } else { answers.lines.insert(line) }
                            answers.suggestCityTrain()
                        } label: {
                            LineBullet(route: line, size: 40)
                                .opacity(on || answers.lines.isEmpty ? 1 : 0.3)
                                .overlay(alignment: .bottomTrailing) {
                                    if on {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.white, .tint)
                                            .offset(x: 3, y: 3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Lines.name(of: line))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(16)
                .background(Self.faint, in: Self.card)
                .padding(.bottom, 14)

                cardLabel(answers.home == nil ? "Your station" : "Your station, nearest Home")
                if let train = answers.train {
                    trainCard(train, picked: false)
                } else {
                    Button("Choose a Train") { choosingTrain = true }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Self.faint, in: Self.card)
                }
            }
        }
        .onAppear { if answers.train == nil { answers.suggestCityTrain() } }
    }

    private var sightsPage: some View {
        Page(title: "What do you want to see?", subtitle: "Your picks top New Trip's Sightseeing list.", scrolls: false,
             next: next) {
            SightPicker(picked: $answers.sights)
        }
    }

    private var gettingAround: some View {
        Page(title: "Getting around",
             subtitle: answers.kind == .visit ? "Walking is half the fun. Change it on any trip." : "Change any of these on a trip.",
             next: next) {
            VStack(spacing: 8) {
                cardLabel("Walk up to (min)")
                HStack(spacing: 6) {
                    ForEach(NewTripView.walkChoices, id: \.minutes) { choice in
                        let on = choice.minutes == answers.walkMinutes
                        Button {
                            answers.walkMinutes = choice.minutes
                        } label: {
                            VStack(spacing: 1) {
                                Text(choice.minutes == 60 ? "60+" : "\(choice.minutes)").font(.subheadline.weight(.semibold))
                                Text(choice.miles).font(.caption2)
                                    .foregroundStyle(on ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                            }
                            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NewTripView.walkLabel(choice.minutes))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.bottom, 12)

                cardLabel(answers.kind == .visit ? "Citi Bike · Day Pass" : "Citi Bike")
                HStack(spacing: 8) {
                    bikeTile(nil, "xmark", "No bikes")
                    bikeTile(.bike, "bicycle", "Bike")
                    bikeTile(.eBike, "bolt.fill", "E-bike")
                }
                .padding(.bottom, 12)

                VStack(spacing: 0) {
                    switchRow("bus.fill", "Include buses",
                              answers.kind == .visit ? "Fine for short hops, and to the ferry" : "Where a bus beats the walk",
                              isOn: $answers.buses)
                    Divider().padding(.leading, 52)
                    switchRow("figure.roll", "Step-free trips", "Only stations with working elevators",
                              isOn: $answers.stepFree)
                }
                .background(Self.faint, in: Self.card)
            }
        }
    }

    private var summary: some View {
        Page(title: "You're set", subtitle: "Change any of these in Settings or on a trip.", primary: "Start Riding",
             canContinue: !saving, next: finish) {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(summaryRows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 56) }
                        HStack(spacing: 12) {
                            Image(systemName: row.symbol).foregroundStyle(.tint).frame(width: 30)
                            Text(row.title)
                            Spacer()
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
                    askRow("location.fill", "Location",
                           answers.kind == .visit ? "Trips from wherever you wander" : "Trips from where you are, and walking turns",
                           allowed: location.isAllowed, denied: location.status == .denied) {
                        location.find()
                    }
                    if answers.kind == .commute && answers.remindsToLeave {
                        Divider().padding(.leading, 56)
                        askRow("bell.badge.fill", "Notifications", "Your reminder to leave", allowed: notificationsAllowed,
                               denied: false) {
                            Task { notificationsAllowed = await LeaveReminder.requestPermission() }
                        }
                    }
                }
                .background(Self.faint, in: Self.card)
            }
        }
        .task { notificationsAllowed = await LeaveReminder.isAllowed }
    }

    /// What's been set, by path.
    private var summaryRows: [(symbol: String, title: String, value: String)] {
        var rows: [(String, String, String)] = []
        let walk = NewTripView.walkLabel(answers.walkMinutes)
        let bike = answers.bike.map { $0 == .eBike ? "E-bike" : "Bike" } ?? "No bikes"
        switch answers.kind {
        case .commute:
            rows.append(("house.fill", "Home", answers.home?.name ?? "Not set"))
            rows.append(("briefcase.fill", "Work", answers.work?.name ?? "Not set"))
            rows.append(("tram.fill", "Your train", answers.train?.station?.name ?? "Not set"))
            if answers.remindsToLeave {
                rows.append(("clock", "Reminder", "Weekdays \(answers.leaveTime.formatted(date: .omitted, time: .shortened))"))
            }
        case .city:
            rows.append(("house.fill", "Home", answers.home?.name ?? "Not set"))
            rows.append(("mappin", "Places", answers.added.isEmpty ? "None" : answers.added.map(\.name).formatted(.list(type: .and))))
            rows.append(("tram.fill", "Your station", answers.train?.station?.name ?? "Not set"))
        case .visit:
            rows.append(("bed.double.fill", "Hotel", answers.hotel?.name ?? "Not set"))
            rows.append(("star.fill", "Sights", answers.sights.isEmpty ? "None" : "\(answers.sights.count) saved"))
            rows.append(("calendar", "Until", answers.until.formatted(.dateTime.weekday().month().day())))
        case nil:
            break
        }
        rows.append(("figure.walk", "Walk up to", "\(walk) · \(bike)"))
        return rows
    }

    // MARK: - Steps

    private func next() {
        step = min(step + 1, Self.steps - 1)
    }

    private func finish() {
        saving = true
        Task {
            await answers.save(to: settings)
            done()
        }
    }

    private func set(_ searching: Searching, to place: TripPlace) {
        switch searching {
        case .home:
            answers.home = place
            answers.train = nil
        case .work:
            answers.work = place
            answers.train = nil
        case .hotel:
            answers.hotel = place
        case .added(let name):
            if let index = answers.added.firstIndex(where: { $0.name == name }) {
                answers.added[index].place = place
            } else {
                answers.added.append(.init(name: name, place: place))
            }
        }
    }

    // MARK: - Parts

    private func choiceCard(_ kind: RiderKind, _ symbol: String, _ title: String, _ detail: String) -> some View {
        let picked = answers.kind == kind
        return Button {
            answers.choose(kind)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(picked ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 48, height: 48)
                    .background(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.12)), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(16)
            .background(Self.faint, in: Self.card)
            .overlay(Self.card.strokeBorder(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
            .contentShape(Self.card)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// A place's row: its icon, name and address once set (or a prompt), a tap to search for it.
    private func placeRow(_ symbol: String, _ name: String, _ place: TripPlace?, prompt: String = "Search for an address or place",
                          remove: (() -> Void)? = nil, search: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: search) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(place == nil ? AnyShapeStyle(.gray) : AnyShapeStyle(.tint), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.headline)
                        Text(place.map { [$0.name, $0.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
                             ?? prompt)
                            .font(.subheadline)
                            .foregroundStyle(place == nil ? .tertiary : .secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: place == nil ? "magnifyingglass" : "pencil")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
    }

    /// The home station as a glass card, as Settings' Home Station; a tap picks another.
    private func trainCard(_ train: Selection, picked: Bool) -> some View {
        Button {
            choosingTrain = true
        } label: {
            HStack(spacing: 12) {
                LineBullets(routes: train.routes, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(train.station?.name ?? "").font(.title3.weight(.semibold)).lineLimit(2)
                    Text("\(train.linesLabel) toward \(train.heading)").font(.subheadline).foregroundStyle(.secondary)
                    if let minutes = answers.walk(to: train) {
                        Label("\(minutes) min walk from \(answers.kind == .visit ? "your hotel" : "Home")",
                              systemImage: "figure.walk")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "pencil")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: Circle())
            }
            .padding(16)
            .contentShape(Self.card)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Self.card)
        .overlay(Self.card.strokeBorder(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
        .accessibilityHint("Choose another station, line or direction")
    }

    private func stationRow(_ train: Selection) -> some View {
        HStack(spacing: 12) {
            LineBullets(routes: train.routes, size: 28).frame(width: LineBullets.width(count: 2, size: 28))
            VStack(alignment: .leading, spacing: 1) {
                Text(train.station?.name ?? "").font(.body.weight(.medium))
                Text("Toward \(train.heading)").font(.footnote).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer()
            if let minutes = answers.walk(to: train) {
                Text("\(minutes) min walk").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }

    private func bikeTile(_ kind: CitiBike.Kind?, _ symbol: String, _ name: String) -> some View {
        let on = answers.bike == kind
        return Button {
            answers.bike = kind
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.headline)
                Text(name).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Self.faint),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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

    private func chip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
    }

    private func cardLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One setup page: a big title and line, its content (scrolling, unless it scrolls itself), and
/// Continue at the foot.
private struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    var primary = "Continue"
    var scrolls = true
    var canContinue = true
    let next: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if scrolls {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        content
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                VStack(spacing: 0) {
                    header
                    content
                }
                .padding(.horizontal, 20)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            Button(action: next) {
                Text(primary)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(canContinue ? .accentColor : .gray).interactive(), in: Capsule())
            .disabled(!canContinue)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }
}

/// The sights in their sections, a chip bar over them that jumps to each, the one in view tinted.
private struct SightPicker: View {
    @Binding var picked: Set<String>
    @State private var inView = SightSection.all.first?.id
    /// The section a chip jumped to, tinted while it's in view, even if it can't scroll to the top.
    @State private var jumped: String?

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 12) {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        // Their own ids, so `scrollTo` finds the section, not its chip
                        ForEach(SightSection.all, id: \.chipID) { section in
                            let on = section.id == inView
                            Button {
                                inView = section.id
                                jumped = section.id
                                withAnimation { proxy.scrollTo(section.id, anchor: .top) }
                            } label: {
                                Text(section.jump)
                                    .font(.footnote.weight(.semibold))
                                    .fixedSize()
                                    .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                    .padding(.horizontal, 9)
                                    .frame(height: 32)
                                    .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Jump to \(section.title)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()

                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(SightSection.all) { section in
                            sectionView(section)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
                .onScrollTargetVisibilityChange(idType: String.self) { visible in
                    if let jumped, visible.contains(jumped) {
                        inView = jumped
                    } else if let first = visible.first {
                        jumped = nil
                        inView = first
                    }
                }
            }
        }
    }

    private func sectionView(_ section: SightSection) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(section.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                let count = section.sights.filter { picked.contains($0.id) }.count
                if count > 0 {
                    Text("\(count) picked").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(section.sights) { sight in
                    tile(sight)
                }
            }
        }
    }

    private func tile(_ sight: Sight) -> some View {
        let on = picked.contains(sight.id)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            if on { picked.remove(sight.id) } else { picked.insert(sight.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: sight.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                    .frame(width: 32, height: 32)
                    .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.12)), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(sight.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(sight.area).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxHeight: .infinity)
            .frame(minHeight: 72)
            .background(Color.primary.opacity(0.05), in: shape)
            .overlay(shape.strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Searching for a place to save: an address, a place or a station, as New Trip's search.
private struct PlaceSearch: View {
    let title: String
    let location: NearbyLocation
    let pick: (TripPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TripPlaceList(search: search, location: location, offersHere: false) { place in
                pick(place)
                dismiss()
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Address or place")
            .searchFocused($focused)
            .onAppear { focused = true }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }
}

#Preview {
    FirstRunView {}
        .environment(SettingsStore())
}
