#if DEBUG
import SwiftUI

// Mockups only: a saved route as From → To on one page (B), with every way there across the
// week worked out, changes in a row, and several stations to choose from at each change.
// Delete once built.

/// When a way runs, as the timetable has it.
private enum MockWhen: String {
    case always = "All times"
    case notNights = "Not late nights"
    case nights = "Late nights"
    case weekdays = "Weekdays"

    var symbol: String {
        switch self {
        case .always: "clock"
        case .notNights: "sun.max"
        case .nights: "moon.stars"
        case .weekdays: "briefcase"
        }
    }
}

/// One change along a way: the stations you could change at (any ticked will do).
private struct MockChange {
    var stations: [(name: String, on: Bool)]
    let how: String
}

private struct MockWay: Identifiable {
    let id: String
    /// Rides in order; each a set of lines that are as good as each other, e.g. ["N", "Q"].
    let rides: [[String]]
    var changes: [MockChange]
    let when: MockWhen
    let minutes: String
    var fastest: String? = nil
    var on: Bool
}

private func mark(_ ride: String, size: CGFloat) -> some View {
    Group {
        if ride.hasPrefix("B"), ride.count > 1 {
            BusBadge(line: ride, size: size * 0.8)
        } else {
            LineBullet(route: ride, size: size)
        }
    }
}

private func marks(_ rides: [String], size: CGFloat) -> some View {
    HStack(spacing: 3) {
        ForEach(rides, id: \.self) { mark($0, size: size) }
    }
}

/// R → N Q → …, each ride's lines together.
private struct RideChain: View {
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
                marks(ride, size: size)
            }
        }
    }
}

/// Lays chips out in rows, wrapping as needed.
private struct Flow: Layout {
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

/// A station to change at: tinted with a tick when on.
private func stationChip(_ name: String, on: Bool, note: String? = nil) -> some View {
    HStack(spacing: 5) {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        Text(name)
        if let note {
            Text(note).foregroundStyle(.secondary)
        }
    }
    .font(.subheadline.weight(on ? .semibold : .regular))
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Capsule().fill(on ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemFill)))
}

// MARK: - Data

private let subwayWays: [MockWay] = [
    MockWay(id: "rnq", rides: [["R"], ["N", "Q"]],
            changes: [MockChange(stations: [("Atlantic Av", true), ("DeKalb Av", true), ("Canal St", false)],
                                 how: "Across the platform")],
            when: .always, minutes: "27–33", fastest: "Fastest daytime", on: true),
    MockWay(id: "r", rides: [["R"]], changes: [], when: .notNights, minutes: "38", on: true),
    MockWay(id: "r1", rides: [["R"], ["1"]],
            changes: [MockChange(stations: [("Whitehall St → South Ferry", false)], how: "4 min walk")],
            when: .nights, minutes: "52", fastest: "Fastest late nights", on: false),
    MockWay(id: "fbd7", rides: [["F"], ["B", "D"], ["7"]],
            changes: [MockChange(stations: [("Jay St", false), ("W 4 St", false)], how: "Across the platform"),
                      MockChange(stations: [("42 St-Bryant Pk", false)], how: "3 min walk")],
            when: .weekdays, minutes: "41", on: false),
]

private let busWays: [MockWay] = [
    MockWay(id: "nq", rides: [["B63"], ["N", "Q"]],
            changes: [MockChange(stations: [("Atlantic Av", true)], how: "3 min walk")],
            when: .always, minutes: "34–40", fastest: "Fastest", on: true),
    MockWay(id: "rnq", rides: [["B63"], ["R"], ["N", "Q"]],
            changes: [MockChange(stations: [("4 Av-9 St", true), ("Union St", true), ("Prospect Av", false)],
                                 how: "1–2 min walk"),
                      MockChange(stations: [("Atlantic Av", true), ("DeKalb Av", true)], how: "Across the platform")],
            when: .always, minutes: "36–44", on: true),
    MockWay(id: "f7", rides: [["B63"], ["F"], ["7"]],
            changes: [MockChange(stations: [("7 Av", false)], how: "4 min walk"),
                      MockChange(stations: [("42 St-Bryant Pk", false)], how: "3 min walk")],
            when: .always, minutes: "45", on: false),
]

// MARK: - New Route page

private struct NewRoutePage: View {
    let from: (name: String, marks: [String])
    let to: (name: String, marks: [String])?
    @State var ways: [MockWay]
    /// Which ticked way covers each part of the week; nil for none.
    var cover: [[[String]?]] = []

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(to.map { "To \($0.name)" } ?? "R from 4 Av-9 St").font(.headline).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                ZStack(alignment: .trailing) {
                    VStack(spacing: 0) {
                        endpoint("From", from.name, from.marks, symbol: "circle.circle.fill", tint: .accentColor)
                        Divider().padding(.leading, 34)
                        if let to {
                            endpoint("To", to.name, to.marks, symbol: "mappin.circle.fill", tint: .red)
                        } else {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(.red).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("To").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text("Choose a station or stop").font(.headline).foregroundStyle(.tint)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    if to != nil {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color(.tertiarySystemFill)))
                    }
                }
            }
            if to != nil {
                Section {
                    ForEach($ways) { $way in
                        WayCard(way: $way)
                    }
                    Label("Add a Way", systemImage: "plus.circle.fill")
                        .foregroundStyle(.tint)
                } header: {
                    Text("Ways there")
                } footer: {
                    Text("Every way the timetable runs, at any time of the week. Tick the ones you'd take; the widget shows whichever ticked way gets you there first at the time.")
                }
                if !cover.isEmpty {
                    Section {
                        CoverGrid(cover: cover)
                    } header: {
                        Text("When you're covered")
                    }
                }
                Section {
                    Toggle("Way Back Too", isOn: .constant(false))
                }
            }
        }
        .navigationTitle("New Route")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) {} }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {}.buttonStyle(.glassProminent).disabled(to == nil)
            }
        }
    }

    private func endpoint(_ title: String, _ name: String, _ lines: [String], symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(name).font(.headline)
                marks(lines, size: 18)
            }
            Spacer(minLength: 44)
        }
        .padding(.vertical, 8)
    }
}

/// A way there: its rides, when it runs, the minutes and a tick; ticked, each change's stations
/// as chips, any of which will do.
private struct WayCard: View {
    @Binding var way: MockWay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                way.on.toggle()
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        RideChain(rides: way.rides)
                        Text(way.changes.isEmpty ? "Straight there"
                             : way.changes.count == 1 ? "1 change" : "\(way.changes.count) changes")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 8) {
                            Label(way.when.rawValue, systemImage: way.when.symbol)
                                .foregroundStyle(way.when == .always ? Color.secondary : Color.orange)
                            if let fastest = way.fastest {
                                Text(fastest).foregroundStyle(.green).fontWeight(.semibold)
                            }
                        }
                        .font(.caption)
                    }
                    Spacer(minLength: 8)
                    Text("\(way.minutes) min").font(.subheadline.weight(.semibold)).monospacedDigit()
                    Image(systemName: way.on ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(way.on ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if way.on {
                ForEach(Array(way.changes.enumerated()), id: \.offset) { index, change in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text(way.changes.count > 1 ? "Change \(index + 1): " : "Change at: ")
                            marks(way.rides[index], size: 14)
                            Image(systemName: "arrow.right").font(.caption2.weight(.bold))
                            marks(way.rides[index + 1], size: 14)
                            Text("· \(change.how)")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Flow {
                            ForEach(Array(change.stations.enumerated()), id: \.offset) { _, station in
                                stationChip(station.name, on: station.on)
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// The week in parts, each showing the ticked way that's fastest then, or a warning where none runs.
private struct CoverGrid: View {
    let cover: [[[String]?]]
    private let days = ["Weekdays", "Saturday", "Sunday"]
    private let parts = ["Rush", "Day", "Evening", "Night"]

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 8) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(parts, id: \.self) {
                    Text($0).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            ForEach(days.indices, id: \.self) { day in
                GridRow {
                    Text(days[day]).font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                    ForEach(parts.indices, id: \.self) { part in
                        cell(cover[day][part])
                    }
                }
            }
        }
        .padding(.vertical, 4)
        if cover.joined().contains(where: { $0 == nil }) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No ticked way runs late nights").font(.subheadline.weight(.semibold))
                    Text("Tick R → 1 to cover them.").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "moon.stars.fill").foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private func cell(_ rides: [String]?) -> some View {
        Group {
            if let rides {
                HStack(spacing: 2) { ForEach(rides, id: \.self) { mark($0, size: 15) } }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(rides == nil ? Color.orange.opacity(0.15) : Color(.tertiarySystemFill)))
    }
}

// MARK: - To

/// Search for where you're going: only places you can get to from the start, in up to two changes.
private struct ToSearch: View {
    var body: some View {
        List {
            Section {
                row("Times Sq-42 St", ["N", "Q", "R", "W", "1", "2", "3", "7"], "R straight there, or 1–2 changes")
                row("42 St-Port Authority", ["A", "C", "E"], "1 change")
                row("42 St-Bryant Pk", ["B", "D", "F", "M", "7"], "F straight there")
                row("Times Sq/W 42 St", ["M42", "M104"], "Bus stop · 1 change")
            } header: {
                Text("Matching \u{201C}42\u{201D}")
            } footer: {
                Text("Places you can't get to from 4 Av-9 St in up to two changes, at any time, aren't listed.")
            }
        }
        .searchable(text: .constant("42"), prompt: "Station or stop")
        .navigationTitle("To")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) {} } }
    }

    private func row(_ name: String, _ lines: [String], _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
            marks(lines, size: 18)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Add a Way

/// Building a way yourself, one ride and change at a time; only lines and stations that still get
/// you there are offered, and any of several ticked at a change will do.
private struct AddWay: View {
    var body: some View {
        List {
            Section {
                stop("4 Av-9 St", symbol: "circle.circle.fill", tint: .accentColor)
                ride(["F", "G", "R"], on: ["R"], notes: [:])
                change(["Atlantic Av": true, "DeKalb Av": true, "Court St": false, "Canal St": false],
                       order: ["Atlantic Av", "DeKalb Av", "Court St", "Canal St"])
                ride(["N", "Q", "W", "2", "3"], on: ["N", "Q"], notes: ["W": "Weekdays"])
                Label("Add Another Change", systemImage: "plus.circle")
                    .foregroundStyle(.tint)
                    .padding(.leading, 34)
                stop("Times Sq-42 St", symbol: "mappin.circle.fill", tint: .red)
            } footer: {
                Text("Only lines and stations that still get you to Times Sq-42 St are offered. Tick several at a change and any of them will do.")
            }
        }
        .navigationTitle("Add a Way")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) {} }
            ToolbarItem(placement: .confirmationAction) { Button("Add") {}.buttonStyle(.glassProminent) }
        }
    }

    private func stop(_ name: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 22)
            Text(name).font(.headline)
        }
    }

    private func ride(_ lines: [String], on: Set<String>, notes: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ride").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Flow(spacing: 10) {
                ForEach(lines, id: \.self) { line in
                    VStack(spacing: 3) {
                        LineToggle(route: line, isOn: on.contains(line)) {}
                        if let note = notes[line] {
                            Text(note).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .padding(.leading, 34)
        .padding(.vertical, 4)
    }

    private func change(_ stations: [String: Bool], order: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Change at").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Flow {
                ForEach(order, id: \.self) { stationChip($0, on: stations[$0] ?? false) }
            }
        }
        .padding(.leading, 34)
        .padding(.vertical, 4)
    }
}

// MARK: - Previews

private let timesSq = (name: "Times Sq-42 St", marks: ["N", "Q", "R", "W", "1", "2", "3", "7"])

/// Rush, Day, Evening, Night for weekdays, Saturday, Sunday.
private let subwayCover: [[[String]?]] = [
    [["R", "N"], ["R", "N"], ["R", "Q"], nil],
    [["R", "Q"], ["R", "Q"], ["R", "N"], nil],
    [["R", "Q"], ["R", "Q"], ["R", "N"], nil],
]

#Preview("B1 From set") {
    NavigationStack {
        NewRoutePage(from: ("4 Av-9 St", ["F", "G", "R"]), to: nil, ways: [])
    }
}

#Preview("B2 To search") {
    NavigationStack { ToSearch() }
}

#Preview("B3 Ways, subway") {
    NavigationStack {
        NewRoutePage(from: ("4 Av-9 St", ["F", "G", "R"]), to: timesSq, ways: subwayWays, cover: subwayCover)
    }
}

#Preview("B4 Ways, from a bus stop") {
    NavigationStack {
        NewRoutePage(from: ("5 Av/9 St", ["B63"]), to: timesSq, ways: busWays)
    }
}

#Preview("B5 Add a Way") {
    NavigationStack { AddWay() }
}
#endif
