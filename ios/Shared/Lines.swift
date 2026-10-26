import Foundation

/// How a train line is drawn, and where its real-time feed lives.
struct LineStyle: Hashable, Sendable {
    /// The bullet text: "S" for all three shuttles, "SI" for Staten Island.
    let label: String
    /// 0xRRGGBB
    let color: UInt32
    /// Black text on light bullets.
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

    /// Label font size for a bullet `size` across; smaller for two letters ("SI").
    func labelSize(bullet size: CGFloat) -> CGFloat {
        size * (label.count > 1 ? 0.45 : 0.62)
    }

    /// 0xRRGGBB as components from 0 to 1.
    static func rgb(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

enum Lines {
    /// Maps feed express routes ("5X") to their line, and the alerts' "[SIR]" to "SI".
    static func normalized(_ route: String) -> String {
        ["5X": "5", "6X": "6", "7X": "7", "FX": "F", "SIR": "SI"][route] ?? route
    }

    /// Feeds whose trains can stop on `routes`' tracks: their own, and others. The MTA publishes
    /// one feed per line group (no API key), and a rerouted train stays in its own group's feed: a
    /// D running local on the R is in B D F M. All lettered lines but the L connect; the numbered
    /// lines and Staten Island have their own tracks.
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

    /// Station filter bullets in MTA order ("GS" stands for all shuttles).
    static let filterRoutes = [
        "1", "2", "3", "4", "5", "6", "7", "A", "C", "E", "B", "D", "F", "M",
        "G", "J", "Z", "L", "N", "Q", "R", "W", "GS", "SI",
    ]

    /// Sort key in `filterRoutes` order, for listing a station's lines.
    static func rank(_ route: String) -> Int {
        filterRoutes.firstIndex(of: LineStyle.of(route).label == "S" ? "GS" : route) ?? filterRoutes.count
    }

    /// The bullet's label, or a shuttle's full name, since all three share the S.
    static func name(of route: String) -> String {
        switch route {
        case "GS": "42 St Shuttle"
        case "FS": "Franklin Av Shuttle"
        case "H": "Rockaway Park Shuttle"
        default: LineStyle.of(route).label
        }
    }

    /// For VoiceOver: "R train", or a shuttle's name, "42 St Shuttle".
    static func spokenName(of route: String) -> String {
        let label = LineStyle.of(route).label
        let called = name(of: route)
        return called == label ? "\(label) train" : called
    }

    /// Every line but the G, the Franklin Av and Rockaway Park shuttles, and Staten Island.
    static func servesManhattan(_ route: String) -> Bool {
        !["G", "FS", "H", "SI"].contains(route)
    }

    /// "R", "42 St Shuttle", "N and R", "D, N and R"; or joined by "or", "D or N"
    static func list(_ routes: [String], joinedBy conjunction: String = "and") -> String {
        joined(routes.count == 1 ? routes.map(name(of:)) : routes.map { LineStyle.of($0).label }, by: conjunction)
    }

    /// For VoiceOver, naming shuttles in full: "N or R", "7 or 42 St Shuttle".
    static func spokenList(_ routes: [String], joinedBy conjunction: String = "and") -> String {
        joined(routes.map(name(of:)), by: conjunction)
    }

    /// "D, N and R".
    static func joined(_ names: [String], by conjunction: String = "and") -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }
}
