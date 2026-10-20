import Foundation
import Observation
import SwiftUI

/// The trains starred in the Live tab, in the order you keep them, each with
/// its own walking time. Apart from the widgets: starring a train doesn't
/// make a widget of it. One train (station, lines and direction) is there at most once.
@MainActor @Observable
final class FavoritesStore {
    /// Each checked against the station list, as the Live tab shows them. One
    /// at a station gone from the list, or that's lost every chosen line, is
    /// left out rather than falling back to Prospect Av.
    private(set) var favorites: [Selection]
    /// As saved, unchecked. A change saves these, with just what it changes,
    /// so a favorite at a station the list lacks just now stays as it was
    /// chosen, for a later list to show again.
    private var stored: [Selection] {
        didSet {
            guard stored != oldValue else { return }
            favorites = Self.shown(stored)
            if let data = try? JSONEncoder().encode(stored) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    private static let key = "favorites"
    /// Saved favorites some of which couldn't be read, as they were, so the
    /// next change, which saves over them, doesn't lose them for good.
    private static let unreadableKey = "favorites.unreadable"

    /// The first time, the default widget's train, so the list doesn't start empty.
    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else {
            let first = [SharedStore.loadWidgets().defaultWidget.selection]
            stored = first
            favorites = Self.shown(first)
            // didSet doesn't run in init, and this mustn't change with the default widget
            if let data = try? JSONEncoder().encode(first) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
            return
        }
        // Each on its own, so one that can't be read doesn't take the rest with it
        let read = try? JSONDecoder().decode([SavedFavorite].self, from: data)
        let saved = read?.compactMap(\.selection) ?? []
        if saved.count != read?.count {
            UserDefaults.standard.set(data, forKey: Self.unreadableKey)
        }
        // A train once: a later copy of one that's shown goes
        var seen = Set<String>()
        let kept = saved.filter { selection in
            selection.validatedIfKnown().map { seen.insert($0.trainID).inserted } ?? true
        }
        stored = kept
        favorites = Self.shown(kept)
    }

    /// Those of `stored` the station list has, checked, each train once.
    private static func shown(_ stored: [Selection]) -> [Selection] {
        var seen = Set<String>()
        return stored.compactMap { $0.validatedIfKnown() }.filter { seen.insert($0.trainID).inserted }
    }

    /// Where each of `favorites` is in `stored`, in the same order.
    private var shownIndices: [Int] {
        var seen = Set<String>()
        return stored.indices.filter { index in
            stored[index].validatedIfKnown().map { seen.insert($0.trainID).inserted } ?? false
        }
    }

    /// Where the favorite of the same train as `selection` is in `stored`.
    private func storedIndex(of selection: Selection) -> Int? {
        favorites.firstIndex { $0.trainID == selection.trainID }.map { shownIndices[$0] }
    }

    func contains(_ selection: Selection) -> Bool {
        favorite(matching: selection) != nil
    }

    /// The favorite of the same train, with its walking time.
    func favorite(matching selection: Selection) -> Selection? {
        favorites.first { $0.trainID == selection.trainID }
    }

    func add(_ selection: Selection) {
        if !contains(selection) { stored.append(selection) }
    }

    func remove(_ selection: Selection) {
        stored.removeAll { $0.validatedIfKnown()?.trainID == selection.trainID }
    }

    /// Saves a favorite's new walking time; a train that isn't one stays out.
    func update(_ selection: Selection) {
        guard let index = storedIndex(of: selection) else { return }
        stored[index] = selection
    }

    /// A favorite changed to another train, in its place in the list. Where the
    /// new train's already a favorite, that one stays and the old one goes.
    func replace(_ old: Selection, with new: Selection) {
        guard let index = storedIndex(of: old) else { return }
        if old.trainID != new.trainID && contains(new) {
            stored.remove(at: index)
        } else {
            stored[index] = new
        }
    }

    /// `offsets` are places in `favorites`; those the list can't show stay.
    func delete(atOffsets offsets: IndexSet) {
        let indices = shownIndices
        stored.remove(atOffsets: IndexSet(offsets.map { indices[$0] }))
    }

    /// Moves favorites among those shown, by their places in `favorites`;
    /// those the list can't show keep theirs.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let indices = shownIndices
        var moved = indices.map { stored[$0] }
        moved.move(fromOffsets: source, toOffset: destination)
        var all = stored
        for (index, selection) in zip(indices, moved) {
            all[index] = selection
        }
        stored = all
    }
}

/// A saved favorite, or nil where it can't be read.
private struct SavedFavorite: Decodable {
    let selection: Selection?

    init(from decoder: Decoder) throws {
        selection = try? Selection(from: decoder)
    }
}
