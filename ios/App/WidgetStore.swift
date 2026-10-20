import Observation
import SwiftUI
import UIKit
import WidgetKit

/// The saved widgets, shared by the app's tabs. Every change is saved for the
/// widgets to read, and they redraw with it: once the changes pause, as typing
/// a name or holding a stepper makes many a second, or at once as the app
/// goes from the screen.
@MainActor @Observable
final class WidgetStore {
    /// Each train checked against the station list, as the widgets show them.
    private(set) var saved: SavedWidgets
    /// How many widgets on the Home Screen and Lock Screen show each saved widget.
    private(set) var placed: [UUID: Int] = [:]
    /// As saved, unchecked. A change saves these, with just what it changes,
    /// so a train at a station the list lacks just now stays as it was chosen.
    private var stored: SavedWidgets
    /// Waits for the changes to pause, then saves them.
    @ObservationIgnored private var saving: Task<Void, Never>?
    /// Whether there are changes not saved yet.
    @ObservationIgnored private var unsaved = false
    /// Whether they change what a widget draws, so the widgets redraw.
    @ObservationIgnored private var redraws = false
    /// Whether `start()` has run.
    @ObservationIgnored private var started = false

    /// How long the changes pause before they're saved.
    private static let pause: Duration = .seconds(0.6)

    /// Loads them. What's done just once is `start()`'s: SwiftUI can make a
    /// view's store, and throw it away, each time it makes the view anew.
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
    }

    /// What the app's store does as the app starts, once: only the first call
    /// does anything.
    func start() {
        guard !started else { return }
        started = true
        SharedStore.removeOldFiles()
        // Each time the app starts, whether or not the Widgets tab is opened,
        // so a widget set up like one removed doesn't open on its map or alert
        Task { await countPlaced() }
        // The app may not run again before it's ended
        _ = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveNow()
            }
        }
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
        for info in infos where info.kind == WidgetKind.train || info.kind == WidgetKind.transfers {
            // One set up before saved widgets, with its own train, shows none of them
            let shown: SavedWidget?
            let intent = info.widgetConfigurationIntent(of: TrainWidgetIntent.self)
            widgetIDs.insert(Self.widgetID(kind: info.kind, family: info.family, configuration: intent ?? TrainWidgetIntent()))
            if info.kind == WidgetKind.transfers {
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
    /// saved too, once the changes pause: every widget is in both, in the
    /// same order.
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

    /// Saves the changes not saved yet, for the widgets, Siri and the
    /// countdown to read. Only the Next train and Transfers widgets show saved
    /// widgets, and they redraw only if what they draw has changed.
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

    /// What the widgets draw of `saved`: everything but the names, which only
    /// their Edit menus show, and iOS asks for those as it opens them.
    private static func drawn(_ saved: SavedWidgets) -> SavedWidgets {
        SavedWidgets(widgets: saved.widgets.map { widget in
            var widget = widget
            widget.name = ""
            return widget
        }, defaultID: saved.defaultID)
    }
}
