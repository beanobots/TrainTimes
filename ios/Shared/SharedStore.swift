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
    private static let refreshFile = container?.appendingPathComponent("refreshed.json")
    private static let toggleFile = container?.appendingPathComponent("toggled.json")
    private static let boardsFile = container?.appendingPathComponent("boards.json")

    /// Whether a choice made in the app can reach the widget on this install.
    static var isAvailable: Bool { file != nil }

    static func load() -> Selection {
        guard let file,
              let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Selection.self, from: data) else { return .fallback }
        return saved.validated()
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

    /// Whether the medium widgets for this train (a `Selection.trainID`) show
    /// where it is instead of the later trains. A widget can't keep state of its
    /// own, so its map button leaves it here.
    static func showsMap(for trainID: String) -> Bool {
        mapTrains().contains(trainID)
    }

    static func toggleMap(for trainID: String) {
        guard let mapFile else { return }
        var trains = mapTrains()
        if trains.remove(trainID) == nil { trains.insert(trainID) }
        if let data = try? JSONEncoder().encode(trains.sorted()) {
            try? data.write(to: mapFile, options: .atomic)
        }
    }

    private static func mapTrains() -> Set<String> {
        guard let mapFile, let data = try? Data(contentsOf: mapFile),
              let trains = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(trains)
    }

    /// When ↻ was last tapped, so the widgets can light it up as their new times come in.
    static func loadRefreshed() -> Date? {
        guard let refreshFile, let data = try? Data(contentsOf: refreshFile) else { return nil }
        return try? JSONDecoder().decode(Date.self, from: data)
    }

    static func saveRefreshed(_ date: Date) {
        guard let refreshFile, let data = try? JSONEncoder().encode(date) else { return }
        try? data.write(to: refreshFile, options: .atomic)
    }

    /// When a map or walk button was last tapped. Those change only how the
    /// widgets look, so they redraw with the times they already have.
    static func loadToggled() -> Date? {
        guard let toggleFile, let data = try? Data(contentsOf: toggleFile) else { return nil }
        return try? JSONDecoder().decode(Date.self, from: data)
    }

    static func saveToggled(_ date: Date) {
        guard let toggleFile, let data = try? JSONEncoder().encode(date) else { return }
        try? data.write(to: toggleFile, options: .atomic)
    }

    /// A train's times and alert as last fetched, by a widget or the countdown,
    /// so a widget redrawn soon after needn't wait on the MTA.
    struct SavedBoard: Codable {
        var fetched: Date
        var trains: [Arrival]
        var notice: Notice?
    }

    static func loadBoard(for selection: Selection) -> SavedBoard? {
        savedBoards()[boardKey(selection)]
    }

    /// Kept for 20 minutes, twice as long as a widget waits to reload.
    @discardableResult
    static func saveBoard(_ board: Board, for selection: Selection, fetched: Date) -> SavedBoard {
        let saved = SavedBoard(fetched: fetched, trains: board.trains, notice: board.notice(includingElevators: selection.elevatorAlerts))
        guard let boardsFile else { return saved }
        var boards = savedBoards().filter { fetched.timeIntervalSince($0.value.fetched) < 20 * 60 }
        boards[boardKey(selection)] = saved
        if let data = try? JSONEncoder().encode(boards) {
            try? data.write(to: boardsFile, options: .atomic)
        }
        return saved
    }

    private static func savedBoards() -> [String: SavedBoard] {
        guard let boardsFile, let data = try? Data(contentsOf: boardsFile),
              let boards = try? JSONDecoder().decode([String: SavedBoard].self, from: data) else { return [:] }
        return boards
    }

    /// The board depends on the train and on whether it counts elevator outages.
    private static func boardKey(_ selection: Selection) -> String {
        "\(selection.trainID) \(selection.elevatorAlerts)"
    }
}
