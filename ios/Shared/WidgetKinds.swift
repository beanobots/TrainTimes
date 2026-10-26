import WidgetKit

/// Kinds of widgets showing a saved widget's train, used for reloads and counting placed
/// widgets. Trains near you's is `Nearby.widgetKind`.
enum WidgetKind {
    /// Next train.
    static let train = "RTrainWidget"
    static let transfers = "TransfersWidget"
    /// Transit Directions: a trip shared from a maps app or planned with Quick Trip, else its
    /// Quick Trip and Favorite Stop buttons.
    static let directions = "DirectionsWidget"
}

/// Widgets reloaded only because others of their kind were, to redraw with other widgets' times
/// (`WidgetCenter.reloadWidgets(showing:drawing:)`): fetching their own would reload others'
/// kinds in turn, each reload costing the daily budget. By widget ID, with when.
enum Bystanders {
    private static let file = SharedStore.url(named: "bystanders.json")

    /// Whether `widgetID` redraws with times saved at `saved` instead of fetching: if it was
    /// marked within a `reloadInterval`, not before its last ↻ (`refreshed`), and the times
    /// (not `failed`) are younger than their `reloadInterval`, by when its own reload is due and
    /// so still fetches. Times after `now` (clock set back) are old.
    static func reuses(saved: Date, failed: Date?, refreshed: Date?, widgetID: String, now: Date) -> Bool {
        guard failed == nil, let marked = load()[widgetID], marked > refreshed ?? .distantPast,
              saved > refreshed ?? .distantPast else { return false }
        return marked.isWithin(TimelinePlan.reloadInterval(at: now), before: now)
            && saved.isWithin(TimelinePlan.reloadInterval(at: saved), before: now)
    }

    /// Marks `widgetIDs` now, dropping marks over an hour old.
    static func mark(_ widgetIDs: Set<String>) {
        guard !widgetIDs.isEmpty else { return }
        let now = Date.now
        change { marks in
            marks = marks.filter { $0.value.isWithin(60 * 60, before: now) }
            for id in widgetIDs { marks[id] = now }
        }
    }

    /// For reloads meant to get new times everywhere.
    static func clear() {
        guard !load().isEmpty else { return }
        change { $0 = [:] }
    }

    private static func load() -> [String: Date] {
        SharedStore.read([String: Date].self, from: file) ?? [:]
    }

    /// A read-modify-write across processes.
    private static func change(_ body: (inout [String: Date]) -> Void) {
        SharedStore.change(file, empty: [:], body)
    }
}

extension WidgetCenter {
    /// Reloads Next train, Transfers and Transit Directions, but not Trains near you, which would
    /// needlessly relocate you and fetch every nearby line. They fetch as usual (`Bystanders`).
    func reloadTrainWidgets() {
        Bystanders.clear()
        reloadTimelines(ofKind: WidgetKind.train)
        reloadTimelines(ofKind: WidgetKind.transfers)
        reloadTimelines(ofKind: WidgetKind.directions)
    }

    /// Reloads the Next train and Transfers widgets showing `trainID`, so they all redraw with
    /// the same times: the countdown's, or ones just saved (which they reuse, see
    /// `TimelinePlan.reuseWindow`, rather than fetch their own). There's no reloading single
    /// widgets, so others of those kinds redraw too, from their own saved times (`Bystanders`).
    /// `drawing`: a widget drawing those times now, whose kind needn't reload for it alone.
    func reloadWidgets(showing trainID: String, drawing widgetID: String? = nil) async {
        guard let infos = try? await currentConfigurations() else { return }
        let saved = SharedStore.loadWidgets()
        let now = Date.now
        let placed = infos.compactMap { info -> (widgetID: String, kind: String, showing: Bool)? in
            guard info.kind == WidgetKind.train || info.kind == WidgetKind.transfers else { return nil }
            let intent = info.widgetConfigurationIntent(of: TrainWidgetIntent.self) ?? TrainWidgetIntent()
            let id = intent.widgetID(kind: info.kind, family: info.family)
            return (id, info.kind, intent.trainID(kind: info.kind, at: now, in: saved) == trainID && id != widgetID)
        }
        let showing = placed.filter(\.showing)
        let kinds = Set(showing.map(\.kind))
        // So they redraw with the times just saved, not fetch their own (`TimelinePlan.reuses`)
        let synced = Set(showing.map(\.widgetID))
        for id in synced {
            SharedStore.recordTap(\.synced, for: id)
        }
        Bystanders.mark(Set(placed.filter { kinds.contains($0.kind) }.map(\.widgetID)).subtracting(synced))
        for kind in kinds {
            reloadTimelines(ofKind: kind)
        }
    }

    /// After ↻ on `widgetID`, gets new times on the other Next train and Transfers widgets with
    /// its setup (`TrainWidgetIntent.setup`), as iOS reloads only the tapped one. Marks them
    /// refreshed so they don't redraw with older saved times, then reloads their kinds; there's
    /// no reloading single widgets, so others of those kinds redraw too, from their own saved
    /// times (`Bystanders`).
    func reloadWidgets(sharingSetupWith widgetID: String) async {
        guard let infos = try? await currentConfigurations() else { return }
        let saved = SharedStore.loadWidgets()
        let placed = infos.compactMap { info -> (widgetID: String, kind: String, setup: String)? in
            guard info.kind == WidgetKind.train || info.kind == WidgetKind.transfers else { return nil }
            let intent = info.widgetConfigurationIntent(of: TrainWidgetIntent.self) ?? TrainWidgetIntent()
            return (intent.widgetID(kind: info.kind, family: info.family), info.kind, intent.setup(kind: info.kind, in: saved))
        }
        guard let setup = placed.first(where: { $0.widgetID == widgetID })?.setup else { return }
        let others = placed.filter { $0.setup == setup && $0.widgetID != widgetID }
        let refreshed = Set(others.map(\.widgetID))
        for widgetID in refreshed {
            SharedStore.recordTap(\.refreshed, for: widgetID)
        }
        let kinds = Set(others.map(\.kind))
        // Not the tapped one, whose ↻ wants new times
        Bystanders.mark(Set(placed.filter { kinds.contains($0.kind) && $0.setup != setup }.map(\.widgetID)))
        for kind in kinds {
            reloadTimelines(ofKind: kind)
        }
    }
}
