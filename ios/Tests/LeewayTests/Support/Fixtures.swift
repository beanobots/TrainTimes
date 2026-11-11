import Foundation

/// The saved feeds and server responses in Tests/LeewayTests/Fixtures, copied into the test
/// bundle as they are.
enum Fixtures {
    private final class Marker {}

    static let bundle = Bundle(for: Marker.self)

    /// A fixture's bytes, by its file name with its extension ("ace-weekday-8am.pb").
    static func data(_ name: String) throws -> Data {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard let url = bundle.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }

    /// New York's time zone, which every service day and timetable is in.
    static let newYork = TimeZone(identifier: "America/New_York")!

    /// A moment in New York: `date("2026-11-10 08:15")`.
    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = newYork
        formatter.dateFormat = text.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }
}
