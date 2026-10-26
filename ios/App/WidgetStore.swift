import Observation
import SwiftUI
import UIKit
import WidgetKit

/// The saved widgets, shared by the app's tabs. Changes are saved and widgets redrawn once edits
/// pause (typing or holding a stepper makes many per second), or at once when the app resigns active.
@MainActor @Observable
final class WidgetStore {
    /// Validated against the station list, as the widgets show them.
    private(set) var saved: SavedWidgets
    /// Number of placed Home/Lock Screen widgets showing each saved widget.
    private(set) var placed: [UUID: Int] = [:]
    /// As saved, unvalidated. Changes apply here too, so a train at a station the list
    /// currently lacks is kept as chosen.
    private var stored: SavedWidgets
    /// Debounced save.
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var unsaved = false
    /// Whether unsaved changes affect what a widget draws.
    @ObservationIgnored private var redraws = false
    @ObservationIgnored private var started = false

    /// Debounce interval before saving.
    private static let pause: Duration = .seconds(0.6)

    /// One-time setup lives in `start()`: SwiftUI may create and discard a view's store each
    /// time it rebuilds the view.
    init() {
        let stored: SavedWidgets
        do {
            if let widgets = try SharedStore.savedWidgets() {
                stored = widgets
            } else {
                // First run: keep the saved widget made from the app's train
                stored = SharedStore.firstWidgets
                SharedStore.saveWidgets(stored)
            }
        } catch {
            // Unreadable file is kept until a change overwrites it, and backed up for then
            SharedStore.keepUnreadableWidgets()
            stored = SharedStore.firstWidgets
        }
        self.stored = stored
        saved = stored.validated()
    }

    /// App-launch setup; only the first call does anything.
    func start() {
        guard !started else { return }
        started = true
        SharedStore.removeOldFiles()
        // On every launch, even without opening the Widgets tab, so a new widget configured like
        // a removed one doesn't open with its map or alert
        Task { await countPlaced() }
        // The app may be killed before it runs again
        _ = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveNow()
            }
        }
    }

    /// Which widget each saved widget was last shown as while editing, so the Widgets tab draws
    /// it that way. Only the app uses it, so it's kept in the app's own defaults.
    private(set) var looks: [UUID: WidgetLook] = WidgetStore.storedLooks()

    private static let looksKey = "widgetLooks"

    private static func storedLooks() -> [UUID: WidgetLook] {
        let raw = UserDefaults.standard.dictionary(forKey: looksKey) as? [String: String] ?? [:]
        return raw.reduce(into: [:]) { looks, entry in
            if let id = UUID(uuidString: entry.key), let look = WidgetLook(rawValue: entry.value) {
                looks[id] = look
            }
        }
    }

    func look(for id: UUID) -> WidgetLook { looks[id] ?? .medium }

    func setLook(_ look: WidgetLook, for id: UUID) {
        guard looks[id] != look else { return }
        looks[id] = look
        saveLooks()
    }

    private func saveLooks() {
        let raw = Dictionary(uniqueKeysWithValues: looks.map { ($0.key.uuidString, $0.value.rawValue) })
        UserDefaults.standard.set(raw, forKey: Self.looksKey)
    }

    func update(_ widget: SavedWidget) { change { $0.update(widget) } }
    func add(_ widget: SavedWidget) { change { $0.add(widget) } }
    func delete(_ id: UUID) {
        change { $0.delete(id) }
        if looks.removeValue(forKey: id) != nil { saveLooks() }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        change { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// Binding by id, so deleting the widget doesn't leave a dangling binding.
    func binding(for id: UUID) -> Binding<SavedWidget>? {
        guard let widget = saved.widget(id) else { return nil }
        return Binding {
            self.saved.widget(id) ?? widget
        } set: { widget in
            self.update(widget)
        }
    }

    /// Asks iOS which saved widget each placed widget shows.
    func countPlaced() async {
        // The async version needs iOS 18
        let result = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { continuation.resume(returning: $0) }
        }
        guard let infos = try? result.get() else { return }
        var counts: [UUID: Int] = [:]
        for info in infos where info.kind == WidgetKind.train || info.kind == WidgetKind.transfers {
            // A widget configured with its own train (pre-saved-widgets) or showing the default
            // train shows none of them
            let intent = info.widgetConfigurationIntent(of: TrainWidgetIntent.self) ?? TrainWidgetIntent()
            let shown = info.kind == WidgetKind.transfers
                ? intent.transfersWidget(in: saved)
                : intent.savedWidget(in: saved)
            guard let widget = shown, widget.id != SavedWidget.defaultID else { continue }
            counts[widget.id, default: 0] += 1
        }
        placed = counts
    }

    /// Applies `body` to `saved` and, if anything changed, to `stored` (same widgets, same order),
    /// then schedules a debounced save.
    private func change(_ body: (inout SavedWidgets) -> Void) {
        let before = saved
        body(&saved)
        guard saved != before else { return }
        body(&stored)
        unsaved = true
        redraws = redraws || Self.drawn(saved) != Self.drawn(before)
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: WidgetStore.pause)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Saves pending changes for the widgets, Siri and the countdown. Only Next train and
    /// Transfers widgets show saved widgets; they reload only if what they draw changed.
    private func saveNow() {
        saving?.cancel()
        saving = nil
        guard unsaved else { return }
        unsaved = false
        SharedStore.saveWidgets(stored)
        if redraws {
            redraws = false
            WidgetCenter.shared.reloadTrainWidgets()
        }
    }

    /// `saved` minus names: only Edit menus show names, and iOS fetches those when opening them.
    private static func drawn(_ saved: SavedWidgets) -> SavedWidgets {
        SavedWidgets(widgets: saved.widgets.map { widget in
            var widget = widget
            widget.name = ""
            return widget
        })
    }
}
