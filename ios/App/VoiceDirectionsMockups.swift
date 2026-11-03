import SwiftUI

// Throwaway mockups of spoken walking directions in Settings. Delete once the real one's built.

private let margin: CGFloat = 16
private let card = RoundedRectangle(cornerRadius: 26, style: .continuous)
private let faint = Color.primary.opacity(0.05)

private func cardLabel(_ title: String) -> some View {
    Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
}

private func footnote(_ text: String) -> some View {
    Text(text)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 14)
}

private func iconRow<Trailing: View>(_ title: String, symbol: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
    HStack(spacing: 12) {
        Image(systemName: symbol)
            .foregroundStyle(.tint)
            .frame(width: 24)
        Text(title)
        Spacer(minLength: 8)
        trailing()
    }
    .padding(.horizontal, margin)
    .frame(minHeight: 52)
}

/// The Settings page around the new card: Trips above it, Alerts below, as now.
private struct MockSettingsPage: View {
    @State var speaks: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                cardLabel("Trips")
                VStack(spacing: 0) {
                    iconRow("Walk to and from a ride", symbol: "figure.walk") {
                        Text("15 min · 0.7 mi").foregroundStyle(.tint)
                    }
                    Divider().padding(.leading, 52)
                    iconRow("Citi Bike", symbol: "bicycle") {
                        Picker("Citi Bike", selection: .constant(0)) {
                            Text("Both").tag(0)
                            Text("Bikes").tag(1)
                            Text("E-bikes").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }
                .background(faint, in: card)
                footnote("New Trip offers rides with a walk up to this long at each end…")

                cardLabel("Walking Voice")
                voiceCard
                footnote(speaks
                         ? "Leeway reads each turn, crossing and station aloud while you walk, with the phone locked too, in your iPhone’s spoken voice from Settings › Accessibility › Read & Speak. Music gets quieter while it speaks and podcasts pause. Mute a walk from the speaker on its map."
                         : "Turn on to hear each turn, crossing and station while you walk.")

                cardLabel("Alerts")
                HStack(spacing: 8) {
                    ForEach(["clock.badge.exclamationmark", "xmark.octagon", "arrow.triangle.swap", "info.circle"],
                            id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 38)
                            .background(.orange, in: Capsule())
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 12)
                .background(faint, in: card)
            }
            .padding(.horizontal, margin)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    private var voiceCard: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $speaks.animation()) {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    Text("Speak directions")
                }
            }
            .padding(.horizontal, margin)
            .frame(minHeight: 52)

            if speaks {
                Divider().padding(.leading, 52)
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hear a Sample").foregroundStyle(.tint)
                        Text("“In 150 feet, turn right onto West 43rd Street.”")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, margin)
                .padding(.vertical, 8)
                .frame(minHeight: 52)
            }
        }
        .background(faint, in: card)
    }
}

#Preview("Settings – on") { MockSettingsPage(speaks: true) }
#Preview("Settings – off") { MockSettingsPage(speaks: false) }
