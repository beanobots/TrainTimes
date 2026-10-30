import SwiftUI

extension Color {
    /// Citi Bike's blue, for its rides and docks.
    static let citiBike = Color(red: 0.0, green: 0.42, blue: 0.80)
}

/// A round bike bullet, to sit beside line bullets; an e-bike's has a bolt badge.
struct BikeBullet: View {
    let size: CGFloat
    var electric = false

    var body: some View {
        Image(systemName: "bicycle")
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.citiBike))
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

/// A New Trip trip with a Citi Bike, laid out as `TripOptionRow`: the bike's bullet and the
/// train's, where from and to, the bikes and docks there (warned where they're few), and how.
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
                    if trip.bikeFirst { BikeBullet(size: 19, electric: electric) }
                    LineBullet(route: train.selection.routes.first ?? "", size: 19)
                    if !trip.bikeFirst { BikeBullet(size: 19, electric: electric) }
                } else {
                    BikeBullet(size: 24, electric: electric)
                }
            }
            .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        dockLine
                        how
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(trip.minutes) min")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
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
        return trip.bikeFirst ? "\(ride) to \(first) → \(last)" : "\(first) → \(last), then \(ride.lowercased())"
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

    /// The ride, and the train before or after it.
    private var how: some View {
        HStack(spacing: 4) {
            if let train = trip.train {
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
}
