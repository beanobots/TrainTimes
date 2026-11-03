import SwiftUI

// Throwaway mockups of spoken walking directions in Settings. Delete once the real one's built.

/// A built-in voice as the picker lists it.
private struct MockVoice: Identifiable {
    let name: String
    let accent: String
    let quality: String
    var id: String { name }
}

private let mockVoices = [
    MockVoice(name: "Ava", accent: "American", quality: "Premium"),
    MockVoice(name: "Zoe", accent: "American", quality: "Premium"),
    MockVoice(name: "Serena", accent: "British", quality: "Premium"),
    MockVoice(name: "Evan", accent: "American", quality: "Enhanced"),
    MockVoice(name: "Daniel", accent: "British", quality: "Enhanced"),
    MockVoice(name: "Karen", accent: "Australian", quality: "Enhanced"),
    MockVoice(name: "Samantha", accent: "American", quality: "Default"),
    MockVoice(name: "Fred", accent: "American", quality: "Default"),
]

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
    @State private var speed = 1

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
                         ? "Leeway reads each turn, crossing and station aloud while you walk, with the phone locked too. Music gets quieter while it speaks and podcasts pause. Mute a walk from the speaker on its map."
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
                iconRow("Voice", symbol: "person.wave.2") {
                    Text("Ava · Premium").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Divider().padding(.leading, 52)
                iconRow("Speed", symbol: "gauge.with.dots.needle.50percent") {
                    Picker("Speed", selection: $speed) {
                        Text("Slower").tag(0)
                        Text("Normal").tag(1)
                        Text("Faster").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
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

/// The voice picker, pushed from the Voice row: English voices on the phone, best first, each
/// with a play button; the picked one ticked.
private struct MockVoicePicker: View {
    private let picked = "Ava"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(["Premium", "Enhanced", "Default"], id: \.self) { quality in
                        cardLabel(quality)
                        VStack(spacing: 0) {
                            let voices = mockVoices.filter { $0.quality == quality }
                            ForEach(voices) { voice in
                                row(voice)
                                if voice.id != voices.last?.id {
                                    Divider().padding(.leading, 52)
                                }
                            }
                        }
                        .background(faint, in: card)
                        .padding(.bottom, 14)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Get More Voices").foregroundStyle(.tint)
                            Text("Settings › Accessibility › Read & Speak › Voices")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, margin)
                    .padding(.vertical, 8)
                    .frame(minHeight: 52)
                    .background(faint, in: card)
                    footnote("Premium and Enhanced voices sound most natural. They download in the Settings app, then show here.")
                }
                .padding(.horizontal, margin)
                .padding(.top, 8)
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ voice: MockVoice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 24)
                .opacity(voice.name == picked ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(voice.name)
                Text(voice.accent).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "play.fill")
                .font(.footnote)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: Circle())
        }
        .padding(.horizontal, margin)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
    }
}

#Preview("Settings – on") { MockSettingsPage(speaks: true) }
#Preview("Settings – off") { MockSettingsPage(speaks: false) }
#Preview("Voice picker") { MockVoicePicker() }
