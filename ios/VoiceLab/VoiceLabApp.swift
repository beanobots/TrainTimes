import AVFoundation
import SwiftUI

/// Voice Lab: the phone's Voice Mixer at the desk, never shipped. The same Kokoro, phonemes,
/// spoken text and mixing (`VoiceMix`) as the phone, from ios/VoicePack's files, so a mix sounds
/// here as it will there. A mix is sent to the simulator or an iPhone as a voice file of its own
/// (Documents/VoicePack/voice-<name>.bin), which the phone's Voice Mixer then lists.
@main
struct VoiceLabApp: App {
    @State private var lab = Lab()

    var body: some Scene {
        Window("Voice Lab", id: "lab") {
            LabView(lab: lab)
                .frame(minWidth: 860, minHeight: 620)
                .task { lab.look() }
        }
        .windowResizability(.contentMinSize)
    }
}

/// What's being mixed and said, and the Kokoro saying it.
@Observable @MainActor
final class Lab {
    /// The pack's folder: ios/VoicePack, as `tools/make_voice_pack.py --extras` makes it.
    var folder: URL {
        didSet {
            UserDefaults.standard.set(folder.path, forKey: "folder")
            look()
        }
    }
    /// The voices there, by name: the phone's Voice tool's first, any others after.
    private(set) var voices: [String] = []
    /// The models there, by file.
    private(set) var models: [String] = []
    var model = UserDefaults.standard.string(forKey: "model") ?? "kokoro.onnx" {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    var mix = VoiceMix.saved {
        didSet { mix.save() }
    }
    var text = Lab.samples[0]
    /// Kokoro's speed (×), as the Voice tool's.
    var speed = 1.0
    /// Higher or lower, in cents.
    var pitch = 0.0
    /// What's happening, or went wrong, under the buttons.
    private(set) var status = ""
    private(set) var busy = false
    /// The last said, for Save Sound.
    private(set) var said: [Float] = []

    /// Instructions as walks say them (the phone's Voice tool's).
    static let samples = [
        "In 150 ft, turn right onto W 43rd St",
        "Continue on Kosciuszko St, then turn left onto Throop Ave",
        "Then cross Ocean Pkwy · No light and wide crossing - watch for cars",
        "Go down the stairs at the NW corner of 4 Av & 9 St",
        "You've arrived at Bedford Av.",
    ]

    static let titles = [
        "female": "Heart (shipped)", "af_bella": "Bella", "af_nicole": "Nicole", "af_sarah": "Sarah",
        "am_michael": "Michael", "am_fenrir": "Fenrir", "am_puck": "Puck", "am_adam": "Adam",
    ]
    private static let order = ["female", "af_bella", "af_nicole", "af_sarah", "am_michael", "am_fenrir", "am_puck", "am_adam"]
    private static let modelOrder = ["kokoro.onnx", "kokoro-fp16.onnx", "kokoro-fp32.onnx"]

    /// Each voice's style vectors, as its file has them.
    private var styles: [String: [Float]] = [:]
    private var kokoro: KokoroVoice?
    private var kokoroModel: String?
    private var phonemizer: Phonemizer?
    private let player = Player()

    init() {
        let saved = UserDefaults.standard.string(forKey: "folder")
        folder = saved.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projects/Leeway/ios/VoicePack")
    }

    static func title(of voice: String) -> String { titles[voice] ?? voice }

    /// The folder's voices and models, read again.
    func look() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var styles: [String: [Float]] = [:]
        for name in names where name.hasPrefix("voice-") && name.hasSuffix(".bin") {
            let voice = String(name.dropFirst("voice-".count).dropLast(".bin".count))
            if let data = try? Data(contentsOf: folder.appending(path: name)) {
                styles[voice] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        self.styles = styles
        let known = Self.order.filter { styles[$0] != nil }
        voices = known + styles.keys.filter { !known.contains($0) }.sorted()
        models = Self.modelOrder.filter(names.contains)
        if !models.contains(model) { model = models.first ?? "kokoro.onnx" }
        kokoro = nil
        phonemizer = try? Phonemizer(folder: folder)
        status = voices.isEmpty
            ? "No voices in \(folder.path). Run tools/make_voice_pack.py ios/VoicePack --extras, or choose the folder."
            : "\(voices.count) voices, \(models.count) models."
    }

    // MARK: Saying

    /// `text` in the mix, or in `voice` alone.
    func play(voice: String? = nil) {
        Task { await say(voice: voice) }
    }

    func stop() { player.stop() }

    private func say(voice: String?) async {
        guard !busy else { return }
        let mix = voice.map { VoiceMix(sound: [$0: 1]) } ?? self.mix
        guard let style = mix.styles(from: styles) else {
            status = "Nothing in the mix: give a voice some of it."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let kokoro = try await loaded()
            let spoken = SpokenText.spoken(text)
            let began = ContinuousClock.now
            guard let samples = try await kokoro.samples(for: spoken, styles: style, speed: Float(speed)) else {
                status = "Kokoro can't say: \(unknownWords(in: spoken).joined(separator: ", ")). The phone would use Apple's voice."
                return
            }
            let took = ContinuousClock.now - began
            said = samples
            player.play(samples, cents: pitch)
            let seconds = Double(samples.count) / KokoroVoice.sampleRate
            status = "“\(spoken)”: \(seconds.formatted(.number.precision(.fractionLength(1)))) s, made in \(took.formatted(.units(allowed: [.milliseconds])))."
        } catch {
            status = "Kokoro failed: \(error.localizedDescription)"
        }
    }

    /// Kokoro with the picked model, loaded once each time it's picked.
    private func loaded() async throws -> KokoroVoice {
        if let kokoro, kokoroModel == model { return kokoro }
        status = "Loading \(model)…"
        let folder = folder, model = model
        let voice = try await Task.detached(priority: .userInitiated) {
            try KokoroVoice(folder: folder, model: model)
        }.value
        kokoro = voice
        kokoroModel = model
        return voice
    }

    /// The words in `spoken` Kokoro has no phonemes for.
    private func unknownWords(in spoken: String) -> [String] {
        guard let phonemizer else { return ["(no lexicon)"] }
        return spoken.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && phonemizer.phonemes(for: $0) == nil }
    }

    // MARK: Mixing

    /// Two or three voices at random for how it sounds, another two for how it speaks, a
    /// touch more character (the phone's Surprise Me).
    func surprise() {
        func pick(_ count: Int) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: voices.shuffled().prefix(count).map {
                ($0, Double(Int.random(in: 4...20)) / 20)
            })
        }
        var next = mix
        next.sound = pick(.random(in: 2...3))
        next.speech = Bool.random() ? pick(2) : nil
        next.character = Double(Int.random(in: 20...30)) / 20
        next.wander = 0
        mix = next
        play()
    }

    /// What the mix is, in a line: "60% Bella, 40% Michael".
    var recipe: String {
        func shares(_ weights: [String: Double]) -> String {
            let present = weights.filter { $0.value > 0 && styles[$0.key] != nil }
            let total = present.values.reduce(0, +)
            return present.sorted { $0.value > $1.value }
                .map { "\(($0.value / total).formatted(.percent.precision(.fractionLength(0)))) \(Self.title(of: $0.key))" }
                .joined(separator: ", ")
        }
        var line = shares(mix.sound)
        if let speech = mix.speech { line += "; speaks like " + shares(speech) }
        if mix.character != 1 { line += "; character \(mix.character.formatted())×" }
        if mix.wander > 0 { line += "; wander \(mix.wander.formatted(.percent))" }
        return line
    }

    // MARK: Files

    /// The mix as a voice file: its style vectors, as Kokoro's own are.
    func voiceFile() -> Data? {
        mix.styles(from: styles).map { style in style.withUnsafeBufferPointer { Data(buffer: $0) } }
    }

    /// Saves the mix as a voice file in the pack's folder, so it can be mixed in turn.
    func keep(as name: String) {
        guard let data = voiceFile() else { return }
        let file = folder.appending(path: "voice-\(name).bin")
        do {
            try data.write(to: file)
            look()
            status = "Saved as \(file.lastPathComponent), now one of the voices here."
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// The last said, as a WAV file.
    func saveSound(to url: URL) {
        do {
            try Player.write(said, to: url)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }

    var hasSound: Bool { !said.isEmpty }

    // MARK: Sending

    /// Sends the mix as voice-<name>.bin into the app's Documents/VoicePack on `target`.
    func send(as name: String, to target: Phones.Target) {
        guard let data = voiceFile() else {
            status = "Nothing in the mix to send."
            return
        }
        let file = "voice-\(name).bin"
        busy = true
        status = "Sending \(file) to \(target.name)…"
        Task {
            defer { busy = false }
            do {
                try await Phones.send(data, as: file, to: target)
                status = "Sent \(file) to \(target.name). On the phone: Voice Mixer, give \(name) all of it, Use for Walks."
            } catch {
                status = "Couldn't send: \(error.localizedDescription)"
            }
        }
    }
}

/// Plays Kokoro's samples, raised or lowered as the phone does (`AVAudioUnitTimePitch`).
@MainActor
final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    static let format = AVAudioFormat(standardFormatWithSampleRate: KokoroVoice.sampleRate, channels: 1)!

    init() {
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: Self.format)
        engine.connect(pitch, to: engine.mainMixerNode, format: Self.format)
    }

    func play(_ samples: [Float], cents: Double) {
        guard let buffer = Self.buffer(samples) else { return }
        stop()
        pitch.pitch = Float(cents)
        pitch.bypass = cents == 0
        if !engine.isRunning { try? engine.start() }
        node.scheduleBuffer(buffer)
        node.play()
    }

    func stop() {
        if node.isPlaying { node.stop() }
    }

    static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { buffer.floatChannelData?[0].update(from: base, count: samples.count) }
        }
        return buffer
    }

    static func write(_ samples: [Float], to url: URL) throws {
        guard let buffer = buffer(samples) else { return }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
