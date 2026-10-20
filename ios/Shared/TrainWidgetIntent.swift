import AppIntents
import WidgetKit

/// What a widget's Edit menu offers: one of the widgets set up in the app.
/// It's here rather than in the widget so the app can tell which saved widget
/// each widget on the Home Screen shows. Which alerts it mentions is the saved
/// widget's, set in the app's Widgets tab.
struct TrainWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a widget"
    static let description = IntentDescription("Pick one of the widgets set up in the app, or leave it empty to show the default.")

    /// Empty follows the default widget, whichever that is at the time.
    @Parameter(title: "Widget", optionsProvider: SavedWidgetOptions())
    var widget: SavedWidgetEntity?

    // How widgets were set up before saved widgets: a station, a line and a
    // direction, or before those the whole train in one choice. They're no
    // longer in the Edit menu, but a widget set up that way keeps its train
    // until it picks a saved widget.

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

    /// The saved widget this shows: the one picked, or the default when none
    /// is or it's been deleted. Nil for a widget set up before saved widgets,
    /// which shows its own train.
    func savedWidget(in saved: SavedWidgets) -> SavedWidget? {
        // Once one's been picked, the earlier train is done with, even if
        // the one picked is deleted
        if let widget {
            return UUID(uuidString: widget.id).flatMap(saved.widget) ?? saved.defaultWidget
        }
        return earlierTrain(basedOn: saved.defaultWidget.selection) == nil ? saved.defaultWidget : nil
    }

    /// This widget's train at `date`, with the alerts it mentions: in its
    /// saved widget's commuting hours, theirs. Also when the train next
    /// switches, for the widget to reload then.
    func selection(at date: Date) -> (Selection, switches: Date?) {
        let saved = SharedStore.loadWidgets()
        if let widget = savedWidget(in: saved) {
            return (widget.shown(at: date).selection, widget.commute?.nextSwitch(after: date))
        }
        return (earlierTrain(basedOn: saved.defaultWidget.selection) ?? saved.defaultWidget.selection, nil)
    }

    /// The saved widget a Transfers widget shows: the one picked, or with none
    /// picked (or the one picked deleted) the first that changes trains, else
    /// the default.
    func transfersWidget(in saved: SavedWidgets) -> SavedWidget {
        if let widget, let picked = UUID(uuidString: widget.id).flatMap(saved.widget) { return picked }
        return saved.widgets.first(where: { $0.change != nil }) ?? saved.defaultWidget
    }

    /// The train a widget set up before saved widgets was given, with the
    /// default widget's walking time and alerts, as it had the app's then.
    /// Nil until all three are chosen, or where the station has none of the
    /// lines left; one it's lost is left out.
    private func earlierTrain(basedOn base: Selection) -> Selection? {
        guard station != nil || line != nil || direction != nil else {
            return stop?.selection(basedOn: base)
        }
        guard let station = station?.station, let routes = line?.routes, let direction = direction?.direction else { return nil }
        return Selection(stationID: station.id, routes: routes, direction: direction, elevatorAlerts: base.elevatorAlerts,
                         serviceAlerts: base.serviceAlerts, walkMinutes: base.walkMinutes).validatedIfKnown()
    }
}

/// A saved widget, as the Edit menu lists it: its name, with its train.
struct SavedWidgetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Widget"
    static let defaultQuery = SavedWidgetQuery()

    /// A `SavedWidget.id`.
    let id: String
    let title: String
    /// "Prospect Av · R Manhattan", then any change: ", then D or N at
    /// Atlantic Av-Barclays Ctr"
    let subtitle: String
    let routes: [String]

    init(_ widget: SavedWidget) {
        id = widget.id.uuidString
        title = widget.title
        let selection = widget.selection
        var subtitle = "\(selection.station?.name ?? "") · \(selection.caption)"
        if let change = widget.change, let station = change.station {
            subtitle += ", then \(Lines.list(change.routes, joinedBy: "or")) at \(station.name)"
        }
        self.subtitle = subtitle
        routes = selection.routes
    }

    /// One picked that's since been deleted in the app. It stays picked, so
    /// the widget shows what `TrainWidgetIntent` shows for a deleted one,
    /// not the train it had before saved widgets.
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
    /// A deleted one too, as `SavedWidgetEntity(deleted:)`: left out, the
    /// widget's choice would be empty.
    func entities(for identifiers: [SavedWidgetEntity.ID]) async throws -> [SavedWidgetEntity] {
        let saved = SharedStore.loadWidgets()
        return identifiers.compactMap { id in
            UUID(uuidString: id).map { uuid in saved.widget(uuid).map(SavedWidgetEntity.init) ?? SavedWidgetEntity(deleted: uuid) }
        }
    }

    /// In the order the app lists them.
    func suggestedEntities() async throws -> [SavedWidgetEntity] {
        SharedStore.loadWidgets().widgets.map(SavedWidgetEntity.init)
    }
}

/// The Edit menu's list of saved widgets. There's no default choice: left
/// empty, a widget follows the default widget even after another becomes it.
struct SavedWidgetOptions: DynamicOptionsProvider {
    func results() async throws -> [SavedWidgetEntity] {
        try await SavedWidgetQuery().suggestedEntities()
    }
}

// MARK: - Choices of widgets set up before saved widgets

// Only so their saved choices still load: the Edit menu no longer offers them.
// The ids are the ones those widgets were saved with.

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

/// "R"; "D,N,R", one platform's lines together; or "all:2,3,4,5,B,D,N,Q,R",
/// every line at a station.
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

/// "N" or "S", then where it was known the station and lines that named it: "N:R31:N,R".
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
