import CoreLocation
import SwiftUI

extension Color {
    /// Citi Bike's blue, for its rides and docks.
    static let citiBike = Color(red: 0.0, green: 0.42, blue: 0.80)
}

/// A round bike bullet, to sit beside line bullets; an e-bike's has a bolt badge.
struct BikeBullet: View {
    let size: CGFloat
    var electric = false
    /// Your own bike's: the tint rather than Citi blue.
    var own = false

    var body: some View {
        Image(systemName: "bicycle")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(own ? Color.accentColor : Color.citiBike))
            .overlay(alignment: .topTrailing) {
                if electric {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.32, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: size * 0.5, height: size * 0.5)
                        .background(Circle().fill(.yellow))
                        .offset(x: size * 0.15, y: -size * 0.15)
                }
            }
            .accessibilityHidden(true)
    }
}

extension View {
    /// The Citi Bike menus' yellow bolt badge, top-trailing, while `shown`. It's always there,
    /// growing in and shrinking out with its own animation: a menu's label drops the picker's
    /// `withAnimation`, so an `if` would pop it.
    func eBikeBadge(_ shown: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 17, height: 17)
                .background(Circle().fill(.yellow))
                .scaleEffect(shown ? 1 : 0.3)
                .opacity(shown ? 1 : 0)
                .offset(x: 3, y: -3)
                .animation(.spring(duration: 0.3, bounce: 0.35), value: shown)
                .accessibilityHidden(true)
        }
    }
}

/// Bikes to take where `trip` starts and docks to leave it where it ends, warned where either's few.
struct BikeDocksLabel: View {
    let trip: BikeTrip

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: trip.isShort ? "exclamationmark.triangle.fill" : "parkingsign.circle.fill")
                .foregroundStyle(trip.isShort ? AnyShapeStyle(.orange) : AnyShapeStyle(Color.citiBike))
            Text("\(trip.bikes < CitiBike.few ? "Only " : "")\(trip.kind.count(trip.bikes)) · "
                 + "\(trip.docks < CitiBike.few ? "only " : "")\(trip.docks) open dock\(trip.docks == 1 ? "" : "s")")
        }
    }
}

/// How much of a ride's on protected bike lanes (`BikeLanes`): a green shield and the percent, on
/// a soft grey pill.
struct ProtectedLanesPill: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.green)
            Text("\(percent)%")
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(percent)% on protected bike lanes")
    }
}

/// A New Trip trip with a Citi Bike, laid out as `TripOptionRow`: the bike's bullet and the
/// train's, where from and to, the bikes and docks there (warned where they're few), and how.
/// On your own bike (`BikeTrip.owned`), what's done with it in place of the docks: ridden door
/// to door, brought on the train, or locked at the station.
struct BikeTripRow: View {
    let trip: BikeTrip
    let picked: Bool
    /// Whether its docks are open to pick from (`BikeTrip.dockChoices`), as New Trip opens them
    /// with a tap on the picked trip; nil where they don't open.
    var docksOpen: Bool? = nil

    private var electric: Bool { trip.kind == .eBike }
    private var ride: String { electric ? "E-bike" : "Bike" }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                if let train = trip.train {
                    if trip.bikeFirst { BikeBullet(size: 19, electric: electric, own: trip.owned) }
                    LineBullet(route: train.selection.routes.first ?? "", size: 19)
                    if !trip.bikeFirst || trip.rideAfter != nil { BikeBullet(size: 19, electric: electric, own: trip.owned) }
                } else {
                    BikeBullet(size: 24, electric: electric, own: trip.owned)
                }
            }
            .frame(width: trip.rideAfter == nil ? 52 : 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    // VoiceOver read "→" as "right arrow"
                    .accessibilityLabel(title.replacingOccurrences(of: " → ", with: " to "))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        if trip.owned { ownLine } else { dockLine }
                        how
                        if trip.isOverIncluded { extraCharge }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    minutes
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityHint(docksOpen == nil ? "" : docksOpen == true ? "Hides the fuller docks nearby"
                               : "Shows the fuller docks nearby")
    }

    /// Where from and to: the dock all the way, the station biked to and the train's end, or the
    /// train's stations and the bike after.
    private var title: String {
        guard let train = trip.train else { return "\(ride) all the way → \(trip.dropoff.name)" }
        let first = train.selection.station?.name ?? ""
        let last = train.endStation?.name ?? ""
        return trip.bikeFirst && trip.rideAfter == nil ? "\(ride) to \(first) → \(last)"
            : trip.bikeFirst ? "\(ride) to \(first) → \(last), then \(ride.lowercased())"
            : "\(first) → \(last), then \(ride.lowercased())"
    }

    /// Its minutes, with how much of the ride's on protected lanes above them where it's any:
    /// tight enough, the two are about as tall as the dock and ride lines beside them.
    private var minutes: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let protectedPercent { ProtectedLanesPill(percent: protectedPercent) }
            Text("\(trip.minutes) min")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    /// The ride's percent on protected lanes; nil under 5%, where it's not shown.
    private var protectedPercent: Int? { Self.protectedPercent(of: trip.protectedShare) }

    /// `share` as a percent; nil under 5%, or not known.
    static func protectedPercent(of share: Double?) -> Int? {
        guard let share, share >= 0.05 else { return nil }
        return Int((min(share, 1) * 100).rounded())
    }

    /// Its docks' counts, and where they open, which way.
    private var dockLine: some View {
        HStack(spacing: 4) {
            BikeDocksLabel(trip: trip)
            if let docksOpen {
                Image(systemName: docksOpen ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
    }

    /// What's done with your own bike: ridden all the way, brought on the train, or locked at
    /// the station it's ridden to.
    private var ownLine: some View {
        HStack(spacing: 4) {
            if let train = trip.train {
                if trip.carried {
                    Image(systemName: "tram.fill").foregroundStyle(.tint).accessibilityHidden(true)
                    Text("Bring it on the")
                    HStack(spacing: 2) {
                        ForEach(train.selection.routes, id: \.self) { LineBullet(route: $0, size: 14) }
                    }
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(.tint).accessibilityHidden(true)
                    Text("Lock it at \(trip.dropoff.name)")
                }
            } else {
                Image(systemName: "house.fill").foregroundStyle(.tint).accessibilityHidden(true)
                Text("Door to door, no docks")
            }
        }
    }

    /// The ride, and the train before or after it.
    private var how: some View {
        HStack(spacing: 4) {
            if trip.owned, let after = trip.rideAfter {
                Text("\(trip.rideMinutes) min ride, then \(after.minutes) min ride")
            } else if trip.owned, trip.train != nil, !trip.carried {
                Text("\(trip.rideMinutes) min ride, \(BikePlanner.lockMinutes) min to lock up")
            } else if trip.owned, trip.train == nil {
                Text("\(trip.rideMinutes) min ride")
            } else if let train = trip.train {
                if trip.bikeFirst {
                    Text("\(trip.rideMinutes) min ride, then")
                    LineBullets(routes: train.selection.routes, size: 14)
                } else {
                    LineBullets(routes: train.selection.routes, size: 14)
                    Text("then a \(trip.rideMinutes) min ride")
                }
            } else {
                Text("\(trip.rideMinutes) min ride from \(trip.pickup.name)")
            }
        }
    }

    /// That the ride's past a member's included minutes, and charged for.
    private var extraCharge: some View {
        HStack(spacing: 4) {
            Image(systemName: "dollarsign.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Over \(CitiBike.includedMinutes) min: extra charge")
                .accessibilityLabel("Over \(CitiBike.includedMinutes) minutes, an extra charge")
        }
    }
}

#Preview("Over 45 min") {
    // Red Hook to Long Island City as planned: over a member's minutes on a bike, not an e-bike
    let pickup = CitiBike.Dock(id: "a", name: "Pioneer St & Richards St", lat: 40.6795, lon: -74.0124,
                               bikes: 7, eBikes: 10, docks: 12, renting: true, returning: true)
    let dropoff = CitiBike.Dock(id: "b", name: "24 St & 41 Ave", lat: 40.7525, lon: -73.9393,
                                bikes: 3, eBikes: 1, docks: 8, renting: true, returning: true)
    List {
        BikeTripRow(trip: BikeTrip(kind: .bike, pickup: pickup, dropoff: dropoff, path: [], rideMinutes: 56,
                                   protectedShare: 0.62, train: nil, bikeFirst: true, minutes: 61), picked: true)
        BikeTripRow(trip: BikeTrip(kind: .eBike, pickup: pickup, dropoff: dropoff, path: [], rideMinutes: 40,
                                   protectedShare: 0.02, train: nil, bikeFirst: true, minutes: 45), picked: false)
        BikeTripRow(trip: BikeTrip(kind: .eBike, pickup: pickup, dropoff: pickup, path: [], rideMinutes: 38,
                                   protectedShare: 0.93, train: nil, bikeFirst: true, minutes: 43), picked: false)
    }
}

#Preview("Own bike") {
    // Upper West Side to Bryant Park on your own: brought on the 1 2 3, locked at 72 St, and
    // door to door
    let home = CitiBike.Dock.place("Start", CLLocation(latitude: 40.7812, longitude: -73.9790))
    let station = CitiBike.Dock.place("72 St", CLLocation(latitude: 40.778453, longitude: -73.98197))
    let off = CitiBike.Dock.place("Times Sq-42 St", CLLocation(latitude: 40.75529, longitude: -73.987495))
    let park = CitiBike.Dock.place("Bryant Park", CLLocation(latitude: 40.7536, longitude: -73.9832))
    let train = SharedTrip.Option(selection: Selection(stationID: "123", routes: ["1", "2", "3"], direction: .south),
                                  destinationID: "127")
    List {
        BikeTripRow(trip: BikeTrip(kind: .bike, pickup: home, dropoff: station, path: [], rideMinutes: 6, train: train,
                                   bikeFirst: true, minutes: 23, owned: true, carried: true,
                                   rideAfter: BikeTrip.Ride(from: off, to: park, path: [], minutes: 4)), picked: true)
        BikeTripRow(trip: BikeTrip(kind: .bike, pickup: home, dropoff: station, path: [], rideMinutes: 6, train: train,
                                   bikeFirst: true, minutes: 26, owned: true), picked: false)
        BikeTripRow(trip: BikeTrip(kind: .eBike, pickup: home, dropoff: park, path: [], rideMinutes: 19, protectedShare: 0.4,
                                   train: nil, bikeFirst: true, minutes: 19, owned: true), picked: false)
    }
}
