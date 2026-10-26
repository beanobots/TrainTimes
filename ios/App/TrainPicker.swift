// xcode: set sdk=iOS

import SwiftUI

/// Picks a train in three steps: station, lines (any number, by platform), then direction,
/// which finishes. Single-line stations skip to direction.
struct TrainPicker: View {
    @Binding var selection: Selection
    /// A widget's Both directions, offered beside the ways where the lines go two; nil to not offer it.
    var bothWays: Binding<Bool>? = nil
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
                    Button(role: .cancel) { dismiss() }
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .lines(let station, let chosen):
                    LinesStep(station: station, chosen: chosen) { routes in
                        path.append(.direction(station, routes: routes))
                    }
                case .direction(let station, let routes):
                    let same = station.id == selection.station?.id && routes == selection.routes
                    DirectionStep(station: station, routes: routes, current: same ? selection.direction : nil,
                                  offersBoth: bothWays != nil, bothCurrent: same && bothWays?.wrappedValue == true) { direction, both in
                        // Assign once, so a saved widget is never saved half-changed
                        var chosen = selection
                        chosen.stationID = station.id
                        chosen.routes = routes
                        chosen.direction = direction
                        selection = chosen
                        bothWays?.wrappedValue = both
                        dismiss()
                    }
                }
            }
        }
    }

    /// Preselects the filtered line, or the current lines if it's the same station.
    private func startingLines(at station: Station, filter: String?) -> [String] {
        if let filter {
            return station.routes.filter { LineStyle.of($0).label == filter }
        }
        return station.id == selection.station?.id ? selection.routes : []
    }
}

/// The step's name over a progress dash per step.
struct StepTitle: View {
    let title: String
    /// Zero-based.
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

/// Step 1: all stations, searchable, optionally filtered to one line.
struct StationStep: View {
    let chosenID: String?
    /// The station and the active filter label, if any.
    let pick: (Station, String?) -> Void
    @State private var search = ""
    /// Bullet label of the line to filter by, e.g. "R" or "S".
    @State private var filter: String?
    @State private var location = NearbyLocation()

    /// Closest stations, limited to the filtered line if any.
    private var nearby: [Nearby.Result] {
        guard let here = location.location else { return [] }
        let stations = filter.map { label in StationDirectory.all.filter { $0.serves(label: label) } } ?? StationDirectory.all
        return Nearby.stations(near: here, among: stations)
    }

    /// Alphabetical, or in stopping order when filtered by a line.
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
                // All lines: three rows of eight
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
                        // S here means all three shuttles, not just 42 St
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

    /// A location prompt, then the closest stations or why there are none. Hidden once
    /// location is refused.
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

struct StationRow: View {
    let station: Station
    let isSelected: Bool
    /// E.g. "0.3 mi"; only for nearby stations.
    var distance: String? = nil
    /// Scales with text, capped so nine bullets fit on the narrowest iPhone.
    @ScaledMetric(relativeTo: .caption) private var bulletSize: CGFloat = 16

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name).foregroundStyle(.primary)
                StepFreeLine(platforms: station.platforms) {
                    HStack(spacing: 4) {
                        ForEach(station.routes, id: \.self) { route in
                            LineBullet(route: route, size: min(bulletSize, 24))
                        }
                        Text(station.borough).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            if let distance {
                Text(distance).font(.subheadline).foregroundStyle(.secondary)
            }
            if isSelected {
                // VoiceOver uses the isSelected trait instead
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Step 2: the station's lines by platform. Pick any number across platforms, or a whole
/// platform; an "all lines" option is at the bottom.
struct LinesStep: View {
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
            HStack {
                StepFreeLine(platforms: [platform]) {
                    PlatformTitle(routes: routes)
                }
                .font(.footnote)
                Spacer()
                if routes.count > 1 {
                    let title = allChosen ? "Clear" : "Select all"
                    // One per platform, so VoiceOver names the platform
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
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle.pickerCard)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(allChosen ? .isSelected : [])
    }
}

/// "N Q R W PLATFORM", prefixed by `station` when it's elsewhere in the complex
/// ("59 ST · 4 5 6 PLATFORM").
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

/// In Step-free mode, warns when `platforms` lack step-free access (in `direction`, if set).
struct StepFreeNote: View {
    let platforms: [Platform]
    var direction: Direction? = nil
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if settings.settings.stepFree, let note = platforms.stepFreeNote(going: direction) {
            // Not a Label: its wide icon gap, and lists line their separators up with its title
            HStack(spacing: 3) {
                Image(systemName: "figure.stairs")
                Text(note)
            }
            .foregroundStyle(.orange)
            .accessibilityElement(children: .combine)
        }
    }
}

/// `content` with its `StepFreeNote` to the right, so the note adds no height; below it only
/// when the two don't fit side by side (e.g. a station with many lines).
struct StepFreeLine<Content: View>: View {
    let platforms: [Platform]
    var direction: Direction? = nil
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                content
                StepFreeNote(platforms: platforms, direction: direction)
            }
            VStack(alignment: .leading, spacing: 2) {
                content
                StepFreeNote(platforms: platforms, direction: direction)
            }
        }
    }
}

extension RoundedRectangle {
    /// A picker card's shape, as round as the system's grouped list rows.
    static let pickerCard = RoundedRectangle(cornerRadius: 20, style: .continuous)
}

extension View {
    /// Card style for a lines step, e.g. a platform.
    func pickerCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle.pickerCard)
    }

    /// Bottom button on a lines step that continues with the chosen lines. A glass button
    /// floating over the cards; the bar's scroll edge effect keeps it legible.
    func chosenLinesButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        safeAreaBar(edge: .bottom) {
            Button(action: action) {
                Text(title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(disabled)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }
}

/// A toggleable line bullet: coloured with a tick when on, gray when off.
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

/// Step 3: a tile for each way the lines go, led by its next train, then for a widget where
/// they go two ways, Both under them. Choosing one finishes.
struct DirectionStep: View {
    let station: Station
    let routes: [String]
    let current: Direction?
    /// Offers Both, a widget's both directions; `bothCurrent` when that's what it shows now.
    let offersBoth: Bool
    let bothCurrent: Bool
    /// The way, and whether it's Both (the way then being your train's).
    let pick: (Direction, Bool) -> Void
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @Environment(\.dynamicTypeSize) private var textSize
    /// Each way's trains you can still catch, once fetched.
    @State private var trains: [Direction: [Arrival]] = [:]
    /// Ways whose trains couldn't be fetched.
    @State private var failed: Set<Direction> = []

    /// Onward directions, as in the Nearby tab. Omits an unnamed direction (end of the line;
    /// if neither is named, both are offered), and one where every chosen line ends its
    /// daytime run though others continue, unless it's `current` (e.g. the 4 runs past
    /// Crown Hts-Utica Av at night).
    private var directions: [Direction] {
        let onward = station.onwardDirections(of: routes)
        return station.directions(of: routes).filter { $0 == current || onward.contains($0) }
    }

    private var showsBoth: Bool { offersBoth && directions.count == 2 }

    var body: some View {
        // Side by side, or stacked where large text wouldn't fit two across
        let tiles = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        ScrollView {
            VStack(spacing: 12) {
                header
                // Counts down while the step is open
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: 12) {
                        tiles {
                            ForEach(directions, id: \.self) { tile($0, now: context.date) }
                        }
                        if showsBoth {
                            bothTile
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Direction", step: 2) }
        }
        .task { await fetchTrains() }
    }

    /// The lines' bullets and the station, big, then the question.
    private var header: some View {
        VStack(spacing: 6) {
            LineBullets(routes: routes, size: 48)
                .accessibilityHidden(true)
            Text(station.name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Which way are you going?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Lines.list(routes)) at \(station.name)")
        .accessibilityAddTraits(.isHeader)
    }

    /// A way's tile: its arrow and whether it's chosen, where it goes, then its next train.
    private func tile(_ direction: Direction, now: Date) -> some View {
        let chosen = direction == current && !bothCurrent
        let label = station.directionLabel(direction, routes: routes)
        return Button {
            pick(direction, false)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    WayDisc(symbol: direction == .north ? "arrow.up" : "arrow.down", routes: routes)
                    Spacer()
                    ChosenMark(chosen: chosen)
                }
                Spacer(minLength: 18)
                Text(direction.compassName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(textSize.isAccessibilitySize ? 6 : 2, reservesSpace: !textSize.isAccessibilitySize)
                    .multilineTextAlignment(.leading)
                // A platform can be step-free in one direction only
                StepFreeNote(platforms: station.platforms(serving: routes), direction: direction)
                    .font(.caption)
                Spacer(minLength: 10)
                nextTrains(direction, now: now)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: textSize.isAccessibilitySize ? nil : 210, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle.directionTile)
            .chosenRing(chosen)
            .contentShape(RoundedRectangle.directionTile)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// The way's next train ("4 min", green when live) and the two after; a placeholder of the
    /// same height while they're fetched.
    @ViewBuilder private func nextTrains(_ direction: Direction, now: Date) -> some View {
        let marks = settings.settings.timeMarks(withoutColor: withoutColor)
        if let found = trains[direction] {
            if let next = found.first {
                let wait = MinutesToGo(until: next.time, from: now)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(wait.number).font(.system(.title, design: .rounded, weight: .bold))
                        if !wait.isNow {
                            Text("min").font(.subheadline.weight(.semibold))
                        }
                        StatusMark(isLive: next.isLive, marks: marks, size: 11)
                    }
                    .monospacedDigit()
                    .foregroundStyle(next.statusColor(scheduled: .primary))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Next train \(wait.spoken)")
                    let then = found.dropFirst().prefix(2).map { MinutesToGo(until: $0.time, from: now).count }
                    Text(then.isEmpty ? " " : "then \(then.map(String.init).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No trains soon")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else if failed.contains(direction) {
            Text("Couldn't get times")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("10 min").font(.system(.title, design: .rounded, weight: .bold))
                Text("then 10, 20").font(.caption)
            }
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
        }
    }

    /// Both: the two ways at once, your train's first.
    private var bothTile: some View {
        Button {
            pick(current.flatMap { directions.contains($0) ? $0 : nil } ?? directions[0], true)
        } label: {
            HStack(spacing: 14) {
                WayDisc(symbol: "arrow.up.arrow.down", routes: routes)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Both ways")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Each way side by side on the medium widget")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                ChosenMark(chosen: bothCurrent)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle.directionTile)
            .chosenRing(bothCurrent)
            .contentShape(RoundedRectangle.directionTile)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(bothCurrent ? .isSelected : [])
    }

    /// Each way's trains together, as the widget would fetch them, filled from the timetable
    /// where the feed has none.
    private func fetchTrains() async {
        let ways = directions.map { Selection(stationID: station.id, routes: routes, direction: $0) }
        await withTaskGroup(of: (Direction, [Arrival]?).self) { group in
            for way in ways {
                group.addTask {
                    let board = try? await TrainService.board(for: way, includingAlerts: false, includingOutages: false,
                                                              fillingFrom: { TimetableStore.load() })
                    return (way.direction, board.map { way.catchable($0.trains, now: .now) })
                }
            }
            for await (direction, found) in group {
                if let found {
                    trains[direction] = found
                } else {
                    failed.insert(direction)
                }
            }
        }
    }
}

/// An arrow in a disc of the lines' colour, or grey where they're more than one colour.
private struct WayDisc: View {
    let symbol: String
    let routes: [String]
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 38

    var body: some View {
        let styles = Set(routes.map { LineStyle.of($0).color })
        let style = styles.count == 1 ? routes.first.map(LineStyle.of) : nil
        Image(systemName: symbol)
            .font(.system(size: min(size, 64) * 0.47, weight: .heavy))
            .foregroundStyle(style?.textColor ?? .primary)
            .frame(width: min(size, 64), height: min(size, 64))
            .background(Circle().fill(style?.swiftUIColor ?? Color(.systemGray5)))
            .accessibilityHidden(true)
    }
}

/// A filled tick when chosen, else an empty circle; VoiceOver uses the isSelected trait instead.
private struct ChosenMark: View {
    let chosen: Bool

    var body: some View {
        Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .accessibilityHidden(true)
    }
}

extension RoundedRectangle {
    /// A direction tile's shape.
    fileprivate static let directionTile = RoundedRectangle(cornerRadius: 26, style: .continuous)
}

extension View {
    /// The accent ring round the chosen direction tile.
    fileprivate func chosenRing(_ chosen: Bool) -> some View {
        overlay {
            if chosen {
                RoundedRectangle.directionTile.strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
    }
}

#Preview("Direction · Both chosen") {
    if let station = StationDirectory.station(id: "R34") {
        NavigationStack {
            DirectionStep(station: station, routes: ["R"], current: .north, offersBoth: true, bothCurrent: true) { _, _ in }
        }
        .environment(SettingsStore())
    }
}

#Preview("Direction · Settings' default train") {
    if let station = StationDirectory.station(id: "R31") {
        NavigationStack {
            DirectionStep(station: station, routes: ["N", "R"], current: .south, offersBoth: false, bothCurrent: false) { _, _ in }
        }
        .environment(SettingsStore())
    }
}
