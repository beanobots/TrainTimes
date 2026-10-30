import CryptoKit
import Foundation

/// Files in the App Group container shared by the app and widgets (widgets can't read the app's
/// own files).
enum SharedStore {
    /// As in Config/App.entitlements and Config/Widget.entitlements.
    static let groupID = "group.dev.dctp.leeway"

    /// Nil if not in the App Group (e.g. signed without the entitlement).
    private static let container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    private static let file = url(named: "selection.json")
    private static let countdownFile = url(named: "countdown.json")
    private static let postedCountdownFile = url(named: "posted-countdown.json")
    private static let tapsFile = url(named: "taps.json")
    private static let boardsFile = url(named: "boards.json")
    private static let widgetsFile = url(named: "widgets.json")
    private static let settingsFile = url(named: "settings.json")
    private static let placeFile = url(named: "place.json")
    private static let nearbyFixFile = url(named: "nearby-fix.json")

    /// The App Group file `name`, "quick-trip.json"; nil if not in the App Group.
    static func url(named name: String) -> URL? {
        container?.appendingPathComponent(name)
    }

    /// Whether the app can share data with the widget on this install.
    static var isAvailable: Bool { file != nil }

    static func load() -> Selection {
        savedSelection()?.validated() ?? .fallback
    }

    /// The saved selection, unvalidated.
    private static func savedSelection() -> Selection? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONDecoder().decode(Selection.self, from: data))?.droppingSavedWalk
    }

    @discardableResult
    static func save(_ selection: Selection) -> Bool {
        guard let file, let data = try? JSONEncoder().encode(selection) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// The Lock Screen countdown's train, saved by the app for widgets' walk buttons.
    struct Countdown: Codable, Equatable {
        /// A `Selection.trainID`.
        var trainID: String
        /// When iOS will have ended it.
        var ends: Date
        /// The `TrainEntry.widgetID` whose walk button started it; only that widget shows it. Nil if
        /// started in the app: every widget for the train shows it.
        var widgetID: String? = nil

        /// Whether this widget shows it, so its walk button stops it.
        func isShown(onWidget widgetID: String, for trainID: String) -> Bool {
            trainID == self.trainID && (self.widgetID == nil || self.widgetID == widgetID)
        }

        private enum CodingKeys: String, CodingKey {
            case trainID, ends, widgetID
        }
    }

    /// The countdown's state as the app last posted it, with its push token, so widgets for its
    /// train can show its times (`CountdownLookup`) even where they can't read it from iOS.
    struct PostedCountdown: Codable, Equatable {
        /// A `Selection.trainID`.
        var trainID: String
        var state: CountdownState
        /// The Live Activity's push token, in lowercase hex, for its state as the push server last
        /// pushed it; nil before iOS gives it one.
        var pushToken: String?
    }

    static func loadPostedCountdown() -> PostedCountdown? {
        guard let postedCountdownFile, let data = try? Data(contentsOf: postedCountdownFile) else { return nil }
        return try? JSONDecoder().decode(PostedCountdown.self, from: data)
    }

    /// Pass nil when no countdown is running.
    static func savePostedCountdown(_ posted: PostedCountdown?) {
        guard let postedCountdownFile else { return }
        if let posted, let data = try? JSONEncoder().encode(posted) {
            try? data.write(to: postedCountdownFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: postedCountdownFile)
        }
    }

    static func loadCountdown() -> Countdown? {
        guard let countdownFile, let data = try? Data(contentsOf: countdownFile) else { return nil }
        return try? JSONDecoder().decode(Countdown.self, from: data)
    }

    /// Pass nil when no countdown is running.
    static func saveCountdown(_ countdown: Countdown?) {
        guard let countdownFile else { return }
        if let countdown, let data = try? JSONEncoder().encode(countdown) {
            try? data.write(to: countdownFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: countdownFile)
        }
    }

    /// Deletes obsolete files: refreshed.json and toggled.json, replaced by taps.json; map.json
    /// and alert.json, from when widgets' maps and alerts opened.
    static func removeOldFiles() {
        guard let container else { return }
        for name in ["refreshed.json", "toggled.json", "map.json", "alert.json"] {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(name))
        }
    }

    /// Runs a read-modify-write of `file` in `body` atomically across processes: several widgets
    /// reload at once, and the app writes the same files.
    private static func changing(_ file: URL, _ body: () -> Void) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &error) { _ in body() }
    }

    /// `file` decoded as `Value`; nil if there's none, or it's unreadable.
    static func read<Value: Decodable>(_ type: Value.Type, from file: URL?) -> Value? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// A read-modify-write of `file`, atomically across processes (`changing`): `body` changes it
    /// as saved, or `empty` if there's none or it's unreadable, and it's saved again.
    static func change<Value: Codable>(_ file: URL?, empty: Value, _ body: (inout Value) -> Void) {
        guard let file else { return }
        changing(file) {
            var value = read(Value.self, from: file) ?? empty
            body(&value)
            if let data = try? JSONEncoder().encode(value) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// When a widget's buttons were last tapped. iOS reloads only the tapped widget, so it alone
    /// reacts.
    struct Taps: Codable {
        /// ↻, so it never redraws with older times.
        var refreshed: Date?
        /// Walk: appearance only, so it redraws with the times it has.
        var toggled: Date?
        /// Not a tap: when another widget for its train (or the countdown) had it reload to show
        /// the same times (`WidgetCenter.reloadWidgets(showing:drawing:)`).
        var synced: Date?

        var latest: Date? { [refreshed, toggled, synced].compactMap { $0 }.max() }

        private enum CodingKeys: String, CodingKey {
            case refreshed, toggled, synced
        }
    }

    /// A `TrainEntry.widgetID`'s taps.
    static func loadTaps(for widgetID: String) -> Taps {
        savedTaps()[widgetID] ?? Taps()
    }

    /// Sets `tap` to now. Keeps only the last hour's; older taps no longer affect redraws.
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

    /// A train's last-fetched times and alert (by a widget or the countdown), so a redraw soon
    /// after needn't wait on the MTA.
    struct SavedBoard: Codable {
        var fetched: Date
        var trains: [Arrival]
        var notice: Notice?
        /// With a change, the trains reaching it and their connections.
        var connections: [Connection]? = nil
        /// When a later fetch failed to reach the MTA, so these are old; nil if none has.
        var failed: Date? = nil
        /// With a destination, when each train gets there (`Board.destinationTimes`).
        var destinationTimes: [String: Date]? = nil
    }

    /// With `change`, the board of the large widget showing it; with `destinationID`, of a Next
    /// train widget timing its trains there.
    static func loadBoard(for selection: Selection, change: Change? = nil, destinationID: String? = nil) -> SavedBoard? {
        savedBoards()[boardKey(selection, change: change, destinationID: destinationID)]
    }

    /// Records that a fetch begun at `tried` failed, so a redraw after a tap still marks the
    /// saved times as old. Skipped if newer times were saved since (by another widget or the
    /// countdown).
    static func markBoardFailed(for selection: Selection, change: Change? = nil, destinationID: String? = nil,
                                tried: Date) {
        guard let boardsFile else { return }
        let key = boardKey(selection, change: change, destinationID: destinationID)
        changing(boardsFile) {
            var boards = savedBoards()
            guard let saved = boards[key], saved.fetched <= tried else { return }
            boards[key]?.failed = .now
            write(boards, to: boardsFile)
        }
    }

    /// Boards are kept for an hour, as iOS can go that long between widget reloads and a tap
    /// redraws with them. Boards dated after now (clock set back) are dropped.
    @discardableResult
    static func saveBoard(_ board: Board, for selection: Selection, change: Change? = nil,
                          destinationID: String? = nil, fetched: Date) -> SavedBoard {
        let settings = loadSettings()
        let saved = SavedBoard(fetched: fetched, trains: board.trains,
                               notice: board.notice(for: selection, settings: settings),
                               connections: change == nil ? nil : board.connections,
                               destinationTimes: destinationID == nil ? nil : board.destinationTimes)
        guard let boardsFile else { return saved }
        let key = boardKey(selection, change: change, destinationID: destinationID, settings: settings)
        changing(boardsFile) {
            // `now` is taken inside the lock, so a board another widget just saved isn't after it
            let now = Date.now
            var boards = savedBoards().filter { $0.value.fetched.isWithin(60 * 60, before: now) }
            boards[key] = saved
            write(boards, to: boardsFile)
        }
        return saved
    }

    /// Decoded once while the file's unchanged: Transit Directions' Trip loads and saves a dozen
    /// boards a request.
    private static func savedBoards() -> [String: SavedBoard] {
        guard let boardsFile else { return [:] }
        return boardsCache.value(of: boardsFile) { data in
            data.flatMap { try? JSONDecoder().decode([String: SavedBoard].self, from: $0) } ?? [:]
        }
    }

    /// Writes `boards`, keeping them as `savedBoards` so this process needn't decode them again.
    /// Within `changing`, so no other process writes in between.
    private static func write(_ boards: [String: SavedBoard], to boardsFile: URL) {
        guard let data = try? JSONEncoder().encode(boards), (try? data.write(to: boardsFile, options: .atomic)) != nil
        else { return }
        boardsCache.wrote(boards, to: boardsFile)
    }

    private static let boardsCache = Cached<[String: SavedBoard]>()
    private static let settingsCache = Cached<AppSettings>()

    /// A file's contents as last read or written by this process, while its modification date is
    /// the same: the app and widgets write the same files.
    private final class Cached<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var read: (changed: Date, value: Value)?

        /// `reading` gets the file's data, nil if there's none.
        func value(of file: URL, reading: (Data?) -> Value) -> Value {
            lock.lock()
            defer { lock.unlock() }
            // Dated before reading: a write in between is then read again next time
            let changed = SharedStore.modified(file)
            if let read, let changed, read.changed == changed { return read.value }
            let value = reading(changed == nil ? nil : (try? Data(contentsOf: file)))
            read = changed.map { ($0, value) }
            return value
        }

        func wrote(_ value: Value, to file: URL) {
            lock.lock()
            defer { lock.unlock() }
            read = SharedStore.modified(file).map { ($0, value) }
        }
    }

    private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// Keyed by train, change or destination, and which alerts it mentions (including Settings'
    /// alert kinds).
    private static func boardKey(_ selection: Selection, change: Change?, destinationID: String? = nil,
                                 settings: AppSettings = loadSettings()) -> String {
        let kinds = settings.alertKinds.map(\.rawValue).sorted().map(String.init).joined(separator: ",")
        let key = "\(selection.trainID) \(selection.elevatorAlerts) \(selection.serviceAlerts) \(kinds)"
        if let change { return "\(key) change \(change.key)" }
        return destinationID.map { "\(key) to \($0)" } ?? key
    }

    /// The Nearby widget's last place name, so it looks it up again only after you move. Undated,
    /// and saved only when you've moved, so not where you are now: see `loadNearbyFix`.
    struct Place: Codable {
        var latitude: Double
        var longitude: Double
        /// "Park Slope"; nil if the lookup failed.
        var name: String?
    }

    static func loadPlace() -> Place? {
        read(Place.self, from: placeFile)
    }

    static func savePlace(_ place: Place) {
        guard let placeFile, let data = try? JSONEncoder().encode(place) else { return }
        try? data.write(to: placeFile, options: .atomic)
    }

    /// Where you were when either Nearby widget last found you (`NearbyLocator`, which saves it).
    struct NearbyFix: Codable {
        var latitude: Double
        var longitude: Double
        /// In meters.
        var accuracy: Double
        var taken: Date
    }

    /// The last nearby fix, if taken within `life` before `date`.
    static func loadNearbyFix(at date: Date = .now, within life: TimeInterval) -> NearbyFix? {
        guard let fix = read(NearbyFix.self, from: nearbyFixFile), fix.taken.isWithin(life, before: date)
        else { return nil }
        return fix
    }

    /// Alerts and outages as the app or a widget last downloaded them (`TrainService.sharedCache`),
    /// in the container's Library/Caches, which iOS may clear. A file per name, named by its hash
    /// and dated when saved.
    struct FeedCache: FeedCaching {
        private static let folder = SharedStore.container?.appendingPathComponent("Library/Caches/Feeds", isDirectory: true)

        func data(for name: String, within age: TimeInterval) -> Data? {
            guard let file = Self.file(for: name), let saved = SharedStore.modified(file),
                  saved.isWithin(age, before: .now) else { return nil }
            return try? Data(contentsOf: file)
        }

        /// Also deletes any saved over an hour ago, such as alerts for routes no widget shows now.
        func save(_ data: Data, for name: String) {
            guard let folder = Self.folder, let file = Self.file(for: name) else { return }
            let manager = FileManager.default
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            let now = Date.now
            for old in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where !(SharedStore.modified(old)?.isWithin(60 * 60, before: now) ?? false) {
                try? manager.removeItem(at: old)
            }
        }

        private static func file(for name: String) -> URL? {
            let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
            return folder?.appendingPathComponent(hash)
        }
    }

    /// The Settings tab's choices, or defaults. Decoded once while the file's unchanged.
    static func loadSettings() -> AppSettings {
        guard let settingsFile else { return AppSettings() }
        return settingsCache.value(of: settingsFile) { data in
            data.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        }
    }

    static func saveSettings(_ settings: AppSettings) {
        guard let settingsFile, let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsFile, options: .atomic)
    }

    /// The app's widgets, validated. If none are saved, the app's selection becomes the first and
    /// default, with a fixed id so widgets set up before the app saves still find it.
    static func loadWidgets() -> SavedWidgets {
        ((try? savedWidgets()) ?? firstWidgets).validated()
    }

    /// The saved widgets, unvalidated, for the app to edit and re-save. Saving validated ones would
    /// permanently turn a train at an unknown station into the fallback. Nil if none saved;
    /// throws if unreadable.
    static func savedWidgets() throws -> SavedWidgets? {
        guard let widgetsFile, FileManager.default.fileExists(atPath: widgetsFile.path) else { return nil }
        return try JSONDecoder().decode(SavedWidgets.self, from: Data(contentsOf: widgetsFile))
    }

    /// Before any widgets are saved: one, of the app's saved selection.
    static var firstWidgets: SavedWidgets {
        SavedWidgets(widgets: [SavedWidget(id: SavedWidget.firstID, selection: savedSelection() ?? .fallback)])
    }

    /// Backs up undecodable widgets to widgets.json.bad before the app saves over them. If the file
    /// can't be read at all, any earlier backup stays.
    static func keepUnreadableWidgets() {
        guard let widgetsFile, let data = try? Data(contentsOf: widgetsFile) else { return }
        try? data.write(to: widgetsFile.appendingPathExtension("bad"), options: .atomic)
    }

    /// Settings' default train: for Siri, the countdown, Favorite Stop, and widgets that pick no
    /// saved widget. Until one's chosen, selection.json's, where older versions saved the default
    /// widget's train.
    static var defaultTrain: Selection {
        loadSettings().defaultTrain?.validatedIfKnown() ?? load()
    }

    static func saveWidgets(_ saved: SavedWidgets) {
        guard let widgetsFile, let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: widgetsFile, options: .atomic)
    }
}

// Hand-written decoders: synthesized Codable ignores defaults, so a newly added field would make
// older saves fail to decode. Read new fields with decodeIfPresent and a default. In extensions
// to keep the memberwise initializers.

extension SharedStore.Countdown {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trainID = try container.decode(String.self, forKey: .trainID)
        ends = try container.decode(Date.self, forKey: .ends)
        widgetID = try container.decodeIfPresent(String.self, forKey: .widgetID)
    }
}

extension SharedStore.Taps {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshed = try container.decodeIfPresent(Date.self, forKey: .refreshed)
        toggled = try container.decodeIfPresent(Date.self, forKey: .toggled)
        synced = try container.decodeIfPresent(Date.self, forKey: .synced)
    }
}

/// App-wide settings for widgets, the countdown and Siri. Per-widget choices (Widgets tab) take
/// precedence.
struct AppSettings: Codable, Hashable, Sendable {
    /// MTA alert kinds that widgets, the countdown and Siri mention. The app always lists all.
    var alertKinds: Set<ServiceAlert.Kind> = Set(ServiceAlert.Kind.allCases)
    /// Marks stations and platforms without step-free access when choosing a train.
    var stepFree = false
    /// Marks live predictions with a symbol, not only in green.
    var marksLiveTimes = false
    /// Marks timetable times with a symbol.
    var marksScheduledTimes = false
    /// How Transit Directions draws Favorite Stop's card, and Next train and Transfers theirs.
    var favoriteCard = FavoriteCardStyle.bulletRow
    /// The station, lines and direction Siri, the countdown, Favorite Stop and unconfigured
    /// widgets use. Nil until chosen; see `SharedStore.defaultTrain`.
    var defaultTrain: Selection?
    /// New Trip offers trips with a bus ride too, from the push server's `GET /routes?bus=1`.
    var includesBuses = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case alertKinds, stepFree, marksLiveTimes, marksScheduledTimes, favoriteCard, defaultTrain, includesBuses
    }

    /// Older saves missing any field still load, with defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        alertKinds = try container.decodeIfPresent(ServiceAlert.KnownKinds.self, forKey: .alertKinds)?.kinds ?? defaults.alertKinds
        stepFree = try container.decodeIfPresent(Bool.self, forKey: .stepFree) ?? defaults.stepFree
        marksLiveTimes = try container.decodeIfPresent(Bool.self, forKey: .marksLiveTimes) ?? defaults.marksLiveTimes
        marksScheduledTimes = try container.decodeIfPresent(Bool.self, forKey: .marksScheduledTimes) ?? defaults.marksScheduledTimes
        // An unknown style, from a later version, falls back too
        favoriteCard = (try? container.decodeIfPresent(FavoriteCardStyle.self, forKey: .favoriteCard)) ?? defaults.favoriteCard
        // An unreadable train falls back to selection.json's
        defaultTrain = (try? container.decodeIfPresent(Selection.self, forKey: .defaultTrain))?.droppingSavedWalk
        includesBuses = try container.decodeIfPresent(Bool.self, forKey: .includesBuses) ?? defaults.includesBuses
    }
}

/// How Transit Directions draws Favorite Stop's card on its buttons, and Next train and Transfers
/// their card (`StopCard`). Neither gives times: those show on the board, once it's tapped.
enum FavoriteCardStyle: String, Codable, CaseIterable, Sendable {
    /// Station and way, then the lines in a row along the bottom, tinted with the first line.
    case bulletRow
    /// Like a station's sign: a white rule, the station in white on black, its lines, the way.
    case stationSign

    var name: String {
        switch self {
        case .bulletRow: "Bullet row"
        case .stationSign: "Station sign"
        }
    }
}
