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
    private var height: CGFloat { otherY + (showsNote ? 28 : 14) }

    var body: some View {
        let layout = TransferMapLayout(connection: connection, selection: selection, now: now, maxRows: 5)
        VStack(alignment: .leading, spacing: 8) {
            labels
            if let layout {
                GeometryReader { geometry in
                    diagram(layout, width: geometry.size.width)
                }
                .frame(height: height)
                // Its names and times sit at set places along the tracks, which
                // larger text would run into each other
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            } else {
                Text("The MTA hasn't said yet")
                    .font(BoardStyle.large.stopFont)
                    .foregroundStyle(Color.boardGray)
            }
        }
        // The tracks and the trains on them are drawn, so VoiceOver has them in words
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layout?.spoken ?? "Where they are: the MTA hasn't said yet")
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
        let station = layout.rows[0].name.mainStationName
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
                        .minimumScaleFactor(0.8)
                        .frame(width: width * 0.62, alignment: .leading)
                        .position(x: width * 0.31, y: otherY + 20)
                }
                Text(station)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.boardText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: width * 0.36, alignment: .trailing)
                    .position(x: width * 0.82, y: otherY + 20)
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
            .mapStop(.caption2, yours: yours, trainStop: isTrainStop, folded: row.kind == .folded, passed: passed)
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
            .widgetAccentable(yours && connection.first.isLive)
            .fixedSize()
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
        let tinted = renderingMode != .fullColor
        Canvas { context, _ in
            let right = track.x(0)
            let left = track.x(CGFloat(layout.rows.count - 1))
            let bar = { (y: CGFloat, thickness: CGFloat, from: CGFloat, to: CGFloat) in
                Path(CGRect(x: from, y: y - thickness / 2, width: max(0, to - from), height: thickness))
            }
            let circle = { (x: CGFloat, y: CGFloat, diameter: CGFloat) in
                Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
            }

            for row in layout.rows.dropLast() {
                context.strokeRail(from: CGPoint(x: track.x(CGFloat(row.id + 1)), y: localY),
                                   to: CGPoint(x: track.x(CGFloat(row.id)), y: localY), color: localColor,
                                   dashed: row.kind == .folded || layout.rows[row.id + 1].kind == .folded)
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
                    context.fillBackground(Path(roundedRect: outline, cornerRadius: 9), tinted: tinted)
                    context.stroke(Path(roundedRect: outline.insetBy(dx: 1.25, dy: 1.25), cornerRadius: 7.75),
                                   with: .color(Color.boardText), lineWidth: 2.5)
                } else if row.kind == .origin {
                    context.fillBackground(circle(x, localY, 16), tinted: tinted)
                    context.stroke(circle(x, localY, 13), with: .color(Color.boardText), lineWidth: 3)
                } else {
                    context.fill(circle(x, localY, 8), with: .color(Color.boardText))
                }
            }

            // Room around the trains, which can't have a background to part them from the tracks
            if tinted {
                let room = BoardStyle.large.markerSize + 4
                let edge = BoardStyle.large.markerSize / 2
                context.fillBackground(circle(max(edge, track.x(layout.firstRow)), localY, room), tinted: true)
                if let row = layout.nextRow {
                    context.fillBackground(circle(max(edge, track.x(row)), otherY, room), tinted: true)
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
