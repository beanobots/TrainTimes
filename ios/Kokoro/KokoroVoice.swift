import Foundation
import OnnxRuntimeBindings

// In its own framework, linking ONNX Runtime's static library, rather than in the app: linked
// into the app, it stops Xcode's previews of any of its screens from launching

/// Kokoro, the walking voice: phonemes (`Phonemizer`) in, 24 kHz audio out, by its 8-bit model
/// on the phone's CPU through ONNX Runtime. Made once, the first time it speaks; about a
/// second's work for a short instruction, so `WalkVoice` makes the next one's ahead of time.
public actor KokoroVoice {
    public static let sampleRate = 24_000.0

    private let session: ORTSession
    /// Each voice's style ("female": its file's name, voice-female.bin), one 256-long
    /// vector for each length of input in phonemes. One model says them all.
    private let styles: [String: [Float]]
    private let vocab: [Character: Int64]
    let phonemizer: Phonemizer

    /// Most phonemes in one go, as the model takes them.
    private static let most = 510
    private static let styleWidth = 256

    /// Kokoro from `folder`'s files, with `model` its model: kokoro.onnx (8-bit + half, the
    /// one in the pack) unless Prototyping's Voice tool picks a bigger one copied in.
    public init(folder: URL, model: String = "kokoro.onnx") throws {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(2)
        session = try ORTSession(env: env, modelPath: folder.appending(path: model).path, sessionOptions: options)
        var styles: [String: [Float]] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix("voice-") && file.pathExtension == "bin" {
            let name = String(file.deletingPathExtension().lastPathComponent.dropFirst("voice-".count))
            styles[name] = try Data(contentsOf: file).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        guard !styles.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        self.styles = styles
        let table = try JSONDecoder().decode([String: Int64].self, from: Data(contentsOf: folder.appending(path: "vocab.json")))
        vocab = Dictionary(uniqueKeysWithValues: table.compactMap { key, id in key.first.map { ($0, id) } })
        phonemizer = try Phonemizer(folder: folder)
    }

    /// The voices it has, by name.
    public var voices: Set<String> { Set(styles.keys) }

    /// `voice`'s style vectors, for mixing one of its own (Prototyping's Voice Mixer): 256 for
    /// each length of input, the first 128 its sound (read by the decoder), the rest how it
    /// speaks (rhythm and intonation, read by the prosody predictor).
    public func styles(of voice: String) -> [Float]? { styles[voice] }

    /// `text` (spoken, `SpokenText`) as samples, in `voice` ("female"; the first it has
    /// if not); nil where a word can't be said by Kokoro. `ending`, if given, is the last
    /// punctuation it's said with, in place of its own: "," for more to come (the last word
    /// lifted), "!" to land it.
    public func samples(for text: String, voice: String, speed: Float = 1, ending: Character? = nil) throws -> [Float]? {
        guard let styles = styles[voice] ?? styles.values.first else { return nil }
        return try samples(for: text, styles: styles, speed: speed, ending: ending)
    }

    /// `text` as samples in a voice given by its style vectors (as `styles(of:)` has them), not
    /// one of its own by name.
    public func samples(for text: String, styles: [Float], speed: Float = 1, ending: Character? = nil) throws -> [Float]? {
        guard let phonemes = phonemizer.phonemes(for: text), styles.count >= 2 * Self.styleWidth else { return nil }
        var out: [Float] = []
        let parts = Self.parts(of: phonemes, most: Self.most)
        for (index, part) in parts.enumerated() {
            out += try samples(phonemes: part, styles: styles, speed: speed,
                               ending: index == parts.count - 1 ? ending : nil)
        }
        return out
    }

    private func samples(phonemes: String, styles: [Float], speed: Float, ending: Character? = nil) throws -> [Float] {
        var phonemes = phonemes.trimmingCharacters(in: .whitespaces)
        if let ending {
            while let last = phonemes.last, ",;:.!?".contains(last) { phonemes.removeLast() }
            phonemes.append(ending)
        } else {
            // Ended as a sentence: without a full stop Kokoro hears more to come and lifts the last word
            while let last = phonemes.last, ",;:".contains(last) { phonemes.removeLast() }
            if let last = phonemes.last, !".!?".contains(last) { phonemes.append(".") }
        }
        let ids = phonemes.compactMap { vocab[$0] }
        var input: [Int64] = [0] + ids + [0]
        let count = min(ids.count, styles.count / Self.styleWidth - 1)
        var style = Array(styles[(count * Self.styleWidth)..<((count + 1) * Self.styleWidth)])
        var speed = speed
        let inputs: [String: ORTValue] = [
            "input_ids": try ORTValue(tensorData: NSMutableData(bytes: &input, length: input.count * 8),
                                      elementType: .int64, shape: [1, NSNumber(value: input.count)]),
            "style": try ORTValue(tensorData: NSMutableData(bytes: &style, length: style.count * 4),
                                  elementType: .float, shape: [1, NSNumber(value: Self.styleWidth)]),
            "speed": try ORTValue(tensorData: NSMutableData(bytes: &speed, length: 4), elementType: .float, shape: [1]),
        ]
        let outputs = try session.run(withInputs: inputs, outputNames: ["waveform"], runOptions: nil)
        guard let waveform = outputs["waveform"] else { return [] }
        let data = try waveform.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// `phonemes` in pieces of at most `most`, split at sentence ends, else commas, else spaces.
    static func parts(of phonemes: String, most: Int) -> [String] {
        guard phonemes.count > most else { return [phonemes] }
        var parts: [String] = []
        var rest = Substring(phonemes)
        while rest.count > most {
            let window = rest.prefix(most)
            let cut = window.lastIndex { ".!?".contains($0) } ?? window.lastIndex(of: ",") ?? window.lastIndex(of: " ")
                ?? window.endIndex
            let end = cut == window.endIndex ? cut : rest.index(after: cut)
            parts.append(String(rest[..<end]).trimmingCharacters(in: .whitespaces))
            rest = rest[end...]
        }
        if !rest.isEmpty { parts.append(String(rest).trimmingCharacters(in: .whitespaces)) }
        return parts
    }
}
