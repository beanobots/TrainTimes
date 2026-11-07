import SwiftUI

/// Comfortable Walk, for Settings and first-run setup: how far New Trip's rides may have you walk to
/// and from them (`NewTripView.walkChoices`). 15 to 45 minutes in fives, then No Limit at the far
/// end. The stretch past 45 is dashed and pulls back: the thumb follows the finger at a third of
/// its speed there, and only a drag to the very end lands on No Limit; let go short and it springs
/// back to 45. At No Limit the whole track turns the tint and the thumb carries the infinity sign.
struct WalkSlider: View {
    @Binding var minutes: Int
    /// How far into the resisting stretch the thumb's dragged, 0…1; 0 when it isn't.
    @State private var pull: CGFloat = 0

    private static let choices = NewTripView.walkChoices.map(\.minutes)
    private static let last = choices.count - 1
    private static let thumb: CGFloat = 28
    /// How much of the finger's travel the thumb follows past 45.
    private static let give: CGFloat = 0.35
    /// How far into the last stretch the finger must be let go for No Limit.
    private static let landing: CGFloat = 0.95

    /// `minutes`' stop; the one below if it's none of them.
    private var stop: Int {
        Self.choices.lastIndex { $0 <= minutes } ?? 0
    }

    private var noLimit: Bool { stop == Self.last }

    private var value: String {
        pull > 0 ? "\(Self.choices[Self.last - 1]) min…" : NewTripView.walkLabel(minutes)
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
        let x = { (position: CGFloat) in position / CGFloat(Self.last) * usable }
        let lastSolid = x(CGFloat(Self.last - 1)), end = x(CGFloat(Self.last))
        let thumbX = noLimit ? end : x(CGFloat(stop)) + pull * (end - lastSolid)
        return ZStack(alignment: .leading) {
            // 15–45, solid
            Capsule()
                .fill(.quaternary)
                .frame(width: lastSolid + Self.thumb / 2, height: 6)
            // Past 45: dashed until No Limit's picked, solid once it is
            DashLine()
                .stroke(noLimit ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary),
                        style: StrokeStyle(lineWidth: noLimit ? 6 : 3, lineCap: .round, dash: noLimit ? [] : [3, 5]))
                .frame(width: end - lastSolid, height: 6)
                .offset(x: lastSolid + Self.thumb / 2)
            Capsule()
                .fill(.tint)
                .frame(width: thumbX + Self.thumb / 2, height: 6)
            ZStack {
                Circle()
                    .fill(noLimit ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                if noLimit {
                    Image(systemName: "infinity")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: Self.thumb, height: Self.thumb)
            .offset(x: thumbX)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let raw = (drag.location.x - Self.thumb / 2) / usable * CGFloat(Self.last)
                    let lastStop = CGFloat(Self.last - 1)
                    if raw <= lastStop {
                        pull = 0
                        set(Int(max(0, raw).rounded()))
                    } else if noLimit && raw > lastStop + 0.5 {
                        // Already No Limit: it stays until dragged well back
                    } else {
                        set(Self.last - 1)
                        pull = min(1, (raw - lastStop) * Self.give)
                    }
                }
                .onEnded { drag in
                    let raw = (drag.location.x - Self.thumb / 2) / usable * CGFloat(Self.last)
                    withAnimation(.spring(duration: 0.3)) {
                        if pull > 0 && raw >= CGFloat(Self.last - 1) + Self.landing { set(Self.last) }
                        pull = 0
                    }
                }
        )
        .sensoryFeedback(.selection, trigger: stop)
        // The stops' labels, each under its place on the track
        .overlay(alignment: .topLeading) {
            ForEach(labels, id: \.position) { label in
                Text(label.text)
                    .font(label.position == Self.last ? .footnote.weight(.semibold) : .caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                    .position(x: x(CGFloat(label.position)) + Self.thumb / 2, y: Self.thumb + 10)
            }
        }
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
