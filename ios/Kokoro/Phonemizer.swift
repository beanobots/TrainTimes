import Foundation

/// Spoken text (`SpokenText`) in Kokoro's phonemes, as misaki, the library Kokoro was trained
/// with, gives them: the city's words first (words.tsv, every name in the city, how New Yorkers
/// say it), then misaki's dictionary (lexicon.tsv), then its rules for what the dictionary
/// leaves out: -s, -ed and -ing on a known word, "the" and "to" as the next word starts,
/// capitals spelled out ("FDR"). Nil where any word can't be said that way: Apple's voice says
/// that instruction instead, as Kokoro would skip the word.
public struct Phonemizer: Sendable {
    let city: SortedWords
    let dictionary: SortedWords

    public init(folder: URL) throws {
        city = try SortedWords(url: folder.appending(path: "words.tsv"))
        dictionary = try SortedWords(url: folder.appending(path: "lexicon.tsv"))
    }

    /// `text`'s phonemes, punctuation kept for its pauses; nil if a word isn't known.
    public func phonemes(for text: String) -> String? {
        let tokens = Self.tokens(of: text)
        var said = [String?](repeating: nil, count: tokens.count)
        // Back to front: "the" and "to" depend on how the word after starts
        var following: String?
        for index in tokens.indices.reversed() {
            let token = tokens[index]
            if Self.isPunctuation(token) {
                said[index] = token
                following = nil
                continue
            }
            guard let phonemes = word(token, before: following) else { return nil }
            said[index] = phonemes
            following = phonemes
        }
        var out = ""
        for (index, token) in tokens.enumerated() {
            guard let phonemes = said[index] else { continue }
            if Self.isPunctuation(token) {
                out += phonemes
            } else {
                out += out.isEmpty ? phonemes : " " + phonemes
            }
        }
        return out
    }

    /// One word's phonemes, `before` the next word's (nil at a pause).
    private func word(_ word: String, before next: String?) -> String? {
        let nextVowel = next.map(Self.startsWithVowel)
        switch word {
        case "a": return "ɐ"
        case "an", "An": return "ɐn"
        case "the", "The": return nextVowel == true ? "ði" : "ðə"
        case "to", "To":
            guard let nextVowel else { return dictionary.lookup("to") }
            return nextVowel ? "tʊ" : "tə"
        case "in", "In": return next == nil ? "ˈɪn" : "ɪn"
        default: break
        }
        // A letter on its own, a line's or a street's ("the W", "Avenue N"): its name, not a word
        // the dictionary has for it
        if word.count == 1, let letter = word.first, letter.isUppercase, let name = Self.letters[letter] {
            return name
        }
        let lower = word.lowercased()
        // Said lightly mid-sentence, as misaki has them
        if Self.light.contains(lower), let found = known(lower) {
            return found.replacingOccurrences(of: "ˌ", with: "")
        }
        if let found = city.lookup(lower) { return found }
        if let found = known(word) { return found }
        // "Bed-Stuy", "forty-third": each part, as one word stressed on the first
        if word.contains("-") {
            let parts = word.split(separator: "-").map { self.word(String($0), before: nil) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.compactMap { $0 }.enumerated().map { index, part in
                index == 0 ? part : part.replacingOccurrences(of: "ˈ", with: "ˌ")
            }.joined()
        }
        if let found = stemmed(word) { return found }
        // "FDR", "Q": letter by letter, the last stressed
        if word.count <= 5, word.allSatisfy({ $0.isUppercase }) {
            return Self.spelled(word)
        }
        return nil
    }

    /// The dictionary's, by the word as written, lower case, or capitalised.
    private func known(_ word: String) -> String? {
        if let found = dictionary.lookup(word) { return found }
        let lower = word.lowercased()
        if lower != word, let found = dictionary.lookup(lower) { return found }
        let capital = lower.prefix(1).uppercased() + lower.dropFirst()
        if capital != word, let found = dictionary.lookup(capital) { return found }
        return nil
    }

    /// misaki's endings on a known word: "minutes", "crossed", "heading".
    private func stemmed(_ word: String) -> String? {
        let lower = word.lowercased()
        if lower.count >= 3, lower.hasSuffix("s") {
            let stems = [String(lower.dropLast()), String(lower.dropLast(2)), String(lower.dropLast(3)) + "y"]
            let ok = [!lower.hasSuffix("ss"), lower.hasSuffix("'s") || (lower.hasSuffix("es") && !lower.hasSuffix("ies")),
                      lower.hasSuffix("ies")]
            for (stem, ok) in zip(stems, ok) where ok {
                if let found = city.lookup(stem) ?? known(stem) { return Self.plural(found) }
            }
        }
        if lower.count >= 4, lower.hasSuffix("d") {
            for stem in [String(lower.dropLast()), String(lower.dropLast(2))] where !stem.hasSuffix("e") || stem.count == lower.count - 1 {
                if let found = known(stem) { return Self.past(found) }
            }
        }
        if lower.count >= 5, lower.hasSuffix("ing") {
            let base = String(lower.dropLast(3))
            for stem in [base, base + "e", String(base.dropLast())] {
                if let found = known(stem) { return found + "ɪŋ" }
            }
        }
        return nil
    }

    private static func plural(_ stem: String) -> String {
        guard let last = stem.last else { return stem }
        if "ptkfθ".contains(last) { return stem + "s" }
        if "szʃʒʧʤ".contains(last) { return stem + "ᵻz" }
        return stem + "z"
    }

    private static func past(_ stem: String) -> String {
        guard let last = stem.last else { return stem }
        if "pkfθʃsʧ".contains(last) { return stem + "t" }
        if last == "d" || last == "t" { return stem + "ᵻd" }
        return stem + "d"
    }

    /// Letters' names, for spelling: misaki's.
    static let letters: [Character: String] = [
        "A": "ˈA", "B": "bˈi", "C": "sˈi", "D": "dˈi", "E": "ˈi", "F": "ˈɛf", "G": "ʤˈi", "H": "ˈAʧ",
        "I": "ˈI", "J": "ʤˈA", "K": "kˈA", "L": "ˈɛl", "M": "ˈɛm", "N": "ˈɛn", "O": "ˈO", "P": "pˈi",
        "Q": "kjˈu", "R": "ˈɑɹ", "S": "ˈɛs", "T": "tˈi", "U": "jˈu", "V": "vˈi", "W": "dˈʌbᵊljˌu",
        "X": "ˈɛks", "Y": "wˈI", "Z": "zˈi",
    ]

    /// "FDR": ˌɛf dˌi ˈɑɹ, the last letter stressed as misaki does.
    static func spelled(_ word: String) -> String? {
        let names = word.compactMap { letters[$0] }
        guard names.count == word.count else { return nil }
        return names.enumerated().map { index, name in
            index == names.count - 1 ? name : name.replacingOccurrences(of: "ˈ", with: "ˌ")
        }.joined()
    }

    /// Words misaki says without stress in a sentence.
    private static let light: Set<String> = ["at", "of", "and", "for", "or", "from", "as", "but", "than"]

    private static let vowels: Set<Character> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")

    private static func startsWithVowel(_ phonemes: String) -> Bool {
        phonemes.first { $0 != "ˈ" && $0 != "ˌ" }.map(vowels.contains) ?? false
    }

    private static func isPunctuation(_ token: String) -> Bool {
        token.count == 1 && ",.;:!?".contains(token)
    }

    /// Words, with apostrophes and hyphens inside them, and punctuation.
    static func tokens(of text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for character in text {
            if character.isLetter || character.isNumber || ((character == "'" || character == "’" || character == "-") && !word.isEmpty) {
                word.append(character == "’" ? "'" : character)
            } else {
                if !word.isEmpty { tokens.append(word.trimmingCharacters(in: CharacterSet(charactersIn: "-'"))) }
                word = ""
                if ",.;:!?".contains(character) { tokens.append(String(character)) }
            }
        }
        if !word.isEmpty { tokens.append(word.trimmingCharacters(in: CharacterSet(charactersIn: "-'"))) }
        return tokens.filter { !$0.isEmpty }
    }
}

/// A sorted "word<TAB>phonemes" file searched where it lies, rather than read into a dictionary:
/// misaki's 180,000 words are 4.6 MB as bytes, many times that as Swift strings.
struct SortedWords: Sendable {
    private let bytes: [UInt8]
    /// Where each line starts.
    private let lines: [Int32]

    init(url: URL) throws {
        bytes = Array(try Data(contentsOf: url, options: .mappedIfSafe))
        var lines: [Int32] = [0]
        lines.reserveCapacity(200_000)
        for index in bytes.indices where bytes[index] == 0x0A && index + 1 < bytes.count {
            lines.append(Int32(index + 1))
        }
        self.lines = lines
    }

    /// `word`'s phonemes, exactly as written there.
    func lookup(_ word: String) -> String? {
        let key = Array(word.utf8)
        var low = 0, high = lines.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let start = Int(lines[middle])
            switch compare(key, at: start) {
            case .orderedSame: return phonemes(at: start + key.count + 1)
            case .orderedAscending: high = middle - 1
            case .orderedDescending: low = middle + 1
            }
        }
        return nil
    }

    /// `key` against the word on the line from `start`, by bytes as the file's sorted.
    private func compare(_ key: [UInt8], at start: Int) -> ComparisonResult {
        var index = start
        for byte in key {
            guard index < bytes.count, bytes[index] != 0x09 else { return .orderedDescending }
            if byte != bytes[index] { return byte < bytes[index] ? .orderedAscending : .orderedDescending }
            index += 1
        }
        return index < bytes.count && bytes[index] == 0x09 ? .orderedSame : .orderedAscending
    }

    private func phonemes(at start: Int) -> String? {
        var end = start
        while end < bytes.count, bytes[end] != 0x0A { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}
