import Foundation

/// Where the app leaves the choice for the widget: a file in an App Group
/// container that both belong to (a widget can't read the app's own files).
enum SharedStore {
    static let fallbackGroupID = "group.com.rtrainwidget.app"

    /// AltStore swaps the group for one unique to your Apple ID and lists it in
    /// Info.plist as ALTAppGroups, so look there first, in the widget's and then the app's.
    private static var candidateGroups: [String] {
        var groups = altGroups(in: Bundle.main)
        if Bundle.main.bundleURL.pathExtension == "appex" {
            let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if let app = Bundle(url: appURL) { groups += altGroups(in: app) }
        }
        return groups + [fallbackGroupID]
    }

    private static func altGroups(in bundle: Bundle) -> [String] {
        bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    }

    /// Nil when this install isn't in an App Group, e.g. it was signed without the entitlement.
    private static let container: URL? = candidateGroups
        .lazy
        .compactMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        .first
    private static let file = container?.appendingPathComponent("selection.json")
    private static let countdownFile = container?.appendingPathComponent("countdown.json")

    /// Whether a choice made in the app can reach the widget on this install.
    static var isAvailable: Bool { file != nil }

    static func load() -> Selection {
        guard let file,
              let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Selection.self, from: data) else { return .fallback }
        return saved.validated()
    }

    @discardableResult
    static func save(_ selection: Selection) -> Bool {
        guard let file, let data = try? JSONEncoder().encode(selection) else { return false }
        return (try? data.write(to: file, options: .atomic)) != nil
    }

    /// The train the Lock Screen countdown is for. Widgets can't see Live
    /// Activities, so the app leaves this for their walk buttons.
    struct Countdown: Codable, Equatable {
        /// A `Selection.trainID`.
        var trainID: String
        /// When iOS will have ended it.
        var ends: Date
    }

    static func loadCountdown() -> Countdown? {
        guard let countdownFile, let data = try? Data(contentsOf: countdownFile) else { return nil }
        return try? JSONDecoder().decode(Countdown.self, from: data)
    }

    /// Nil once no countdown is running.
    static func saveCountdown(_ countdown: Countdown?) {
        guard let countdownFile else { return }
        if let countdown, let data = try? JSONEncoder().encode(countdown) {
            try? data.write(to: countdownFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: countdownFile)
        }
    }
}
