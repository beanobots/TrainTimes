//
//  LeewaySplashView.swift
//  Leeway
//
//  Animated launch sequence for the Leeway mark.
//    1. The map background is already on screen (it matches the static launch screen).
//    2. The four route lines draw in, from the top of the screen, around the bend, and off to the right.
//    3. The pill outline draws itself on, then fills white with a small pop.
//    4. "Leeway" writes on from left to right.
//
//  Shown over first-run setup, which it fades away to (`FirstRunView`).
//
//  All geometry was measured from the 1024×1024 app icon and is expressed in that
//  coordinate space ("mark units"), then scaled to the device.
//

import SwiftUI

// MARK: - Palette (sampled from the icon)

private enum LeewayPalette {
    static let yellow = Color(red: 251 / 255, green: 203 / 255, blue: 10 / 255)   // #FBCB0A
    static let orange = Color(red: 232 / 255, green: 105 / 255, blue: 29 / 255)   // #E8691D
    static let blue   = Color(red: 43 / 255,  green: 108 / 255, blue: 212 / 255)  // #2B6CD4
    static let green  = Color(red: 31 / 255,  green: 143 / 255, blue: 90 / 255)   // #1F8F5A
    static let ink    = Color(red: 22 / 255,  green: 21 / 255,  blue: 20 / 255)   // #161514

    static let paperTop    = Color(red: 246 / 255, green: 241 / 255, blue: 227 / 255) // #F6F1E3
    static let paperBottom = Color(red: 228 / 255, green: 219 / 255, blue: 197 / 255) // #E4DBC5
    static let gridLine    = Color(red: 140 / 255, green: 115 / 255, blue: 60 / 255).opacity(0.16)
}

/// The paper the mark is drawn on: the icon's cream, or a dark one.
enum SplashPaper {
    case cream, charcoal, navy

    var top: Color {
        switch self {
        case .cream: LeewayPalette.paperTop
        case .charcoal: Color(red: 38 / 255, green: 36 / 255, blue: 33 / 255)
        case .navy: Color(red: 44 / 255, green: 56 / 255, blue: 78 / 255)
        }
    }
    var bottom: Color {
        switch self {
        case .cream: LeewayPalette.paperBottom
        case .charcoal: Color(red: 20 / 255, green: 19 / 255, blue: 17 / 255)
        case .navy: Color(red: 30 / 255, green: 39 / 255, blue: 56 / 255)
        }
    }
    /// Text on the paper: the icon's ink, or white on dark.
    var ink: Color { self == .cream ? LeewayPalette.ink : .white }
    var grid: Color {
        switch self {
        case .cream: LeewayPalette.gridLine
        case .charcoal: Color(red: 230 / 255, green: 210 / 255, blue: 170 / 255).opacity(0.09)
        case .navy: Color(red: 150 / 255, green: 180 / 255, blue: 230 / 255).opacity(0.10)
        }
    }
}

// MARK: - Splash view

struct LeewaySplashView: View {
    /// Name of your existing background asset. Leave nil to draw the matching map grid in code.
    var backgroundImageName: String? = nil
    /// Called once the sequence has finished (use it to dismiss the splash).
    var onFinished: (() -> Void)? = nil
    /// Where the mark's centre sits, as a fraction of the screen's height.
    var markCenterY: CGFloat = 0.47
    /// Drawn finished and without "Leeway", not animated: the Routes tab's background.
    var still = false
    var paper = SplashPaper.cream
    /// How strongly the four lines show: 1 as the icon, less behind other things.
    var lineOpacity = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var yellowProgress: CGFloat = 0
    @State private var orangeProgress: CGFloat = 0
    @State private var blueProgress: CGFloat = 0
    @State private var greenProgress: CGFloat = 0
    @State private var pillOutline: CGFloat = 0
    @State private var pillFill: Double = 0
    @State private var pillScale: CGFloat = 1
    @State private var wordReveal: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let m = MarkLayout(size: geo.size, centerY: markCenterY)

            ZStack(alignment: .topLeading) {
                background

                // Route lines (drawn outer-to-inner so the bend fans open)
                route(.yellow, progress: shown(yellowProgress), m: m)
                route(.orange, progress: shown(orangeProgress), m: m)
                route(.blue,   progress: shown(blueProgress),   m: m)
                route(.green,  progress: shown(greenProgress),  m: m)

                // The pill / "slash"
                ZStack {
                    // Dimmed with the lines: plain paper under it, so they don't show through
                    if lineOpacity < 1 {
                        PillShape(centerY: markCenterY).fill(paperFill)
                        PillShape(centerY: markCenterY).stroke(paperFill, lineWidth: m.v(21))
                    }
                    ZStack {
                        PillShape(centerY: markCenterY)
                            .fill(Color.white)
                            .opacity(still ? 1 : pillFill)
                        PillShape(centerY: markCenterY)
                            .trim(from: 0, to: shown(pillOutline))
                            .stroke(LeewayPalette.ink,
                                    style: StrokeStyle(lineWidth: m.v(21), lineCap: .round, lineJoin: .round))
                    }
                    .opacity(lineOpacity)
                }
                .scaleEffect(pillScale, anchor: m.unitPoint(for: MarkLayout.pillCenter))

                // Wordmark, centred across the screen
                if !still {
                    wordmark(m: m)
                        .frame(width: geo.size.width)
                        .offset(y: m.p(0, 905).y)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .task { if !still { await runSequence() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Leeway")
        .accessibilityHidden(still)
    }

    /// The paper's gradient, as the background draws it, for under dimmed parts.
    private var paperFill: LinearGradient {
        LinearGradient(colors: [paper.top, paper.bottom],
                       startPoint: UnitPoint(x: 0.5, y: 0), endPoint: UnitPoint(x: 0.3, y: 1))
    }

    /// An animated amount, or all of it when still.
    private func shown(_ progress: CGFloat) -> CGFloat { still ? 1 : progress }

    // MARK: Pieces

    @ViewBuilder
    private var background: some View {
        if let name = backgroundImageName {
            Image(name)
                .resizable()
                .scaledToFill()
        } else {
            MapGridBackground(centerY: markCenterY, paper: paper)
        }
    }

    private func route(_ line: RouteLine, progress: CGFloat, m: MarkLayout) -> some View {
        let shape = RouteShape(line: line, centerY: markCenterY).trim(from: 0, to: progress)
        let style = StrokeStyle(lineWidth: m.v(60), lineCap: .butt, lineJoin: .round)
        return ZStack {
            // Dimmed, solid: plain paper under the line, so the grid doesn't show through
            if lineOpacity < 1 {
                shape.stroke(paperFill, style: style)
            }
            shape.stroke(line.color, style: style).opacity(lineOpacity)
        }
    }

    private func wordmark(m: MarkLayout) -> some View {
        // Helvetica, the subway signs' typeface
        Text("Leeway")
            .font(.custom("HelveticaNeue-Bold", fixedSize: m.v(170)))
            .kerning(-m.v(3))
            .foregroundColor(LeewayPalette.ink)
            .fixedSize()
            // "Write on": a soft-edged mask sweeps left to right
            .mask(alignment: .leading) {
                GeometryReader { g in
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: g.size.width * 1.25 * wordReveal)
                }
            }
            .offset(y: (1 - wordReveal) * m.v(18))
    }

    // MARK: Timeline

    @MainActor
    private func runSequence() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.35)) {
                yellowProgress = 1; orangeProgress = 1; blueProgress = 1; greenProgress = 1
                pillOutline = 1; pillFill = 1; wordReveal = 1
            }
            await pause(0.35 + Self.hold)
            onFinished?()
            return
        }

        // Background is already visible; give it a beat.
        await pause(0.25)

        // 1. Lines — staggered, with a smooth ease-in-out.
        let draw = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 1.1)
        withAnimation(draw)              { yellowProgress = 1 }
        withAnimation(draw.delay(0.12))  { orangeProgress = 1 }
        withAnimation(draw.delay(0.24))  { blueProgress = 1 }
        withAnimation(draw.delay(0.36))  { greenProgress = 1 }

        // 2. Pill — outline draws as the lines finish rounding the bend.
        await pause(1.05)
        withAnimation(.easeInOut(duration: 0.5)) { pillOutline = 1 }

        await pause(0.42)
        withAnimation(.easeOut(duration: 0.18)) {
            pillFill = 1
            pillScale = 1.07
        }
        await pause(0.18)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { pillScale = 1 }

        // 3. Wordmark writes on.
        await pause(0.15)
        withAnimation(.easeOut(duration: 0.8)) { wordReveal = 1 }

        // Hold 1.5 s once the wordmark's written on (its 0.8 s), then hand off.
        await pause(0.8 + Self.hold)
        onFinished?()
    }

    /// How long the finished mark stays before the hand-off.
    private static let hold: Double = 1.5

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Layout (icon coordinates → screen)

/// Maps the 1024×1024 icon coordinate space onto the screen.
/// The mark sits slightly above center to leave room for the wordmark.
private struct MarkLayout {
    static let bendCenter = CGPoint(x: 510, y: 520)   // shared center of all four quarter-turns
    static let pillCenter = CGPoint(x: 372.5, y: 657.5)

    let size: CGSize
    let scale: CGFloat
    let origin: CGPoint

    init(size: CGSize, centerY: CGFloat) {
        self.size = size
        scale = min(size.width, size.height * 0.62) / 1024
        let side = 1024 * scale
        origin = CGPoint(x: (size.width - side) / 2,
                         y: size.height * centerY - side / 2)
    }

    /// Point in mark units → screen point.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }
    func p(_ pt: CGPoint) -> CGPoint { p(pt.x, pt.y) }

    /// Length in mark units → screen points.
    func v(_ d: CGFloat) -> CGFloat { d * scale }

    func unitPoint(for markPoint: CGPoint) -> UnitPoint {
        let s = p(markPoint)
        return UnitPoint(x: s.x / max(size.width, 1), y: s.y / max(size.height, 1))
    }
}

// MARK: - Route lines

private enum RouteLine {
    case yellow, orange, blue, green

    /// x of the vertical run, in mark units (line centre).
    var x: CGFloat {
        switch self {
        case .yellow: return 201
        case .orange: return 279
        case .blue:   return 357
        case .green:  return 435
        }
    }
    /// y of the horizontal run, in mark units (line centre).
    var y: CGFloat {
        switch self {
        case .yellow: return 829
        case .orange: return 751
        case .blue:   return 673
        case .green:  return 595
        }
    }
    /// Bend radius — all four are concentric around MarkLayout.bendCenter.
    var radius: CGFloat { y - MarkLayout.bendCenter.y }

    var color: Color {
        switch self {
        case .yellow: return LeewayPalette.yellow
        case .orange: return LeewayPalette.orange
        case .blue:   return LeewayPalette.blue
        case .green:  return LeewayPalette.green
        }
    }
}

/// One route: enters from the top edge, bends 90°, exits off the right edge.
private struct RouteShape: Shape {
    let line: RouteLine
    let centerY: CGFloat

    func path(in rect: CGRect) -> Path {
        let m = MarkLayout(size: rect.size, centerY: centerY)
        let overshoot = m.v(40)
        let corner = m.p(line.x, line.y)
        let start = CGPoint(x: corner.x, y: rect.minY - overshoot)
        let end = CGPoint(x: rect.maxX + overshoot, y: corner.y)

        var path = Path()
        path.move(to: start)
        path.addArc(tangent1End: corner, tangent2End: end, radius: m.v(line.radius))
        path.addLine(to: end)
        return path
    }
}

// MARK: - Pill

/// The white capsule with black outline, lying on the 45° diagonal through the bend.
private struct PillShape: Shape {
    let centerY: CGFloat

    func path(in rect: CGRect) -> Path {
        let m = MarkLayout(size: rect.size, centerY: centerY)
        // Stroke centreline: outer size is ~338 × 102 units with a 21-unit outline.
        let length = m.v(317)
        let width = m.v(81)
        let capsule = Path(roundedRect: CGRect(x: -length / 2, y: -width / 2, width: length, height: width),
                           cornerRadius: width / 2,
                           style: .circular)
        let c = m.p(MarkLayout.pillCenter)
        let transform = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: -.pi / 4)
        return capsule.applying(transform)
    }
}

// MARK: - Background (matches the icon's paper + street grid)

/// Cream paper gradient with the faint rotated street grid from the icon.
/// The grid is anchored to the mark so it lines up exactly with the icon at any screen size.
private struct MapGridBackground: View {
    let centerY: CGFloat
    var paper = SplashPaper.cream

    var body: some View {
        Canvas { context, size in
            let m = MarkLayout(size: size, centerY: centerY)
            let rect = CGRect(origin: .zero, size: size)

            // Paper
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: [paper.top, paper.bottom]),
                    startPoint: CGPoint(x: size.width * 0.5, y: 0),
                    endPoint: CGPoint(x: size.width * 0.3, y: size.height)
                )
            )

            // Screen bounds in mark units
            let minX = -m.origin.x / m.scale, maxX = (size.width - m.origin.x) / m.scale
            let minY = -m.origin.y / m.scale, maxY = (size.height - m.origin.y) / m.scale
            let slope: CGFloat = 0.545   // grid is rotated ~28.6°

            var grid = Path()

            // Shallow streets: y = slope·x + c, every 72 units vertically
            let cs = [minY - slope * maxX, maxY - slope * minX]
            var c = -303.5 + (((cs[0] + 303.5) / 72).rounded(.down)) * 72
            while c <= cs[1] {
                grid.move(to: m.p(minX - 50, slope * (minX - 50) + c))
                grid.addLine(to: m.p(maxX + 50, slope * (maxX + 50) + c))
                c += 72
            }

            // Steep avenues: x = d − slope·y, every 172 units horizontally
            let ds = [minX + slope * minY, maxX + slope * maxY]
            var d = 553 + (((ds[0] - 553) / 172).rounded(.down)) * 172
            while d <= ds[1] {
                grid.move(to: m.p(d - slope * (minY - 50), minY - 50))
                grid.addLine(to: m.p(d - slope * (maxY + 50), maxY + 50))
                d += 172
            }

            context.stroke(grid, with: .color(paper.grid), lineWidth: m.v(7))
        }
    }
}

// MARK: - Preview

#if DEBUG
private struct LeewaySplashReplay: View {
    @State private var run = 0
    var body: some View {
        LeewaySplashView()
            .id(run)
            .onTapGesture { run += 1 }   // tap to replay
    }
}

struct LeewaySplashView_Previews: PreviewProvider {
    static var previews: some View {
        LeewaySplashReplay()
    }
}
#endif
