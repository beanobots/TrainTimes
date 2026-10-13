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
}

enum Lines {
    /// The express versions of a line are their own routes in the feeds.
    static func normalized(_ route: String) -> String {
        ["6X": "6", "7X": "7", "FX": "F"][route] ?? route
    }

    /// The MTA publishes one real-time feed per group of lines; no API key needed.
    static func feedURL(for route: String) -> URL {
        let suffix: String
        switch route {
        case "A", "C", "E", "H": suffix = "-ace"
        case "B", "D", "F", "M", "FS": suffix = "-bdfm"
        case "G": suffix = "-g"
        case "J", "Z": suffix = "-jz"
        case "L": suffix = "-l"
        case "N", "Q", "R", "W": suffix = "-nqrw"
        case "SI": suffix = "-si"
        default: suffix = "" // 1 2 3 4 5 6 7 and the 42 St shuttle
        }
        return URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs\(suffix)")!
    }

    /// The bullets to filter stations by, in the order the MTA draws them ("GS" stands for all the shuttles).
    static let filterRoutes = [
        "1", "2", "3", "4", "5", "6", "7", "A", "C", "E", "B", "D", "F", "M",
        "G", "J", "Z", "L", "N", "Q", "R", "W", "GS", "SI",
    ]
}
