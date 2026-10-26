import Foundation

/// What the server asks of others' APIs (`TransitRoutes`, `BusTime`).
enum Web {
    /// Sends a request; returns the body and status.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    /// `Fetch` with URLSession.
    static let fetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// ISO8601DateFormatter is safe to share between threads, and costly to make.
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    nonisolated(unsafe) private static let withFraction = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// An RFC 3339 time, with or without fractions of a second.
    static func date(_ text: String) -> Date? {
        plain.date(from: text) ?? withFraction.date(from: text)
    }
}
