import SwiftUI

/// Picks a widget's change in two steps: the station (from stops after yours), then the lines
/// to change to there and which way they go.
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
                    Button(role: .cancel) { dismiss() }
                }
            }
            .navigationDestination(for: Station.self) { station in
                ChangeLinesStep(selection: selection, station: station, change: change) { routes, direction in
                    // Keep the existing quick-change and walk settings
                    var chosen = change ?? Change(stationID: station.id, routes: routes)
                    chosen.stationID = station.id
                    chosen.routes = routes
                    // nil means your train's way
                    chosen.direction = direction == selection.direction ? nil : direction
                    change = chosen
                    dismiss()
                }
            }
        }
    }
}

/// Step 1: stations after yours, each with the lines you can change to. Built from one running
/// train per line, so they follow route changes and include each branch where lines split.
private struct ChangeStationStep: View {
    let selection: Selection
    let chosenID: String?
    let pick: (Station) -> Void
    @State private var stations: [Station]?
    /// Whether there are any stops after yours, with or without a change.
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
                Text("Stops after \(stationName) on \(selection.routes.count > 1 ? "any of " : "")the \(Spoken.describe(line: Lines.list(selection.routes), heading: selection.heading)), with the lines you can change to at each.")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Change at", step: 0, count: 2) }
        }
        // Load once; they're kept when coming back from step 2
        .task {
            if stations == nil { await load() }
        }
    }

    /// Whether the cross-platform lines `across` are an express for your train, going their
    /// suggested way (the other N/S for a line that runs opposite to yours there).
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
            // Only stations with a line to change to
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
    /// Scales with the text, like the train picker's bullets.
    @ScaledMetric(relativeTo: .caption) private var bulletSize: CGFloat = 16

    /// Platforms for `others` in this station's complex; empty for a cross-platform-only change.
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
                    // Cross-platform lines that skip your station are an express
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

/// Step 2: the change station's lines by platform (including joined stations), with the
/// cross-platform lines chosen to start. Can't choose: your own lines, a line ending its run
/// here going the chosen way, or one that would flip a chosen line's way. Both ways are offered
/// where the chosen lines could go either, unless all are cross-platform and every line here
/// plainly goes your way. Lines on another platform add the widget's walk time.
private struct ChangeLinesStep: View {
    let selection: Selection
    let station: Station
    let walkMinutes: Int
    let done: ([String], Direction) -> Void
    /// Every line you can change to here, in order.
    private let lines: [String]
    /// Offer both ways regardless of choice: lines here go either way and don't all plainly go yours.
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
        // If every line here plainly goes your way, there's no other way to offer
        var every = Change(stationID: station.id, routes: lines)
        let usual = every.suggestedDirection(for: selection)
        every.direction = usual
        let bothWays = Direction.allCases.allSatisfy { way in
            lines.contains { Change.leaves($0, from: station, going: way, with: lines) }
        }
        offersBothWays = bothWays && (direction != usual || !every.goesYourWay(from: selection)
            || lines.contains { !Change.leaves($0, from: station, going: usual, with: lines) })
    }

    /// `chosen`, in `lines` order.
    private var ordered: [String] { lines.filter(chosen.contains) }

    /// Platforms in the complex with a line to change to.
    private var platforms: [Platform] {
        StationDirectory.stations(inComplexOf: station).flatMap(\.platforms)
            .filter { platform in platform.routes.contains(where: lines.contains) }
    }

    /// Show the way picker once a line is chosen (that sets the starting way), if
    /// `offersBothWays` or the chosen lines leave both ways and aren't all cross-platform.
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

    /// The chosen lines on `platform`, or if none, all its lines to change to.
    private func linesTogether(on platform: Platform) -> [String] {
        let chosenHere = chosen.filter(platform.routes.contains)
        return chosenHere.isEmpty ? lines.filter(platform.routes.contains) : chosenHere
    }

    /// Whether your train also stops at `platform`, on the side the chosen lines leave from
    /// (the other N/S for a line running opposite to yours there).
    private func isAcross(_ platform: Platform) -> Bool {
        Change.isAcross(linesTogether(on: platform), going: direction, at: platform, from: selection)
    }

    /// Whether `route` can be chosen: it goes the chosen way (any way if none chosen yet, since the
    /// first choice sets it), and wouldn't flip a chosen line's way (`way(with:)`).
    private func canChoose(_ route: String) -> Bool {
        if chosen.isEmpty { return true }
        let routes = chosen.contains(route) ? chosen : chosen + [route]
        guard let way = way(with: routes) else { return false }
        return Change.leaves(route, from: station, going: way, with: routes)
    }

    private func toggle(_ route: String) {
        if chosen.contains(route) {
            let rest = chosen.filter { $0 != route }
            if let way = way(with: rest) {
                direction = way
                chosen = rest
            } else {
                // Drop lines that would flip direction without it
                chosen = keeping(rest, going: direction)
            }
        } else {
            direction = chosen.isEmpty ? Change(stationID: station.id, routes: [route]).suggestedDirection(for: selection)
                : way(with: chosen + [route]) ?? direction
            chosen.append(route)
        }
    }

    /// The way to use if `routes` replaced `chosen`: the current way or its opposite, whichever
    /// keeps the still-chosen lines going as they do; nil if neither. A line running opposite to
    /// the rest on its platform uses their N/S with them and its own alone
    /// (`Platform.direction(_:of:with:)`), e.g. the G with the A/C at Hoyt-Schermerhorn Sts.
    private func way(with routes: [String]) -> Direction? {
        let kept = chosen.filter(routes.contains)
        return [direction, direction.opposite].first { keeping(routes, going: $0) == kept }
    }

    /// The `chosen` lines that are in `routes` and keep their departure way if `routes` go `way`.
    private func keeping(_ routes: [String], going way: Direction) -> [String] {
        let current = Change(stationID: station.id, routes: chosen, direction: direction)
        let changed = Change(stationID: station.id, routes: routes, direction: way)
        return chosen.filter { route in
            routes.contains(route)
                && changed.departureDirection(of: route, for: selection) == current.departureDirection(of: route, for: selection)
        }
    }

    private func chosenLines(going way: Direction) -> [String] {
        chosen.filter { Change.leaves($0, from: station, going: way, with: chosen) }
    }

    /// Where the chosen lines go `way`, or that none do.
    private func name(of way: Direction) -> String {
        let going = chosenLines(going: way)
        guard !going.isEmpty else { return "No \(Lines.list(chosen, joinedBy: "or")) trains leave this way" }
        return Change(stationID: station.id, routes: going, direction: way).heading(for: selection)
    }

    /// Both ways, your train's first; a way no chosen line goes is disabled.
    private var wayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GOING")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach([selection.direction, selection.direction.opposite], id: \.self) { way in
                Button {
                    direction = way
                    // Drop lines that end their run here going this way
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
        // Destination names for the lines from this platform
        let heading = Station.directionNames(direction, on: [platform], routes: linesTogether(on: platform))
            .joined(separator: " or ")
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Joined station's platforms show its name: "59 St · 4 5 6 platform"
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
                    } else if way(with: chosen + [route]) == nil {
                        // Would turn a line chosen the other way
                        LineBullet(route: route, size: 46)
                            .opacity(0.3)
                            .accessibilityLabel("\(Lines.spokenName(of: route)), which goes the other way to the lines chosen")
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

/// Picks where you're going. With a change, for the Transfers widget to time each way there: the
/// stops after the change on each line changed to, and on your own train after the change.
/// Without one, for Next train to show when you'd get there: the stops ahead on your train.
struct DestinationPicker: View {
    let selection: Selection
    let change: Change?
    @Binding var destinationID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var stations: [(station: Station, routes: [String])]?
    @State private var failed = false
    /// Scales with the text, like the change picker's bullets.
    @ScaledMetric(relativeTo: .caption) private var bulletSize: CGFloat = 16

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        choose(nil)
                    } label: {
                        row(name: "None", routes: [], selected: destinationID == nil)
                    }
                } footer: {
                    Text(change == nil ? "Without a destination, the widget shows no arrival time."
                                       : "Without a destination, the large widget times each line to the change.")
                }
                Section {
                    if let stations {
                        if stations.isEmpty {
                            Text("No trains are running to list the stops.").foregroundStyle(.secondary)
                        }
                        ForEach(stations, id: \.station.id) { item in
                            Button {
                                choose(item.station.id)
                            } label: {
                                row(name: item.station.name, routes: item.routes,
                                    selected: destinationID == item.station.id)
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
                            Text(change == nil ? "Finding the stops ahead…" : "Finding the stops after the change…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(change == nil ? "Stops ahead" : "Stops after the change")
                } footer: {
                    Text(change == nil ? "Stops on your train, with the lines that get there."
                                       : "Stops on the lines you change to, and on your own train, with the lines that get there.")
                }
            }
            .navigationTitle("Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
            .task {
                if stations == nil { await load() }
            }
        }
    }

    private func choose(_ id: String?) {
        destinationID = id
        dismiss()
    }

    private func row(name: String, routes: [String], selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(Color.primary)
                if !routes.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(routes, id: \.self) { route in
                            LineBullet(route: route, size: min(bulletSize, 24))
                        }
                    }
                }
            }
            Spacer()
            if selected {
                // VoiceOver says it's selected instead
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Each line changed to from where it's changed to (the station of its complex it stops at),
    /// then your own train from the change on, merged with the lines reaching each. Without a
    /// change, just your own train's stops ahead.
    private func load() async {
        failed = false
        guard let change else {
            do {
                stations = try await TrainService.stations(after: selection)
                    .filter { $0.id != selection.stationID }
                    .map { ($0, selection.routes.filter($0.routes.contains)) }
            } catch {
                failed = true
            }
            return
        }
        let parts = change.smartChanges(for: selection)
        let changeIDs = Set(parts.compactMap(\.change.station).flatMap(StationDirectory.stations(inComplexOf:)).map(\.id))
        var trips: [(selection: Selection, routes: [String])] = []
        for part in parts {
            guard let station = part.change.station else { continue }
            for route in part.change.routes {
                guard let stop = StationDirectory.stations(inComplexOf: station).first(where: { $0.routes.contains(route) }) else {
                    continue
                }
                let way = part.change.departureDirection(of: route, for: selection.only(part.lines))
                trips.append((Selection(stationID: stop.id, routes: [route], direction: way), [route]))
            }
        }
        do {
            var found: [(station: Station, routes: [String])] = []
            let add = { (station: Station, routes: [String]) in
                guard !changeIDs.contains(station.id), station.id != selection.stationID else { return }
                if let index = found.firstIndex(where: { $0.station.id == station.id }) {
                    found[index].routes += routes.filter { !found[index].routes.contains($0) }
                } else {
                    found.append((station, routes))
                }
            }
            for trip in trips {
                for station in try await TrainService.stations(after: trip.selection) {
                    add(station, trip.routes)
                }
            }
            // Staying on: only stops after the change
            let own = try await TrainService.stations(after: selection)
            for station in own.drop(while: { !changeIDs.contains($0.id) }).dropFirst() {
                add(station, selection.routes.filter(station.routes.contains))
            }
            stations = found
        } catch {
            failed = true
        }
    }
}
