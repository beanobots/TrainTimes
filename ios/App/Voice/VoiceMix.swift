import Foundation

/// A voice of one's own, mixed in Prototyping's Voice Mixer (`VoiceMixerTool`) from Kokoro's,
/// kept across launches. Each Kokoro voice is a style: 256 numbers for each length of input,
/// the first 128 how it sounds (tone, depth, breathiness) and the rest how it speaks (rhythm,
/// intonation), so the two can be mixed apart. A mix can only go between and beyond Kokoro's
/// voices: it can't copy a recorded one. The Mac's Voice Lab mixes with it too.
struct VoiceMix: Codable, Equatable {
    /// How much of each voice it sounds like, by name: shares of the total.
    var sound: [String: Double]
    /// How much of each voice it speaks like; nil for the same as `sound`.
    var speech: [String: Double]?
    /// 1 as mixed; higher pushes it away from the average of all the voices there are, more
    /// of its own character; lower draws it toward that average, 0 being it.
    var character = 1.0
    /// Random nudges to each of the 256, 0–1, as big as the voices differ there (a tenth of
    /// itself with only one voice): the same at every length, so one voice throughout.
    var wander = 0.0
    /// Which nudges.
    var seed: UInt64 = 1

    /// Its name as `VoiceStyle.voice`.
    static let name = "mix"
    static let defaultsKey = "voiceMix"
    /// All the pack's own voice, af_heart (`WalkVoice.kokoroVoice`).
    static let fresh = VoiceMix(sound: ["female": 1])

    static var saved: VoiceMix {
        UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode(VoiceMix.self, from: $0) } ?? fresh
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    /// What makes its audio differ, for `VoiceStyle.key`.
    var key: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static let width = 256
    /// The first this many of each 256 are how it sounds.
    private static let soundWidth = 128

    /// Its style from `voices` (each voice's styles, by name); nil with none of its voices
    /// there, or nothing in it.
    func styles(from voices: [String: [Float]]) -> [Float]? {
        guard let count = voices.values.map(\.count).min(), count >= 2 * Self.width else { return nil }
        let length = count - count % Self.width
        guard let sounds = Self.blend(sound, of: voices, length: length) else { return nil }
        let speaks = speech.flatMap { Self.blend($0, of: voices, length: length) } ?? sounds
        var out = (0..<length).map { $0 % Self.width < Self.soundWidth ? sounds[$0] : speaks[$0] }

        // Character, from the average of every voice there is
        if character != 1 {
            let mean = Self.blend(voices.mapValues { _ in 1 }, of: voices, length: length) ?? out
            let k = Float(character)
            for index in out.indices { out[index] = mean[index] + k * (out[index] - mean[index]) }
        }

        // Wander: one nudge per place in the 256, scaled by how far apart the voices are there
        if wander > 0 {
            var random = SplitMix(seed: seed)
            let nudges = (0..<Self.width).map { _ in random.normal() }
            let spread = Self.spread(of: voices, length: length)
            let amount = Float(wander)
            for index in out.indices {
                let size = spread?[index] ?? abs(out[index]) * 0.1
                out[index] += amount * nudges[index % Self.width] * size
            }
        }
        return out
    }

    /// `voices` mixed by `weights` (shares of their total); nil with none there.
    private static func blend(_ weights: [String: Double], of voices: [String: [Float]], length: Int) -> [Float]? {
        let present = weights.filter { $0.value > 0 && voices[$0.key] != nil }
        let total = present.values.reduce(0, +)
        guard total > 0 else { return nil }
        var out = [Float](repeating: 0, count: length)
        for (name, weight) in present {
            guard let style = voices[name] else { continue }
            let share = Float(weight / total)
            for index in 0..<length { out[index] += share * style[index] }
        }
        return out
    }

    /// How far the voices are apart at each place (their standard deviation); nil with fewer than two.
    private static func spread(of voices: [String: [Float]], length: Int) -> [Float]? {
        guard voices.count >= 2, let mean = blend(voices.mapValues { _ in 1 }, of: voices, length: length) else { return nil }
        var out = [Float](repeating: 0, count: length)
        for style in voices.values {
            for index in 0..<length {
                let off = style[index] - mean[index]
                out[index] += off * off
            }
        }
        let n = Float(voices.count)
        return out.map { ($0 / n).squareRoot() }
    }

    /// Random numbers that come out the same for the same seed.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 0 to 1, never 0.
        mutating func uniform() -> Float { Float(next() >> 40 + 1) / Float(1 << 24 + 1) }

        /// Normally spread around 0, by Box–Muller.
        mutating func normal() -> Float {
            (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
    }
}
