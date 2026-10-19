import Observation
import SwiftUI
import WidgetKit

/// The saved widgets, shared by the app's tabs. Every change is saved for the
/// widgets to read, and they redraw with it.
@MainActor @Observable
final class WidgetStore {
    /// Each train checked against the station list, as the widgets show them.
    private(set) var saved: SavedWidgets
    /// How many widgets on the Home Screen and Lock Screen show each saved widget.
    private(set) var placed: [UUID: Int] = [:]
    /// As saved, unchecked. A change saves these, with just what it changes,
    /// so a train at a station the list lacks just now stays as it was chosen.
    private var stored: SavedWidgets

    init() {
        let stored: SavedWidgets
        do {
            if let widgets = try SharedStore.savedWidgets() {
                stored = widgets
            } else {
                // The first time, this keeps the saved widget made from the app's train
                stored = SharedStore.firstWidgets
                SharedStore.saveWidgets(stored)
            }
        } catch {
            // Left as it is until a change saves over it, and kept aside for then
            SharedStore.keepUnreadableWidgets()
            stored = SharedStore.firstWidgets
        }
        self.stored = stored
        saved = stored.validated()
        SharedStore.removeOldFiles()
    }

    var defaultWidget: SavedWidget { saved.defaultWidget }

    func update(_ widget: SavedWidget) { change { $0.update(widget) } }
    func add(_ widget: SavedWidget) { change { $0.add(widget) } }
    func delete(_ id: UUID) { change { $0.delete(id) } }
    func makeDefault(_ id: UUID) { change { $0.makeDefault(id) } }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        change { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// One saved widget to edit, by id, so deleting it doesn't leave a binding
    /// to something gone.
    func binding(for id: UUID) -> Binding<SavedWidget>? {
        guard let widget = saved.widget(id) else { return nil }
        return Binding {
            self.saved.widget(id) ?? widget
        } set: { widget in
            self.update(widget)
        }
    }

    /// Asks iOS which saved widget each widget out there shows, and forgets
    /// the maps and alerts opened on any that are gone.
    func countPlaced() async {
        // The async version is iOS 18 and later
        let result = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { continuation.resume(returning: $0) }
        }
        guard let infos = try? result.get() else { return }
        var counts: [UUID: Int] = [:]
        var widgetIDs = Set<String>()
        for info in infos where info.kind == "RTrainWidget" || info.kind == "TransfersWidget" {
            // One set up before saved widgets, with its own train, shows none of them
            let shown: SavedWidget?
            let intent = info.widgetConfigurationIntent(of: TrainWidgetIntent.self)
            widgetIDs.insert(Self.widgetID(kind: info.kind, family: info.family, configuration: intent ?? TrainWidgetIntent()))
            if info.kind == "TransfersWidget" {
                shown = (intent ?? TrainWidgetIntent()).transfersWidget(in: saved)
            } else if let intent {
                shown = intent.savedWidget(in: saved)
            } else {
                shown = saved.defaultWidget
            }
            guard let widget = shown else { continue }
            counts[widget.id, default: 0] += 1
        }
        placed = counts
        SharedStore.forgetToggles(keeping: widgetIDs)
    }

    /// A widget's `TrainEntry.widgetID`, made as its timeline provider in
    /// RTrainWidget.swift makes it: its kind, its size and what its Edit menu has.
    private static func widgetID(kind: String, family: WidgetFamily, configuration: TrainWidgetIntent) -> String {
        let chosen = configuration.widget.map { "widget \($0.id)" }
            ?? [configuration.station?.id, configuration.line?.id, configuration.direction?.id, configuration.stop?.id]
                .map { $0 ?? "-" }.joined(separator: ",")
        return "\(kind) \(family) \(chosen)"
    }

    /// `body` changes the widgets as shown and, if that changes anything, as
    /// saved too: every widget is in both, in the same order.
    private func change(_ body: (inout SavedWidgets) -> Void) {
        let before = saved
        body(&saved)
        guard saved != before else { return }
        body(&stored)
        SharedStore.saveWidgets(stored)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
