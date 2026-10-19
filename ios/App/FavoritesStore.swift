import Foundation
import Observation
import SwiftUI

/// The trains starred in the Live tab, in the order you keep them, each with
/// its own walking time. Apart from the widgets: starring a train doesn't
/// make a widget of it. One train (station, lines and direction) is there at most once.
@MainActor @Observable
final class FavoritesStore {
    private(set) var favorites: [Selection] {
        didSet {
            guard favorites != oldValue, let data = try? JSONEncoder().encode(favorites) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private static let key = "favorites"
    /// Saved favorites some of which couldn't be read, as they were, so the
    /// next change, which saves over them, doesn't lose them for good.
    private static let unreadableKey = "favorites.unreadable"

    /// The first time, the default widget's train, so the list doesn't start empty.
    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else {
            favorites = [SharedStore.loadWidgets().defaultWidget.selection]
            // didSet doesn't run in init, and this mustn't change with the default widget
            if let data = try? JSONEncoder().encode(favorites) {
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
        // A station gone from the list, or one that's lost every chosen line, is
        // left out rather than falling back to Prospect Av
        var seen = Set<String>()
        favorites = saved
            .filter { selection in
                selection.station.map { $0.routes.contains(where: selection.routes.contains) } ?? false
            }
            .map { $0.validated() }
            .filter { seen.insert($0.trainID).inserted }
    }

    func contains(_ selection: Selection) -> Bool {
        favorite(matching: selection) != nil
    }

    /// The favorite of the same train, with its walking time.
    func favorite(matching selection: Selection) -> Selection? {
        favorites.first { $0.trainID == selection.trainID }
    }

    func add(_ selection: Selection) {
        if !contains(selection) { favorites.append(selection) }
    }

    func remove(_ selection: Selection) {
        favorites.removeAll { $0.trainID == selection.trainID }
    }

    /// Saves a favorite's new walking time; a train that isn't one stays out.
    func update(_ selection: Selection) {
        guard let index = favorites.firstIndex(where: { $0.trainID == selection.trainID }) else { return }
        favorites[index] = selection
    }

    /// A favorite changed to another train, in its place in the list. Where the
    /// new train's already a favorite, that one stays and the old one goes.
    func replace(_ old: Selection, with new: Selection) {
        guard let index = favorites.firstIndex(where: { $0.trainID == old.trainID }) else { return }
        if old.trainID != new.trainID && contains(new) {
            favorites.remove(at: index)
        } else {
            favorites[index] = new
        }
    }

    func delete(atOffsets offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
    }
}

/// A saved favorite, or nil where it can't be read.
private struct SavedFavorite: Decodable {
    let selection: Selection?

    init(from decoder: Decoder) throws {
        selection = try? Selection(from: decoder)
    }
}
