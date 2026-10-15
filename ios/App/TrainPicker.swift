import SwiftUI

/// Choosing a train in three steps, each leading straight to the next: the
/// station, then its lines (by platform, any number of them), then the
/// direction, which finishes. A station with one line skips to the direction.
struct TrainPicker: View {
    @Binding var selection: Selection
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []

    enum Step: Hashable {
        case lines(Station, chosen: [String])
        case direction(Station, routes: [String])
    }

    var body: some View {
        NavigationStack(path: $path) {
            StationStep(chosenID: selection.station?.id) { station, filter in
                if station.routes.count == 1 {
                    path.append(.direction(station, routes: station.routes))
                } else {
                    path.append(.lines(station, chosen: startingLines(at: station, filter: filter)))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .lines(let station, let chosen):
                    LinesStep(station: station, chosen: chosen) { routes in
                        path.append(.direction(station, routes: routes))
                    }
                case .direction(let station, let routes):
                    let current = station.id == selection.station?.id && routes == selection.routes ? selection.direction : nil
                    DirectionStep(station: station, routes: routes, current: current) { direction in
                        selection.stationID = station.id
                        selection.routes = routes
                        selection.direction = direction
                        dismiss()
                    }
                }
            }
        }
    }

    /// The line filtered by, or at the station already chosen, its lines.
    private func startingLines(at station: Station, filter: String?) -> [String] {
        if let filter {
            return station.routes.filter { LineStyle.of($0).label == filter }
        }
        return station.id == selection.station?.id ? selection.routes : []
    }
}

/// The step's name, and three dashes for how far along it is.
private struct StepTitle: View {
    let title: String
    /// 0, 1 or 2.
    let step: Int

    var body: some View {
        VStack(spacing: 5) {
            Text(title).font(.headline)
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color(.systemGray4))
                        .frame(width: 28, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), step \(step + 1) of 3")
    }
}

/// Step 1: every station, searchable, and optionally only those a line stops at.
private struct StationStep: View {
    let chosenID: String?
    /// The station, and the bullet label filtered by, if any.
    let pick: (Station, String?) -> Void
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
                            .accessibilityAddTraits(filter == label ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Only stations on")
            }

            Section {
                ForEach(matches) { station in
                    Button {
                        pick(station, filter)
                    } label: {
                        StationRow(station: station, isSelected: station.id == chosenID)
                    }
                }
            } header: {
                Text(filter.map { "Stations on the \($0)" } ?? "\(matches.count) stations")
            }
        }
        .searchable(text: $search, prompt: "Search stations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Station", step: 0) }
        }
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
                    ForEach(station.routes, id: \.self) { route in
                        LineBullet(route: route, size: 16)
                    }
                    Text(station.borough).font(.caption).foregroundStyle(.secondary)
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

/// Step 2: the station's lines, platform by platform. Tap any number of them,
/// from one platform or several, or all of a platform's at once; every line
/// at the station is at the bottom.
private struct LinesStep: View {
    let station: Station
    let next: ([String]) -> Void
    @State private var chosen: [String]

    init(station: Station, chosen: [String], next: @escaping ([String]) -> Void) {
        self.station = station
        self.next = next
        _chosen = State(initialValue: chosen)
    }

    /// In the station's order.
    private var ordered: [String] { station.routes.filter(chosen.contains) }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("\(station.name): tap the lines you want, from one platform or several.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                ForEach(station.platforms) { platform in
                    platformCard(station.routes.filter(platform.routes.contains))
                }
                if station.platforms.count > 1 {
                    everyLine
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            Button {
                next(ordered)
            } label: {
                Text(nextLabel)
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
            ToolbarItem(placement: .principal) { StepTitle(title: "Lines", step: 1) }
        }
    }

    private var nextLabel: String {
        if chosen.isEmpty { return "Next" }
        if ordered.count == station.routes.count && ordered.count > 4 { return "Next: all \(ordered.count) lines" }
        return "Next: \(Lines.list(ordered))"
    }

    private func platformCard(_ routes: [String]) -> some View {
        let allChosen = routes.allSatisfy(chosen.contains)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(routes.map { LineStyle.of($0).label }.joined(separator: " ")) platform".uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if routes.count > 1 {
                    Button(allChosen ? "Clear" : "Select all") {
                        if allChosen {
                            chosen.removeAll(where: routes.contains)
                        } else {
                            chosen += routes.filter { !chosen.contains($0) }
                        }
                    }
                    .font(.subheadline)
                }
            }
            HStack(spacing: 12) {
                ForEach(routes, id: \.self) { route in
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var everyLine: some View {
        let allChosen = station.routes.allSatisfy(chosen.contains)
        return Button {
            chosen = allChosen ? [] : station.routes
        } label: {
            HStack(spacing: 12) {
                LineBullets(routes: station.routes, size: 34)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All \(station.routes.count) lines").foregroundStyle(.primary)
                    Text("Every platform at this station").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: allChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(allChosen ? Color.accentColor : Color(.systemGray3))
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(allChosen ? .isSelected : [])
    }
}

/// A line's bullet to tap on or off: in its colour with a tick when chosen,
/// gray when not.
private struct LineToggle: View {
    let route: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        let style = LineStyle.of(route)
        Button(action: toggle) {
            ZStack(alignment: .bottomTrailing) {
                if isOn {
                    LineBullet(route: route, size: 46)
                } else {
                    let fontSize = 46 * (style.label.count > 1 ? 0.42 : 0.56)
                    Text(style.label)
                        .font(.system(size: fontSize, weight: .bold))
                        .offset(y: -LineBullet.capitalsOffset(fontSize: fontSize))
                        .foregroundStyle(Color(.secondaryLabel))
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color(.systemGray5)))
                }
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Color.accentColor)
                        .background(Circle().fill(Color(.secondarySystemGroupedBackground)).padding(-2))
                        .offset(x: 3, y: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Lines.name(of: route)) train")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Step 3: which way, named by the station: choosing one finishes.
private struct DirectionStep: View {
    let station: Station
    let routes: [String]
    let current: Direction?
    let pick: (Direction) -> Void

    var body: some View {
        List {
            Section {
                ForEach(Direction.allCases, id: \.self) { direction in
                    Button {
                        pick(direction)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: direction == .north ? "arrow.up" : "arrow.down")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(Color(.systemGray5)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(station.directionLabel(direction, routes: routes)).foregroundStyle(.primary)
                                Text(direction == .north ? "Northbound" : "Southbound")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if direction == current {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } header: {
                Text("\(Lines.list(routes)) at \(station.name)")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Direction", step: 2) }
        }
    }
}
