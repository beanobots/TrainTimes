import SwiftUI

// Throwaway mockups: where a Citi Bike trip shows how much of its ride is on protected lanes.
// Delete once one's built.

private enum Style: String, CaseIterable {
    case a = "A · Own line"
    case b = "B · On the ride line"
    case c = "C · Bar"
    case d = "D · Pill by the minutes"
}

private struct MockTrip {
    let title: String
    let train: String?
    let ride: String
    let minutes: Int
    let share: Double
}

private let trips = [
    MockTrip(title: "Bike all the way → 1 Ave & E 39 St", train: nil,
             ride: "14 min ride from E 7 St & Avenue A", minutes: 19, share: 0.93),
    MockTrip(title: "Bike to Bedford Av → 8 Av", train: "L",
             ride: "11 min ride, then", minutes: 24, share: 0.41),
    MockTrip(title: "Bike all the way → Macon St & Patchen Av", train: nil,
             ride: "9 min ride from Gates Av & Tompkins Av", minutes: 13, share: 0),
]

private let pickup = CitiBike.Dock(id: "a", name: "E 7 St & Avenue A", lat: 40.7265, lon: -73.9839,
                                   bikes: 9, eBikes: 4, docks: 14, renting: true, returning: true)

private struct MockRow: View {
    let trip: MockTrip
    let style: Style
    let picked: Bool

    private var percent: String { "\(Int((trip.share * 100).rounded()))%" }
    private var protectedText: String { trip.share < 0.05 ? "No protected lanes" : "\(percent) protected lanes" }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                if let train = trip.train {
                    BikeBullet(size: 19)
                    LineBullet(route: train, size: 19)
                } else {
                    BikeBullet(size: 24)
                }
            }
            .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.title)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        BikeDocksLabel(trip: BikeTrip(kind: .bike, pickup: pickup, dropoff: pickup, path: [],
                                                      rideMinutes: 0, train: nil, bikeFirst: true, minutes: 0))
                        HStack(spacing: 4) {
                            Text(trip.ride)
                            if let train = trip.train { LineBullets(routes: [train], size: 14) }
                            if style == .b {
                                Text("· \(trip.share < 0.05 ? "no protected lanes" : "\(percent) protected")")
                            }
                        }
                        if style == .a {
                            HStack(spacing: 4) {
                                Image(systemName: "shield.lefthalf.filled")
                                    .foregroundStyle(trip.share < 0.05 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                                Text(protectedText)
                            }
                        }
                        if style == .c {
                            HStack(spacing: 6) {
                                Capsule().fill(.quaternary)
                                    .overlay(alignment: .leading) {
                                        GeometryReader { geometry in
                                            Capsule().fill(.green)
                                                .frame(width: geometry.size.width * trip.share)
                                        }
                                    }
                                    .frame(width: 70, height: 5)
                                Text(protectedText)
                            }
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        if style == .d, trip.share >= 0.05 {
                            HStack(spacing: 2) {
                                Image(systemName: "shield.lefthalf.filled")
                                Text(percent)
                            }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.green))
                        }
                        Text("\(trip.minutes) min")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(picked ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MockCard: View {
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(style.rawValue)
                .font(.headline)
                .padding(.horizontal, 14)
            VStack(spacing: 0) {
                ForEach(trips.indices, id: \.self) { index in
                    MockRow(trip: trips[index], style: style, picked: index == 0)
                    if index < trips.count - 1 { Divider().padding(.leading, 78) }
                }
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

#Preview("A and B") {
    ScrollView {
        VStack(spacing: 24) {
            MockCard(style: .a)
            MockCard(style: .b)
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}

#Preview("C and D") {
    ScrollView {
        VStack(spacing: 24) {
            MockCard(style: .c)
            MockCard(style: .d)
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
