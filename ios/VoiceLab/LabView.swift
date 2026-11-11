import SwiftUI
import UniformTypeIdentifiers

/// The mixer on the left (as the phone's Voice Mixer has it), what's said on the right.
struct LabView: View {
    @Bindable var lab: Lab
    @State private var targets = [Phones.Target.simulator]
    @AppStorage("target") private var targetID = Phones.Target.simulator.id
    @AppStorage("name") private var name = "mix1"
    @State private var choosingFolder = false

    var body: some View {
        HSplitView {
            mixer
                .frame(minWidth: 380, idealWidth: 420)
            speaker
                .frame(minWidth: 420)
        }
        .task { targets = await Phones.targets() }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { lab.folder = url }
        }
    }

    // MARK: The mixer

    private var mixer: some View {
        Form {
            Section {
                ForEach(lab.voices, id: \.self) { voice in
                    share(voice, in: $lab.mix.sound)
                }
            } header: {
                Text("Sounds Like")
            } footer: {
                Text("Tone, depth and breathiness: the first half of each voice, what Kokoro's decoder hears.")
            }

            Section {
                Toggle("Speaks Like Another Mix", isOn: Binding {
                    lab.mix.speech != nil
                } set: { on in
                    lab.mix.speech = on ? lab.mix.sound : nil
                })
                if lab.mix.speech != nil {
                    ForEach(lab.voices, id: \.self) { voice in
                        share(voice, in: Binding { lab.mix.speech ?? [:] } set: { lab.mix.speech = $0 })
                    }
                }
            } header: {
                Text("Speaks Like")
            } footer: {
                Text("Rhythm, word lengths and the rise and fall of the sentence: the second half.")
            }

            Section {
                LabeledContent("Character", value: lab.mix.character == 1 ? "As Mixed" : "\(lab.mix.character.formatted(.number.precision(.fractionLength(2))))×")
                Slider(value: $lab.mix.character, in: 0...2.5, step: 0.05, onEditingChanged: playOnRelease)
                LabeledContent("Wander", value: lab.mix.wander == 0 ? "None" : lab.mix.wander.formatted(.percent.precision(.fractionLength(0))))
                Slider(value: $lab.mix.wander, in: 0...1.5, step: 0.05, onEditingChanged: playOnRelease)
                if lab.mix.wander > 0 {
                    Button("Wander Somewhere Else", systemImage: "shuffle") {
                        lab.mix.seed = .random(in: 1...UInt64.max)
                        lab.play()
                    }
                }
            } header: {
                Text("Shape")
            } footer: {
                Text("Character: 0 is the average of every voice here, above 1 an exaggeration of the mix. Wander nudges the voice at random; past 100% it can break up.")
            }

            Section {
                HStack {
                    Button("Surprise Me", systemImage: "dice", action: lab.surprise)
                        .disabled(lab.voices.count < 2)
                    Spacer()
                    Button("Start Over", role: .destructive) { lab.mix = .fresh }
                        .disabled(lab.mix == .fresh)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A slider for `voice`'s share of `weights`, with its percentage of the total and a
    /// button to hear it alone.
    private func share(_ voice: String, in weights: Binding<[String: Double]>) -> some View {
        let value = weights.wrappedValue[voice] ?? 0
        let total = weights.wrappedValue.filter { lab.voices.contains($0.key) }.values.reduce(0, +)
        return HStack {
            Text(Lab.title(of: voice))
                .frame(width: 110, alignment: .leading)
            Slider(value: Binding { value } set: { weights.wrappedValue[voice] = $0 == 0 ? nil : $0 },
                   in: 0...1, step: 0.05, onEditingChanged: playOnRelease)
            Text(total > 0 && value > 0 ? (value / total).formatted(.percent.precision(.fractionLength(0))) : "—")
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)
            Button("Hear \(Lab.title(of: voice)) Alone", systemImage: "speaker.wave.2") { lab.play(voice: voice) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    private func playOnRelease(_ editing: Bool) {
        if !editing { lab.play() }
    }

    // MARK: What's said

    private var speaker: some View {
        Form {
            Section("Say") {
                TextEditor(text: $lab.text)
                    .font(.title3)
                    .frame(minHeight: 90)
                Picker("Instruction", selection: $lab.text) {
                    ForEach(Lab.samples, id: \.self) { Text($0).tag($0) }
                    if !Lab.samples.contains(lab.text) { Text("Your Own").tag(lab.text) }
                }
                HStack {
                    Button("Play Mix", systemImage: "play.fill") { lab.play() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                    Button("Play Heart (Shipped)", systemImage: "play") { lab.play(voice: "female") }
                    Button("Stop", systemImage: "stop.fill", action: lab.stop)
                        .keyboardShortcut(".", modifiers: .command)
                    if lab.busy { ProgressView().controlSize(.small) }
                }
                Text(lab.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Voice") {
                LabeledContent("Speed", value: "\(lab.speed.formatted(.number.precision(.fractionLength(2))))×")
                Slider(value: $lab.speed, in: 0.7...1.4, step: 0.05, onEditingChanged: playOnRelease)
                LabeledContent("Pitch", value: lab.pitch == 0 ? "As It Comes" : "\(lab.pitch > 0 ? "+" : "")\((lab.pitch / 100).formatted()) Semitones")
                Slider(value: $lab.pitch, in: -400...400, step: 25, onEditingChanged: playOnRelease)
                Picker("Model", selection: $lab.model) {
                    ForEach(lab.models, id: \.self) { Text(modelTitle($0)).tag($0) }
                }
            }

            Section {
                LabeledContent("Mix", value: lab.recipe.isEmpty ? "—" : lab.recipe)
                TextField("Name", text: $name)
                Picker("Send To", selection: $targetID) {
                    ForEach(targets) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Button("Send to Phone", systemImage: "iphone.and.arrow.forward") {
                        if let target = targets.first(where: { $0.id == targetID }) { lab.send(as: fileName, to: target) }
                    }
                    Button("Keep Here as a Voice", systemImage: "plus.circle") { lab.keep(as: fileName) }
                    Button("Save Sound…", systemImage: "square.and.arrow.down", action: saveSound)
                        .disabled(!lab.hasSound)
                }
                .disabled(lab.busy || fileName.isEmpty)
            } header: {
                Text("Keep")
            } footer: {
                Text("Sent, it's voice-\(fileName).bin in Leeway's Documents/VoicePack: debug builds only, Leeway relaunched to see it. Kept here, it's a voice to mix with. The sound's saved without the pitch change.")
            }

            Section("Pack") {
                LabeledContent("Folder") {
                    Text(lab.folder.path).lineLimit(1).truncationMode(.head)
                }
                HStack {
                    Button("Choose…") { choosingFolder = true }
                    Button("Look Again", action: lab.look)
                    Button("Show in Finder") { NSWorkspace.shared.open(lab.folder) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The name, as a file can have it: letters, digits, _ and -.
    private var fileName: String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    /// The last said, as a WAV file wherever's picked.
    private func saveSound() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(fileName).wav"
        if panel.runModal() == .OK, let url = panel.url { lab.saveSound(to: url) }
    }

    private func modelTitle(_ file: String) -> String {
        switch file {
        case "kokoro.onnx": "8-bit + Half (shipped)"
        case "kokoro-fp16.onnx": "Half"
        case "kokoro-fp32.onnx": "Full"
        default: file
        }
    }
}
