import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TrainService {
    /// The trains still to come for `selection`, from the MTA's real-time feed.
    static func upcoming(for selection: Selection, now: Date = Date()) async throws -> [Arrival] {
        let request = URLRequest(url: Lines.feedURL(for: selection.route), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try SubwayFeed.upcoming(stopID: selection.stopID, route: selection.route, from: data, now: now)
    }
}
