import Foundation
import Observation

/// Addresses picked in New Trip lately (places, contacts' addresses and calendar events, not
/// stations), to pick again: the last 4, each for a day. Kept on this device.
@MainActor
@Observable
final class RecentPlaces {
    private struct Recent: Codable {
        var place: TripPlace
        var used: Date
    }

    static let shared = RecentPlaces()

    private static let key = "recentPlaces"
    private static let most = 4
    private static let keptFor: TimeInterval = 24 * 60 * 60

    private var recents: [Recent]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        recents = data.flatMap { try? JSONDecoder().decode([Recent].self, from: $0) } ?? []
    }

    /// The places, newest first, none older than a day.
    var places: [TripPlace] {
        let since = Date.now.addingTimeInterval(-Self.keptFor)
        return recents.filter { $0.used > since }.map(\.place)
    }

    /// Puts `place` first, once only.
    func add(_ place: TripPlace) {
        guard !place.isHere else { return }
        recents.removeAll { $0.place.id == place.id }
        recents.insert(Recent(place: place, used: .now), at: 0)
        save()
    }

    func remove(_ place: TripPlace) {
        recents.removeAll { $0.place.id == place.id }
        save()
    }

    private func save() {
        let since = Date.now.addingTimeInterval(-Self.keptFor)
        recents = Array(recents.filter { $0.used > since }.prefix(Self.most))
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
