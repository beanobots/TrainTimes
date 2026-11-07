import SwiftUI
import UIKit
import WidgetKit

/// Home screen widget sizes. Medium widgets 158+ pt tall (iPhone 12 and later, except minis)
/// are large; the small widget, and medium on an SE or mini, are compact.
struct BoardStyle {
    let isLarge: Bool
    /// Text size to measure at, which the widget may cap below the phone's; nil for the phone's.
    var textSize: DynamicTypeSize? = nil

    static let compact = BoardStyle(isLarge: false)
    static let large = BoardStyle(isLarge: true)

    func at(_ size: DynamicTypeSize) -> BoardStyle {
        BoardStyle(isLarge: isLarge, textSize: size)
    }

    // Header: station and direction

    var bulletSize: CGFloat { isLarge ? 30 : 26 }
    var headerSpacing: CGFloat { isLarge ? 8 : 7 }
    var nameFont: Font { isLarge ? .body.bold() : .subheadline.bold() }
    var headingFont: Font { isLarge ? .footnote : .caption2 }
    var headingScale: CGFloat { isLarge ? 0.85 : 0.8 }

    // ↻, map and walk

    var buttonHeight: CGFloat { isLarge ? 26 : 24 }

    /// `style`'s font at `textSize`, for measuring text.
    func font(_ style: UIFont.TextStyle) -> UIFont {
        let traits = textSize.map { UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory($0)) }
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
    }

    func points(_ style: UIFont.TextStyle) -> CGFloat {
        font(style).pointSize
    }
}

extension EnvironmentValues {
    /// Drawn as the Saved Route widget (and the Widgets tab's copy of it): the app's colours and
    /// corners, and its own layouts. Off, as the Magic Widget draws its boards, today's look.
    @Entry var routeLook = false
    /// The widget size a board draws at in the app's Widgets tab, which can't set
    /// `widgetFamily`; nil in a widget, which uses iOS's.
    @Entry var boardFamily: WidgetFamily? = nil
    /// The content margins in the app's Widgets tab, which can't set `widgetContentMargins`.
    @Entry var boardMargins: EdgeInsets? = nil
    /// Walk and ✕ drawn as their faces only, not buttons: for a board drawn as a toggle's face
    /// (`TrainWidgetView.still`), which can't hold buttons.
    @Entry var stillControls = false
    /// Transit Directions' buttons as a picture, which its ✕ toggle shows at once on a tap.
    @Entry var endTripFace: EndTripFace? = nil
    /// Transit Directions' size, for a toggle's face drawn over all of it (`wholeWidgetFace`).
    @Entry var widgetSize: CGSize? = nil
}

/// The boards' ink: today's colours, or with `routeLook` the app's (secondary text, tertiary fill),
/// so one board serves both widgets.
struct BoardInk: ShapeStyle {
    enum Kind { case text, gray, tile }
    let kind: Kind

    static let text = BoardInk(kind: .text)
    static let gray = BoardInk(kind: .gray)
    static let tile = BoardInk(kind: .tile)

    func resolve(in environment: EnvironmentValues) -> Color {
        Self.color(kind, route: environment.routeLook)
    }

    /// As a plain colour, for where a `Color` is needed.
    static func color(_ kind: Kind, route: Bool) -> Color {
        switch (kind, route) {
        case (.text, true): Color(uiColor: .label)
        case (.gray, true): Color(uiColor: .secondaryLabel)
        case (.tile, true): Color(uiColor: .tertiarySystemFill)
        case (.text, false): .boardText
        case (.gray, false): .boardGray
        case (.tile, false): Color.boardText.opacity(0.07)
        }
    }
}

/// A board's grey tile: today's 16 (or `radius`) corners, or with `routeLook` the app's 18,
/// continuous.
struct BoardTile: View {
    var radius: CGFloat = 16
    @Environment(\.routeLook) private var routeLook

    var body: some View {
        RoundedRectangle(cornerRadius: routeLook ? 18 : radius, style: routeLook ? .continuous : .circular)
            .fill(BoardInk.tile)
    }
}

/// A board's countdown from `start` to `end`: a live timer, or on a toggle's face
/// (`stillControls`) the time left at `start`, as plain text. A tap on a live timer always opens
/// the app, as iOS draws it in a layer of its own, and a toggle's face is there to be tapped
/// even before it shows: Favorite Stop's board over its card, on Transit Directions' buttons.
/// The face shows only until the redraw, which counts down again.
struct CountdownTimer: View {
    let start: Date
    let end: Date
    @Environment(\.stillControls) private var still

    var body: some View {
        if still {
            Text(Self.frozen(seconds: end.timeIntervalSince(start)))
        } else {
            // A held train still shows after its leave time
            Text(timerInterval: start...max(start, end), countsDown: true)
        }
    }

    /// As a timer counting down shows `seconds`: "7:04", "12:30", "1:02:03".
    static func frozen(seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// The boards' big countdown from `start` to `end` (after a walker, to when to leave), green and
/// accented when live, with its live or timetable mark per Settings.
struct BoardCountdown: View {
    let start: Date
    let end: Date
    let isLive: Bool
    let marks: TimeMarks
    let size: CGFloat
    let walking: Bool
    /// "At Station" in place of 0:00, for a train just due (`TimelinePlan.atStation`).
    let atStation: Bool
    /// What it says then: "At Station", or a bus's "At Stop".
    var atLabel = AtStation.label
    @Environment(\.routeLook) private var routeLook

    /// To `train` on `entry`'s board, or to leaving for it with a walking time; at the station
    /// once it's due, without one.
    init(_ train: Arrival, on entry: TrainEntry, marks: TimeMarks, size: CGFloat) {
        self.init(start: entry.date, end: entry.selection.leaveTime(for: train), isLive: train.isLive, marks: marks,
                  size: size, walking: entry.selection.walkMinutes > 0,
                  atStation: TimelinePlan.atStation(train, at: entry.date, selection: entry.selection))
    }

    init(start: Date, end: Date, isLive: Bool, marks: TimeMarks, size: CGFloat, walking: Bool = false,
         atStation: Bool = false, atLabel: String = AtStation.label) {
        self.start = start
        self.end = end
        self.isLive = isLive
        self.marks = marks
        self.size = size
        self.walking = walking
        self.atStation = atStation
        self.atLabel = atLabel
    }

    /// "At Station" at half the countdown's size, so it fits in the box the digits do.
    private var textSize: CGFloat { atStation ? size * 0.5 : size }

    var body: some View {
        let color = isLive ? Color.liveText : BoardInk.color(.text, route: routeLook)
        HStack(spacing: 4) {
            if walking {
                Image(systemName: "figure.walk")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(BoardInk.gray)
                    .accessibilityLabel("Leave in")
            }
            // A live timer takes all the width it's offered, so the placeholder sizes it
            Text(atStation ? atLabel : TimerText.placeholder(seconds: end.timeIntervalSince(start)))
                .hidden()
                .overlay(alignment: .leading) {
                    if atStation {
                        Text(atLabel).lineLimit(1)
                    } else {
                        CountdownTimer(start: start, end: end)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: textSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .timerForeground(color)
                .widgetAccentable(isLive)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            StatusMark(isLive: isLive, marks: marks, size: size / 3)
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityValue(isLive ? "Live" : "Scheduled")
    }
}

/// The boards' tinted rounded box, filling the room it's given.
struct BoardBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BoardTile())
    }
}

/// The large Transfers widget's top card, as tall as medium's box (`WaysBoard.boxHeight`), also
/// large Transfers without a change: the countdown to `train` (or to leaving for it), then its
/// line and when it leaves, and the next ones' minutes to go (`later`).
struct TopCard: View {
    let entry: TrainEntry
    let train: Arrival
    let later: [MinutesToGo]
    let marks: TimeMarks

    var body: some View {
        HStack(spacing: 8) {
            BoardCountdown(train, on: entry, marks: marks, size: 48)
            Spacer(minLength: 0)
            LeavesColumn(train: train, later: later)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: WaysBoard.boxHeight)
        .background(BoardTile())
    }
}

/// In a board's header: ↻ from a tap until the new times, unless `showsRefreshing` is off (it
/// shows elsewhere); no signal while the times shown are old or the timetable's.
struct RefreshMark: View {
    let entry: TrainEntry
    let refreshing: Bool
    var showsRefreshing = true

    var body: some View {
        if (refreshing && showsRefreshing) || (!refreshing && entry.isOffline) {
            Image(systemName: refreshing ? "arrow.clockwise" : "wifi.slash")
                .font(.caption.weight(.bold))
                .foregroundStyle(BoardInk.gray)
                .accessibilityLabel(refreshing ? "Refreshing" : entry.offlineLabel)
        }
    }
}

/// A board's walk button, with a ✕ before it (`TrainEntry.closes`), spaced as the header leaves
/// room for them.
struct BoardButtons<Walk: View>: View {
    let entry: TrainEntry
    let large: Bool
    let spacing: CGFloat
    @ViewBuilder let walk: Walk

    var body: some View {
        HStack(spacing: spacing) {
            if entry.closes {
                // Over walk, as on a tap it draws over the whole widget
                EndTripButton(large: large, closing: entry.tripSource == nil ? entry.widgetID : nil)
                    .zIndex(1)
            }
            walk
        }
    }
}

extension AnyTransition {
    /// A toggle's face as iOS draws it on a tap: settling in from a touch larger, so the tap
    /// feels pressed. Larger rather than smaller, so it covers what's under it throughout
    /// instead of crossfading over it; and gone at once, as the redraw that replaces it is the same.
    static var pressed: AnyTransition {
        .asymmetric(insertion: .scale(scale: 1.02).animation(.snappy(duration: 0.2)), removal: .identity)
    }
}

extension View {
    /// While `shown`, `face` over the whole of Transit Directions, from wherever this is in it: a
    /// toggle's face, which iOS draws at once on a tap, before its intent runs and the widget
    /// redraws. Needs the widget's `EndTripFace.space` and `widgetSize`; without, nothing.
    func wholeWidgetFace<Face: View>(_ shown: Bool, @ViewBuilder _ face: @escaping () -> Face) -> some View {
        modifier(WholeWidgetFace(shown: shown, face: face))
    }
}

private struct WholeWidgetFace<Face: View>: ViewModifier {
    let shown: Bool
    let face: () -> Face
    @Environment(\.widgetSize) private var size
    @Environment(\.routeLook) private var routeLook

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if shown, let size {
                GeometryReader { proxy in
                    // From here back to the widget's top left
                    let origin = proxy.frame(in: .named(EndTripFace.space)).origin
                    face()
                        .frame(width: size.width, height: size.height)
                        .background(routeLook ? Color.routeBackground : Color.boardBackground)
                        .offset(x: -origin.x, y: -origin.y)
                }
                // Not crossfaded over what's under it
                .transition(.pressed)
            }
        }
    }
}

/// What Transit Directions' ✕ shows at once on a tap (`EndTripButton`): its Quick Trip and
/// Favorite Stop buttons, drawn over the whole widget from wherever the ✕ is.
struct EndTripFace {
    /// The widget's coordinate space, from which the ✕ finds where the widget starts.
    static let space = "transitDirections"
    let view: AnyView
    /// The widget's size.
    let size: CGSize
}

extension String {
    /// Single-line width in `font`.
    func width(in font: UIFont) -> CGFloat {
        ceil((self as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// A way's mark: its line's bullet, or for a bus (`BusLeg.route`) its badge.
struct WayMark: View {
    let route: String
    let size: CGFloat
    var relativeTo: Font.TextStyle? = nil

    var body: some View {
        if let line = BusLeg.line(of: route) {
            BusBadge(line: line, size: size)
        } else {
            LineBullet(route: route, size: size, relativeTo: relativeTo)
        }
    }
}
