import SwiftUI
import WidgetKit

/// The large Transfers widget's map, under its next change: your train's stops
/// on the way to the change along the top track, left to right, and below it
/// the track of the lines changed to, the two meeting at the change. Each train
/// is drawn where it would be by how long it has to go to the change, so two
/// that meet with little wait ride side by side.
struct TransferTrack: View {
    let connection: Connection
    let selection: Selection
    let change: Change
    let now: Date
    /// Your train's times under its stops.
    var showsTimes = true
    /// Where the train it meets is, when it's further off than the track, and the change's name.
    var showsNote = true

    static let localY: CGFloat = 28
    private var otherY: CGFloat { showsTimes ? 64 : 50 }
    private var height: CGFloat { otherY + (showsNote ? 30 : 14) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            labels
            if let layout = TransferMapLayout(connection: connection, selection: selection, now: now, maxRows: 5) {
                GeometryReader { geometry in
                    diagram(layout, width: geometry.size.width)
                }
                .frame(height: height)
            } else {
                Text("The MTA hasn't said yet")
                    .font(BoardStyle.large.stopFont)
                    .foregroundStyle(Color.boardGray)
            }
        }
    }

    private var localColor: Color { Color(hex: LineStyle.of(selection.firstRoute).color) }

    /// A line for each colour of the lines changed to: the D's orange and the N's yellow.
    private var otherColors: [Color] {
        var colors: [UInt32] = []
        for route in change.routes where !colors.contains(LineStyle.of(route).color) {
            colors.append(LineStyle.of(route).color)
        }
        return colors.prefix(3).map { Color(hex: $0) }
    }

    /// "WHERE THEY ARE", and which track is which: local and express, or their lines.
    private var labels: some View {
        let express = change.isExpress(for: selection)
        return HStack(spacing: 5) {
            Text("WHERE THEY ARE")
            Spacer(minLength: 8)
            swatch([localColor], height: 4)
            Text(express ? "LOCAL" : selection.routes.map { LineStyle.of($0).label }.joined(separator: " "))
            swatch(otherColors, height: 3)
                .padding(.leading, 6)
            Text(express ? "EXPRESS" : change.routes.map { LineStyle.of($0).label }.joined(separator: " "))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.boardGray)
        .lineLimit(1)
    }

    private func swatch(_ colors: [Color], height: CGFloat) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 14, height: height)
            }
        }
        .accessibilityHidden(true)
    }

    private func diagram(_ layout: TransferMapLayout, width: CGFloat) -> some View {
        let track = TrackGeometry(width: width, stops: layout.rows.count)
        let marker = BoardStyle.large.markerSize
        // The change's name goes under it, out of the way of the stop before
        let station = layout.rows[0].name.split(separator: "-").first.map(String.init) ?? layout.rows[0].name
        return ZStack(alignment: .topLeading) {
            TrackRails(layout: layout, track: track, localY: Self.localY, otherY: otherY,
                       localColor: localColor, otherColors: otherColors)
                .frame(width: width, height: height)
            ForEach(Array(layout.rows.dropFirst())) { row in
                stopName(row, layout: layout)
                    .frame(width: max(0, track.spacing - 4))
                    .position(x: track.x(CGFloat(row.id)), y: 7)
                if showsTimes && row.kind != .folded {
                    stopTime(row, layout: layout)
                        .position(x: track.x(CGFloat(row.id)), y: 44)
                }
            }
            if let row = layout.nextRow, let next = connection.next {
                TrainMarker(route: next.route, isLive: next.isLive, size: marker)
                    .position(x: max(marker / 2, track.x(row)), y: otherY)
            }
            TrainMarker(route: connection.first.route, isLive: connection.first.isLive, size: marker)
                .position(x: max(marker / 2, track.x(layout.firstRow)), y: Self.localY)
            if showsNote {
                if let note = layout.nextNote {
                    Text(note)
                        .font(.caption.italic())
                        .foregroundStyle(Color.boardGray)
                        .lineLimit(1)
                        .frame(width: width * 0.62, alignment: .leading)
                        .position(x: width * 0.31, y: otherY + 22)
                }
                Text(station)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.boardText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: width * 0.36, alignment: .trailing)
                    .position(x: width * 0.82, y: otherY + 22)
            }
        }
    }

    /// Yours stands out, as does the one your train is at or heading for; those
    /// it has passed are dimmed.
    private func stopName(_ row: TransferMapLayout.Row, layout: TransferMapLayout) -> some View {
        let passed = CGFloat(row.id) > layout.firstRow + 0.01
        let isTrainStop = row.id == min(layout.rows.count - 1, Int(layout.firstRow.rounded(.down)))
        let yours = row.kind == .origin
        return Text(row.name)
            .font(.caption2.weight(yours ? .bold : isTrainStop ? .semibold : .medium))
            .italic(row.kind == .folded)
            .foregroundStyle(yours || isTrainStop ? Color.boardText : passed ? Color.boardDim : Color.boardGray)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// When your train is due there.
    private func stopTime(_ row: TransferMapLayout.Row, layout: TransferMapLayout) -> some View {
        let passed = CGFloat(row.id) > layout.firstRow + 0.01
        let yours = row.kind == .origin
        return Text(row.time.clock)
            .font(.caption.weight(yours ? .semibold : .medium))
            .monospacedDigit()
            .foregroundStyle(yours ? connection.first.statusColor : passed ? Color.boardDim : Color.boardGray)
            .fixedSize()
    }
}

/// Where the track's stops go across the widget: the change near the right
/// edge, the others evenly spaced to its left, with room before the first for
/// a train still on its way to it.
struct TrackGeometry {
    let right: CGFloat
    let spacing: CGFloat

    /// The change's way in from the right edge, past the platform's outline.
    static let changeInset: CGFloat = 12
    /// The furthest left a train is drawn.
    static let leftmost: CGFloat = 10

    init(width: CGFloat, stops: Int) {
        right = width - Self.changeInset
        spacing = (right - Self.leftmost) / (CGFloat(max(1, stops - 1)) + 0.6)
    }

    /// Where a stop is, or a train between stops, counted from the change.
    func x(_ row: CGFloat) -> CGFloat {
        right - row * spacing
    }
}

/// Which stops the map shows, from the change back to where your train is, and
/// where the two trains are among them, in stops from the change.
struct TransferMapLayout {
    enum Kind: Equatable {
        case change, origin, stop, folded
    }

    struct Row: Identifiable {
        /// Its place in the list, from the top.
        let id: Int
        let name: String
        let kind: Kind
        /// When your train is due there; for folded stops, midway between them.
        let time: Date
        /// The train it meets stops here too.
        let shared: Bool
    }

    /// From the change, at the right end of the track, back to the left end.
    let rows: [Row]
    /// Where your train is: 0 at the change, 1.5 midway between the second and
    /// third stops, and past the last while it's on its way to it.
    let firstRow: CGFloat
    /// Where the train it meets would be on your train's way with as long to
    /// go to the change; nil without one.
    let nextRow: CGFloat?
    /// Where the train it meets is, when it's further off than the map shows:
    /// "D at 9 Av".
    let nextNote: String?

    /// `maxRows` is 4 or more.
    init?(connection: Connection, selection: Selection, now: Date, maxRows: Int = 6) {
        let stops = connection.arrival.approach
        let yours = Set(selection.stopIDs)
        guard let origin = stops.firstIndex(where: { yours.contains($0.id) }), origin < stops.count - 1 else { return nil }
        let last = stops.count - 1

        // The change first, then the stops between it and yours, yours, the
        // stops between yours and where the train is, and that. When there are
        // too many, the longer of the runs between folds into one row, then
        // the other.
        let between = Array((origin + 1)..<last)
        let before = origin > 1 ? Array(1..<origin) : []
        let room = maxRows - (origin > 0 ? 3 : 2)
        var foldBetween = false
        var foldBefore = false
        var shown = between.count + before.count
        for run in [between, before].sorted(by: { $0.count > $1.count }) where shown > room && run.count >= 2 {
            if run == between { foldBetween = true } else { foldBefore = true }
            shown -= run.count - 1
        }
        var groups: [[Int]] = [[last]]
        groups += foldBetween ? [Array(between.reversed())] : between.reversed().map { [$0] }
        groups.append([origin])
        groups += foldBefore ? [Array(before.reversed())] : before.reversed().map { [$0] }
        if origin > 0 { groups.append([0]) }

        // Stations the train it meets calls at on its way, where the two share a platform
        let station = { (stop: String) in StationDirectory.station(id: String(stop.dropLast()))?.id }
        let theirs = Set((connection.next?.approach ?? []).compactMap { station($0.id) })

        let rows = groups.enumerated().map { (index, group) -> Row in
            if group.count > 1 {
                let times = group.map { stops[$0].time.timeIntervalSince1970 }
                let middle = Date(timeIntervalSince1970: ((times.min() ?? 0) + (times.max() ?? 0)) / 2)
                return Row(id: index, name: "\(group.count) more stops", kind: .folded, time: middle, shared: false)
            }
            let stop = group[0]
            let kind: Kind = stop == last ? .change : stop == origin ? .origin : .stop
            let shared = stop == last || (station(stops[stop].id).map(theirs.contains) ?? false)
            return Row(id: index, name: stops[stop].name, kind: kind, time: stops[stop].time, shared: shared)
        }
        self.rows = rows
        firstRow = Self.row(at: now, in: rows)

        if let next = connection.next {
            // Your train gets to the change at the top row's time; the train it
            // meets is where yours would be with as long to go
            let row = Self.row(at: connection.arrival.time.addingTimeInterval(-next.time.timeIntervalSince(now)), in: rows)
            nextRow = row
            nextNote = row > CGFloat(rows.count - 1) ? Self.note(for: next, now: now) : nil
        } else {
            nextRow = nil
            nextNote = nil
        }
    }

    /// Where your train is at `time`: between two stops by how far it has come
    /// from one to the next, or before the last while it's on its way there.
    private static func row(at time: Date, in rows: [Row]) -> CGFloat {
        guard let top = rows.first, time < top.time else { return 0 }
        for index in rows.indices.dropLast() where time >= rows[index + 1].time {
            let upper = rows[index].time
            let lower = rows[index + 1].time
            let span = upper.timeIntervalSince(lower)
            let fraction = span > 0 ? upper.timeIntervalSince(time) / span : 0
            return CGFloat(index) + CGFloat(min(1, max(0, fraction)))
        }
        return CGFloat(rows.count - 1) + 0.6
    }

    /// "D at 36 St", "D heading for 36 St"
    private static func note(for train: Arrival, now: Date) -> String? {
        guard let place = train.place(now: now) else { return nil }
        switch place {
        case .starting:
            return train.approach.first.map { "\(train.lineLabel) starting at \($0.name)" }
        case .at(let index):
            return "\(train.lineLabel) at \(train.approach[index].name)"
        case .approaching(let index):
            return "\(train.lineLabel) heading for \(train.approach[index].name)"
        }
    }
}

/// The two tracks: your train's along the top, dashed past folded stops, with a
/// dot at each stop and a ring at yours; below it a line for each colour of the
/// lines changed to; and a platform's outline across both where they stop
/// together. Both fade in from the left, where trains come from.
private struct TrackRails: View {
    let layout: TransferMapLayout
    let track: TrackGeometry
    let localY: CGFloat
    let otherY: CGFloat
    let localColor: Color
    let otherColors: [Color]
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        // Tinted and clear Home Screens draw the widget in one color, keeping
        // only how opaque each part is: there, what's filled with the widget's
        // background here is cut out of the tracks instead
        let tinted = renderingMode != .fullColor
        Canvas { context, _ in
            var eraser = context
            eraser.blendMode = .destinationOut
            let right = track.x(0)
            let left = track.x(CGFloat(layout.rows.count - 1))
            let bar = { (y: CGFloat, thickness: CGFloat, from: CGFloat, to: CGFloat) in
                Path(CGRect(x: from, y: y - thickness / 2, width: max(0, to - from), height: thickness))
            }
            let circle = { (x: CGFloat, y: CGFloat, diameter: CGFloat) in
                Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
            }

            for row in layout.rows.dropLast() {
                let from = track.x(CGFloat(row.id + 1))
                let to = track.x(CGFloat(row.id))
                if row.kind == .folded || layout.rows[row.id + 1].kind == .folded {
                    var dashes = Path()
                    dashes.move(to: CGPoint(x: from, y: localY))
                    dashes.addLine(to: CGPoint(x: to, y: localY))
                    context.stroke(dashes, with: .color(localColor), style: StrokeStyle(lineWidth: 4, dash: [3, 3]))
                } else {
                    context.fill(bar(localY, 4, from, to), with: .color(localColor))
                }
            }
            context.fill(bar(localY, 4, 0, left), with: Self.fading(localColor, y: localY, to: left))

            let count = CGFloat(otherColors.count)
            for (index, color) in otherColors.enumerated() {
                let y = otherY - (count * 5 - 2) / 2 + 1.5 + CGFloat(index) * 5
                context.fill(bar(y, 3, left, right), with: .color(color))
                context.fill(bar(y, 3, 0, left), with: Self.fading(color, y: y, to: left))
            }

            for row in layout.rows where row.kind != .folded {
                let x = track.x(CGFloat(row.id))
                if row.shared {
                    let outline = CGRect(x: x - 9, y: localY - 12, width: 18, height: otherY - localY + 24)
                    let platform = Path(roundedRect: outline, cornerRadius: 9)
                    if tinted {
                        eraser.fill(platform, with: .color(.black))
                    } else {
                        context.fill(platform, with: .color(Color.boardBackground))
                    }
                    context.stroke(Path(roundedRect: outline.insetBy(dx: 1.25, dy: 1.25), cornerRadius: 7.75),
                                   with: .color(Color.boardText), lineWidth: 2.5)
                } else if row.kind == .origin {
                    if tinted {
                        eraser.fill(circle(x, localY, 16), with: .color(.black))
                    } else {
                        context.fill(circle(x, localY, 16), with: .color(Color.boardBackground))
                    }
                    context.stroke(circle(x, localY, 13), with: .color(Color.boardText), lineWidth: 3)
                } else {
                    context.fill(circle(x, localY, 8), with: .color(Color.boardText))
                }
            }

            // Room for the trains' outlines, which can't have a background to part them from the tracks
            if tinted {
                let room = BoardStyle.large.markerSize + 4
                let edge = BoardStyle.large.markerSize / 2
                eraser.fill(circle(max(edge, track.x(layout.firstRow)), localY, room), with: .color(.black))
                if let row = layout.nextRow {
                    eraser.fill(circle(max(edge, track.x(row)), otherY, room), with: .color(.black))
                }
            }
        }
    }

    /// Fading in from the widget's left edge to `x`.
    private static func fading(_ color: Color, y: CGFloat, to x: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [color.opacity(0), color]),
                        startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: x, y: y))
    }
}
