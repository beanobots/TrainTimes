import Foundation

/// A widget set up in the app's Widgets tab: a train, and what its widget
/// mentions. A widget on the Home Screen or Lock Screen picks one in its Edit menu.
struct SavedWidget: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    /// Blank to go by the station's name.
    var name: String
    var selection: Selection

    /// The id of the one made from the app's train before there were saved widgets.
    static let firstID = UUID(uuidString: "5D1C8A0E-0F57-4E2B-9C3A-7B1E2D4F6A01")!

    init(id: UUID = UUID(), name: String = "", selection: Selection) {
        self.id = id
        self.name = name
        self.selection = selection
    }

    /// Its name, or the station's.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? (selection.station?.name ?? "Train") : trimmed
    }
}

/// The saved widgets, in the order the Widgets tab lists them, and which one
/// is the default: the one widgets show until they pick another, and the
/// one the Live tab, Siri and the countdown go by.
struct SavedWidgets: Codable, Hashable, Sendable {
    /// Never empty.
    private(set) var widgets: [SavedWidget]
    private(set) var defaultID: UUID

    init(widgets: [SavedWidget], defaultID: UUID? = nil) {
        let widgets = widgets.isEmpty ? [SavedWidget(selection: .fallback)] : widgets
        self.widgets = widgets
        self.defaultID = defaultID.flatMap { id in widgets.contains { $0.id == id } ? id : nil } ?? widgets[0].id
    }

    private enum CodingKeys: String, CodingKey {
        case widgets, defaultID
    }

    /// Through `init(widgets:defaultID:)`, so a saved file with no widgets, or
    /// a default that's gone, still loads as something valid.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(widgets: try container.decode([SavedWidget].self, forKey: .widgets),
                  defaultID: try container.decodeIfPresent(UUID.self, forKey: .defaultID))
    }

    var defaultWidget: SavedWidget { widget(defaultID) ?? widgets[0] }

    func widget(_ id: UUID) -> SavedWidget? {
        widgets.first { $0.id == id }
    }

    /// Replaces the saved widget with the same id.
    mutating func update(_ widget: SavedWidget) {
        guard let index = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        widgets[index] = widget
    }

    mutating func add(_ widget: SavedWidget) {
        widgets.append(widget)
    }

    /// The last one stays; deleting the default makes the first of the rest it.
    mutating func delete(_ id: UUID) {
        guard widgets.count > 1 else { return }
        widgets.removeAll { $0.id == id }
        if id == defaultID { defaultID = widgets[0].id }
    }

    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { widgets[$0] }
        var rest = widgets.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: destination - before)
        widgets = rest
    }

    mutating func makeDefault(_ id: UUID) {
        if widget(id) != nil { defaultID = id }
    }

    /// Each saved train checked against the station list, as `Selection.validated` does.
    func validated() -> SavedWidgets {
        var saved = self
        saved.widgets = widgets.map { widget in
            var widget = widget
            widget.selection = widget.selection.validated()
            return widget
        }
        return saved
    }
}
