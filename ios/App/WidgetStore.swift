import Observation
import SwiftUI
import WidgetKit

/// The saved widgets, shared by the app's tabs. Every change is saved for the
/// widgets to read, and they redraw with it.
@MainActor @Observable
final class WidgetStore {
    private(set) var saved: SavedWidgets
    /// How many widgets on the Home Screen and Lock Screen show each saved widget.
    private(set) var placed: [UUID: Int] = [:]

    init() {
        saved = SharedStore.loadWidgets()
        // The first time, this keeps the saved widget made from the app's train
        SharedStore.saveWidgets(saved)
    }

    var defaultWidget: SavedWidget { saved.defaultWidget }

    func update(_ widget: SavedWidget) { change { $0.update(widget) } }
    func add(_ widget: SavedWidget) { change { $0.add(widget) } }
    func delete(_ id: UUID) { change { $0.delete(id) } }
    func makeDefault(_ id: UUID) { change { $0.makeDefault(id) } }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        change { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// The default widget's train, for the Live tab to show and change.
    var defaultSelection: Binding<Selection> {
        Binding {
            self.defaultWidget.selection
        } set: { selection in
            var widget = self.defaultWidget
            widget.selection = selection
            self.update(widget)
        }
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

    /// Asks iOS which saved widget each widget out there shows.
    func countPlaced() async {
        // The async version is iOS 18 and later
        let result = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { continuation.resume(returning: $0) }
        }
        guard let infos = try? result.get() else { return }
        var counts: [UUID: Int] = [:]
        for info in infos where info.kind == "RTrainWidget" {
            // One set up before saved widgets, with its own train, shows none of them
            let shown: SavedWidget?
            if let intent = info.widgetConfigurationIntent(of: TrainWidgetIntent.self) {
                shown = intent.savedWidget(in: saved)
            } else {
                shown = saved.defaultWidget
            }
            guard let widget = shown else { continue }
            counts[widget.id, default: 0] += 1
        }
        placed = counts
    }

    private func change(_ body: (inout SavedWidgets) -> Void) {
        let before = saved
        body(&saved)
        guard saved != before else { return }
        SharedStore.saveWidgets(saved)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
