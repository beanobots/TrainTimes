import CoreGraphics
import SwiftUI

/// How Nearby's map marks change from one look to another (a station's sign to its bubble, a bus
/// stop's dot to its lines' tag, a mark showing or hiding): the old one shrinks into its place,
/// a hair bigger first, and the new one springs out of it, a little past its size and back. One
/// after the other, never both at once, nor see-through. With Reduce Motion on, at once.
enum MarkBubble {
    /// How small a look that's gone is drawn: not nothing, which can't be turned back to a size.
    static let gone: CGFloat = 0.001
    /// How long the old look takes to shrink, before the new one starts out.
    static let shrinkTime = 0.1
    /// Shrinking: a curve that dips below its start first, so it swells about 4% before it goes.
    static let shrink = Animation.timingCurve(0.35, -0.2, 0.8, 0.4, duration: shrinkTime)
    /// Springing out, past its size to about 110% and back, once the old look's gone.
    static let pop = Animation.spring(duration: 0.25, bounce: 0.4).delay(shrinkTime)

    /// The animation for a look `showing` now, or not: popping out, or shrinking.
    static func animation(showing: Bool, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : showing ? pop : shrink
    }

    /// A look gone, not drawn at all once it's shrunk away (as one only too small to see still
    /// is, its shadow too, slowing the map): there at once as it comes back, as it springs out.
    struct Gone<Value: Equatable>: ViewModifier {
        let gone: Bool
        /// What it's gone or come with, for the change to wait for its shrinking.
        let look: Value

        func body(content: Content) -> some View {
            content
                .opacity(gone ? 0 : 1)
                .animation(gone ? .linear(duration: 0).delay(shrinkTime) : nil, value: look)
        }
    }

    /// A look coming in or going out of its place, the middle of its frame.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .asymmetric(insertion: AnyTransition.scale(scale: gone).animation(pop),
                                               removal: AnyTransition.scale(scale: gone).animation(shrink))
    }
}

/// Where Nearby's bus stops' tags go, each clear of the marks before it where it can be: as it
/// is; else, its lines put in the tag of a stop just by it its buses also stop at, going the same
/// way ("B61 B103"), itself a dot; else moved a little along its street; else, past close in,
/// over others as long as most of it shows, and close in, hidden. Worked out on the screen, in
/// points, for `LiveView.layOutMarks`.
enum BusTagLayout {
    /// A stop's tag to place.
    struct Tag {
        let id: String
        /// Where it's drawn, with the room round it marks keep.
        let rect: CGRect
        /// Where its stop is, and the way its buses go: radians from east, y down.
        let stop: CGPoint
        let angle: Double
        /// The lines it names, and those stopping there (`TrackShapes.busKey`).
        let lines: [String]
        let serves: Set<String>
    }

    /// A tag placed, and where.
    struct Shown {
        let tag: Tag
        var rect: CGRect
        /// Its place in the marks placed, to grow there when another's lines are put in it.
        let placed: Int
    }

    enum Decision: Equatable {
        /// Shown, moved this far along its street.
        case shown(nudge: CGSize)
        /// Its lines put in another's tag, by its id.
        case joined(into: String)
        case hidden
    }

    /// Points apart, at most, two stops' places for one's lines to go in the other's tag.
    static let joinReach: CGFloat = 48
    /// How near the same way two stops' buses must go for that: within 30°.
    static let joinWay = cos(30 * Double.pi / 180)
    /// Points a tag may be moved along its street, either way, shortest first.
    static let nudges: [CGFloat] = [8, -8, 16, -16, 24, -24]
    /// How much of a tag, or of the mark it's over, may be covered, past close in, and it still show.
    static let overlapShown: CGFloat = 0.35

    /// Where `tag` goes, clear of `placed` (every mark placed before it, tags too), and of the
    /// tags `shown`, which it's added to, or whose lines it's put in (`extra`). `close`: nothing
    /// over anything. `width` is how much wider a tag is for more lines.
    static func place(_ tag: Tag, placed: inout [CGRect], shown: inout [Shown], extra: inout [String: [String]],
                      close: Bool, width: ([String]) -> CGFloat) -> Decision {
        func clear(_ rect: CGRect) -> Bool { !placed.contains { $0.intersects(rect) } }
        func show(_ rect: CGRect, nudge: CGSize) -> Decision {
            shown.append(Shown(tag: tag, rect: rect, placed: placed.count))
            placed.append(rect)
            return .shown(nudge: nudge)
        }
        if clear(tag.rect) { return show(tag.rect, nudge: .zero) }
        // Over a stop's tag just by it going the same way, whose buses its lines are among: its
        // lines in that one
        let keys = Set(tag.lines.map(TrackShapes.busKey))
        let joinable = shown.indices.filter { index in
            let other = shown[index]
            return other.rect.intersects(tag.rect) && keys.isSubset(of: other.tag.serves)
                && cos(tag.angle - other.tag.angle) >= joinWay
                && hypot(other.tag.stop.x - tag.stop.x, other.tag.stop.y - tag.stop.y) <= joinReach
        }
        if let index = joinable.min(by: { distance(shown[$0].tag.stop, tag.stop) < distance(shown[$1].tag.stop, tag.stop) }) {
            let grows = width(tag.lines)
            shown[index].rect = shown[index].rect.insetBy(dx: -grows / 2, dy: 0)
            placed[shown[index].placed] = shown[index].rect
            extra[shown[index].tag.id, default: []] += tag.lines
            return .joined(into: shown[index].tag.id)
        }
        // A little along its street, either way, to where it's clear
        let along = CGVector(dx: cos(tag.angle), dy: sin(tag.angle))
        for step in nudges {
            let nudge = CGSize(width: along.dx * step, height: along.dy * step)
            let moved = tag.rect.offsetBy(dx: nudge.width, dy: nudge.height)
            if clear(moved) { return show(moved, nudge: nudge) }
        }
        // Past close in, over others as long as most of it shows; close in, not at all
        guard !close else { return .hidden }
        // Most of it, and of each it's over: not a tag hiding most of one placed before it
        let mostShows = placed.allSatisfy { other in
            let overlap = other.intersection(tag.rect)
            let smaller = min(tag.rect.width * tag.rect.height, other.width * other.height)
            return overlap.isNull || overlap.width * overlap.height <= smaller * overlapShown
        }
        return mostShows ? show(tag.rect, nudge: .zero) : .hidden
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// About the size `BusStopMark` draws at, for one not yet measured: its lines' pill, or its
    /// dot with room round it to tap.
    static func size(lines: [String]?, arrow: Bool) -> CGSize {
        guard let lines else { return CGSize(width: arrow ? 24 : 20, height: arrow ? 24 : 20) }
        let spacing = CGFloat(max(0, lines.count - 1 + (arrow ? 1 : 0))) * 2
        return CGSize(width: badgesWidth(lines) + spacing + (arrow ? 11 : 0) + 6, height: 21)
    }

    /// About how wide `lines`' badges are, side by side, and the room after each.
    static func badgesWidth(_ lines: [String]) -> CGFloat {
        lines.reduce(CGFloat(0)) { width, line in
            width + CGFloat(BusBadge.label(line).count) * 6.5 + 8 + (BusBadge.isSBS(line) ? 16 : 0)
        }
    }

    /// How far out from its stop a tag `size` big is drawn, the way its buses go `angle` on the
    /// screen, for its edge to clear its line: to the right of that way, its kerb side.
    static func kerbOffset(angle: Double, size: CGSize) -> CGFloat {
        let side = CGVector(dx: -sin(angle), dy: cos(angle))
        return abs(side.dx) * size.width / 2 + abs(side.dy) * size.height / 2 + 1
    }
}
