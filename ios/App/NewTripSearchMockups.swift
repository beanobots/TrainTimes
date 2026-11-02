import SwiftUI

// Throwaway mockups: a simpler New Trip search. The end being picked is one bar at the top,
// everything under it is results. No Current Location, no Stations near you. Delete once built.

private enum Mock {
    static let typed = "86"

    /// Stations for what's typed, as the real list finds them.
    static var stations: [Station] {
        let query = StationSearch(typed)
        return Array(StationDirectory.all.filter { query.matches($0) }.prefix(5))
    }

    static let places: [(String, String)] = [
        ("86th Street Bagels", "1567 2nd Ave, New York, NY"),
        ("86 Bedford St", "New York, NY 10014"),
        ("86 Orchard St", "New York, NY 10002"),
    ]

    static let saved: [(String, String, String)] = [
        ("Home", "house.fill", "214 Prospect Park W"),
        ("Work", "briefcase.fill", "11 W 53rd St"),
    ]
}

/// The end being picked: its name, the field, and closing it.
private struct SearchBar: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("To").fontWeight(.semibold)
            Group {
                if text.isEmpty {
                    Text("Station or address").foregroundStyle(.tertiary)
                } else {
                    (Text(text) + Text("|").foregroundStyle(.tint))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.quaternary, in: Circle())
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 52)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 16)
    }
}

/// A stand-in for the keyboard and its number row.
private struct Keyboard: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array("1234567890"), id: \.self) { digit in
                    Text(String(digit))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            Rectangle()
                .fill(Color(.systemGray4))
                .frame(height: 250)
                .overlay { Text("Keyboard").foregroundStyle(.secondary) }
        }
    }
}

private struct SavedRow: View {
    let name: String
    let symbol: String
    let address: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.tint, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(address).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PlaceRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Home and Work as glass chips, as New Trip has them now.
private struct SavedChips: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Mock.saved, id: \.0) { saved in
                Label(saved.0, systemImage: saved.1)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .glassEffect(.regular, in: Capsule())
            }
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .frame(width: 38, height: 38)
                .glassEffect(.regular, in: Circle())
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

private enum Variant: String, CaseIterable {
    /// Home and Work as rows at the head of the results; with nothing typed, they're all there is.
    case savedRows = "A · Home/Work as result rows"
    /// Home and Work chips kept, just under the bar.
    case chips = "B · Home/Work chips under the bar"
    /// Nothing until you type.
    case blank = "C · Blank until you type"
}

private struct SearchScreen: View {
    let variant: Variant
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(text: text)
                .padding(.top, 62)
                .padding(.bottom, 8)
            if variant == .chips {
                SavedChips().padding(.vertical, 6)
            }
            results
            Keyboard()
        }
        .background(Color(.systemGroupedBackground))
        .frame(width: 393, height: 852)
        .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
    }

    @ViewBuilder
    private var results: some View {
        if text.isEmpty && variant != .savedRows {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.title2)
                Text("Search for a station, address or place")
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if variant == .savedRows && text.isEmpty {
                    Section {
                        ForEach(Mock.saved, id: \.0) { SavedRow(name: $0.0, symbol: $0.1, address: $0.2) }
                        Label("Add Place", systemImage: "plus").foregroundStyle(.tint)
                    }
                }
                if !text.isEmpty {
                    Section("Stations") {
                        ForEach(Mock.stations) { StationRow(station: $0, isSelected: false) }
                    }
                    Section("Places") {
                        ForEach(Mock.places, id: \.0) { PlaceRow(title: $0.0, subtitle: $0.1) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollDisabled(true)
        }
    }
}

private struct VariantPair: View {
    let variant: Variant

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(variant.rawValue).font(.title2.bold())
            HStack(spacing: 24) {
                SearchScreen(variant: variant, text: "")
                SearchScreen(variant: variant, text: Mock.typed)
            }
        }
        .padding(24)
        .background(Color(.systemBackground))
    }
}

#Preview("A", traits: .sizeThatFitsLayout) { VariantPair(variant: .savedRows) }
#Preview("B", traits: .sizeThatFitsLayout) { VariantPair(variant: .chips) }
#Preview("C", traits: .sizeThatFitsLayout) { VariantPair(variant: .blank) }
