import Foundation

/// Street names as people read them, from the city's labels (`WalkGraph.names`): "4 AVE" is
/// 4th Ave, "W 43 ST" W 43rd St, "AVE N" Avenue N, "MCDONALD AVE" McDonald Ave. OpenStreetMap's
/// names, already written that way, are left as they are.
enum StreetNames {
    /// The kinds of street, and how they're written.
    static let kinds: [String: String] = [
        "ST": "St", "AVE": "Ave", "AV": "Ave", "BLVD": "Blvd", "PKWY": "Pkwy", "PL": "Pl", "RD": "Rd",
        "DR": "Dr", "TER": "Ter", "CT": "Ct", "LN": "Ln", "SQ": "Sq", "EXPY": "Expy", "EXPWY": "Expy",
        "HWY": "Hwy", "TPKE": "Tpke", "CIR": "Cir", "PLZ": "Plaza", "ALY": "Alley", "BRG": "Bridge",
        "BR": "Bridge", "CONC": "Concourse", "ESPL": "Esplanade", "PROM": "Promenade", "BDWK": "Boardwalk",
        "OPAS": "Overpass", "PTH": "Path", "LP": "Loop", "WAY": "Way", "WALK": "Walk", "ROW": "Row",
        "SLIP": "Slip", "OVAL": "Oval", "XING": "Crossing", "PK": "Park", "GRN": "Green", "HTS": "Heights",
    ]
    /// OSM's kinds of street, written out, shortened.
    static let spelledOut: [String: String] = [
        "Street": "St", "Avenue": "Ave", "Boulevard": "Blvd", "Parkway": "Pkwy", "Place": "Pl", "Road": "Rd",
        "Terrace": "Ter", "Court": "Ct", "Lane": "Ln", "Expressway": "Expy",
    ]
    /// Kept in capitals.
    static let acronyms: Set<String> = ["FDR", "JFK", "MLK", "US", "NYC", "CUNY", "II", "III", "IV", "NE", "NW", "SE", "SW"]
    /// Written in lower case, but for the first word.
    static let small: Set<String> = ["OF", "THE", "AND", "AT", "DE", "LA"]
    /// The ones written their own way.
    static let exceptions: [String: String] = [
        "DE KALB AVE": "DeKalb Ave", "AVE OF THE AMERICAS": "Avenue of the Americas", "BROADWAY": "Broadway",
        "MALCOLM X BLVD": "Malcolm X Blvd", "ADAM C POWELL BLVD": "Adam Clayton Powell Jr Blvd",
    ]

    /// `label` as people read it; nil for none.
    static func display(_ label: String) -> String? {
        let label = label.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        // OSM's, in its own mixed case: its kind of street shortened as the city's are
        if label.contains(where: \.isLowercase) {
            var words = label.split(separator: " ").map(String.init)
            if words.count > 1, let last = words.last, let short = spelledOut[last] { words[words.count - 1] = short }
            return words.joined(separator: " ")
        }
        if let written = exceptions[label] { return written }
        let words = label.split(separator: " ").map(String.init)
        // "AVE N" is Avenue N, as Brooklyn's lettered avenues are
        if words.count == 2, words[0] == "AVE" || words[0] == "AV", words[1].count == 1 { return "Avenue \(words[1])" }
        var out: [String] = []
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : nil
            let before = index > 0 ? words[index - 1] : nil
            if let number = Int(word), next.map({ kinds[$0] != nil }) ?? false
                || ["N", "S", "E", "W", "BEACH"].contains(before ?? "") {
                out.append(ordinal(number))
            } else if index > 0, let kind = kinds[word], index == words.count - 1 || kinds[next ?? ""] == nil {
                out.append(kind)
            } else if word.count == 1 || acronyms.contains(word) {
                out.append(word)
            } else if index > 0, small.contains(word) {
                out.append(word.lowercased())
            } else {
                out.append(titled(word))
            }
        }
        return out.joined(separator: " ")
    }

    /// 1st, 2nd, 3rd, 4th, 11th, 12th, 13th, 21st, 101st, 111th.
    static func ordinal(_ number: Int) -> String {
        let suffix = (11...13).contains(number % 100) ? "th"
            : number % 10 == 1 ? "st" : number % 10 == 2 ? "nd" : number % 10 == 3 ? "rd" : "th"
        return "\(number)\(suffix)"
    }

    /// A word in title case: McDonald and O'Brien as they're written.
    static func titled(_ word: String) -> String {
        let lower = word.lowercased()
        if lower.hasPrefix("mc"), lower.count > 2 {
            return "Mc" + lower.dropFirst(2).prefix(1).uppercased() + lower.dropFirst(3)
        }
        if lower.hasPrefix("o'"), lower.count > 2 {
            return "O'" + lower.dropFirst(2).prefix(1).uppercased() + lower.dropFirst(3)
        }
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}
