import SwiftUI

/// Every station, searchable, and optionally only those a given line stops at.
struct StationPicker: View {
    @Binding var selection: Selection
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    /// The bullet label of the line to filter by, e.g. "R" or "S".
    @State private var filter: String?

    private var matches: [Station] {
        let words = search.lowercased().split(separator: " ")
        return StationDirectory.all.filter { station in
            let onLine = filter.map { station.serves(label: $0) } ?? true
            let text = "\(station.name) \(station.borough)".lowercased()
            return onLine && words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Lines.filterRoutes, id: \.self) { route in
                            let label = LineStyle.of(route).label
                            Button {
                                filter = filter == label ? nil : label
                            } label: {
                                LineBullet(route: route, size: 34)
                                    .opacity(filter == nil || filter == label ? 1 : 0.3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Only stations served by")
            }

            Section {
                ForEach(matches) { station in
                    Button {
                        selection.choose(station, preferring: filter)
                        dismiss()
                    } label: {
                        StationRow(station: station, isSelected: station.id == selection.stationID)
                    }
                }
            } header: {
                Text("\(matches.count) stations")
            }
        }
        .searchable(text: $search, prompt: "Search stations")
        .navigationTitle("Station")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StationRow: View {
    let station: Station
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text(station.borough).font(.caption).foregroundStyle(.secondary)
                    ForEach(station.routes, id: \.self) { route in
                        LineBullet(route: route, size: 16)
                    }
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
