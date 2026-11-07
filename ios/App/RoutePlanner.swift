import SwiftUI

// MARK: - Planning

/// Ways from a saved route's start to where it's going (`WayFinder`), which of them it takes, and
/// each change's stations it takes, written to the route as its train, change and destination.
@Observable @MainActor
final class RoutePlan {
    private(set) var ways: [WayFinder.Way] = []
    /// Found but not listed, for Add a Way.
    private(set) var more: [WayFinder.Way] = []
    private(set) var finding = false
    /// No timetable to plan with yet.
    private(set) var noTimetable = false
    /// Ticked ways, by id.
    var ticked: Set<String> = []
    /// Per way, per change, the ticked stations' complexes.
    var stations: [String: [Set<String>]] = [:]
    /// The from and to the ways are for.
    private var planned: (from: String, to: String)?

    /// The finder for the timetable on the phone, made once per timetable.
    private static var finder: (made: Date, finder: WayFinder)?

    static func finder() async -> WayFinder? {
        guard let timetable = TimetableStore.load() else { return nil }
        if let cached = finder, cached.made == timetable.made { return cached.finder }
        let made = await Task.detached(priority: .userInitiated) { WayFinder(timetable: timetable) }.value
        finder = (timetable.made, made)
        return made
    }

    /// Places reachable from `station` in up to two changes, as complexes.
    static func reachable(from station: Station) async -> Set<String>? {
        guard let finder = await finder() else { return nil }
        let complex = station.complex
        return await Task.detached(priority: .userInitiated) { finder.reachable(from: complex) }.value
    }

    /// Finds the ways for `widget`'s start and destination, ticking those it takes already, or
    /// with `fresh` the quickest at each part of the week.
    func plan(for widget: SavedWidget, fresh: Bool) async {
        guard let from = widget.selection.station, let to = widget.destination else {
            ways = []
            more = []
            planned = nil
            return
        }
        if let planned, planned.from == from.id, planned.to == to.id { return }
        finding = true
        defer { finding = false }
        guard let finder = await Self.finder() else {
            noTimetable = true
            return
        }
        noTimetable = false
        let found = await Task.detached(priority: .userInitiated) { finder.ways(from: from, to: to) }.value
        ways = found.listed
        more = found.more
        planned = (from.id, to.id)
        if fresh { tickDefaults() } else { tickMatching(widget) }
    }

    /// The quickest way at each part of the week, from where the quickest of all starts and
    /// going its way; each with all its stations.
    func tickDefaults() {
        ticked = []
        stations = [:]
        guard let lead = ways.min(by: { $0.best < $1.best }) else { return }
        for part in WayFinder.Part.allCases {
            let running = ways.filter { $0.minutes[part] != nil && $0.startsLike(lead) }
            if let fastest = running.min(by: { $0.minutes[part]! < $1.minutes[part]! }) { ticked.insert(fastest.id) }
        }
        for way in ways { stations[way.id] = way.changes.map { Set($0.map(\.complex)) } }
    }

    /// Ticks the ways `widget` takes now: its lines from its station, changing where it changes.
    private func tickMatching(_ widget: SavedWidget) {
        ticked = []
        stations = [:]
        let stops = widget.change?.stops ?? []
        for way in ways + more {
            stations[way.id] = way.changes.map { Set($0.map(\.complex)) }
            guard way.fromStationID == widget.selection.stationID,
                  !Set(way.rides[0]).isDisjoint(with: widget.selection.routes) else { continue }
            if way.changes.isEmpty {
                ticked.insert(way.id)
                continue
            }
            // Its first change's stations among the route's, for its lines; a second change likewise
            let first = way.changes[0].filter { option in
                stops.contains { stop in
                    stop.station?.complex == option.complex && !Set(stop.routes).isDisjoint(with: way.rides[1])
                        && (stop.then == nil) == (way.changes.count == 1)
                        && (way.changes.count == 1 || way.changes[1].contains { option in
                            stop.then?.stops.contains { $0.station?.complex == option.complex } == true
                        })
                }
            }
            guard !first.isEmpty else { continue }
            ticked.insert(way.id)
            var picked = [Set(first.map(\.complex))]
            if way.changes.count == 2 {
                let thens = stops.compactMap(\.then).flatMap(\.stops)
                let second = way.changes[1].filter { option in thens.contains { $0.station?.complex == option.complex } }
                picked.append(Set((second.isEmpty ? way.changes[1] : second).map(\.complex)))
            }
            stations[way.id] = picked
        }
        // Ticked from Add a Way: listed with the rest
        for way in more where ticked.contains(way.id) {
            ways.append(way)
            more.removeAll { $0.id == way.id }
        }
    }

    /// Ticks or unticks `way`. Ticking one that starts elsewhere or goes another way unticks
    /// those, as a route has one train to start.
    func toggle(_ way: WayFinder.Way) {
        if ticked.contains(way.id) {
            ticked.remove(way.id)
        } else {
            let others = (ways + more).filter { ticked.contains($0.id) && !$0.startsLike(way) }
            ticked.subtract(others.map(\.id))
            ticked.insert(way.id)
        }
    }

    /// Ticks or unticks a change's station; the last ticked stays.
    func toggle(_ option: WayFinder.Way.Option, change index: Int, of way: WayFinder.Way) {
        var picked = stations[way.id] ?? way.changes.map { Set($0.map(\.complex)) }
        if picked[index].contains(option.complex) {
            guard picked[index].count > 1 else { return }
            picked[index].remove(option.complex)
        } else {
            picked[index].insert(option.complex)
        }
        stations[way.id] = picked
    }

    /// Adds a way from Add a Way to those listed, ticked.
    func add(_ way: WayFinder.Way) {
        more.removeAll { $0.id == way.id }
        if !ways.contains(where: { $0.id == way.id }) { ways.append(way) }
        if !ticked.contains(way.id) { toggle(way) }
    }

    /// Whether `way`'s change at `index` is at `option`'s station.
    func isTicked(_ option: WayFinder.Way.Option, change index: Int, of way: WayFinder.Way) -> Bool {
        (stations[way.id] ?? []).indices.contains(index) ? stations[way.id]![index].contains(option.complex) : true
    }

    /// The ticked ways.
    var takes: [WayFinder.Way] { ways.filter { ticked.contains($0.id) } }

    /// `widget` taking the ticked ways: its train from their start, with all their first lines;
    /// its change at their stations, each with any second change; going to `to`.
    func applied(to widget: SavedWidget) -> SavedWidget {
        var widget = widget
        guard let to = widget.destination, let lead = takes.first else { return widget }
        let takes = self.takes.filter { $0.startsLike(lead) }
        guard let station = StationDirectory.station(id: lead.fromStationID) else { return widget }
        var selection = widget.selection
        selection.stationID = station.id
        let lines = Set(takes.flatMap { $0.rides[0] })
        selection.routes = station.routes.filter(lines.contains)
        if selection.routes.isEmpty { selection.routes = Array(lines).sorted() }
        selection.direction = lead.direction
        var stops: [Change] = []
        for way in takes where !way.changes.isEmpty {
            let picked = stations[way.id] ?? way.changes.map { Set($0.map(\.complex)) }
            let then: Change? = way.changes.count < 2 ? nil : Change(stops: way.changes[1]
                .filter { picked[1].contains($0.complex) }
                .map { Change(stationID: $0.stationID, routes: way.rides[2], direction: $0.direction) })
            for option in way.changes[0] where picked[0].contains(option.complex) {
                stops.append(Change(stationID: option.stationID, routes: way.rides[1], direction: option.direction, then: then))
            }
        }
        widget.selection = selection
        widget.bothWays = false
        if var change = Change(stops: stops) {
            change.destinationID = to.id
            widget.change = change.validated(for: selection)
            widget.change?.destinationID = to.id
        } else {
            widget.change = nil
        }
        widget.destinationID = to.id
        return widget
    }

    /// Per part of the week, the quickest ticked way then, and its minutes; nil where none runs.
    func cover() -> [WayFinder.Part: (way: WayFinder.Way, minutes: Int)?] {
        var cover: [WayFinder.Part: (way: WayFinder.Way, minutes: Int)?] = [:]
        for part in WayFinder.Part.allCases {
            let quickest = takes.compactMap { way in way.minutes[part].map { (way, $0) } }.min { $0.1 < $1.1 }
            cover[part] = quickest.map { (way: $0.0, minutes: $0.1) }
        }
        return cover
    }

    /// The quickest unticked way that runs where no ticked one does, to suggest.
    func filling() -> (way: WayFinder.Way, time: WayFinder.Part.Time)? {
        let gaps = cover().filter { $0.value == nil }.map(\.key)
        guard !gaps.isEmpty, let lead = takes.first else { return nil }
        let candidates = ways.filter { !ticked.contains($0.id) && $0.startsLike(lead) }
        for part in gaps.sorted() {
            if let way = candidates.filter({ $0.minutes[part] != nil }).min(by: { $0.minutes[part]! < $1.minutes[part]! }) {
                return (way, part.time)
            }
        }
        return nil
    }
}

extension WayFinder.Way {
    /// Its quickest minutes at any part of the week.
    var best: Int { minutes.values.min() ?? .max }

    /// Whether it starts from the same station going the same way as `other`.
    func startsLike(_ other: WayFinder.Way) -> Bool {
        fromStationID == other.fromStationID && direction == other.direction
    }

    /// "All times", "Not late nights", "Late nights", "Weekdays", "Weekends", or the parts.
    var when: String {
        let parts = Set(minutes.keys)
        let all = Set(WayFinder.Part.allCases)
        let nights = Set(all.filter { $0.time == .night })
        let weekdays = Set(all.filter { $0.day == .weekday })
        if parts == all { return "All times" }
        if parts == all.subtracting(nights) { return "Not late nights" }
        if parts.isSubset(of: nights) { return "Late nights" }
        if parts.isSubset(of: weekdays) { return "Weekdays" }
        if parts.isDisjoint(with: weekdays) { return "Weekends" }
        if parts.isSuperset(of: all.subtracting(nights)) { return "All times, some late nights" }
        return "Some times"
    }

    var isLimited: Bool { minutes.count < WayFinder.Part.allCases.count }

    var whenSymbol: String {
        switch when {
        case "All times": "clock"
        case "Not late nights": "sun.max"
        case "Late nights": "moon.stars"
        case "Weekdays": "briefcase"
        case "Weekends": "calendar"
        default: "clock.badge.exclamationmark"
        }
    }

    /// "27–33 min", or one number.
    var minutesLabel: String {
        let low = minutes.values.min() ?? 0
        let high = minutes.values.max() ?? 0
        return low == high ? "\(low) min" : "\(low)–\(high) min"
    }

    /// "Straight there", "1 change", "2 changes".
    var changesLabel: String {
        changes.isEmpty ? "Straight there" : changes.count == 1 ? "1 change" : "\(changes.count) changes"
    }

    /// "Fastest", "Fastest daytime", "Fastest late nights", "Fastest weekends" among `ways`; nil
    /// if it's never the quickest.
    func fastest(among ways: [WayFinder.Way]) -> String? {
        let won = Set(minutes.keys.filter { part in
            ways.compactMap { $0.minutes[part] }.min() == minutes[part]
        })
        guard !won.isEmpty else { return nil }
        if won == Set(WayFinder.Part.allCases) || won == Set(minutes.keys) && !isLimited { return "Fastest" }
        if won.contains(where: { $0.day == .weekday && ($0.time == .rush || $0.time == .day) }) { return "Fastest daytime" }
        if won.allSatisfy({ $0.time == .night }) { return "Fastest late nights" }
        if won.allSatisfy({ $0.day != .weekday }) { return "Fastest weekends" }
        return "Fastest at times"
    }
}

// MARK: - The route's planning sections

/// A subway route's planning: its name, From and To, then the ways there to tick, when you're
/// covered, and for a new route, the way back too.
struct RoutePlanSections: View {
    @Binding var widget: SavedWidget
    /// Whether to add the way back as another route; nil when editing.
    var wayBack: Binding<Bool>?
    @State private var plan = RoutePlan()
    @State private var choosingFrom = false
    @State private var choosingTo = false
    @State private var addingWay = false
    /// Ways not yet looked for since the route came in: tick what it takes, not the defaults.
    @State private var matched = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(widget.summary, text: $widget.name)
                    .font(.headline)
                    .accessibilityLabel("Name")
            }
            .padding(.vertical, 4)
            ends
        }
        if widget.destination != nil {
            waysSection
            if !plan.takes.isEmpty {
                coverSection
            }
            if let wayBack {
                Section {
                    Toggle("Way Back Too", isOn: wayBack)
                } footer: {
                    Text("Adds the trip from \(widget.destination?.name ?? "there") as a route of its own.")
                }
            }
        }
        EmptyView()
            .task(id: "\(widget.selection.stationID) \(widget.destinationID ?? "")") {
                await plan.plan(for: widget, fresh: matched)
                matched = true
                if !plan.ways.isEmpty, !plan.takes.isEmpty { widget = plan.applied(to: widget) }
            }
            .onChange(of: plan.ticked) { apply() }
            .onChange(of: plan.stations) { apply() }
    }

    /// Writes the ticks to the route, once there's something ticked.
    private func apply() {
        guard !plan.takes.isEmpty else { return }
        widget = plan.applied(to: widget)
    }

    // MARK: From and To

    private var ends: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                Button { choosingFrom = true } label: {
                    endpoint("From", widget.selection.station?.name, lines: widget.selection.station?.routes ?? [],
                             symbol: "circle.circle.fill", tint: .accentColor, placeholder: "Choose a station")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Choose where you start")
                Divider().padding(.leading, 34)
                Button { choosingTo = true } label: {
                    endpoint("To", widget.destination?.name, lines: widget.destination?.routes ?? [],
                             symbol: "mappin.circle.fill", tint: .red, placeholder: "Choose a station")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Choose where you're going")
            }
            if widget.destination != nil {
                Button(action: swap) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel("Swap From and To")
            }
        }
        .sheet(isPresented: $choosingFrom) {
            StationSearchSheet(title: "From", chosenID: widget.selection.stationID, reachableFrom: nil) { station in
                setFrom(station)
            }
        }
        .sheet(isPresented: $choosingTo) {
            StationSearchSheet(title: "To", chosenID: widget.destinationID, reachableFrom: widget.selection.station) { station in
                setTo(station)
            }
        }
    }

    private func endpoint(_ title: String, _ name: String?, lines: [String], symbol: String, tint: Color,
                          placeholder: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let name {
                    Text(name).font(.headline).foregroundStyle(.primary)
                    HStack(spacing: 3) {
                        ForEach(lines, id: \.self) { LineBullet(route: $0, size: 18) }
                    }
                } else {
                    Text(placeholder).font(.headline).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 44)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func setFrom(_ station: Station) {
        var selection = widget.selection
        selection.stationID = station.id
        selection.routes = station.routes
        widget.selection = selection
        widget.change = nil
        if widget.destinationID == station.id { widget.destinationID = nil }
        matched = true
    }

    private func setTo(_ station: Station) {
        widget.change = nil
        widget.destinationID = station.id
        matched = true
    }

    /// From becomes To and To From; the ways are found again.
    private func swap() {
        guard let to = widget.destination, let from = widget.selection.station else { return }
        var selection = widget.selection
        selection.stationID = to.id
        selection.routes = to.routes
        widget.selection = selection
        widget.change = nil
        widget.destinationID = from.id
        matched = true
    }

    // MARK: Ways there

    private var waysSection: some View {
        Section {
            if plan.finding {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Finding every way there this week…").foregroundStyle(.secondary)
                }
            } else if plan.noTimetable {
                Text("The timetable hasn't downloaded yet. Try again in a moment.").foregroundStyle(.secondary)
            } else if plan.ways.isEmpty {
                Text("No way there in up to two changes.").foregroundStyle(.secondary)
            }
            ForEach(plan.ways) { way in
                WayCard(way: way, plan: plan, fastest: way.fastest(among: plan.ways))
            }
            if !plan.more.isEmpty {
                Button("Add a Way", systemImage: "plus.circle.fill") { addingWay = true }
            }
        } header: {
            Text("Ways there")
        } footer: {
            Text("Every way the timetable runs this week, in up to two changes. Tick the ones you'd take; the widget shows whichever ticked way gets you there first at the time.")
        }
        .sheet(isPresented: $addingWay) {
            AddWaySheet(plan: plan)
        }
    }

    // MARK: Cover

    private var coverSection: some View {
        let cover = plan.cover()
        return Section {
            CoverGrid(cover: cover)
            if let gap = plan.filling() {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: gap.time == .night ? "moon.stars.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No ticked way runs at some times").font(.subheadline.weight(.semibold))
                        Text("Tick \(gap.way.rides.map { Lines.list($0, joinedBy: "/") }.joined(separator: " → ")) to cover them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Tick") { plan.toggle(gap.way) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        } header: {
            Text("When you're covered")
        }
    }
}

/// A way there: its lines in turn, how many changes, when it runs, its minutes and a tick; ticked,
/// each change's stations as chips, any ticked of which will do.
private struct WayCard: View {
    let way: WayFinder.Way
    let plan: RoutePlan
    let fastest: String?

    private var isTicked: Bool { plan.ticked.contains(way.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                plan.toggle(way)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        RideChain(rides: way.rides, size: 24)
                        Text(way.changesLabel).font(.subheadline.weight(.semibold))
                        HStack(spacing: 4) {
                            Image(systemName: way.whenSymbol)
                            Text(way.when)
                        }
                        .font(.caption)
                        .foregroundStyle(way.isLimited ? Color.orange : Color.secondary)
                        if let fastest {
                            Text(fastest).font(.caption.weight(.semibold)).foregroundStyle(.green)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(way.minutesLabel).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Image(systemName: isTicked ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isTicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isTicked ? .isSelected : [])
            if isTicked {
                ForEach(Array(way.changes.enumerated()), id: \.offset) { index, options in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(way.changes.count > 1 ? "Change \(index + 1):" : "Change at:")
                            RideChain(rides: [way.rides[index], way.rides[index + 1]], size: 14)
                            if let how = how(options) { Text("· \(how)") }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        ChipFlow {
                            ForEach(options, id: \.complex) { option in
                                let on = plan.isTicked(option, change: index, of: way)
                                Button {
                                    plan.toggle(option, change: index, of: way)
                                } label: {
                                    StationChip(name: option.name, on: on)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// "Across the platform", "3 min walk", or a range across the stations.
    private func how(_ options: [WayFinder.Way.Option]) -> String? {
        if options.allSatisfy(\.across) { return "Across the platform" }
        let walks = options.map { $0.across ? 0 : $0.walkMinutes }
        guard let low = walks.min(), let high = walks.max() else { return nil }
        if low == 0 { return "Across or \(high) min walk" }
        return low == high ? "\(low) min walk" : "\(low)–\(high) min walk"
    }
}

/// Lines ridden in turn: R → N Q → S.
struct RideChain: View {
    let rides: [[String]]
    var size: CGFloat = 24

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(rides.enumerated()), id: \.offset) { index, ride in
                if index > 0 {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 2) {
                    ForEach(ride, id: \.self) { LineBullet(route: $0, size: size) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rides.map { Lines.spokenList($0) }.joined(separator: ", then "))
    }
}

/// A change's station: tinted with a tick when on.
private struct StationChip: View {
    let name: String
    let on: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            Text(name).lineLimit(1)
        }
        .font(.subheadline.weight(on ? .semibold : .regular))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(on ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemFill)))
    }
}

/// Lays chips out in rows, wrapping as needed.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

/// The week in parts, each with the ticked way that's quickest then, or a warning where none runs.
private struct CoverGrid: View {
    let cover: [WayFinder.Part: (way: WayFinder.Way, minutes: Int)?]

    private func name(_ day: WayFinder.Part.Day) -> String {
        switch day {
        case .weekday: "Weekdays"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }

    private func name(_ time: WayFinder.Part.Time) -> String {
        switch time {
        case .rush: "Rush"
        case .day: "Day"
        case .evening: "Evening"
        case .night: "Night"
        }
    }

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 8) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(WayFinder.Part.Time.allCases, id: \.self) { time in
                    Text(name(time)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            ForEach(WayFinder.Part.Day.allCases, id: \.self) { day in
                GridRow {
                    Text(name(day)).font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                    ForEach(WayFinder.Part.Time.allCases, id: \.self) { time in
                        cell(cover[WayFinder.Part(day: day, time: time)] ?? nil, label: "\(name(day)) \(name(time))")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func cell(_ quickest: (way: WayFinder.Way, minutes: Int)?, label: String) -> some View {
        Group {
            if let quickest {
                HStack(spacing: 2) {
                    ForEach(quickest.way.rides.map { $0[0] }.prefix(3), id: \.self) { LineBullet(route: $0, size: 15) }
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(quickest == nil ? Color.orange.opacity(0.15) : Color(.tertiarySystemFill)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(quickest.map { q in
            "\(q.way.rides.map { Lines.spokenList($0) }.joined(separator: ", then ")), \(q.minutes) minutes"
        } ?? "No ticked way runs")
    }
}

// MARK: - Sheets

/// Picks a station by name. For To, only those reachable from `reachableFrom` in up to two
/// changes, at any time this week.
struct StationSearchSheet: View {
    let title: String
    let chosenID: String?
    let reachableFrom: Station?
    let pick: (Station) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @State private var search = ""
    @State private var reachable: Set<String>?

    private var stations: [Station] {
        let query = StationSearch(search)
        let all = StationDirectory.all.filter { station in
            station.id != reachableFrom?.id && (reachable?.contains(station.complex) ?? true)
        }
        let shown = search.isEmpty ? all : all.filter(query.matches)
        return shown.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty, reachableFrom == nil, let home = settings.defaultTrain.station {
                    Section {
                        row(home, note: "Home Station")
                    }
                }
                Section {
                    if reachableFrom != nil && reachable == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Finding where you can get to…").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(stations) { row($0, note: nil) }
                    }
                } footer: {
                    if let from = reachableFrom {
                        Text("Places you can't get to from \(from.name) in up to two changes, at any time this week, aren't listed.")
                    }
                }
            }
            .searchable(text: $search, prompt: "Station")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
            }
            .task {
                guard let from = reachableFrom else { return }
                // No timetable yet: every station
                reachable = await RoutePlan.reachable(from: from) ?? Set(StationDirectory.all.map(\.complex))
            }
        }
    }

    private func row(_ station: Station, note: String?) -> some View {
        Button {
            pick(station)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name).foregroundStyle(.primary)
                    HStack(spacing: 3) {
                        ForEach(station.routes, id: \.self) { LineBullet(route: $0, size: 18) }
                    }
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if station.id == chosenID {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(station.id == chosenID ? .isSelected : [])
    }
}

/// The other ways there, found but not listed, to add to the route's.
private struct AddWaySheet: View {
    let plan: RoutePlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(plan.more) { way in
                        Button {
                            plan.add(way)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    RideChain(rides: way.rides, size: 20)
                                    Text(way.changes.isEmpty ? "Straight there"
                                         : way.changes.map { $0.map(\.name).joined(separator: " or ") }.joined(separator: ", then "))
                                        .font(.subheadline)
                                    Text(way.when).font(.caption).foregroundStyle(way.isLimited ? Color.orange : Color.secondary)
                                }
                                Spacer()
                                Text(way.minutesLabel).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Other ways the timetable runs this week, slower or no better than those listed.")
                }
            }
            .navigationTitle("Add a Way")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
            }
        }
    }
}
