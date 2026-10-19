import Foundation

/// Where the app leaves the choice for the widget: a file in an App Group
/// container that both belong to (a widget can't read the app's own files).
enum SharedStore {
    static let fallbackGroupID = "group.com.rtrainwidget.app"

    /// AltStore swaps the group for one unique to your Apple ID and lists it in
    /// Info.plist as ALTAppGroups, so look there first, in the widget's and then the app's.
    private static var candidateGroups: [String] {
        var groups = altGroups(in: Bundle.main)
        if Bundle.main.bundleURL.pathExtension == "appex" {
            let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let app = Bundle(url: appURL) { groups += altGroups(in: app) }
        }
        return groups + [fallbackGroupID]
    }

    private static func altGroups(in bundle: Bundle) -> [String] {
        bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    }

    /// Nil when this install isn't in an App Group, e.g. it was signed without the entitlement.
    private static let container: URL? = candidateGroups
        .lazy
        .compactMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        .first
    private static let file = container?.appendingPathComponent("selection.json")
    private static let countdownFile = container?.appendingPathComponent("countdown.json")
    private static let mapFile = container?.appendingPathComponent("map.json")
    private static let alertFile = container?.appendingPathComponent("alert.json")
    private static let tapsFile = container?.appendingPathComponent("taps.json")
    private static let boardsFile = container?.appendingPathComponent("boards.json")
    private static let widgetsFile = container?.appendingPathComponent("widgets.json")
    private static let settingsFile = container?.appendingPathComponent("settings.json")
    private static let placeFile = container?.appendingPathComponent("place.json")

    /// Whether a choice made in the app can reach the widget on this install.
    static var isAvailable: Bool { file != nil }

    static func load() -> Selection {
        savedSelection()?.validated() ?? .fallback
    }

    /// The app's choice as saved, before checking it against the station list.
    private static func savedSelection() -> Selection? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Selection.self, from: data)
    }

    @discardableResult
    static func save(_ selection: Selection) -> Bool {
        guard let file, let data = try? JSONEncoder().encode(selection) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// The train the Lock Screen countdown is for. Widgets can't see Live
    /// Activities, so the app leaves this for their walk buttons.
    struct Countdown: Codable, Equatable {
        /// A `Selection.trainID`.
        var trainID: String
        /// When iOS will have ended it.
        var ends: Date
        /// The `TrainEntry.widgetID` of the widget whose walk button started
        /// it, which alone shows it; nil when started in the app, when every
        /// widget for the train does.
        var widgetID: String? = nil

        /// Whether it's this widget's, so its walk button stops it.
        func isShown(onWidget widgetID: String, for trainID: String) -> Bool {
            trainID == self.trainID && (self.widgetID == nil || self.widgetID == widgetID)
        }
    }

    static func loadCountdown() -> Countdown? {
        guard let countdownFile, let data = try? Data(contentsOf: countdownFile) else { return nil }
        return try? JSONDecoder().decode(Countdown.self, from: data)
    }

    /// Nil once no countdown is running.
    static func saveCountdown(_ countdown: Countdown?) {
        guard let countdownFile else { return }
        if let countdown, let data = try? JSONEncoder().encode(countdown) {
            try? data.write(to: countdownFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: countdownFile)
        }
    }

    /// Whether this widget (a `TrainEntry.widgetID`) shows where this train
    /// (a `Selection.trainID`) is instead of the later trains. A widget can't
    /// keep state of its own, so its map button leaves it here. Kept by train
    /// too, so the other train of commuting hours starts out with its times.
    static func showsMap(for trainID: String, in widgetID: String) -> Bool {
        trains(in: mapFile).contains("\(widgetID) \(trainID)")
    }

    static func toggleMap(for trainID: String, in widgetID: String) {
        toggle("\(widgetID) \(trainID)", in: mapFile)
    }

    /// Whether this widget shows the alert of this train, with these alerts
    /// (a `Selection.alertID`), in full instead of the times. Its banner
    /// leaves it here, as the map button does.
    static func showsAlert(for alertID: String, in widgetID: String) -> Bool {
        trains(in: alertFile).contains("\(widgetID) \(alertID)")
    }

    static func toggleAlert(for alertID: String, in widgetID: String) {
        toggle("\(widgetID) \(alertID)", in: alertFile)
    }

    /// Closes the widget's alert. Unlike a toggle, two reloads doing this at
    /// once can't open it again.
    static func closeAlert(for alertID: String, in widgetID: String) {
        guard let alertFile else { return }
        changing(alertFile) {
            var trains = trains(in: alertFile)
            guard trains.remove("\(widgetID) \(alertID)") != nil else { return }
            write(trains, to: alertFile)
        }
    }

    private static func toggle(_ trainID: String, in file: URL?) {
        guard let file else { return }
        changing(file) {
            var trains = trains(in: file)
            if trains.remove(trainID) == nil { trains.insert(trainID) }
            write(trains, to: file)
        }
    }

    private static func write(_ trains: Set<String>, to file: URL) {
        if let data = try? JSONEncoder().encode(trains.sorted()) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Reads and rewrites `file` in `body` with no other change to it in
    /// between, from this process or another: several widgets reload at once,
    /// and the app can write the same files.
    private static func changing(_ file: URL, _ body: () -> Void) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &error) { _ in body() }
    }

    private static func trains(in file: URL?) -> Set<String> {
        guard let file, let data = try? Data(contentsOf: file),
              let trains = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(trains)
    }

    /// When one widget's buttons were last tapped, so it alone redraws as
    /// they ask: iOS reloads only the widget tapped.
    struct Taps: Codable {
        /// ↻, so it never redraws with times from before.
        var refreshed: Date?
        /// The map or walk button or the alert banner. Those change only how
        /// the widget looks, so it redraws with the times it already has.
        var toggled: Date?

        var latest: Date? { [refreshed, toggled].compactMap { $0 }.max() }
    }

    /// A `TrainEntry.widgetID`'s taps.
    static func loadTaps(for widgetID: String) -> Taps {
        savedTaps()[widgetID] ?? Taps()
    }

    /// Sets `tap` to now for the widget. Only the last hour's are kept: after
    /// that, none of them changes how a widget redraws.
    static func recordTap(_ tap: WritableKeyPath<Taps, Date?>, for widgetID: String) {
        guard let tapsFile else { return }
        let now = Date.now
        changing(tapsFile) {
            var taps = savedTaps().filter { $0.value.latest.map { now.timeIntervalSince($0) < 60 * 60 } ?? false }
            taps[widgetID, default: Taps()][keyPath: tap] = now
            if let data = try? JSONEncoder().encode(taps) {
                try? data.write(to: tapsFile, options: .atomic)
            }
        }
    }

    private static func savedTaps() -> [String: Taps] {
        guard let tapsFile, let data = try? Data(contentsOf: tapsFile),
              let taps = try? JSONDecoder().decode([String: Taps].self, from: data) else { return [:] }
        return taps
    }

    /// A train's times and alert as last fetched, by a widget or the countdown,
    /// so a widget redrawn soon after needn't wait on the MTA.
    struct SavedBoard: Codable {
        var fetched: Date
        var trains: [Arrival]
        var notice: Notice?
        /// With a change, the trains that get there and the trains they meet.
        var connections: [Connection]? = nil
    }

    /// With `change`, the times of the large widget showing it.
    static func loadBoard(for selection: Selection, change: Change? = nil) -> SavedBoard? {
        savedBoards()[boardKey(selection, change: change)]
    }

    /// Kept for an hour: iOS can leave a widget that long between reloads,
    /// showing these times, and a tap redraws it with them.
    @discardableResult
    static func saveBoard(_ board: Board, for selection: Selection, change: Change? = nil, fetched: Date) -> SavedBoard {
        let saved = SavedBoard(fetched: fetched, trains: board.trains,
                               notice: board.notice(for: selection, settings: loadSettings()),
                               connections: change == nil ? nil : board.connections)
        guard let boardsFile else { return saved }
        let key = boardKey(selection, change: change)
        changing(boardsFile) {
            var boards = savedBoards().filter { fetched.timeIntervalSince($0.value.fetched) < 60 * 60 }
            boards[key] = saved
            if let data = try? JSONEncoder().encode(boards) {
                try? data.write(to: boardsFile, options: .atomic)
            }
        }
        return saved
    }

    private static func savedBoards() -> [String: SavedBoard] {
        guard let boardsFile, let data = try? Data(contentsOf: boardsFile),
              let boards = try? JSONDecoder().decode([String: SavedBoard].self, from: data) else { return [:] }
        return boards
    }

    /// The board depends on the train, any change, and which alerts it
    /// mentions, which Settings has a say in too.
    private static func boardKey(_ selection: Selection, change: Change?) -> String {
        let kinds = loadSettings().alertKinds.map(\.rawValue).sorted().map(String.init).joined(separator: ",")
        let key = "\(selection.trainID) \(selection.elevatorAlerts) \(selection.serviceAlerts) \(kinds)"
        return change.map { "\(key) change \($0.key)" } ?? key
    }

    /// What the Nearby widget last called where you were, so it looks the name
    /// up again only once you've moved on.
    struct Place: Codable {
        var latitude: Double
        var longitude: Double
        /// "Park Slope"; nil where the lookup failed.
        var name: String?
    }

    static func loadPlace() -> Place? {
        guard let placeFile, let data = try? Data(contentsOf: placeFile) else { return nil }
        return try? JSONDecoder().decode(Place.self, from: data)
    }

    static func savePlace(_ place: Place) {
        guard let placeFile, let data = try? JSONEncoder().encode(place) else { return }
        try? data.write(to: placeFile, options: .atomic)
    }

    /// The choices made in the app's Settings tab; the defaults until there are any.
    static func loadSettings() -> AppSettings {
        guard let settingsFile, let data = try? Data(contentsOf: settingsFile),
              let saved = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return saved
    }

    static func saveSettings(_ settings: AppSettings) {
        guard let settingsFile, let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsFile, options: .atomic)
    }

    /// The widgets set up in the app, each train checked against the station
    /// list. Before there were any, the one train chosen in the app becomes
    /// the first, and the default. Its id is always the same, so a widget set
    /// up before the app saves it still finds it.
    static func loadWidgets() -> SavedWidgets {
        ((try? savedWidgets()) ?? firstWidgets).validated()
    }

    /// The widgets as saved, before checking them against the station list,
    /// for the app to change and save again: saving what checking made of them
    /// would turn a train at a station the list lacks into Prospect Av for
    /// good. Nil before any are saved; throws when they can't be read.
    static func savedWidgets() throws -> SavedWidgets? {
        guard let widgetsFile, FileManager.default.fileExists(atPath: widgetsFile.path) else { return nil }
        return try JSONDecoder().decode(SavedWidgets.self, from: Data(contentsOf: widgetsFile))
    }

    /// What there is before any widgets are saved: one, of the train chosen in
    /// the app, as saved.
    static var firstWidgets: SavedWidgets {
        SavedWidgets(widgets: [SavedWidget(id: SavedWidget.firstID, selection: savedSelection() ?? .fallback)])
    }

    /// Copies saved widgets that can't be read to widgets.json.bad, so they
    /// aren't lost for good when a change in the app saves over them.
    static func keepUnreadableWidgets() {
        guard let widgetsFile else { return }
        let copy = widgetsFile.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: widgetsFile, to: copy)
    }

    /// Also leaves the default's train as the app's choice, which Siri, the
    /// countdown and widgets set up before saved widgets go by.
    static func saveWidgets(_ saved: SavedWidgets) {
        save(saved.defaultWidget.selection)
        guard let widgetsFile, let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: widgetsFile, options: .atomic)
    }
}

/// The app's Settings: what goes for every widget, the countdown and Siri. A
/// widget's own choices, in the Widgets tab, come first.
struct AppSettings: Codable, Hashable, Sendable {
    /// The kinds of MTA alert that widgets, the countdown and Siri mention. The
    /// app always lists them all.
    var alertKinds: Set<ServiceAlert.Kind> = Set(ServiceAlert.Kind.allCases)
    /// Marks stations and platforms without step-free access when choosing a train.
    var stepFree = false
    /// A bigger countdown on the small widget, and the medium widget's larger
    /// layout on every iPhone.
    var largerWidgetText = false
    /// Marks live predictions with a symbol, not only in green.
    var marksLiveTimes = false
    /// Marks timetable times with a symbol, so they stand out from live ones.
    var marksScheduledTimes = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case alertKinds, stepFree, largerWidgetText, marksLiveTimes, marksScheduledTimes
    }

    /// Settings saved before any of these existed still load, with the rest at their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        alertKinds = try container.decodeIfPresent(ServiceAlert.KnownKinds.self, forKey: .alertKinds)?.kinds ?? defaults.alertKinds
        stepFree = try container.decodeIfPresent(Bool.self, forKey: .stepFree) ?? defaults.stepFree
        largerWidgetText = try container.decodeIfPresent(Bool.self, forKey: .largerWidgetText) ?? defaults.largerWidgetText
        marksLiveTimes = try container.decodeIfPresent(Bool.self, forKey: .marksLiveTimes) ?? defaults.marksLiveTimes
        marksScheduledTimes = try container.decodeIfPresent(Bool.self, forKey: .marksScheduledTimes) ?? defaults.marksScheduledTimes
    }
}
