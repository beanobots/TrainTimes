import Foundation

/// A walking instruction as it's said rather than read: "Take a right onto W 43rd St" is
/// "Take a right onto West Forty-Third Street", "Down the stairs at the NW corner of 4 Av & 9 St"
/// "…at the northwest corner of Fourth Avenue and Ninth Street", "150 ft" "a hundred and fifty
/// feet". Both voices say this: Kokoro's (`WalkVoice`) and Apple's, which reads "St" and "Av"
/// as well as it can but not "4 Av-9 St".
enum SpokenText {
    /// `text`, written out to be said.
    static func spoken(_ text: String) -> String {
        var words = tokens(of: text)
        var out: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            let before = out.last { !isPunctuation($0) }
            let next = words[(index + 1)...].first { !isPunctuation($0) }
            let nextNext = words.dropFirst(index + 1).filter { !isPunctuation($0) }.dropFirst().first

            // "8:12", "8:12 AM": eight twelve, A M
            if let time = clock(word) {
                out.append(time)
                if let next, ["AM", "PM", "am", "pm"].contains(next) {
                    out.append(next.uppercased().map(String.init).joined(separator: " "))
                    words.remove(at: index + 1)
                }
                index += 1
                continue
            }
            // "0.2 mi": point two miles
            if let decimal = Double(word), word.contains(".") {
                out.append(decimalWords(decimal))
                index += 1
                continue
            }
            // "43rd", "1st": forty-third, first
            if let ordinal = ordinalWords(word) {
                out.append(ordinal)
                index += 1
                continue
            }
            if let number = Int(word) {
                // A street's number: "179 St", "4 Av" are 179th Street, Fourth Avenue
                if let next, streetKinds[next] != nil || next == "St" || next == "ST" {
                    out.append(ordinal(number))
                } else {
                    out.append(cardinal(number))
                }
                index += 1
                continue
            }
            // "St": Saint before a name ("St Marks Pl"), else Street
            if word == "St" || word == "ST" {
                let saint = before.map { streetKinds[$0] != nil || ["at", "onto", "on", "to", "of", "and", "&"].contains($0) }
                    ?? true
                if saint, let next, next.first?.isUppercase == true, streetKinds[next] == nil {
                    out.append("Saint")
                } else {
                    out.append("Street")
                }
                index += 1
                continue
            }
            // "Dr": Doctor before a name ("Dr Martin Luther King Jr Blvd"), else Drive
            if word == "Dr", let next, next.first?.isUppercase == true, streetKinds[next] == nil,
               before.map({ streetKinds[$0] == nil }) ?? true, nextNext != nil {
                out.append("Doctor")
                index += 1
                continue
            }
            if let kind = streetKinds[word] {
                out.append(kind)
                index += 1
                continue
            }
            // A compass point: "W 43rd St" West, "Head W" west, "the NW corner" northwest; not a
            // street's own letter ("Avenue N") nor a line ("the W", "N train"), said as letters
            if let direction = compass(word, before: before, next: next) {
                out.append(direction)
                index += 1
                continue
            }
            if let word = plainWords[word] {
                out.append(word)
                index += 1
                continue
            }
            // "3 min": minutes, or minute after a one
            if word == "min" {
                out.append(before == "one" ? "minute" : "minutes")
                index += 1
                continue
            }
            out.append(word)
            index += 1
        }
        return joined(out)
    }

    // MARK: Words

    /// The city's and Apple Maps' kinds of street, said in full.
    static let streetKinds: [String: String] = [
        "Ave": "Avenue", "Av": "Avenue", "AVE": "Avenue", "AV": "Avenue", "Blvd": "Boulevard", "BLVD": "Boulevard",
        "Pkwy": "Parkway", "Pky": "Parkway", "Pl": "Place", "Rd": "Road", "Ter": "Terrace", "Ct": "Court",
        "Ln": "Lane", "Sq": "Square", "Expy": "Expressway", "Expwy": "Expressway", "Hwy": "Highway",
        "Tpke": "Turnpike", "Cir": "Circle", "Plz": "Plaza", "Hts": "Heights", "Jct": "Junction",
        "Ctr": "Center", "Sta": "Station", "Brg": "Bridge", "Br": "Bridge", "Bch": "Beach", "Pk": "Park",
        "Gdns": "Gardens", "Bdwy": "Broadway", "Dr": "Drive", "Cres": "Crescent", "Hwy.": "Highway",
        "Avs": "Avenues", "Sts": "Streets",
    ]
    private static let compassPoints = ["N": "north", "S": "south", "E": "east", "W": "west",
                                        "NE": "northeast", "NW": "northwest", "SE": "southeast", "SW": "southwest"]
    private static let plainWords = [
        "&": "and", "ft": "feet", "mi": "miles", "km": "kilometers", "m": "meters", "Jr": "Junior",
        "Ft": "Fort", "Mt": "Mount", "Pt": "Point", "Hosp": "Hospital", "Ctr.": "Center",
    ]
    /// Words after a line's letter: "the N train", "N or R".
    private static let lineWordsAfter: Set<String> = ["train", "trains", "line", "lines", "or", "and", "&", "shuttle"]
    /// Words before a line's letter: "the W", "N or W", "to the E".
    private static let lineWordsBefore: Set<String> = ["the", "or", "and", "&", "a", "an"]

    /// `word` as a compass point, nil if it isn't one here. Before a street it's part of the
    /// name, capitalised ("W 43rd St": West); anywhere else, the direction ("Head W": west).
    /// A single letter after "Avenue" is the street's own ("Avenue N"), and one beside "the",
    /// "train" or another line is a line ("the W", "N or R"): both left as letters.
    private static func compass(_ word: String, before: String?, next: String?) -> String? {
        guard let point = compassPoints[word] else { return nil }
        if isLetterStreet(before: before) { return nil }
        let single = word.count == 1
        if single, let next, lineWordsAfter.contains(next.lowercased()) { return nil }
        // "W 43rd St", "E Houston St": the start of a street's name
        if let next, next.first?.isNumber == true || (next.first?.isUppercase == true && next.count > 1) {
            return point.prefix(1).uppercased() + point.dropFirst()
        }
        if single, let before, lineWordsBefore.contains(before.lowercased()) { return nil }
        return point
    }

    /// Whether a letter after `before` is a street's own ("Avenue N", "Ave J"), not a compass point.
    private static func isLetterStreet(before: String?) -> Bool {
        guard let before else { return false }
        return before == "Avenue" || before == "Ave" || before == "Av" || before == "AVE" || before == "Beach"
    }

    // MARK: Numbers

    private static let spelling: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        return formatter
    }()

    /// 43: forty-three.
    static func cardinal(_ number: Int) -> String {
        spelling.string(from: NSNumber(value: number)) ?? String(number)
    }

    /// 43: forty-third.
    static func ordinal(_ number: Int) -> String {
        let words = cardinal(number)
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        // The last word, after any hyphen: "forty-three" → "forty-third"
        let split = words.lastIndex { $0 == " " || $0 == "-" }.map { words.index(after: $0) } ?? words.startIndex
        let head = words[..<split], last = String(words[split...])
        let ordinal = irregular[last] ?? (last.hasSuffix("y") ? last.dropLast() + "ieth" : last + "th")
        return head + ordinal
    }

    /// "43rd", "1st", "2nd", "4th": the number said as an ordinal; nil for anything else.
    private static func ordinalWords(_ word: String) -> String? {
        guard let match = word.wholeMatch(of: /([0-9]+)(st|nd|rd|th)/), let number = Int(match.1) else { return nil }
        return ordinal(number)
    }

    /// 0.2: point two; 1.5: one point five.
    private static func decimalWords(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        let parts = text.split(separator: ".")
        let whole = Int(parts[0]) ?? 0
        let tenth = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let head = whole == 0 ? "point" : "\(cardinal(whole)) point"
        return "\(head) \(cardinal(tenth))"
    }

    /// "8:12": eight twelve; "8:05": eight oh five; "8:00": eight o'clock.
    private static func clock(_ word: String) -> String? {
        guard let match = word.wholeMatch(of: /([0-9]{1,2}):([0-9]{2})/),
              let hour = Int(match.1), let minute = Int(match.2), minute < 60 else { return nil }
        if minute == 0 { return "\(cardinal(hour)) o'clock" }
        if minute < 10 { return "\(cardinal(hour)) oh \(cardinal(minute))" }
        return "\(cardinal(hour)) \(cardinal(minute))"
    }

    // MARK: Splitting and joining

    /// Words and punctuation: "4 Av-9 St, 3 min · No light" → 4, Av, ",", 9, St, ",", 3, min, ".",
    /// No, light. A hyphen between names (a station's, "Bedford-Nostrand Avs") or a spaced dash
    /// is a pause; one inside a word ("Bed-Stuy", "Co-op") stays.
    static func tokens(of text: String) -> [String] {
        var text = text.replacingOccurrences(of: " · ", with: ". ")
            .replacingOccurrences(of: "·", with: ". ")
            .replacingOccurrences(of: " - ", with: ", ")
            .replacingOccurrences(of: " – ", with: ", ")
            .replacingOccurrences(of: " — ", with: ", ")
        // "Av-9", "St-Hostos": a station's two names, said with a pause
        text = text.replacing(/(?<a>[A-Za-z0-9]+)-(?<b>[A-Za-z0-9]+)/) { match in
            let a = String(match.a), b = String(match.b)
            let named = streetKinds[a] != nil || a == "St" || a.first?.isNumber == true || b.first?.isNumber == true
            return named ? "\(a), \(b)" : "\(a)-\(b)"
        }
        var out: [String] = []
        for piece in text.split(separator: " ") {
            var word = Substring(piece)
            var trailing: [String] = []
            while let last = word.last, ",.;:!?".contains(last), word.count > 1 || out.isEmpty == false {
                // Keep "0.2"'s point and "Hwy."'s: only end punctuation splits off
                if last == ".", let number = Double(word), word.dropLast().contains(".") == false, number > 0 { break }
                trailing.insert(String(last), at: 0)
                word = word.dropLast()
                if word.isEmpty { break }
            }
            if !word.isEmpty { out.append(String(word)) }
            out += trailing
        }
        return out
    }

    private static func isPunctuation(_ token: String) -> Bool {
        token.count == 1 && ",.;:!?".contains(token)
    }

    /// Words again, with punctuation against the word before and no doubled pauses.
    private static func joined(_ words: [String]) -> String {
        var text = ""
        for word in words {
            if isPunctuation(word) {
                if let last = text.last, ",.;:!?".contains(last) { continue }
                text += word
            } else {
                text += text.isEmpty ? word : " " + word
            }
        }
        return text
    }
}
