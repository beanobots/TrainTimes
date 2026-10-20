import SwiftUI

/// Choosing where a widget's train is left for another, in two steps: the
/// station, from the stops after yours, then the lines there to change to,
/// and which way they go, which finishes.
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
                ChangeLinesStep(selection: selection, station: station, change: change) { routes, direction in
                    // Keeps the quick change and walk already set
                    var chosen = change ?? Change(stationID: station.id, routes: routes)
                    chosen.stationID = station.id
                    chosen.routes = routes
                    // None for your train's way
                    chosen.direction = direction == selection.direction ? nil : direction
                    change = chosen
                    dismiss()
                }
            }
        }
    }
}

/// Step 1: the stations after yours on your train's way, each with the lines
/// you can change to there. They come from a train running now, so they
/// follow any change to the line's route.
private struct ChangeStationStep: View {
    let selection: Selection
    let chosenID: String?
    let pick: (Station) -> Void
    @State private var stations: [Station]?
    /// Whether the train has any stops after yours, with a line to change to or not.
    @State private var anyStops = false
    @State private var failed = false

    private var stationName: String { selection.station?.name ?? "your station" }

    var body: some View {
        List {
            Section {
                if let stations {
                    if stations.isEmpty && anyStops {
                        Text("No stops after \(stationName) have another line to change to.")
                            .foregroundStyle(.secondary)
                    } else if stations.isEmpty {
                        Text("No \(Spoken.trainsPlural(line: Lines.list(selection.routes), heading: selection.heading)) are running to list the stops.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(stations) { station in
                        let lines = Change.lines(at: station, from: selection)
                        Button {
                            pick(station)
                        } label: {
                            ChangeStationRow(station: station, across: lines.across, others: lines.others,
                                             isExpress: isExpress(lines.across, at: station),
                                             isSelected: station.id == chosenID)
                        }
                        .accessibilityAddTraits(station.id == chosenID ? .isSelected : [])
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

    /// Whether `across`, the lines across the platform from your train at
    /// `station`, are an express for it, going the way they'd start out
    /// chosen: for a line that runs the other way to yours there, the other N or S.
    private func isExpress(_ across: [String], at station: Station) -> Bool {
        var change = Change(stationID: station.id, routes: across)
        change.direction = change.suggestedDirection(for: selection)
        return !across.isEmpty && change.isExpress(for: selection)
    }

    private func load() async {
        failed = false
        do {
            let after = try await TrainService.stations(after: selection)
            anyStops = !after.isEmpty
            // Just the stations with another line to change to
            stations = after.filter { station in
                let lines = Change.lines(at: station, from: selection)
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
    /// The bullets grow with the text beside them, as the train picker's do.
    @ScaledMetric(relativeTo: .caption) private var bulletSize: CGFloat = 16

    /// The platforms walked to for `others`, here and at the stations joined
    /// to this one; none for a change only across the platform.
    private var otherPlatforms: [Platform] {
        StationDirectory.stations(inComplexOf: station).flatMap(\.platforms)
            .filter { $0.routes.contains(where: others.contains) }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(Color.primary)
                if !across.isEmpty {
                    // Lines across the platform that don't stop at your station are its express
                    lines(across, note: isExpress ? "Express, across the platform" : "Across the platform", prominent: true)
                }
                if !others.isEmpty {
                    lines(others, note: across.isEmpty ? "Another platform" : "Other platforms", prominent: false)
                }
                StepFreeNote(platforms: otherPlatforms)
                    .font(.caption)
            }
            Spacer()
            if isSelected {
                // VoiceOver says it's selected instead
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func lines(_ routes: [String], note: String, prominent: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(routes, id: \.self) { route in
                LineBullet(route: route, size: min(bulletSize, 24))
            }
            Text(note)
                .font(.caption.weight(prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.primary : Color.secondary)
                .padding(.leading, 2)
        }
    }
}

/// Step 2: the change station's lines, platform by platform, with those of
/// any station joined to it, starting with those across the platform from
/// your train chosen. Your train's own are there but can't be chosen, nor can
/// a line that ends its run there going the way chosen. Both ways are offered
/// where the lines chosen could go either, unless they're all across the
/// platform from your train and every line here plainly goes your way. A line
/// on another platform counts the walk to it, set on the widget.
private struct ChangeLinesStep: View {
    let selection: Selection
    let station: Station
    let walkMinutes: Int
    let done: ([String], Direction) -> Void
    /// Every line you can change to here, in order.
    private let lines: [String]
    /// Whether to offer both ways the lines go whichever are chosen: where
    /// the lines here go either way and don't all plainly go yours.
    private let offersBothWays: Bool
    @State private var chosen: [String]
    @State private var direction: Direction

    init(selection: Selection, station: Station, change: Change?, done: @escaping ([String], Direction) -> Void) {
        self.selection = selection
        self.station = station
        self.done = done
        walkMinutes = change?.walkMinutes ?? Change.defaultWalkMinutes
        let changeLines = Change.lines(at: station, from: selection)
        let lines = Change.lines(at: station).filter { changeLines.across.contains($0) || changeLines.others.contains($0) }
        self.lines = lines
        let starting = change.flatMap { $0.stationID == station.id ? $0 : nil }
        let chosen = starting?.routes ?? changeLines.across
        _chosen = State(initialValue: chosen)
        let direction = starting?.departureDirection(for: selection)
            ?? Change(stationID: station.id, routes: chosen.isEmpty ? lines : chosen).suggestedDirection(for: selection)
        _direction = State(initialValue: direction)
        // Where every line here plainly goes your way, there's no other to offer
        var every = Change(stationID: station.id, routes: lines)
        let usual = every.suggestedDirection(for: selection)
        every.direction = usual
        let bothWays = Direction.allCases.allSatisfy { way in
            lines.contains { Change.leaves($0, from: station, going: way, with: lines) }
        }
        offersBothWays = bothWays && (direction != usual || !every.goesYourWay(from: selection)
            || lines.contains { !Change.leaves($0, from: station, going: usual, with: lines) })
    }

    /// In the order of the lines.
    private var ordered: [String] { lines.filter(chosen.contains) }

    /// Platforms with a line to change to, here and at the stations joined to this one.
    private var platforms: [Platform] {
        StationDirectory.stations(inComplexOf: station).flatMap(\.platforms)
            .filter { platform in platform.routes.contains(where: lines.contains) }
    }

    /// Whether to show which way the lines go: once one is chosen, as that
    /// sets the way to start with; where `offersBothWays`, or the lines chosen
    /// leave both ways and aren't all across the platform.
    private var showsWays: Bool {
        guard !chosen.isEmpty else { return false }
        return offersBothWays
            || (Direction.allCases.allSatisfy { !chosenLines(going: $0).isEmpty }
                && !Change(stationID: station.id, routes: chosen, direction: direction).isAllAcross(from: selection))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("\(station.name): tap the lines to change to, from one platform or several.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if showsWays {
                    wayCard
                }
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
        .chosenLinesButton(chosen.isEmpty ? "Done" : "Done: \(Lines.list(ordered))", disabled: chosen.isEmpty) {
            done(ordered, direction)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Lines", step: 1, count: 2) }
        }
    }

    /// The lines on `platform` that go the way chosen together: those chosen
    /// there, or with none chosen there, all it has to change to.
    private func linesTogether(on platform: Platform) -> [String] {
        let chosenHere = chosen.filter(platform.routes.contains)
        return chosenHere.isEmpty ? lines.filter(platform.routes.contains) : chosenHere
    }

    /// Whether your train stops at `platform` too, on the side the lines
    /// chosen go from, which for a line that runs the other way to yours
    /// there is under the other N or S.
    private func isAcross(_ platform: Platform) -> Bool {
        Change.isAcross(linesTogether(on: platform), going: direction, at: platform, from: selection)
    }

    /// Whether `route` can be chosen: it goes the way chosen, or with none
    /// chosen yet, either way, as the first line chosen sets the way.
    private func canChoose(_ route: String) -> Bool {
        let routes = chosen.contains(route) ? chosen : chosen + [route]
        return chosen.isEmpty || Change.leaves(route, from: station, going: way(with: routes), with: routes)
    }

    private func toggle(_ route: String) {
        if chosen.contains(route) {
            let rest = chosen.filter { $0 != route }
            direction = way(with: rest)
            chosen = rest
        } else {
            direction = chosen.isEmpty ? Change(stationID: station.id, routes: [route]).suggestedDirection(for: selection)
                : way(with: chosen + [route])
            chosen.append(route)
        }
    }

    /// The way chosen, with `routes` chosen in place of the lines chosen now:
    /// as it is, or the other where that keeps those still chosen going as
    /// they do. A line that runs the other way to the rest on its platform
    /// goes by the other N or S with them, and by its own alone
    /// (`Platform.direction(_:of:with:)`), as the G does with the A and C at
    /// Hoyt-Schermerhorn Sts.
    private func way(with routes: [String]) -> Direction {
        let current = Change(stationID: station.id, routes: chosen, direction: direction)
        let kept = chosen.filter(routes.contains)
        return [direction, direction.opposite].first { way in
            let changed = Change(stationID: station.id, routes: routes, direction: way)
            return kept.allSatisfy {
                changed.departureDirection(of: $0, for: selection) == current.departureDirection(of: $0, for: selection)
            }
        } ?? direction
    }

    /// The lines chosen that go `way` from here.
    private func chosenLines(going way: Direction) -> [String] {
        chosen.filter { Change.leaves($0, from: station, going: way, with: chosen) }
    }

    /// Where the lines chosen go `way`, or that none of them do.
    private func name(of way: Direction) -> String {
        let going = chosenLines(going: way)
        guard !going.isEmpty else { return "No \(Lines.list(chosen, joinedBy: "or")) trains leave this way" }
        return Change(stationID: station.id, routes: going, direction: way).heading(for: selection)
    }

    /// The two ways the lines chosen can go, your train's first. A way none
    /// of them goes can't be chosen.
    private var wayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GOING")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach([selection.direction, selection.direction.opposite], id: \.self) { way in
                Button {
                    direction = way
                    // Lines that end their run here going this way are let go
                    chosen = chosenLines(going: way)
                } label: {
                    HStack {
                        Text(name(of: way))
                            .foregroundStyle(chosenLines(going: way).isEmpty ? Color.secondary : Color.primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        if way == direction {
                            // VoiceOver says it's selected instead
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(chosenLines(going: way).isEmpty)
                .accessibilityAddTraits(way == direction ? .isSelected : [])
            }
        }
        .pickerCard()
    }

    private func platformCard(_ platform: Platform) -> some View {
        let routes = platform.routes.filter { lines.contains($0) || selection.routes.contains($0) }
        // Where the lines to change to go from it, each of their names
        let heading = Station.directionNames(direction, on: [platform], routes: linesTogether(on: platform))
            .joined(separator: " or ")
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Another station's platform has its name: "59 St · 4 5 6 platform"
                PlatformTitle(routes: routes, station: platform.name == station.name ? nil : platform.name)
                if isAcross(platform) {
                    Label("Across the platform from your \(Lines.list(selection.routes.filter(platform.routes.contains)))",
                          systemImage: "arrow.left.arrow.right")
                        .font(.footnote)
                } else {
                    Label("Another platform: \(walkMinutes) min walk", systemImage: "figure.walk")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    StepFreeNote(platforms: [platform], direction: direction)
                        .font(.footnote)
                }
                if showsWays {
                    Label(heading.isEmpty ? "Trains end here going this way" : "To \(heading)", systemImage: "arrow.forward")
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
                            .accessibilityLabel("\(Lines.spokenName(of: route)), the one you're on")
                    } else if canChoose(route) {
                        LineToggle(route: route, isOn: chosen.contains(route)) {
                            toggle(route)
                        }
                    } else {
                        // Ends its run here going the way chosen
                        LineBullet(route: route, size: 46)
                            .opacity(0.3)
                            .accessibilityLabel("\(Lines.spokenName(of: route)), which ends here going this way")
                    }
                }
            }
        }
        .pickerCard()
    }
}
