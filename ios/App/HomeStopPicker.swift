import CoreLocation
import SwiftUI

/// Picks the home stop, in Settings and setup's Another stop: Subway or Bus switched at the top.
/// Subway is TrainPicker's Station → Lines → Direction. Bus starts at the stops near you, or a line
/// or place searched for. A stop goes on to its lines, one or more, where it has several, then
/// which way; a line to its stops in order each way. Picking a train clears the bus, and a bus
/// is kept in place of the train, which stays for if it's cleared.
struct HomeStopPicker: View {
    @Binding var train: Selection
    @Binding var bothWays: Bool
    @Binding var bus: BusChoice?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var busPicked: Bool

    init(train: Binding<Selection>, bothWays: Binding<Bool>, bus: Binding<BusChoice?>) {
        _train = train
        _bothWays = bothWays
        _bus = bus
        _busPicked = State(initialValue: bus.wrappedValue != nil)
    }

    enum Step: Hashable {
        case lines(Station, chosen: [String])
        case direction(Station, routes: [String])
        case busLines(NearbyBusPlace)
        case busWay(NearbyBusPlace, lines: [String])
        case lineStops(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if busPicked {
                    BusHomeStep(chosen: bus) { place in
                        let lines = place.lines(at: .now)
                        if lines.count > 1 {
                            path.append(.busLines(place))
                        } else {
                            path.append(.busWay(place, lines: lines.map(\.line)))
                        }
                    } line: { line in
                        path.append(.lineStops(line))
                    }
                } else {
                    StationStep(chosenID: bus == nil ? train.station?.id : nil) { station, filter in
                        if station.routes.count == 1 {
                            path.append(.direction(station, routes: station.routes))
                        } else {
                            path.append(.lines(station, chosen: startingLines(at: station, filter: filter)))
                        }
                    }
                }
            }
            // Subway or Bus, over either's list
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Kind", selection: $busPicked) {
                    Label("Subway", systemImage: "tram.fill").tag(false)
                    Label("Bus", systemImage: "bus.fill").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
            }
            .navigationDestination(for: Step.self, destination: step)
        }
    }

    @ViewBuilder private func step(_ step: Step) -> some View {
        switch step {
        case .lines(let station, let chosen):
            LinesStep(station: station, chosen: chosen) { routes in
                path.append(.direction(station, routes: routes))
            }
        case .direction(let station, let routes):
            let same = bus == nil && station.id == train.station?.id && routes == train.routes
            DirectionStep(station: station, routes: routes, current: same ? train.direction : nil,
                          offersBoth: true, bothCurrent: same && bothWays) { direction, both in
                // Assigned once, so the widgets reload once
                var chosen = train
                chosen.stationID = station.id
                chosen.routes = routes
                chosen.direction = direction
                train = chosen
                bothWays = both
                bus = nil
                dismiss()
            }
        case .busLines(let place):
            BusLinesStep(place: place, chosen: chosenLines(at: place)) { lines in
                path.append(.busWay(place, lines: lines))
            }
        case .busWay(let place, let lines):
            BusWayStep(place: place, lines: lines, current: bus) { finish($0) }
        case .lineStops(let line):
            BusLineStopsStep(line: line) { finish($0) }
        }
    }

    private func finish(_ choice: BusChoice) {
        bus = choice
        dismiss()
    }

    /// Preselects the filtered line, or the current lines if it's the same station.
    private func startingLines(at station: Station, filter: String?) -> [String] {
        if let filter {
            return station.routes.filter { LineStyle.of($0).label == filter }
        }
        return bus == nil && station.id == train.station?.id ? train.routes : []
    }

    /// The lines already ridden at `place` if it's the home stop, else all of them.
    private func chosenLines(at place: NearbyBusPlace) -> [String] {
        let all = place.lines(at: .now).map(\.line)
        guard let bus, place.ways.contains(where: { $0.stop.id == bus.stop.id }) else { return all }
        let kept = all.filter { line in bus.allLines.contains { BusRoutes.key($0) == BusRoutes.key(line) } }
        return kept.isEmpty ? all : kept
    }
}

// MARK: - Bus steps

/// Bus step 1: the stops near you, each with its lines and walk; typing, the lines it matches, and
/// on Search, the stops near a street or place of that name.
private struct BusHomeStep: View {
    let chosen: BusChoice?
    let pick: (NearbyBusPlace) -> Void
    let line: (String) -> Void
    @State private var location = NearbyLocation()
    @State private var search = ""
    @State private var places: [NearbyBusPlace]?
    @State private var failed = false
    /// A place searched for, rather than near you.
    @State private var searched: String?

    /// Lines whose names start as typed, the line's own first: "B6" is the B6, then the B60s.
    private var lines: [String] {
        let typed = BusRoutes.key(search.trimmingCharacters(in: .whitespaces))
        guard !typed.isEmpty, typed.first?.isLetter == true, typed.count <= 6 else { return [] }
        return BusRoutes.lineNames.filter { $0.hasPrefix(typed) }.prefix(8).map { $0 }
    }

    var body: some View {
        List {
            if !lines.isEmpty {
                Section("Lines") {
                    ForEach(lines, id: \.self) { name in
                        Button {
                            line(name)
                        } label: {
                            lineRow(name)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            if searched == nil, !location.isAllowed {
                Section {
                    Button {
                        location.find()
                    } label: {
                        Label("Show stops near you", systemImage: "location")
                    }
                } footer: {
                    Text("Or search for a line, street or place.")
                }
            }
            if let places {
                Section {
                    if places.isEmpty {
                        Text("No bus stops within a quarter mile").foregroundStyle(.secondary)
                    }
                    ForEach(places, id: \.self) { place in
                        Button {
                            pick(place)
                        } label: {
                            placeRow(place)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text(searched.map { "Near \($0)" } ?? "Nearby")
                }
            } else if failed {
                Section {
                    Text("Couldn't reach Bus Time").foregroundStyle(.secondary)
                }
            } else if location.isAllowed || searched != nil {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Finding stops…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Line or stop, like B63 or 5 Av")
        .onSubmit(of: .search) {
            let text = search.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            // A line's name goes to its stops; anything else is a place
            if let exact = lines.first(where: { $0 == BusRoutes.key(text) }) {
                line(exact)
            } else {
                Task { await find(near: findPlace(text), named: text) }
            }
        }
        .onChange(of: search) { _, text in
            // Cleared: back to near you
            if text.isEmpty, searched != nil {
                searched = nil
                places = nil
                Task { await find(near: location.location, named: nil) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Stop", step: 0) }
        }
        .onAppear {
            location.start()
            if location.isAllowed { location.find() }
        }
        .task(id: location.location.map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }) {
            guard searched == nil, let here = location.location else { return }
            await find(near: here, named: nil)
        }
    }

    private func find(near place: CLLocation?, named name: String?) async {
        searched = name
        failed = false
        guard let place else {
            places = []
            return
        }
        places = nil
        let found = await NearbyBuses.places(near: place, wait: NearbyBuses.appWait)
        failed = found == nil
        places = found
    }

    /// The name first, then its lines and the walk under it, so any number of lines fits.
    private func placeRow(_ place: NearbyBusPlace) -> some View {
        let isChosen = chosen.map { bus in place.ways.contains { $0.stop.id == bus.stop.id } } ?? false
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(place.name)
                HStack(spacing: 4) {
                    ForEach(place.lines(at: .now).prefix(6).map(\.line), id: \.self) { BusBadge(line: $0, size: 20) }
                    Text("· \(place.walkMinutes) min walk")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isChosen {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func lineRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            BusBadge(line: name, size: 24)
                .frame(width: 60, alignment: .leading)
            Text(BusLineStopsStep.ends(of: name))
                .lineLimit(2)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Bus step 2, for a stop with more than one line: tick one or more, then Continue to the ways.
private struct BusLinesStep: View {
    let place: NearbyBusPlace
    let next: ([String]) -> Void
    @State private var chosen: [String]

    init(place: NearbyBusPlace, chosen: [String], next: @escaping ([String]) -> Void) {
        self.place = place
        self.next = next
        _chosen = State(initialValue: chosen)
    }

    private var lines: [NearbyBusPick] { place.lines(at: .now) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name).font(.headline)
                    Text("\(place.walkMinutes) min walk").font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Section {
                ForEach(lines, id: \.line) { pick in
                    let on = chosen.contains(pick.line)
                    Button {
                        if on { chosen.removeAll { $0 == pick.line } } else { chosen.append(pick.line) }
                    } label: {
                        HStack(spacing: 12) {
                            BusBadge(line: pick.line, size: 26)
                                .frame(width: 60, alignment: .leading)
                            Text(pick.ways.map(\.name).joined(separator: " – "))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            } header: {
                Text("Lines")
            } footer: {
                Text("Pick one, or more to see whichever comes first.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                // In the stop's order, soonest first
                next(lines.map(\.line).filter(chosen.contains))
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(chosen.isEmpty)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Lines", step: 1) }
        }
    }
}

/// Bus step 3: which way. Each way is its own stop, one on each side of the street, so each says
/// which side, with its next buses on the lines picked; Both keeps the two.
private struct BusWayStep: View {
    let place: NearbyBusPlace
    let lines: [String]
    let current: BusChoice?
    let done: (BusChoice) -> Void

    private func key(_ line: String) -> String { BusRoutes.key(line) }

    /// The lines' buses at `way`, soonest first.
    private func buses(at way: NearbyBusPick.Way, now: Date) -> [BusArrival] {
        let keys = Set(lines.map(key))
        return way.arrivals.filter { keys.contains(key($0.line)) && ($0.time ?? .distantPast) > now }
    }

    /// Where the lines' buses from `way` go: each place once, "Pier 6 / Downtown Brooklyn".
    private func going(_ way: NearbyBusPick.Way) -> String {
        var names: [String] = []
        for bus in buses(at: way, now: .distantPast) {
            if let destination = bus.destination.map(BusNames.destination), !names.contains(destination) {
                names.append(destination)
            }
        }
        return names.isEmpty ? way.name : names.prefix(2).joined(separator: " / ")
    }

    /// The ways the lines run from here: the place's stops with one of their buses due.
    private var ways: [NearbyBusPick.Way] {
        let shown = place.ways.filter { !buses(at: $0, now: .now).isEmpty }
        return shown.isEmpty ? place.ways : shown
    }

    private func choice(_ index: Int, both: Bool) -> BusChoice {
        let way = ways[index]
        let other = ways.indices.first { $0 != index }.map { ways[$0] }
        let first = lines.first ?? ""
        return BusChoice(line: first, lines: lines.count > 1 ? lines : nil, stop: way.stop,
                         destination: buses(at: way, now: .distantPast).first?.destination ?? way.destination,
                         otherStop: other?.stop,
                         otherDestination: other.flatMap { buses(at: $0, now: .distantPast).first?.destination ?? $0.destination },
                         bothWays: both && other != nil)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    HStack(spacing: 3) {
                        ForEach(lines, id: \.self) { BusBadge(line: $0, size: lines.count > 2 ? 24 : 32) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name).font(.headline)
                        Text("\(place.walkMinutes) min walk").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Section {
                    ForEach(ways.indices, id: \.self) { index in
                        let way = ways[index]
                        let picked = current.map { !$0.bothWays && $0.stop.id == way.stop.id } ?? false
                        Button {
                            done(choice(index, both: false))
                        } label: {
                            wayRow(symbol: index == 0 ? "arrow.up" : "arrow.down", title: "Toward \(going(way))",
                                   detail: detail(way, index: index, now: context.date), on: picked)
                        }
                        .foregroundStyle(.primary)
                    }
                    if ways.count == 2 {
                        let picked = current.map { $0.bothWays && ways.contains { way in way.stop.id == $0.stop.id } } ?? false
                        Button {
                            done(choice(0, both: true))
                        } label: {
                            wayRow(symbol: "arrow.up.arrow.down", title: "Both ways",
                                   detail: "The medium widget shows the next bus each way", on: picked)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Which way do you ride?")
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "Direction", step: 2) }
        }
    }

    /// "This side · Next: 4 min, 12 min"; with more than one line, each bus's.
    private func detail(_ way: NearbyBusPick.Way, index: Int, now: Date) -> String {
        let side = index == 0 ? "This side" : "Across the street"
        let next = buses(at: way, now: now).prefix(2).compactMap { bus -> String? in
            guard let time = bus.time else { return nil }
            let minutes = max(0, Int(time.timeIntervalSince(now) / 60))
            let when = minutes == 0 ? "Now" : "\(minutes) min"
            return lines.count > 1 ? "\(BusNames.label(bus.line)) \(when)" : when
        }
        return next.isEmpty ? side : "\(side) · Next: \(next.joined(separator: ", "))"
    }

    private func wayRow(symbol: String, title: String, detail: String, on: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// From a line searched for: its two ways, then its stops in riding order on a line of its own, the
/// one nearest you marked. A tap on a stop finishes; Both ways keeps the stop across the street too.
private struct BusLineStopsStep: View {
    let line: String
    let done: (BusChoice) -> Void
    @State private var location = NearbyLocation()
    @State private var wayIndex = 0
    @State private var both = false

    /// Its two ways: the longest pattern each headsign has, the two longest headsigns.
    private var ways: [BusRoutes.Way] { Self.mainWays(of: line) }

    static func mainWays(of line: String) -> [BusRoutes.Way] {
        var longest: [String: BusRoutes.Way] = [:]
        for way in BusRoutes.ways(of: line) where (longest[way.to]?.stops.count ?? 0) < way.stops.count {
            longest[way.to] = way
        }
        let sorted = longest.values.sorted { $0.stops.count > $1.stops.count }
        guard let first = sorted.first else { return [] }
        // The other way: the longest one not sharing its first stop
        let other = sorted.dropFirst().first { $0.stops.first?.code != first.stops.first?.code
            && $0.stops.last?.code != first.stops.last?.code }
        return [first] + (other.map { [$0] } ?? [])
    }

    /// "Pier 6 – Bay Ridge": where its two ways go.
    static func ends(of line: String) -> String {
        let names = mainWays(of: line).map { BusNames.destination($0.to) }
        return names.isEmpty ? "Bus line" : names.joined(separator: " – ")
    }

    private var way: BusRoutes.Way? { ways.indices.contains(wayIndex) ? ways[wayIndex] : ways.first }

    /// The way's stop nearest you, if you're near it.
    private var nearest: String? {
        guard let here = location.location, let way else { return nil }
        let best = way.stops.min { $0.location.distance(from: here) < $1.location.distance(from: here) }
        return best.flatMap { $0.location.distance(from: here) < 1_600 ? $0.code : nil }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    BusBadge(line: line, size: 32)
                    Text(Self.ends(of: line)).font(.headline)
                }
                .accessibilityElement(children: .combine)
            }
            if ways.count == 2 {
                Section {
                    Picker("Way", selection: $wayIndex) {
                        ForEach(ways.indices, id: \.self) { index in
                            Text("To \(BusNames.destination(ways[index].to))").tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            if let way {
                Section {
                    ForEach(Array(way.stops.enumerated()), id: \.offset) { index, stop in
                        Button {
                            done(choice(at: stop, on: way))
                        } label: {
                            stopRow(stop, first: index == 0, last: index == way.stops.count - 1)
                        }
                        .foregroundStyle(.primary)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                    if ways.count == 2 {
                        Toggle("Both ways", isOn: $both)
                    }
                } footer: {
                    if ways.count == 2 {
                        Text("Both ways keeps this stop and the one across the street.")
                    }
                }
            } else {
                Section {
                    Text("No stops found for this line").foregroundStyle(.secondary)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { StepTitle(title: "\(BusNames.label(line)) Stop", step: 1, count: 2) }
        }
        .onAppear {
            location.start()
            if location.isAllowed { location.find() }
        }
    }

    /// The stop picked, with the other way's stop nearest it for Both ways.
    private func choice(at stop: BusRoutes.Stop, on way: BusRoutes.Way) -> BusChoice {
        let other = ways.first { $0 != way }
        let across = other?.stops.min { $0.location.distance(from: stop.location) < $1.location.distance(from: stop.location) }
        return BusChoice(line: line, stop: stop.busStop, destination: way.to, otherStop: across?.busStop,
                         otherDestination: other?.to, bothWays: both && across != nil)
    }

    private func stopRow(_ stop: BusRoutes.Stop, first: Bool, last: Bool) -> some View {
        let isNearest = stop.code == nearest
        return HStack(spacing: 12) {
            // The line down the stops, as a route map
            ZStack {
                Rectangle()
                    .fill(BusBadge.blue)
                    .frame(width: 4)
                    .padding(.top, first ? 28 : 0)
                    .padding(.bottom, last ? 28 : 0)
                Circle()
                    .fill(isNearest ? BusBadge.blue : .white)
                    .overlay(Circle().stroke(BusBadge.blue, lineWidth: 3))
                    .frame(width: isNearest ? 16 : 12)
            }
            .frame(width: 20)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(BusNames.readable(stop.name))
                    .fontWeight(isNearest ? .semibold : .regular)
                if isNearest {
                    Label("Closest to you", systemImage: "location.fill")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
