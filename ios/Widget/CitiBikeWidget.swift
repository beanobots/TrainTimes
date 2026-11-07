import AppIntents
import CoreLocation
import SwiftUI
import WidgetKit

/// Citi Bike: a favorite dock's counts, or the dock nearest you. Drawn as the Saved Route's dock
/// boards (`RouteBoard`): a card until a tap, then the counts, with a ✕ back to the card.
struct CitiBikeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.citiBike, intent: CitiBikeWidgetIntent.self, provider: CitiBikeProvider()) { entry in
            TrainWidgetView(entry: entry)
                .environment(\.routeLook, true)
                .containerBackground(Color.routeBackground, for: .widget)
        }
        .configurationDisplayName("Citi Bike")
        .description("Show a favorite dock or the one nearest you.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
        // As the Saved Route's: TrainWidgetView adds its own margins
        .contentMarginsDisabled()
    }
}

// MARK: - Edit menu

/// The Citi Bike widget's Edit menu: the nearest dock, or a favorite picked from every dock.
struct CitiBikeWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a dock"
    static let description = IntentDescription("Show a favorite dock or the one nearest you.")

    @Parameter(title: "Show", default: .nearest)
    var show: DockShowChoice

    /// Only asked for with Favorite Dock.
    @Parameter(title: "Dock")
    var dock: DockEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$show, .equalTo, .favorite) {
            Summary {
                \.$show
                \.$dock
            }
        } otherwise: {
            Summary {
                \.$show
            }
        }
    }
}

/// Nearest Dock or Favorite Dock.
enum DockShowChoice: String, AppEnum {
    case nearest, favorite

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Show"
    static let caseDisplayRepresentations: [DockShowChoice: DisplayRepresentation] = [
        .nearest: DisplayRepresentation(title: "Nearest Dock", image: .init(systemName: "location.fill")),
        .favorite: DisplayRepresentation(title: "Favorite Dock", image: .init(systemName: "star.fill")),
    ]
}

/// A Citi Bike dock, as the Edit menu lists it: its name, and your walk to it when you're found.
struct DockEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Dock"
    static let defaultQuery = DockQuery()

    /// The dock's GBFS id, place and name, so a picked dock is known again without reaching
    /// Citi Bike. Don't change the format: placed widgets keep it.
    let id: String
    let choice: DockChoice
    var walkMinutes: Int? = nil

    init(_ choice: DockChoice, walkMinutes: Int? = nil) {
        self.choice = choice
        self.walkMinutes = walkMinutes
        id = [choice.id, String(choice.latitude), String(choice.longitude), choice.name].joined(separator: "\t")
    }

    init?(id: String) {
        let parts = id.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, let latitude = Double(parts[1]), let longitude = Double(parts[2]) else { return nil }
        self.id = id
        choice = DockChoice(id: parts[0], name: parts[3], latitude: latitude, longitude: longitude)
    }

    var displayRepresentation: DisplayRepresentation {
        if let walkMinutes {
            return DisplayRepresentation(title: "\(choice.name)", subtitle: "\(walkMinutes) min walk")
        }
        return DisplayRepresentation(title: "\(choice.name)")
    }
}

/// Every dock in service, nearest you first when you're found (else by name); a search matches
/// any part of a dock's name.
struct DockQuery: EntityStringQuery {
    func entities(for identifiers: [DockEntity.ID]) async throws -> [DockEntity] {
        identifiers.compactMap(DockEntity.init(id:))
    }

    func suggestedEntities() async throws -> [DockEntity] {
        await docks()
    }

    func entities(matching string: String) async throws -> [DockEntity] {
        let typed = string.trimmingCharacters(in: .whitespaces)
        let all = await docks()
        guard !typed.isEmpty else { return all }
        return all.filter { $0.choice.name.range(of: typed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private func docks() async -> [DockEntity] {
        let docks = (await CitiBike.docks() ?? []).filter { $0.renting || $0.returning }
        guard case .found(let here) = await NearbyLocator.locateQuickly() else {
            return docks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { DockEntity(DockChoice($0)) }
        }
        return docks
            .map { (dock: $0, meters: $0.location.distance(from: here)) }
            .sorted { $0.meters < $1.meters }
            .map { DockEntity(DockChoice($0.dock), walkMinutes: TripPlanner.walkMinutes($0.meters)) }
    }
}

// MARK: - Timeline

struct CitiBikeProvider: AppIntentTimelineProvider {
    /// How soon it fetches again: open on the Home Screen; on the Lock Screen, always showing,
    /// within iOS's budget; closed, showing its card, less often, as a tap fetches anyway.
    private static let openReload: TimeInterval = 5 * 60
    private static let lockReload: TimeInterval = 15 * 60
    private static let cardReload: TimeInterval = 30 * 60

    /// Seconds it waits for the counts before drawing without them, as the Saved Route's.
    private static let fetchWait: TimeInterval = 8

    func placeholder(in context: Context) -> TrainEntry {
        .dockPreview(nearest: true)
    }

    func snapshot(for configuration: CitiBikeWidgetIntent, in context: Context) async -> TrainEntry {
        if context.isPreview { return .dockPreview(nearest: configuration.show == .nearest) }
        return await timeline(configuration, in: context).entries[0]
    }

    func timeline(for configuration: CitiBikeWidgetIntent, in context: Context) async -> Timeline<TrainEntry> {
        let (entries, reload) = await timeline(configuration, in: context)
        return Timeline(entries: entries, policy: .after(reload))
    }

    /// Whether it shows a card until a tap opens its board: on the Home Screen, not the Lock Screen.
    private func taps(_ context: Context) -> Bool {
        [.systemSmall, .systemMedium, .systemLarge].contains(context.family)
    }

    /// Lets the card's tap and ✕ act on only this widget (`OpenBoards`), by size and Edit menu.
    private func widgetID(_ configuration: CitiBikeWidgetIntent, _ context: Context) -> String {
        let dock = configuration.show == .favorite ? configuration.dock?.choice.id ?? "-" : "-"
        return "\(WidgetKind.citiBike) \(context.family) \(configuration.show.rawValue) \(dock)"
    }

    /// The dock's counts now, as one entry; on the Home Screen, a card until a tap.
    private func timeline(_ configuration: CitiBikeWidgetIntent, in context: Context) async -> (entries: [TrainEntry], reload: Date) {
        let now = Date.now
        let settings = SharedStore.loadSettings()
        let thisWidget = widgetID(configuration, context)
        let board = await board(configuration, kinds: settings.bikeKinds, now: now)
        var entry = TrainEntry(date: now, selection: .fallback, trains: [], widgetID: thisWidget, settings: settings)
        entry.route = .dock(board)
        var entries = [entry]
        if taps(context) { entries = Provider.withCards(entries, widgetID: thisWidget, now: now) }
        let reload = if taps(context) {
            OpenBoards.closes(thisWidget, now: now) != nil ? Self.openReload : Self.cardReload
        } else {
            Self.lockReload
        }
        return (entries, now.addingTimeInterval(reload))
    }

    /// The favorite's counts, or the nearest dock's; or why there are none.
    private func board(_ configuration: CitiBikeWidgetIntent, kinds: SharedBikeKinds, now: Date) async -> SavedDockBoard {
        // Each fetch's timeout only counts idle time, so a slow connection could hold the widget
        // past iOS's limit and leave it blank: late by this, shown unreachable
        let deadline = now.addingTimeInterval(Self.fetchWait)
        switch configuration.show {
        case .favorite:
            guard let dock = configuration.dock?.choice else {
                return SavedDockBoard(dock: Self.unnamed("Choose a dock"), fetched: now, problem: "Choose a dock in Edit Widget")
            }
            let fetching = Task { await SavedDockBoard.fetch(dock, kinds: kinds, now: now) }
            return await TrainService.value(of: fetching, by: deadline)
                ?? SavedDockBoard(dock: dock, kinds: kinds, fetched: now, problem: "Couldn't reach Citi Bike")
        case .nearest:
            let problem: String
            switch await NearbyLocator.locateQuickly() {
            case .found(let here):
                let fetching = Task { await SavedDockBoard.fetchNearest(to: here, kinds: kinds, now: now) }
                if let board = await TrainService.value(of: fetching, by: deadline) ?? nil { return board }
                problem = "Couldn't reach Citi Bike"
            case .notAllowed:
                problem = "Allow Location for Leeway to find the nearest dock"
            case .notFound:
                problem = "Couldn't find where you are"
            }
            return SavedDockBoard(dock: Self.unnamed("Citi Bike"), kinds: kinds, fetched: now, problem: problem, nearest: true)
        }
    }

    /// A board's name when there's no dock to show.
    private static func unnamed(_ name: String) -> DockChoice {
        DockChoice(id: "", name: name, latitude: 0, longitude: 0)
    }
}

// MARK: - Previews

#Preview("Citi Bike", as: .systemMedium) {
    CitiBikeWidget()
} timeline: {
    TrainEntry.dockPreview(nearest: true).asCard()
    TrainEntry.dockPreview(nearest: true).asCard(opened: true)
    TrainEntry.dockPreview().asCard()
    TrainEntry.dockPreview().asCard(opened: true)
    TrainEntry.dockPreview(kinds: .eBikes).asCard(opened: true)
}

#Preview("Citi Bike, small", as: .systemSmall) {
    CitiBikeWidget()
} timeline: {
    TrainEntry.dockPreview(nearest: true).asCard()
    TrainEntry.dockPreview(nearest: true).asCard(opened: true)
    TrainEntry.dockPreview(name: "Pier 40").asCard(opened: true)
    TrainEntry.dockPreview().asCard()
    TrainEntry.dockPreview().asCard(opened: true)
}

#Preview("Citi Bike, large", as: .systemLarge) {
    CitiBikeWidget()
} timeline: {
    TrainEntry.dockPreview(nearest: true).asCard(opened: true)
    TrainEntry.dockPreview().asCard(opened: true)
    TrainEntry.dockPreview(kinds: .eBikes).asCard(opened: true)
}

#Preview("Citi Bike, Lock Screen", as: .accessoryRectangular) {
    CitiBikeWidget()
} timeline: {
    TrainEntry.dockPreview(nearest: true)
    TrainEntry.dockPreview()
}
