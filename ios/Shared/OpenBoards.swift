import AppIntents
import Foundation

/// Next train and Transfers on the Home Screen show a card with no times until a tap opens their
/// board, as Transit Directions' Favorite Stop does. The board closes by itself once the train it
/// showed has left, or after `duration`, whichever is sooner; or at once with its ✕. By widget ID
/// (`TrainEntry.widgetID`), when each open board closes.
enum OpenBoards {
    /// The longest a board stays open.
    static let duration: TimeInterval = 5 * 60
    /// The shortest, so a train about to leave doesn't close it as it opens.
    static let shortest: TimeInterval = 60

    private static let file = SharedStore.url(named: "openBoards.json")

    /// When `widgetID`'s board closes, if it's open at `now`.
    static func closes(_ widgetID: String, now: Date = .now) -> Date? {
        load()[widgetID].flatMap { $0 > now ? $0 : nil }
    }

    /// Opens `widgetID`'s board until the train it shows `leaves` (nil without one), or for
    /// `duration`, whichever is sooner.
    static func open(_ widgetID: String, leaves: Date?) {
        let now = Date.now
        let until = max(min(now.addingTimeInterval(duration), leaves ?? .distantFuture), now.addingTimeInterval(shortest))
        change(now: now) { $0[widgetID] = until }
    }

    static func close(_ widgetID: String) {
        change(now: .now) { $0[widgetID] = nil }
    }

    private static func load() -> [String: Date] {
        SharedStore.read([String: Date].self, from: file) ?? [:]
    }

    /// A read-modify-write across processes, dropping boards closed by `now`.
    private static func change(now: Date, _ body: (inout [String: Date]) -> Void) {
        SharedStore.change(file, empty: [String: Date]()) { boards in
            boards = boards.filter { $0.value > now }
            body(&boards)
        }
    }
}

/// A tap on Next train's or Transfers' card: opens its board. iOS then reloads the widget, which
/// redraws with the times it has if they're fresh, else fetches new ones while the toggle's face
/// shows the old. Not a walk-style tap (`Taps.toggled`), which would redraw with times of any age.
struct OpenBoardIntent: AppIntent {
    static let title: LocalizedStringResource = "Show the times"
    static let isDiscoverable = false

    /// A `TrainEntry.widgetID`.
    @Parameter(title: "Widget", default: "")
    var widgetID: String

    /// When the train the board shows leaves (or when to leave for it, with a walking time).
    @Parameter(title: "Leaves")
    var leaves: Date?

    init() {}

    init(widgetID: String, leaves: Date?) {
        self.widgetID = widgetID
        self.leaves = leaves
    }

    func perform() async throws -> some IntentResult {
        guard !widgetID.isEmpty else { return .result() }
        OpenBoards.open(widgetID, leaves: leaves)
        return .result()
    }
}

/// An open board's ✕: back to the card.
struct CloseBoardIntent: AppIntent {
    static let title: LocalizedStringResource = "Hide the times"
    static let isDiscoverable = false

    /// A `TrainEntry.widgetID`.
    @Parameter(title: "Widget", default: "")
    var widgetID: String

    init() {}

    init(widgetID: String) {
        self.widgetID = widgetID
    }

    func perform() async throws -> some IntentResult {
        guard !widgetID.isEmpty else { return .result() }
        OpenBoards.close(widgetID)
        // Appearance only: the card has no times, so it redraws with those it has
        SharedStore.recordTap(\.toggled, for: widgetID)
        return .result()
    }
}
