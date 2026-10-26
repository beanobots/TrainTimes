import ActivityKit
import Foundation

/// The running countdown's state as the Lock Screen shows it, for widgets showing its train to
/// take its times (`CountdownSync`). The push server updates the countdown without the app, so
/// the newest of what's known is used: iOS's own copy of the Live Activity where the widget can
/// read it, the state the push server last pushed it, and the one the app last posted.
enum CountdownLookup {
    /// Info.plist's TrainTimesServerURL, as the app's `PushServer` uses.
    private static var serverURL: URL? { ServerRoutes.baseURL }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // A widget has seconds to draw; without it, the other copies do
        configuration.timeoutIntervalForRequest = 3
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// The countdown's state for `trainID` (a `Selection.trainID`), not yet moved on to `now`;
    /// nil if no countdown for it is running. With `localOnly`, without asking the push server, for
    /// a draw that can't wait for the network.
    static func state(for trainID: String, now: Date = .now, localOnly: Bool = false) async -> CountdownState? {
        guard let countdown = SharedStore.loadCountdown(), countdown.trainID == trainID, countdown.ends > now else {
            return nil
        }
        let posted = SharedStore.loadPostedCountdown().flatMap { $0.trainID == trainID ? $0 : nil }
        let activity = Activity<TrainActivityAttributes>.activities.first {
            [.active, .stale].contains($0.activityState) && $0.attributes.selection.trainID == trainID
        }
        var states = [activity?.content.state, posted?.state].compactMap { $0 }
        if !localOnly, let token = activity?.pushToken.map(hex) ?? posted?.pushToken, let pushed = await pushedState(token: token) {
            states.append(pushed)
        }
        return states.max { $0.updated < $1.updated }
    }

    /// The state the push server last pushed to the countdown with push token `token`; nil if it
    /// has none, or can't be reached in time.
    private static func pushedState(token: String) async -> CountdownState? {
        guard let serverURL, let url = URL(string: serverURL.absoluteString + "/activities/\(token)/state"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // Dates as ActivityKit decodes them
        return try? JSONDecoder().decode(CountdownState.self, from: data)
    }

    /// Lowercase hex, as the push server has tokens.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
