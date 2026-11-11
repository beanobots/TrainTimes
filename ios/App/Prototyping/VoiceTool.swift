import SwiftUI

/// Tries how the walking voice sounds (`VoiceStyle`, kept across launches): Kokoro's model and
/// voice, its speed and pauses between phrases, its pitch and an even or lively delivery, with
/// a sample to compare, Apple's voice too. The bigger models and other voices aren't in the App
/// Store's pack: they're copied into debug builds' Documents/VoicePack
/// (tools/make_voice_pack.py --extras), and where they're missing the pack's own are used.
struct VoiceTool: View {
    @AppStorage(VoiceStyle.modelKey) private var model = VoiceStyle.standard.model
    @AppStorage(VoiceStyle.voiceKey) private var voice = VoiceStyle.standard.voice
    @AppStorage(VoiceStyle.speedKey) private var speed = VoiceStyle.standard.speed
    @AppStorage(VoiceStyle.pauseKey) private var pause = VoiceStyle.standard.pause
    @AppStorage(VoiceStyle.pitchKey) private var pitch = VoiceStyle.standard.pitch
    @AppStorage(VoiceStyle.deliveryKey) private var delivery = VoiceStyle.standard.delivery
    /// The pack's files on this phone, by name: none until it's downloaded.
    @State private var files: Set<String> = []
    @State private var hasPack = false
    @State private var sample = Self.samples[0]

    /// Instructions as walks say them, for the sample (the Voice Mixer's too).
    static let samples = [
        "In 150 ft, turn right onto W 43rd St",
        "Continue on Kosciuszko St, then turn left onto Throop Ave",
        "Then cross Ocean Pkwy · No light and wide crossing - watch for cars",
        "Go down the stairs at the NW corner of 4 Av & 9 St",
        "You've arrived at Bedford Av.",
    ]

    private var isStandard: Bool {
        VoiceStyle(model: model, voice: voice, speed: speed, pause: pause, pitch: pitch, delivery: delivery)
            == .standard
    }

    var body: some View {
        Form {
            Section {
                Picker("Instruction", selection: $sample) {
                    ForEach(Self.samples, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                Button("Play Sample", systemImage: "play.fill") { WalkVoice.shared.sample(sample) }
                Button("Play in Apple's Voice", systemImage: "apple.logo") { WalkVoice.shared.sample(sample, apple: true) }
            } footer: {
                Text(hasPack
                     ? "Kokoro speaks. A newly picked model takes a few seconds to load the first time."
                     : "The voice pack isn't on this phone yet: Apple's voice speaks.")
            }

            Section {
                Picker("Model", selection: $model) {
                    ForEach(VoiceStyle.Model.allCases) { option in
                        Text(option.title).tag(option)
                            .selectionDisabled(!files.contains(option.file))
                            .foregroundStyle(files.contains(option.file) ? .primary : .secondary)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Model")
            } footer: {
                Text(missingNote(VoiceStyle.Model.allCases.map(\.file)))
            }

            Section {
                Picker("Voice", selection: $voice) {
                    ForEach(VoiceStyle.voices, id: \.name) { option in
                        Text(option.title).tag(option.name)
                            .selectionDisabled(!has(option.name))
                            .foregroundStyle(has(option.name) ? .primary : .secondary)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Voice")
            } footer: {
                Text(missingNote(VoiceStyle.voices.map(\.name).filter { $0 != VoiceMix.name }.map { "voice-\($0).bin" })
                     + " My Mix is made in the Voice Mixer.")
            }

            Section {
                LabeledContent("Speed", value: "\(speed.formatted(.number.precision(.fractionLength(2))))×")
                Slider(value: $speed, in: 0.7...1.4, step: 0.05)
                LabeledContent("Pauses Between Phrases", value: pause == 0 ? "None" : "\(pause.formatted(.number.precision(.fractionLength(2)))) s")
                Slider(value: $pause, in: 0...0.8, step: 0.05)
            } header: {
                Text("Cadence")
            } footer: {
                Text("With pauses, each phrase (to a comma or full stop) is said on its own with silence after.")
            }

            Section {
                LabeledContent("Pitch", value: pitch == 0 ? "As It Comes" : "\(pitch > 0 ? "+" : "")\((pitch / 100).formatted(.number.precision(.fractionLength(0...2)))) Semitones")
                Slider(value: $pitch, in: -400...400, step: 25)
                Picker("Delivery", selection: $delivery) {
                    ForEach(VoiceStyle.Delivery.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Intonation")
            } footer: {
                Text(deliveryNote)
            }

            Section {
                Button("Back to Shipped", role: .destructive) {
                    model = VoiceStyle.standard.model
                    voice = VoiceStyle.standard.voice
                    speed = VoiceStyle.standard.speed
                    pause = VoiceStyle.standard.pause
                    pitch = VoiceStyle.standard.pitch
                    delivery = VoiceStyle.standard.delivery
                }
                .disabled(isStandard)
            }
        }
        .onAppear(perform: look)
    }

    private var deliveryNote: String {
        switch delivery {
        case .natural: "Natural: Kokoro's own reading, as shipped."
        case .even: "Even: every phrase a statement of its own, ending low, all at one pace."
        case .lively: "Lively: lead-ins lift and go a touch quicker; the instruction lands with an exclamation, a touch slower. Apple's voice follows speed, pitch and pauses, not delivery."
        }
    }

    /// The pack's files, for which choices can be picked.
    private func look() {
        guard let folder = VoicePack.folder() else {
            hasPack = false
            files = []
            return
        }
        hasPack = true
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        files = Set(names)
    }

    /// Whether `voice` can be picked: its file's on this phone, or it's My Mix and the pack is.
    private func has(_ voice: String) -> Bool {
        voice == VoiceMix.name ? hasPack : files.contains("voice-\(voice).bin")
    }

    /// Says which of `names` aren't on this phone, and why.
    private func missingNote(_ names: [String]) -> String {
        guard hasPack else { return "Once the voice pack's downloaded." }
        let missing = names.filter { !files.contains($0) }.count
        guard missing > 0 else { return "All copied in." }
        #if DEBUG
        return "\(missing) not copied in: run tools/make_voice_pack.py --extras and copy them into Documents/VoicePack. Never in the App Store's pack."
        #else
        return "Only the shipped one is in the App Store's pack; the others are for debug builds."
        #endif
    }
}

#Preview {
    NavigationStack { VoiceTool() }
}
