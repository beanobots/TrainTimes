import SwiftUI

/// Comfortable Walk, for Settings and first-run setup: how far New Trip's rides may have you walk to
/// and from them (`NewTripView.walkChoices`). 15 to 45 minutes in fives, then No Limit at the far
/// end. The thumb follows the finger and springs to the nearest stop when let go. The stretch past
/// 45 is dashed and pulls back: the thumb follows at a third of the finger's speed there, and only
/// a drag to the very end springs it onto No Limit, as dragging back past halfway springs it off;
/// let go short and it springs back to 45, though a tap anywhere past 45, on its ring or on ∞, picks
/// No Limit, and a tap on 15–45 its nearest stop. At No Limit the tint grows along the whole track
/// and the thumb carries the infinity sign.
struct WalkSlider: View {
    @Binding var minutes: Int
    /// Where the thumb is while it's dragged, from the track's start; nil when it rests on its stop.
    @State private var finger: CGFloat?
    /// Whether the thumb's dragged past 45, short of No Limit.
    @State private var pulling = false
    /// Whether the drag began on No Limit: back across the dashed stretch the thumb then follows the
    /// finger, as it leaves No Limit at halfway, rather than sticking at the end and then jumping
    /// most of the way back to 45.
    @State private var leaving = false

    private static let choices = NewTripView.walkChoices.map(\.minutes)
    private static let last = choices.count - 1
    private static let thumb: CGFloat = 28
    /// How much of the finger's travel the thumb follows past 45.
    private static let give: CGFloat = 0.35
    /// How far into the last stretch the finger must be let go for No Limit.
    private static let landing: CGFloat = 0.95
    /// How far past the track a touch still takes it: above it, down over the numbers under it,
    /// and out past each end, so the thumb's easy to catch, on No Limit at the far end most of all.
    private static let reach = EdgeInsets(top: 14, leading: 12, bottom: 30, trailing: 16)
    /// How much of the track 15–45 takes; the dashed stretch to No Limit gets the rest.
    private static let solidShare: CGFloat = 0.75

    /// `minutes`' stop; the one below if it's none of them.
    private var stop: Int {
        Self.choices.lastIndex { $0 <= minutes } ?? 0
    }

    private var noLimit: Bool { stop == Self.last }

    private var value: String {
        pulling ? "\(Self.choices[Self.last - 1]) min…" : NewTripView.walkLabel(minutes)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Comfortable Walk")
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(.tint)
                    .monospacedDigit()
            }
            .accessibilityHidden(true)
            GeometryReader { geo in
                track(width: geo.size.width)
            }
            .frame(height: Self.thumb)
            .padding(.bottom, 18)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Comfortable Walk")
        .accessibilityValue(NewTripView.walkLabel(minutes))
        .accessibilityHint("The longest walk to or from a ride")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: minutes = Self.choices[min(stop + 1, Self.last)]
            case .decrement: minutes = Self.choices[max(stop - 1, 0)]
            @unknown default: break
            }
        }
    }

    private func track(width: CGFloat) -> some View {
        let usable = width - Self.thumb
        let lastSolid = usable * Self.solidShare, end = usable
        // 15–45 evenly across the solid share; No Limit at the far end
        let x = { (position: CGFloat) in
            position >= CGFloat(Self.last) ? end : position / CGFloat(Self.last - 1) * lastSolid
        }
        let thumbX = finger ?? (noLimit ? end : x(CGFloat(stop)))
        return ZStack(alignment: .leading) {
            // 15–45, solid, from 15's centre to 45's so the two ends match
            Capsule()
                .fill(.quaternary)
                .frame(width: lastSolid, height: 6)
                .offset(x: Self.thumb / 2)
            // Past 45, dashed, stopping at the landing ring; at No Limit the tint grows over it
            DashLine()
                .stroke(.tertiary, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [3, 5]))
                .frame(width: max(0, end - lastSolid - Self.thumb / 2 - 4), height: 6)
                .offset(x: lastSolid + Self.thumb / 2)
            // No Limit's landing place: an empty ring where the thumb settles
            Circle()
                .strokeBorder(.tertiary, lineWidth: 2)
                .frame(width: Self.thumb, height: Self.thumb)
                .offset(x: end)
                .opacity(noLimit ? 0 : 1)
            Capsule()
                .fill(.tint)
                .frame(width: thumbX, height: 6)
                .offset(x: Self.thumb / 2)
            ZStack {
                Circle()
                    .fill(noLimit ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                if noLimit {
                    Image(systemName: "infinity")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: Self.thumb, height: Self.thumb)
            .offset(x: thumbX)
        }
        .frame(maxHeight: .infinity)
        // The stops' labels, each under its place on the track; not taps of their own, so drags
        // and taps on them reach the track (a tap on ∞ is past 45, so No Limit)
        .overlay(alignment: .topLeading) {
            ForEach(labels, id: \.position) { label in
                Text(label.text)
                    .font(label.position == Self.last ? .footnote.weight(.semibold) : .caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                    .allowsHitTesting(false)
                    .position(x: x(CGFloat(label.position)) + Self.thumb / 2, y: Self.thumb + 10)
            }
        }
        // Touches taken around the track too (`reach`), then the layout put back as it was; the
        // gestures' x is then from the reach's edge, so `reach.leading` comes off it
        .padding(Self.reach)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if finger == nil { leaving = noLimit }
                    let at = min(max(0, drag.location.x - Self.reach.leading - Self.thumb / 2), end)
                    // How far past 45 into the dashed stretch, 0…1 across it
                    let past = (at - lastSolid) / (end - lastSolid)
                    // No Limit's caught only near the end, and once caught kept until dragged well back
                    let toNoLimit = noLimit ? past > 0.5 : past >= Self.landing
                    let index: Int, place: CGFloat
                    if toNoLimit {
                        (index, place) = (Self.last, leaving ? max(at, lastSolid) : end)
                    } else if at <= lastSolid {
                        // Following the finger; the stop it's nearest picked
                        (index, place) = (Int((at / lastSolid * CGFloat(Self.last - 1)).rounded()), at)
                    } else if leaving {
                        // Off No Limit, back toward 45: following the finger
                        (index, place) = (Self.last - 1, at)
                    } else {
                        // Past 45 the thumb lags the finger
                        (index, place) = (Self.last - 1, lastSolid + past * Self.give * (end - lastSolid))
                    }
                    pulling = !toNoLimit && at > lastSolid
                    // A tap, or a step onto No Limit, springs there; otherwise it tracks the finger.
                    // Stepping off No Limit the thumb's already under it, so only its look changes
                    if finger == nil || (toNoLimit && !noLimit) {
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            finger = place
                            set(index)
                        }
                    } else if noLimit && !toNoLimit {
                        finger = place
                        withAnimation(.smooth(duration: 0.2)) { set(index) }
                    } else {
                        finger = place
                        set(index)
                    }
                }
                .onEnded { drag in
                    // Settles on the stop picked; short of No Limit, back to 45. A tap past 45,
                    // on the dashed stretch or the ring, is a pick of No Limit; the 45 thumb
                    // itself spans lastSolid…lastSolid + thumb, so only taps beyond it count
                    let tapped = abs(drag.translation.width) < 8
                        && drag.startLocation.x - Self.reach.leading > lastSolid + Self.thumb
                    pulling = false
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        finger = nil
                        if tapped { set(Self.last) }
                    }
                }
        )
        // A tap of its own: in a scroll view (Settings) a tap that doesn't move never reaches the
        // drag. Past 45, the dashed stretch or No Limit's ring, is No Limit, as ∞ under it is;
        // on 15–45, the nearest stop
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { tap in
                    let tapX = tap.location.x - Self.reach.leading
                    let at = min(max(0, tapX - Self.thumb / 2), end)
                    let index = tapX > lastSolid + Self.thumb ? Self.last
                        : Int((min(at, lastSolid) / lastSolid * CGFloat(Self.last - 1)).rounded())
                    pulling = false
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        finger = nil
                        set(index)
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: stop)
        .padding(EdgeInsets(top: -Self.reach.top, leading: -Self.reach.leading,
                            bottom: -Self.reach.bottom, trailing: -Self.reach.trailing))
    }

    private func set(_ index: Int) {
        let picked = Self.choices[index]
        if picked != minutes { minutes = picked }
    }

    /// 15, 30, 45 and ∞ under their stops.
    private var labels: [(position: Int, text: String)] {
        Self.choices.indices.compactMap { index in
            if index == Self.last { return (index, "∞") }
            return Self.choices[index] % 15 == 0 ? (index, "\(Self.choices[index])") : nil
        }
    }
}

/// A line across the middle of its frame, for the slider's dashed stretch.
private struct DashLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

#Preview {
    @Previewable @State var minutes = 30
    WalkSlider(minutes: $minutes)
        .padding()
}
