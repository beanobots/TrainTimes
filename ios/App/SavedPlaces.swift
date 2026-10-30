import Foundation
import Observation

/// New Trip's Home and Work, and places added beside them: where each is, once set, kept on this device.
@MainActor
@Observable
final class SavedPlaces {
    private enum Kind: String, Codable {
        case home, work
    }

    /// One of the chips: Home, Work, or a place added with +.
    enum Slot: Hashable {
        case home, work
        /// A visitor's in place of Work: not a place, but the list of sights to pick one from.
        case sightseeing
        case added(UUID)
        /// A place being added under this name, saved once its place is picked.
        case new(String)
    }

    /// A place added with +, under the name it was given.
    private struct Added: Codable, Identifiable {
        let id: UUID
        var name: String
        var place: TripPlace
    }

    /// The one New Trip and first-run setup share, so either sees what the other sets.
    static let shared = SavedPlaces()

    private static let key = "savedPlaces"
    private static let addedKey = "savedPlacesAdded"
    private static let hotelKey = "savedPlacesHomeIsHotel"

    /// Home and Work's places, as set: the name each was picked by and where it is.
    private var places: [Kind: TripPlace]
    /// The places added, in the order they were.
    private var added: [Added]
    /// Home's chip is a visitor's hotel, named and drawn as one (first-run setup's Just visiting).
    private(set) var homeIsHotel: Bool

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        places = data.flatMap { try? JSONDecoder().decode([Kind: TripPlace].self, from: $0) } ?? [:]
        let addedData = UserDefaults.standard.data(forKey: Self.addedKey)
        added = addedData.flatMap { try? JSONDecoder().decode([Added].self, from: $0) } ?? []
        homeIsHotel = UserDefaults.standard.bool(forKey: Self.hotelKey)
    }

    /// Nothing set or added yet.
    var isEmpty: Bool { places.isEmpty && added.isEmpty }

    /// Makes Home a visitor's hotel (with Sightseeing for Work), set to `hotel` once it's picked;
    /// or, ending a visit, forgets the hotel and makes Home a home again.
    func setVisiting(_ visiting: Bool, hotel: TripPlace? = nil) {
        homeIsHotel = visiting
        UserDefaults.standard.set(visiting, forKey: Self.hotelKey)
        set(.home, to: visiting ? hotel : nil)
    }

    /// The chips in order: Home, Work, then the places added; a visitor's Hotel and Sightseeing
    /// in place of Home and Work.
    var slots: [Slot] {
        [.home, homeIsHotel ? .sightseeing : .work] + added.map { .added($0.id) }
    }

    func name(_ slot: Slot) -> String {
        switch slot {
        case .home: homeIsHotel ? "Hotel" : "Home"
        case .work: "Work"
        case .sightseeing: "Sightseeing"
        case .added(let id): added.first { $0.id == id }?.name ?? ""
        case .new(let name): name
        }
    }

    func symbol(_ slot: Slot) -> String {
        switch slot {
        case .home: homeIsHotel ? "bed.double.fill" : "house.fill"
        case .work: "briefcase.fill"
        case .sightseeing: "binoculars.fill"
        case .added, .new: "mappin"
        }
    }

    /// `slot`'s place, named for it ("Home"), what it was picked as under it; nil until it's set.
    func place(_ slot: Slot) -> TripPlace? {
        let place: TripPlace? = switch slot {
        case .home: places[.home]
        case .work: places[.work]
        case .added(let id): added.first { $0.id == id }?.place
        case .sightseeing, .new: nil
        }
        guard let place else { return nil }
        return TripPlace(name: name(slot), detail: place.name, point: place.point)
    }

    /// Sets `slot`'s place, or forgets it with nil (an added place's chip going with it). A new
    /// place is added, and its slot returned.
    @discardableResult
    func set(_ slot: Slot, to place: TripPlace?) -> Slot {
        var slot = slot
        switch slot {
        case .home: places[.home] = place
        case .work: places[.work] = place
        case .sightseeing: return slot
        case .added(let id):
            if let place, let index = added.firstIndex(where: { $0.id == id }) {
                added[index].place = place
            } else {
                added.removeAll { $0.id == id }
            }
        case .new(let name):
            guard let place else { return slot }
            let new = Added(id: UUID(), name: name, place: place)
            added.append(new)
            slot = .added(new.id)
        }
        save()
        return slot
    }

    /// Forgets every place: Home, Work and those added, and a visitor's hotel, Home a home again.
    func clear() {
        places = [:]
        added = []
        homeIsHotel = false
        UserDefaults.standard.set(false, forKey: Self.hotelKey)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        if let data = try? JSONEncoder().encode(added) {
            UserDefaults.standard.set(data, forKey: Self.addedKey)
        }
    }
}
