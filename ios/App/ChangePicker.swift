import SwiftUI

/// Choosing where a widget's train is left for another, in two steps: the
/// station, from the stops after yours, then the lines there to change to,
/// which finishes. They go the same way as the train.
struct ChangePicker: View {
    let selection: Selection
    @Binding var change: Change?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Station] = []

    var body: some View {
        NavigationStack(path: $path) {
            ChangeStationStep(selection: selection, chosenID: change?.stationID) { station in
                path.append(station)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: Station.self) { station in
                ChangeLinesStep(selection: selection, station: station, change: change) { routes in
                    // Keeps the quick change and walk already set
                    var chosen = change ?? Change(stationID: station.id, routes: routes)
                    chosen.stationID = station.id
                    chosen.routes = routes
                    change = chosen
                    dismiss()
                }
            }
        }
    }
}

/// The lines you can change to at `station` from `selection`'s train: those
/// across the platform from it, and those on other platforms.
private func changeLines(at station: Station, from selection: Selection) -> (across: [String], others: [String]) {
    let platformLines = station.platforms(serving: selection.routes).flatMap(\.routes)
    let lines = station.routes.filter { !selection.routes.contains($0) }
    return (lines.filter(platformLines.contains), lines.filter { !platformLines.contains($0) })
}

/// Step 1: the stations after yours on your train's way, each with the lines
/// you can change to there. They come from a train running now, so they
/// follow any change to the line's route.
private struct ChangeStationStep: View {
    let selection: Selection
    let chosenID: String?
    let pick: (Station) -> Void
    @State private var stations: [Station]?
    @State private var failed = false

    private var stationName: String { selection.station?.name ?? "your station" }

    var body: some View {
        List {
            Section {
                if let stations {
                    if stations.isEmpty {
                        Text("No \(Spoken.trainsPlural(line: Lines.list(selection.routes), heading: selection.heading)) are running to list the stops.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(stations) { station in
                        let lines = changeLines(at: station, from: selection)
                        Button {
                            pick(station)
                        } label: {
                            ChangeStationRow(station: station, across: lines.across, others: lines.others,
                                             isExpress: isExpress(lines.across), isSelected: station.id == chosenID)
                        }
                    }
                } else if failed {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Couldn't reach the MTA. Try again", systemImage: "arrow.clockwise")
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Finding the stops after \(stationName)…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Next stops")
            } footer: {
                Text("Stops after \(stationName) on the \(Spoken.describe(line: Lines.list(selection.routes), heading: selection.heading)), with the lines you can change to at each.")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Change at", step: 0, count: 2) }
        }
        // Only the first time: coming back from the lines, they're still here
        .task {
            if stations == nil { await load() }
        }
    }

    /// Lines across the platform that don't stop at your station are its express.
    private func isExpress(_ across: [String]) -> Bool {
        let stopping = selection.station?.routes ?? []
        return !across.isEmpty && !across.contains(where: stopping.contains)
    }

    private func load() async {
        failed = false
        do {
            // Just the stations with another line to change to
            stations = try await TrainService.stations(after: selection).filter { station in
                let lines = changeLines(at: station, from: selection)
                return !lines.across.isEmpty || !lines.others.isEmpty
            }
        } catch {
            failed = true
        }
    }
}

private struct ChangeStationRow: View {
    let station: Station
    let across: [String]
    let others: [String]
    let isExpress: Bool
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(Color.primary)
                if !across.isEmpty {
                    lines(across, note: isExpress ? "Express, across the platform" : "Across the platform", prominent: true)
                }
                if !others.isEmpty {
                    lines(others, note: across.isEmpty ? "Another platform" : "Other platforms", prominent: false)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func lines(_ routes: [String], note: String, prominent: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(routes, id: \.self) { route in
                LineBullet(route: route, size: 16)
            }
            Text(note)
                .font(.caption.weight(prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.primary : Color.secondary)
                .padding(.leading, 2)
        }
    }
}

/// Step 2: the change station's lines, platform by platform, starting with
/// those across the platform from your train chosen. Your train's own are
/// there but can't be chosen. A line on another platform counts the walk to
/// it, set on the widget.
private struct ChangeLinesStep: View {
    let selection: Selection
    let station: Station
    let walkMinutes: Int
    let done: ([String]) -> Void
    @State private var chosen: [String]

    init(selection: Selection, station: Station, change: Change?, done: @escaping ([String]) -> Void) {
        self.selection = selection
        self.station = station
        self.done = done
        walkMinutes = change?.walkMinutes ?? Change.defaultWalkMinutes
        let starting = change.flatMap { $0.stationID == station.id ? $0.routes : nil }
        _chosen = State(initialValue: starting ?? changeLines(at: station, from: selection).across)
    }

    /// In the station's order.
    private var ordered: [String] { station.routes.filter(chosen.contains) }

    /// Platforms with a line to change to.
    private var platforms: [Platform] {
        station.platforms.filter { platform in platform.routes.contains { !selection.routes.contains($0) } }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("\(station.name): tap the lines to change to, from one platform or several.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                ForEach(platforms) { platform in
                    platformCard(platform)
                }
                if platforms.contains(where: { !isAcross($0) }) {
                    Text("A line on another platform counts the walk in its wait. Set how long it takes on the widget.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            Button {
                done(ordered)
            } label: {
                Text(chosen.isEmpty ? "Done" : "Done: \(Lines.list(ordered))")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Lines", step: 1, count: 2) }
        }
    }

    /// Whether your train stops at `platform` too.
    private func isAcross(_ platform: Platform) -> Bool {
        platform.routes.contains(where: selection.routes.contains)
    }

    private func platformCard(_ platform: Platform) -> some View {
        let routes = station.routes.filter(platform.routes.contains)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(routes.map { LineStyle.of($0).label }.joined(separator: " ")) platform".uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isAcross(platform) {
                    Label("Across the platform from your \(Lines.list(selection.routes))", systemImage: "arrow.left.arrow.right")
                        .font(.footnote)
                } else {
                    Label("Another platform: \(walkMinutes) min walk", systemImage: "figure.walk")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                ForEach(routes, id: \.self) { route in
                    if selection.routes.contains(route) {
                        // Your own train
                        LineBullet(route: route, size: 46)
                            .opacity(0.3)
                            .accessibilityLabel("\(Lines.name(of: route)) train, the one you're on")
                    } else {
                        LineToggle(route: route, isOn: chosen.contains(route)) {
                            if chosen.contains(route) {
                                chosen.removeAll { $0 == route }
                            } else {
                                chosen.append(route)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
