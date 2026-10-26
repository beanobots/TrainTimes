import AppIntents
import WidgetKit

/// A widget's Edit menu: pick one of the saved widgets. Lives in Shared so the app can tell which
/// saved widget each Home Screen widget shows.
struct TrainWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a widget"
    static let description = IntentDescription("Pick one of the widgets set up in the app, or leave it empty to show your default train.")

    /// Empty follows Settings' default train.
    @Parameter(title: "Widget", optionsProvider: SavedWidgetOptions())
    var widget: SavedWidgetEntity?

    // Legacy setup from before saved widgets: station, line and direction, or earlier a single
    // `stop`. No longer in the Edit menu; such widgets keep their train until one is picked.

    @Parameter(title: "Station")
    var station: StationEntity?

    @Parameter(title: "Line")
    var line: LineEntity?

    @Parameter(title: "Direction")
    var direction: DirectionEntity?

    @Parameter(title: "Train")
    var stop: StopEntity?

    static var parameterSummary: some ParameterSummary {
        Summary {
            \.$widget
        }
    }

    /// The picked saved widget, or Settings' default train (`SavedWidget.default(_:)`) if none is
    /// picked or it was deleted. Nil for a legacy widget, which shows its own train.
    func savedWidget(in saved: SavedWidgets, defaultTrain: Selection = SharedStore.defaultTrain) -> SavedWidget? {
        let fallback = SavedWidget.default(defaultTrain)
        // Once one's picked, the legacy train is ignored, even if the pick is deleted
        if let widget {
            return UUID(uuidString: widget.id).flatMap(saved.widget) ?? fallback
        }
        return earlierTrain(basedOn: defaultTrain) == nil ? fallback : nil
    }

    /// This widget's train at `date` (the commuting hours' train when active), and when it next
    /// switches so the widget can reload then.
    func selection(at date: Date) -> (Selection, switches: Date?) {
        let saved = SharedStore.loadWidgets()
        let defaultTrain = SharedStore.defaultTrain
        if let widget = savedWidget(in: saved, defaultTrain: defaultTrain) {
            return (widget.shown(at: date).selection, widget.commute?.nextSwitch(after: date))
        }
        return (earlierTrain(basedOn: defaultTrain) ?? defaultTrain, nil)
    }

    /// Where this widget's train at `date` is timed to: its saved widget's destination, when it
    /// has no change (`SavedWidget.directDestination`).
    func destination(at date: Date) -> Station? {
        savedWidget(in: SharedStore.loadWidgets())?.shown(at: date).directDestination
    }

    /// This widget's change of trains at `date`, if its saved widget has one, for the medium Next
    /// train widget to show the ways on as Transfers does.
    func change(at date: Date) -> Change? {
        savedWidget(in: SharedStore.loadWidgets())?.shown(at: date).change
    }

    /// Whether this widget's saved widget shows both directions, on the medium Next train widget.
    func bothWays() -> Bool {
        savedWidget(in: SharedStore.loadWidgets())?.bothWays ?? false
    }

    /// For a Transfers widget: the picked one if it exists, else the first with a change, else
    /// Settings' default train.
    func transfersWidget(in saved: SavedWidgets, defaultTrain: Selection = SharedStore.defaultTrain) -> SavedWidget {
        if let widget, let picked = UUID(uuidString: widget.id).flatMap(saved.widget) { return picked }
        return saved.widgets.first(where: { $0.change != nil }) ?? .default(defaultTrain)
    }

    /// The `Selection.trainID` a widget of `kind` shows at `date`, as its timeline picks it.
    func trainID(kind: String, at date: Date, in saved: SavedWidgets) -> String {
        guard kind == WidgetKind.transfers else { return selection(at: date).0.trainID }
        return transfersWidget(in: saved).shown(at: date).selection.trainID
    }

    /// A widget's `TrainEntry.widgetID`: identifies it as far as WidgetKit allows, by kind, size
    /// and Edit menu choices. Two widgets alike in all three can't be told apart, so they change
    /// together.
    func widgetID(kind: String, family: WidgetFamily) -> String {
        "\(kind) \(family) \(chosen)"
    }

    /// The setup a widget of `kind` shows: its saved widget, or a legacy widget's own train.
    /// Widgets with the same setup, whatever their kind or size, refresh together.
    func setup(kind: String, in saved: SavedWidgets) -> String {
        let widget = kind == WidgetKind.transfers ? transfersWidget(in: saved) : savedWidget(in: saved)
        return widget.map { "widget \($0.id)" } ?? chosen
    }

    /// The Edit menu choices.
    private var chosen: String {
        widget.map { "widget \($0.id)" }
            ?? [station?.id, line?.id, direction?.id, stop?.id].map { $0 ?? "-" }.joined(separator: ",")
    }

    /// A legacy widget's train, with the default train's walking time and alerts (as it once had
    /// the app's). Nil unless station, line and direction are all set and the station still has
    /// one of the lines; lines it no longer has are dropped.
    private func earlierTrain(basedOn base: Selection) -> Selection? {
        guard station != nil || line != nil || direction != nil else {
            return stop?.selection(basedOn: base)
        }
        guard let station = station?.station, let routes = line?.routes, let direction = direction?.direction else { return nil }
        return StopEntity(stationID: station.id, direction: direction, routes: routes).selection(keeping: base)
            .validatedIfKnown()
    }
}

/// A saved widget as listed in the Edit menu.
struct SavedWidgetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Widget"
    static let defaultQuery = SavedWidgetQuery()

    /// A `SavedWidget.id`.
    let id: String
    let title: String
    /// "Prospect Av · R Manhattan", plus any change: ", then D or N at Atlantic Av-Barclays Ctr"
    let subtitle: String
    let routes: [String]

    init(_ widget: SavedWidget) {
        id = widget.id.uuidString
        title = widget.title
        let selection = widget.selection
        var subtitle = "\(selection.station?.name ?? "") · \(selection.caption)"
        if let change = widget.change, change.station != nil {
            subtitle += ", then \(Lines.list(change.allRoutes, joinedBy: "or")) at \(change.stationNames(for: selection))"
        }
        self.subtitle = subtitle
        routes = selection.routes
    }

    /// A picked widget since deleted in the app. It stays picked so the widget falls back as
    /// `TrainWidgetIntent` does for deleted ones, not to its legacy train.
    init(deleted id: UUID) {
        self.id = id.uuidString
        title = "Deleted widget"
        subtitle = "Pick another in its place"
        routes = []
    }

    var displayRepresentation: DisplayRepresentation {
        let image = routes.isEmpty ? nil : BulletImage.data(for: routes).map { DisplayRepresentation.Image(data: $0) }
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: image)
    }
}

struct SavedWidgetQuery: EntityQuery {
    /// Returns deleted ids as `SavedWidgetEntity(deleted:)`; omitting them would empty the choice.
    func entities(for identifiers: [SavedWidgetEntity.ID]) async throws -> [SavedWidgetEntity] {
        let saved = SharedStore.loadWidgets()
        return identifiers.compactMap { id in
            UUID(uuidString: id).map { uuid in saved.widget(uuid).map(SavedWidgetEntity.init) ?? SavedWidgetEntity(deleted: uuid) }
        }
    }

    /// In app order.
    func suggestedEntities() async throws -> [SavedWidgetEntity] {
        SharedStore.loadWidgets().widgets.map(SavedWidgetEntity.init)
    }
}

/// No default choice on purpose: left empty, a widget follows the default even when it changes.
struct SavedWidgetOptions: DynamicOptionsProvider {
    func results() async throws -> [SavedWidgetEntity] {
        try await SavedWidgetQuery().suggestedEntities()
    }
}

// MARK: - Legacy choices from before saved widgets

// Kept only so saved choices still load; don't change the id formats.

/// A `Station.id`.
struct StationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Station"
    static let defaultQuery = StationQuery()

    let id: String

    var station: Station? { StationDirectory.station(id: id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(station?.name ?? id)")
    }
}

struct StationQuery: EntityQuery {
    func entities(for identifiers: [StationEntity.ID]) async throws -> [StationEntity] {
        identifiers.compactMap { StationDirectory.station(id: $0).map { StationEntity(id: $0.id) } }
    }
}

/// "R"; "D,N,R" for one platform's lines; or "all:2,3,4,5,B,D,N,Q,R" for a whole station.
struct LineEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Line"
    static let defaultQuery = LineQuery()

    let id: String
    /// Real-time route ids, in their station's order.
    let routes: [String]

    init?(id: String) {
        let routes = id.dropFirst(id.hasPrefix("all:") ? 4 : 0).split(separator: ",").map(String.init)
        guard !routes.isEmpty else { return nil }
        self.id = id
        self.routes = routes
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(Lines.list(routes))")
    }
}

struct LineQuery: EntityQuery {
    func entities(for identifiers: [LineEntity.ID]) async throws -> [LineEntity] {
        identifiers.compactMap(LineEntity.init(id:))
    }
}

/// "N" or "S", optionally followed by station and lines: "N:R31:N,R".
struct DirectionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"
    static let defaultQuery = DirectionQuery()

    let id: String
    let direction: Direction

    init?(id: String) {
        guard let first = id.split(separator: ":").first, let direction = Direction(rawValue: String(first)) else { return nil }
        self.id = id
        self.direction = direction
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(direction.compassName)")
    }
}

struct DirectionQuery: EntityQuery {
    func entities(for identifiers: [DirectionEntity.ID]) async throws -> [DirectionEntity] {
        identifiers.compactMap(DirectionEntity.init(id:))
    }
}
