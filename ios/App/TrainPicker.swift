// xcode: set sdk=iOS

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
                        // All at once, so a saved widget is never saved half changed
                        var chosen = selection
                        chosen.stationID = station.id
                        chosen.routes = routes
                        chosen.direction = direction
                        selection = chosen
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

/// The step's name, and a dash for each step, lit up to this one.
struct StepTitle: View {
    let title: String
    /// From 0.
    let step: Int
    var count = 3

    var body: some View {
        VStack(spacing: 5) {
            Text(title).font(.headline)
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.accentColor : Color(.systemGray4))
                        .frame(width: 28, height: 4)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), step \(step + 1) of \(count)")
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
    @State private var location = NearbyLocation()

    /// The closest stations, or with a line filtered by, the closest it stops at.
    private var nearby: [Nearby.Result] {
        guard let here = location.location else { return [] }
        let stations = filter.map { label in StationDirectory.all.filter { $0.serves(label: label) } } ?? StationDirectory.all
        return Nearby.stations(near: here, among: stations)
    }

    /// Every station, alphabetically, or with a line filtered by, its stations in the order it stops at them.
    private var matches: [Station] {
        let query = StationSearch(search)
        let stations = StationDirectory.all.filter { station in
            let onLine = filter.map { station.serves(label: $0) } ?? true
            return onLine && query.matches(station)
        }
        return filter.map { StationDirectory.inLineOrder(stations, label: $0) } ?? stations
    }

    var body: some View {
        List {
            Section {
                // Every line at once: three rows of eight
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 10) {
                    ForEach(Lines.filterRoutes, id: \.self) { route in
                        let label = LineStyle.of(route).label
                        Button {
                            filter = filter == label ? nil : label
                        } label: {
                            LineBullet(route: route, size: 32)
                                .opacity(filter == nil || filter == label ? 1 : 0.3)
                        }
                        .buttonStyle(.plain)
                        // The S stands for all three shuttles here, not the 42 St one alone
                        .accessibilityLabel(label == "S" ? "Shuttles" : Lines.spokenName(of: route))
                        .accessibilityAddTraits(filter == label ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Only stations on")
            }

            if search.isEmpty {
                nearbySection
            }

            Section {
                ForEach(matches) { station in
                    Button {
                        pick(station, filter)
                    } label: {
                        StationRow(station: station, isSelected: station.id == chosenID)
                    }
                    .accessibilityAddTraits(station.id == chosenID ? .isSelected : [])
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
        .onAppear { location.start() }
    }

    /// A button to allow location until it's allowed, then the closest stations,
    /// or why there are none. Nothing once location is refused.
    @ViewBuilder
    private var nearbySection: some View {
        if location.status == .notDetermined {
            Section {
                Button {
                    location.find()
                } label: {
                    Label("Show stations near you", systemImage: "location")
                }
            }
        } else if location.isAllowed {
            if location.failed {
                Section {
                    Button {
                        location.find()
                    } label: {
                        Label("Couldn't find you. Try again", systemImage: "location.slash")
                    }
                } header: {
                    Text("Near you")
                }
            } else if location.location == nil {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Finding stations near you…").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Near you")
                }
            } else if nearby.isEmpty {
                Section {
                    Text(filter.map { "No \($0) stations within \(Nearby.rangeDescription) of you" }
                         ?? "No stations within \(Nearby.rangeDescription) of you")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Near you")
                }
            } else {
                Section {
                    ForEach(nearby) { result in
                        Button {
                            pick(result.station, filter)
                        } label: {
                            StationRow(station: result.station, isSelected: result.station.id == chosenID,
                                       distance: result.distance)
                        }
                        .accessibilityAddTraits(result.station.id == chosenID ? .isSelected : [])
                    }
                } header: {
                    Text(filter.map { "Near you on the \($0)" } ?? "Near you")
                }
            }
        }
    }
}

private struct StationRow: View {
    let station: Station
    let isSelected: Bool
    /// "0.3 mi", in the stations near you.
    var distance: String? = nil
    /// The bullets grow with the text beside them, up to where nine still fit
    /// on the narrowest iPhone.
    @ScaledMetric(relativeTo: .caption) private var bulletSize: CGFloat = 16

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    ForEach(station.routes, id: \.self) { route in
                        LineBullet(route: route, size: min(bulletSize, 24))
                    }
                    Text(station.borough).font(.caption).foregroundStyle(.secondary)
                }
                StepFreeNote(platforms: station.platforms)
                    .font(.caption)
            }
            Spacer()
            if let distance {
                Text(distance).font(.subheadline).foregroundStyle(.secondary)
            }
            if isSelected {
                // VoiceOver says it's selected instead
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
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
                    platformCard(platform)
                }
                if station.platforms.count > 1 {
                    everyLine
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .chosenLinesButton(nextLabel, disabled: chosen.isEmpty) { next(ordered) }
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

    private func platformCard(_ platform: Platform) -> some View {
        let routes = station.lines(on: platform)
        let allChosen = routes.allSatisfy(chosen.contains)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    PlatformTitle(routes: routes)
                    Spacer()
                    if routes.count > 1 {
                        let title = allChosen ? "Clear" : "Select all"
                        // Each platform has one, so VoiceOver says whose
                        let label = allChosen ? "Clear the \(Lines.list(routes)) platform"
                            : "Select all on the \(Lines.list(routes)) platform"
                        Button(title) {
                            if allChosen {
                                chosen.removeAll(where: routes.contains)
                            } else {
                                chosen += routes.filter { !chosen.contains($0) }
                            }
                        }
                        .font(.subheadline)
                        .accessibilityLabel(label)
                        .accessibilityInputLabels([title])
                    }
                }
                StepFreeNote(platforms: [platform])
                    .font(.footnote)
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
        .pickerCard()
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

/// "N Q R W PLATFORM" over a platform's lines on a lines step, with the name
/// of the station it's at first where that's another: "59 ST · 4 5 6 PLATFORM".
struct PlatformTitle: View {
    let routes: [String]
    var station: String? = nil

    var body: some View {
        let place = station.map { "\($0) · " } ?? ""
        let labels = routes.map { LineStyle.of($0).label }.joined(separator: " ")
        Text("\(place)\(labels) platform".uppercased())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// With Settings › Step-free mode, where `platforms` have no step-free
/// access, going `direction` once it's chosen; nothing where they all have it.
struct StepFreeNote: View {
    let platforms: [Platform]
    var direction: Direction? = nil
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if settings.settings.stepFree, let note = platforms.stepFreeNote(going: direction) {
            Label(note, systemImage: "figure.stairs")
                .foregroundStyle(.orange)
        }
    }
}

extension View {
    /// A card on a lines step, such as a platform's.
    func pickerCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The button at the foot of a lines step that goes on with the lines chosen.
    func chosenLinesButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom) {
            Button(action: action) {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

/// A line's bullet to tap on or off: in its colour with a tick when chosen,
/// gray when not.
struct LineToggle: View {
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
                    LineBullet.label(style, size: 46)
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
        .accessibilityLabel(Lines.spokenName(of: route))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Step 3: which way, named by the station: choosing one finishes.
private struct DirectionStep: View {
    let station: Station
    let routes: [String]
    let current: Direction?
    let pick: (Direction) -> Void
    /// The arrow's circle grows with the text beside it.
    @ScaledMetric(relativeTo: .subheadline) private var arrowSize: CGFloat = 32

    /// The ways the lines go from here. One the MTA gives no name, at the end
    /// of the line, has no trains and is left out, as in the Live tab; where
    /// it names neither, both.
    private var directions: [Direction] {
        station.directions(of: routes)
    }

    var body: some View {
        List {
            Section {
                ForEach(directions, id: \.self) { direction in
                    Button {
                        pick(direction)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: direction == .north ? "arrow.up" : "arrow.down")
                                .font(.subheadline.weight(.bold))
                                // No bigger than its circle
                                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                                .foregroundStyle(.secondary)
                                .frame(width: min(arrowSize, 64), height: min(arrowSize, 64))
                                .background(Circle().fill(Color(.systemGray5)))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(station.directionLabel(direction, routes: routes)).foregroundStyle(.primary)
                                Text(direction.compassName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                // A partly accessible platform can be step-free one way only
                                StepFreeNote(platforms: station.platforms(serving: routes), direction: direction)
                                    .font(.footnote)
                            }
                            Spacer()
                            if direction == current {
                                // VoiceOver says it's selected instead
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(direction == current ? .isSelected : [])
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
