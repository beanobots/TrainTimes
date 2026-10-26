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

    /// To `train` on `entry`'s board, or to leaving for it with a walking time.
    init(_ train: Arrival, on entry: TrainEntry, marks: TimeMarks, size: CGFloat) {
        self.init(start: entry.date, end: entry.selection.leaveTime(for: train), isLive: train.isLive, marks: marks,
                  size: size, walking: entry.selection.walkMinutes > 0)
    }

    init(start: Date, end: Date, isLive: Bool, marks: TimeMarks, size: CGFloat, walking: Bool = false) {
        self.start = start
        self.end = end
        self.isLive = isLive
        self.marks = marks
        self.size = size
        self.walking = walking
    }

    var body: some View {
        let color = isLive ? Color.liveText : Color.boardText
        HStack(spacing: 4) {
            if walking {
                Image(systemName: "figure.walk")
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(Color.boardGray)
                    .accessibilityLabel("Leave in")
            }
            // A live timer takes all the width it's offered, so the placeholder sizes it
            Text(TimerText.placeholder(seconds: end.timeIntervalSince(start)))
                .hidden()
                .overlay(alignment: .leading) {
                    CountdownTimer(start: start, end: end)
                        .lineLimit(1)
                }
                .font(.system(size: size, weight: .bold, design: .rounded))
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
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
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
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.boardText.opacity(0.07)))
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
                .foregroundStyle(Color.boardGray)
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

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if shown, let size {
                GeometryReader { proxy in
                    // From here back to the widget's top left
                    let origin = proxy.frame(in: .named(EndTripFace.space)).origin
                    face()
                        .frame(width: size.width, height: size.height)
                        .background(Color.boardBackground)
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
