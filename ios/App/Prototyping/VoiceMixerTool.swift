import SwiftUI

/// Mixes a walking voice of one's own from Kokoro's (`VoiceMix`, kept across launches): how
/// much of each voice it sounds like, and apart from that how much it speaks like, then more
/// or less character and random nudges. Letting go of a slider plays the sample in the mix;
/// Use for Walks makes it the walks' voice (My Mix in the Voice tool). Only the voices copied
/// in can be mixed: just Heart in the App Store's pack.
struct VoiceMixerTool: View {
    @State private var mix = VoiceMix.saved
    @AppStorage(VoiceStyle.voiceKey) private var walkVoice = VoiceStyle.standard.voice
    /// The voices on this phone, by name: none until the pack's downloaded.
    @State private var voices: [String] = []
    @State private var sample = VoiceTool.samples[0]

    private var separateSpeech: Binding<Bool> {
        Binding {
            mix.speech != nil
        } set: { on in
            mix.speech = on ? mix.sound : nil
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Instruction", selection: $sample) {
                    ForEach(VoiceTool.samples, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                Button("Play Mix", systemImage: "play.fill", action: play)
                Button("Play Heart (Shipped)", systemImage: "play") {
                    var style = VoiceStyle.current
                    style.voice = WalkVoice.kokoroVoice
                    style.mix = nil
                    WalkVoice.shared.sample(sample, style: style)
                }
                Button("Surprise Me", systemImage: "dice", action: surprise)
                    .disabled(voices.count < 2)
            } footer: {
                Text(voices.isEmpty
                     ? "The voice pack isn't on this phone yet: Apple's voice speaks."
                     : "Letting go of a slider plays the mix. Speed, pauses, pitch and delivery are the Voice tool's.")
            }

            Section {
                ForEach(voices, id: \.self) { name in
                    share(name, in: $mix.sound)
                }
            } header: {
                Text("Sounds Like")
            } footer: {
                Text("Tone, depth and breathiness: what Kokoro's decoder hears.")
            }

            Section {
                Toggle("Speaks Like Another Mix", isOn: separateSpeech)
                if mix.speech != nil {
                    ForEach(voices, id: \.self) { name in
                        share(name, in: Binding { mix.speech ?? [:] } set: { mix.speech = $0 })
                    }
                }
            } header: {
                Text("Speaks Like")
            } footer: {
                Text("Rhythm, word lengths and the rise and fall of the sentence, apart from how it sounds: Bella's sound with Michael's way of speaking, say.")
            }

            Section {
                LabeledContent("Character", value: characterLabel)
                Slider(value: $mix.character, in: 0...2.5, step: 0.05, onEditingChanged: playOnRelease)
                LabeledContent("Wander", value: mix.wander == 0 ? "None" : mix.wander.formatted(.percent.precision(.fractionLength(0))))
                Slider(value: $mix.wander, in: 0...1.5, step: 0.05, onEditingChanged: playOnRelease)
                if mix.wander > 0 {
                    Button("Wander Somewhere Else", systemImage: "shuffle") {
                        mix.seed = .random(in: 1...UInt64.max)
                        play()
                    }
                }
            } header: {
                Text("Shape")
            } footer: {
                Text("Character: 0 is the average of every voice here, 1 the mix, above that further from the average, an exaggeration of it. Wander nudges every part of the voice at random, by as much as the voices differ there; past 100% it can break up.")
            }

            Section {
                Toggle("Use for Walks", isOn: Binding {
                    walkVoice == VoiceMix.name
                } set: { on in
                    walkVoice = on ? VoiceMix.name : VoiceStyle.standard.voice
                })
                .disabled(voices.isEmpty)
                Button("Start Over", role: .destructive) { mix = .fresh }
                    .disabled(mix == .fresh)
            } footer: {
                Text("Used for walks, it's My Mix in the Voice tool, with the mix as it is here.")
            }
        }
        .onAppear(perform: look)
        .onChange(of: mix) { mix.save() }
    }

    /// A slider for `name`'s share of `weights`, with its percentage of the total.
    private func share(_ name: String, in weights: Binding<[String: Double]>) -> some View {
        let value = weights.wrappedValue[name] ?? 0
        let total = weights.wrappedValue.filter { voices.contains($0.key) }.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title(of: name),
                           value: total > 0 && value > 0 ? (value / total).formatted(.percent.precision(.fractionLength(0))) : "—")
            Slider(value: Binding { value } set: { weights.wrappedValue[name] = $0 == 0 ? nil : $0 },
                   in: 0...1, step: 0.05, onEditingChanged: playOnRelease)
        }
    }

    private var characterLabel: String {
        switch mix.character {
        case 0: "Average of All"
        case 1: "As Mixed"
        default: "\(mix.character.formatted(.number.precision(.fractionLength(2))))×"
        }
    }

    private func title(of name: String) -> String {
        VoiceStyle.voices.first { $0.name == name }?.title ?? name
    }

    private func playOnRelease(_ editing: Bool) {
        if !editing { play() }
    }

    /// The sample in the mix, at the Voice tool's speed, pauses, pitch and delivery.
    private func play() {
        var style = VoiceStyle.current
        style.voice = VoiceMix.name
        style.mix = mix
        WalkVoice.shared.sample(sample, style: style)
    }

    /// Two or three voices at random for how it sounds, another two for how it speaks, a
    /// touch more character.
    private func surprise() {
        func pick(_ count: Int) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: voices.shuffled().prefix(count).map {
                ($0, Double(Int.random(in: 4...20)) / 20)
            })
        }
        mix.sound = pick(.random(in: 2...3))
        mix.speech = Bool.random() ? pick(2) : nil
        mix.character = Double(Int.random(in: 20...30)) / 20
        mix.wander = 0
        play()
    }

    /// The voices in the pack's folder, in the Voice tool's order, any others after.
    private func look() {
        guard let folder = VoicePack.folder(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            voices = []
            return
        }
        let found = names.filter { $0.hasPrefix("voice-") && $0.hasSuffix(".bin") }
            .map { String($0.dropFirst("voice-".count).dropLast(".bin".count)) }
        let known = VoiceStyle.voices.map(\.name).filter(found.contains)
        voices = known + found.filter { !known.contains($0) }.sorted()
    }
}

#Preview {
    NavigationStack { VoiceMixerTool() }
}
