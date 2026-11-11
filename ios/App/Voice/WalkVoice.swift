import AVFoundation
import Foundation
import Kokoro

/// Speaks walking directions (Settings' Speak Directions, on unless turned off): Kokoro's
/// voice once its asset pack is on the phone (`VoicePack`), Apple's best installed voice
/// before then, or for an instruction with a word Kokoro can't say. Music gets quieter and
/// spoken audio (podcasts, audiobooks) pauses while it talks, as with Apple Maps; the newest
/// instruction cuts off one still being said.
@MainActor
final class WalkVoice: NSObject {
    static let shared = WalkVoice()
    nonisolated static let log = AppLog(category: "WalkVoice")

    /// Speak Directions, on unless turned off: the walking map's sound button (`WalkSound`).
    static let speaksKey = "walkSpeaks"
    static var speaks: Bool {
        get { UserDefaults.standard.object(forKey: speaksKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: speaksKey) }
    }

    /// Kokoro's voice in its pack (voice-female.bin): af_heart.
    nonisolated static let kokoroVoice = "female"

    private var kokoro: KokoroVoice?
    /// The model file Kokoro's loaded (or loading) from: another picked reloads it.
    private var kokoroModel: String?
    /// Loading Kokoro, or tried and failed: not tried again until the pack changes.
    private var loading: Task<KokoroVoice?, Never>?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Kokoro's pitch, raised or lowered (`VoiceStyle.pitch`); passed straight through at 0.
    private let pitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: KokoroVoice.sampleRate, channels: 1)!
    private let apple = AVSpeechSynthesizer()
    /// Audio made ahead for what's coming up, by its spoken text and how it's said: the last few.
    private var made: [(key: String, samples: [Float])] = []
    private var making: [String: Task<[Float]?, Never>] = [:]
    /// Said now, so a newer one can stop it, and the audio session be let go once it's done.
    private var current = 0

    override private init() {
        super.init()
        engine.attach(player)
        engine.attach(pitch)
        pitch.bypass = true
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        apple.usesApplicationAudioSession = true
        apple.delegate = self
    }

    // MARK: Speaking

    /// Says `text` (as written: `SpokenText` reads it out), stopping anything being said.
    func say(_ text: String) {
        guard Self.speaks else { return }
        speak(text)
    }

    /// Says `text` whether or not directions are spoken: Prototyping's Voice tool's sample,
    /// in Apple's voice if `apple`, as `style` has it (the Voice Mixer's mix) if given.
    func sample(_ text: String, apple: Bool = false, style: VoiceStyle? = nil) {
        speak(text, apple: apple, style: style)
    }

    private func speak(_ text: String, apple: Bool = false, style: VoiceStyle? = nil) {
        let spoken = SpokenText.spoken(text)
        let style = style ?? .current
        current += 1
        let turn = current
        stopPlaying()
        Task {
            let samples = apple ? nil : await self.samples(for: spoken, style: style)
            guard turn == self.current else { return }
            if let samples, !samples.isEmpty {
                self.play(samples, turn: turn, pitch: style.pitch)
            } else {
                self.sayWithApple(spoken)
            }
        }
    }

    /// Makes `text`'s audio now, for saying soon: the next turn's, as its step comes up.
    func prepare(_ text: String) {
        guard Self.speaks else { return }
        let spoken = SpokenText.spoken(text)
        let key = VoiceStyle.current.key + spoken
        guard !made.contains(where: { $0.key == key }), making[key] == nil else { return }
        _ = Task { await self.samples(for: spoken) }
    }

    /// Stops speaking, as the walk ends.
    func stop() {
        current += 1
        stopPlaying()
        release()
    }

    /// Kokoro's audio for `spoken`: made already, being made, or made now; nil without the voice
    /// or for words it can't say.
    private func samples(for spoken: String, style: VoiceStyle = .current) async -> [Float]? {
        // By how it's said too: a voice, model or speed picked since makes it again
        let key = style.key + spoken
        if let found = made.first(where: { $0.key == key }) { return found.samples }
        if let task = making[key] { return await task.value }
        let task = Task<[Float]?, Never> {
            guard let voice = await self.voice() else { return nil }
            do {
                let began = ContinuousClock.now
                let samples = try await Self.make(spoken, with: voice, style: style)
                let took = ContinuousClock.now - began
                if let samples {
                    let seconds = Double(samples.count) / KokoroVoice.sampleRate
                    Self.log.info("Kokoro: \(took.formatted(.units(allowed: [.milliseconds]))) for \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
                } else {
                    Self.log.notice("Kokoro can't say “\(spoken)”: Apple's voice instead")
                }
                return samples
            } catch {
                Self.log.error("Kokoro failed: \(error.localizedDescription)")
                return nil
            }
        }
        making[key] = task
        let samples = await task.value
        making[key] = nil
        if let samples {
            made.append((key, samples))
            if made.count > 6 { made.removeFirst() }
        }
        return samples
    }

    /// `spoken` in Kokoro's voice as `style` has it. At its defaults it's said in one go, as
    /// shipped; with pauses or an even or lively delivery, phrase by phrase (`VoiceStyle.phrases`),
    /// each made on its own with silence between.
    private nonisolated static func make(_ spoken: String, with kokoro: KokoroVoice, style: VoiceStyle) async throws -> [Float]? {
        // A voice not copied in: the pack's own
        let name = await kokoro.voices.contains(style.voice) ? style.voice : kokoroVoice
        // The Voice Mixer's own, made from the voices there are
        var voices: [String: [Float]] = [:]
        if style.mix != nil {
            for voice in await kokoro.voices { voices[voice] = await kokoro.styles(of: voice) }
        }
        let mixed = style.mix?.styles(from: voices)
        func say(_ text: String, speed: Double, ending: Character? = nil) async throws -> [Float]? {
            if let mixed {
                return try await kokoro.samples(for: text, styles: mixed, speed: Float(speed), ending: ending)
            }
            return try await kokoro.samples(for: text, voice: name, speed: Float(speed), ending: ending)
        }
        guard style.phrased else {
            return try await say(spoken, speed: style.speed)
        }
        let phrases = VoiceStyle.phrases(of: spoken)
        let gap = [Float](repeating: 0, count: Int(style.pause * KokoroVoice.sampleRate))
        var out: [Float] = []
        for (index, phrase) in phrases.enumerated() {
            let (ending, speed) = style.delivery.say(phrase, last: index == phrases.count - 1)
            guard let part = try await say(phrase, speed: style.speed * speed, ending: ending)
            else { return nil }
            if !out.isEmpty { out += gap }
            out += part
        }
        return out
    }

    /// Kokoro, loaded the first time it's needed once its pack is on the phone; loaded again
    /// with another model once one's picked (Prototyping's Voice tool).
    private func voice() async -> KokoroVoice? {
        if let folder = VoicePack.folder() {
            let model = VoiceStyle.current.modelFile(in: folder)
            if model != kokoroModel {
                kokoro = nil
                loading = nil
                made.removeAll()
                kokoroModel = model
            }
        }
        if let kokoro { return kokoro }
        if loading == nil {
            guard let folder = VoicePack.folder() else {
                VoicePack.ensure()
                return nil
            }
            let model = kokoroModel ?? "kokoro.onnx"
            loading = Task.detached(priority: .userInitiated) {
                do {
                    return try KokoroVoice(folder: folder, model: model)
                } catch {
                    Self.log.error("Kokoro didn't load \(model): \(error.localizedDescription)")
                    // A bigger model that won't load: the pack's own
                    guard model != "kokoro.onnx" else { return nil }
                    return try? KokoroVoice(folder: folder)
                }
            }
        }
        kokoro = await loading?.value
        // Failed (a file missing or bad): tried again for the next sentence, not left off till
        // the app's next launch
        if kokoro == nil { loading = nil }
        return kokoro
    }

    /// The pack's downloaded: Kokoro's tried again, for the next instruction.
    func packArrived() {
        if kokoro == nil { loading = nil }
    }

    // MARK: Playing

    private func play(_ samples: [Float], turn: Int, pitch cents: Double) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        guard activate() else { return }
        pitch.pitch = Float(cents)
        pitch.bypass = cents == 0
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Self.log.error("Couldn't start audio: \(error.localizedDescription)")
            return
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, turn == self.current else { return }
                self.release()
            }
        }
        player.play()
    }

    /// Apple's voice: the best installed for American English, Premium over Enhanced over the
    /// phone's own, a woman's as Kokoro's is where there's one, at its usual pace. It follows
    /// the Voice tool's speed, pitch and pauses (phrase by phrase, with a wait after each), not
    /// its even or lively delivery.
    private func sayWithApple(_ spoken: String) {
        guard activate() else { return }
        let style = VoiceStyle.current
        let phrases = style.pause > 0 ? VoiceStyle.phrases(of: spoken) : [spoken]
        for (index, phrase) in phrases.enumerated() {
            let utterance = AVSpeechUtterance(string: phrase)
            utterance.voice = Self.appleVoice
            if style.speed != 1 {
                utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * Float(style.speed),
                                         AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            }
            if style.pitch != 0 {
                utterance.pitchMultiplier = Float(min(max(pow(2, style.pitch / 1200), 0.5), 2))
            }
            if index < phrases.count - 1 { utterance.postUtteranceDelay = style.pause }
            apple.speak(utterance)
            appleLast = ObjectIdentifier(utterance)
        }
    }

    /// The last of Apple's utterances queued: the audio's let go only once it's said.
    private var appleLast: ObjectIdentifier?

    static var appleVoice: AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        let matching = english.filter { $0.gender == .female }
        let voices = matching.isEmpty ? english : matching
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func stopPlaying() {
        if player.isPlaying { player.stop() }
        if apple.isSpeaking { apple.stopSpeaking(at: .immediate) }
    }

    // MARK: The audio session

    /// Ready to speak over other audio: music ducked, podcasts paused, even with the phone locked.
    private func activate() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            Self.log.error("Couldn't take the audio: \(error.localizedDescription)")
            return false
        }
    }

    /// Lets music back up, and paused podcasts carry on.
    private func release() {
        if engine.isRunning { engine.pause() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension WalkVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finished = ObjectIdentifier(utterance)
        Task { @MainActor in
            // Not between phrases, with the next still to come after its pause
            guard finished == self.appleLast else { return }
            if !self.apple.isSpeaking && !self.player.isPlaying { self.release() }
        }
    }
}

/// How the walking voice sounds, picked in Prototyping's Voice tool (`VoiceTool`) and kept
/// across launches. At its defaults it's the voice as shipped: the pack's model and af_heart,
/// said in one go at Kokoro's own pace and pitch. The bigger models and other voices are only
/// in debug builds' copied-in files, never the App Store pack: picked without their files,
/// the pack's own are used.
struct VoiceStyle: Equatable {
    /// Kokoro's model: onnx-community's Kokoro-82M-v1.0-ONNX, by its weights.
    enum Model: String, CaseIterable, Identifiable {
        /// 8-bit weights, half-precision maths (model_q8f16, 86 MB): the pack's.
        case q8f16
        /// Half precision (model_fp16, 163 MB).
        case fp16
        /// Full precision (model.onnx, 326 MB).
        case fp32

        var id: Self { self }

        var file: String {
            switch self {
            case .q8f16: "kokoro.onnx"
            case .fp16: "kokoro-fp16.onnx"
            case .fp32: "kokoro-fp32.onnx"
            }
        }

        var title: String {
            switch self {
            case .q8f16: "8-bit + Half (86 MB)"
            case .fp16: "Half (163 MB)"
            case .fp32: "Full (326 MB)"
            }
        }
    }

    /// How phrases are ended and paced.
    enum Delivery: String, CaseIterable, Identifiable {
        /// As shipped: Kokoro's own reading, commas lifting into what follows.
        case natural
        /// Level: every phrase said as a statement of its own, ending low, all at one pace.
        case even
        /// Livelier: lead-in phrases lift ("In 150 feet,") and go a touch quicker, and the
        /// instruction lands on an exclamation, a touch slower, which Kokoro says with more
        /// energy and a wider swing in pitch.
        case lively

        var id: Self { self }

        var title: String { rawValue.capitalized }

        /// The ending `phrase` is said with and how much quicker (×), as the `last` or not.
        func say(_ phrase: String, last: Bool) -> (ending: Character?, speed: Double) {
            switch self {
            case .natural:
                // Its own punctuation: a comma lifts as it would mid-sentence
                (last ? nil : phrase.last.flatMap { ",;:".contains($0) ? "," : nil }, 1)
            case .even:
                (".", 1)
            case .lively:
                last || phrase.last.map({ ".!?".contains($0) }) == true ? ("!", 0.96) : (",", 1.06)
            }
        }
    }

    var model: Model
    /// The Kokoro voice, by its file (voice-<name>.bin): "female" is the pack's, af_heart.
    var voice: String
    /// Kokoro's speed (×): 1 is its own.
    var speed: Double
    /// Extra silence between phrases, in seconds.
    var pause: Double
    /// Higher or lower, in cents (100 a semitone).
    var pitch: Double
    var delivery: Delivery
    /// The Voice Mixer's voice, said in place of `voice`'s; nil for one of Kokoro's own.
    var mix: VoiceMix? = nil

    static let modelKey = "voiceModel"
    static let voiceKey = "voiceName"
    static let speedKey = "voiceSpeed"
    static let pauseKey = "voicePause"
    static let pitchKey = "voicePitch"
    static let deliveryKey = "voiceDelivery"

    static let standard = VoiceStyle(model: .q8f16, voice: WalkVoice.kokoroVoice, speed: 1, pause: 0,
                                     pitch: 0, delivery: .natural)

    /// The Kokoro voices to pick from, American English: the pack's (af_heart) and, in debug
    /// builds with them copied in, three more women's and four men's.
    static let voices: [(name: String, title: String)] = [
        (WalkVoice.kokoroVoice, "Heart (shipped)"), ("af_bella", "Bella"), ("af_nicole", "Nicole"),
        ("af_sarah", "Sarah"), ("am_michael", "Michael"), ("am_fenrir", "Fenrir"),
        ("am_puck", "Puck"), ("am_adam", "Adam"), (VoiceMix.name, "My Mix"),
    ]

    static var current: VoiceStyle {
        let defaults = UserDefaults.standard
        let voice = defaults.string(forKey: voiceKey) ?? standard.voice
        return VoiceStyle(
            model: defaults.string(forKey: modelKey).flatMap(Model.init) ?? standard.model,
            voice: voice,
            speed: defaults.object(forKey: speedKey) as? Double ?? standard.speed,
            pause: defaults.object(forKey: pauseKey) as? Double ?? standard.pause,
            pitch: defaults.object(forKey: pitchKey) as? Double ?? standard.pitch,
            delivery: defaults.string(forKey: deliveryKey).flatMap(Delivery.init) ?? standard.delivery,
            mix: voice == VoiceMix.name ? .saved : nil)
    }

    /// Said phrase by phrase, not in one go.
    var phrased: Bool { pause > 0 || delivery != .natural }

    /// What makes Kokoro's audio differ, for `WalkVoice`'s made-ahead audio: not pitch, put on
    /// as it plays.
    var key: String { "\(model.rawValue)|\(voice)|\(speed)|\(pause)|\(delivery.rawValue)|\(mix?.key ?? "")|" }

    /// The model's file in `folder`, or the pack's own where it isn't there (always, in the App
    /// Store's pack).
    func modelFile(in folder: URL) -> String {
        FileManager.default.fileExists(atPath: folder.appending(path: model.file).path) ? model.file : Model.q8f16.file
    }

    /// `spoken` cut after each comma, semicolon, colon and sentence end that's followed by a
    /// space ("0.2" stays whole), each phrase with its punctuation.
    static func phrases(of spoken: String) -> [String] {
        var phrases: [String] = []
        var phrase = ""
        var previous: Character?
        for character in spoken {
            if character == " ", let previous, ",;:.!?".contains(previous) {
                let trimmed = phrase.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { phrases.append(trimmed) }
                phrase = ""
            } else {
                phrase.append(character)
            }
            previous = character
        }
        let trimmed = phrase.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { phrases.append(trimmed) }
        return phrases
    }
}

#if DEBUG
extension WalkVoice {
    /// TEMP: says some walking instructions in turn (`-VoiceTest`), for Kokoro's timing in the log.
    static func test() async {
        let lines = [
            "In 150 ft, turn right onto W 43rd St",
            "Go down the stairs at the NW corner of 4 Av & 9 St",
            "Continue on Kosciuszko St, then turn left onto Throop Ave",
            "Then cross Ocean Pkwy · No light and wide crossing - watch for cars",
            "In 0.2 mi, take a left onto Gouverneur Ln",
        ]
        for line in lines {
            shared.say(line)
            try? await Task.sleep(for: .seconds(7))
        }
    }
}
#endif
