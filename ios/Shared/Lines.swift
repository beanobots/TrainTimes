import Foundation

/// How a train line is drawn, and where its real-time feed lives.
struct LineStyle: Hashable, Sendable {
    /// What's printed in the bullet: "S" for the three shuttles, "SI" for Staten Island.
    let label: String
    /// 0xRRGGBB
    let color: UInt32
    /// Black text on the light bullets, white on the rest.
    let usesDarkText: Bool

    /// `route` is a real-time route id such as "R", "FS" (Franklin shuttle) or "SI".
    static func of(_ route: String) -> LineStyle {
        switch route {
        case "1", "2", "3": LineStyle(label: route, color: 0xEE352E, usesDarkText: false)
        case "4", "5", "6": LineStyle(label: route, color: 0x00933C, usesDarkText: false)
        case "7": LineStyle(label: route, color: 0xB933AD, usesDarkText: false)
        case "A", "C", "E": LineStyle(label: route, color: 0x0039A6, usesDarkText: false)
        case "B", "D", "F", "M": LineStyle(label: route, color: 0xFF6319, usesDarkText: false)
        case "G": LineStyle(label: route, color: 0x6CBE45, usesDarkText: true)
        case "J", "Z": LineStyle(label: route, color: 0x996633, usesDarkText: false)
        case "L": LineStyle(label: route, color: 0xA7A9AC, usesDarkText: true)
        case "N", "Q", "R", "W": LineStyle(label: route, color: 0xFCCC0A, usesDarkText: true)
        case "GS", "FS", "H": LineStyle(label: "S", color: 0x808183, usesDarkText: false)
        case "SI": LineStyle(label: "SI", color: 0x0078C6, usesDarkText: false)
        default: LineStyle(label: route, color: 0x808183, usesDarkText: false)
        }
    }

    /// How big its label is in a bullet `size` across: a little smaller for
    /// two letters, "SI", than for one.
    func labelSize(bullet size: CGFloat) -> CGFloat {
        size * (label.count > 1 ? 0.45 : 0.62)
    }

    /// A 0xRRGGBB colour's red, green and blue, each from 0 to 1.
    static func rgb(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

enum Lines {
    /// The express versions of a line are their own routes in the feeds, and
    /// the alerts write the Staten Island Railway "[SIR]".
    static func normalized(_ route: String) -> String {
        ["5X": "5", "6X": "6", "7X": "7", "FX": "F", "SIR": "SI"][route] ?? route
    }

    /// The real-time feeds whose trains can stop on `routes`' tracks: their own,
    /// and the others. The MTA publishes one per group of lines (no API key
    /// needed), and a train rerouted onto another line stays in its own group's:
    /// a D running local on the R is in the B D F M feed. The lettered lines all
    /// connect, apart from the L; the numbered lines and Staten Island have their own tracks.
    static func feedURLs(sharingTracksWith routes: [String]) -> (own: [URL], others: [URL]) {
        var own: [String] = []
        for suffix in routes.map(feedSuffix) where !own.contains(suffix) {
            own.append(suffix)
        }
        let connected = ["-ace", "-bdfm", "-g", "-jz", "-nqrw"]
        let others = own.contains(where: { connected.contains($0) }) ? connected.filter { !own.contains($0) } : []
        let url = { (suffix: String) in URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs\(suffix)")! }
        return (own.map(url), others.map(url))
    }

    private static func feedSuffix(for route: String) -> String {
        switch route {
        case "A", "C", "E", "H": "-ace"
        case "B", "D", "F", "M", "FS": "-bdfm"
        case "G": "-g"
        case "J", "Z": "-jz"
        case "L": "-l"
        case "N", "Q", "R", "W": "-nqrw"
        case "SI": "-si"
        default: "" // 1 2 3 4 5 6 7 and the 42 St shuttle
        }
    }

    /// The bullets to filter stations by, in the order the MTA draws them ("GS" stands for all the shuttles).
    static let filterRoutes = [
        "1", "2", "3", "4", "5", "6", "7", "A", "C", "E", "B", "D", "F", "M",
        "G", "J", "Z", "L", "N", "Q", "R", "W", "GS", "SI",
    ]

    /// Where `route` comes in that order, for listing a station's lines.
    static func rank(_ route: String) -> Int {
        filterRoutes.firstIndex(of: LineStyle.of(route).label == "S" ? "GS" : route) ?? filterRoutes.count
    }

    /// What a line is called on its own: its bullet's letter, or a shuttle's
    /// name, since the three share the S.
    static func name(of route: String) -> String {
        switch route {
        case "GS": "42 St Shuttle"
        case "FS": "Franklin Av Shuttle"
        case "H": "Rockaway Park Shuttle"
        default: LineStyle.of(route).label
        }
    }

    /// A line as VoiceOver and Siri name a train of it: "R train", or a
    /// shuttle by its name, "42 St Shuttle", which says what it is.
    static func spokenName(of route: String) -> String {
        let label = LineStyle.of(route).label
        let called = name(of: route)
        return called == label ? "\(label) train" : called
    }

    /// Whether `route` runs into Manhattan: every line but the G, the Franklin
    /// Av and Rockaway Park shuttles, and the Staten Island Railway.
    static func servesManhattan(_ route: String) -> Bool {
        !["G", "FS", "H", "SI"].contains(route)
    }

    /// "R", "42 St Shuttle", "N and R", "D, N and R"; or joined by "or", "D or N"
    static func list(_ routes: [String], joinedBy conjunction: String = "and") -> String {
        let names = routes.count == 1 ? routes.map(name(of:)) : routes.map { LineStyle.of($0).label }
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }
}
