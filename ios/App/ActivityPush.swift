import ActivityKit
import BackgroundTasks
import Foundation
import os
import WidgetKit

/// Registers each running countdown's push token with the push server, so it gets new times
/// while the app isn't running, and remembers which ones the server has.
///
/// All best effort: a countdown the server doesn't have (unreachable, no App Attest in the
/// simulator, a build that can't have push tokens) is kept up to date by the app as before, when
/// it's opened or a refresh button runs, and by a background refresh while one runs. Registering
/// is tried again, backing off, each time the app becomes active or refreshes.
@MainActor
enum ActivityPush {
    /// The background refresh, also in Info.plist's BGTaskSchedulerPermittedIdentifiers.
    nonisolated static let refreshTaskID = "com.rtrainwidget.app.refresh"

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Leeway", category: "ActivityPush")

    /// What's known of one countdown's registration, by `Activity.id`.
    struct Record: Codable {
        /// Lowercase hex.
        var token: String?
        /// The widget push token it was last registered with, so it's registered again when that
        /// changes.
        var widgetToken: String?
        /// The alert kinds (`AppSettings.alertKinds`' raw values, sorted) it was last registered
        /// with, so it's registered again when they change in Settings.
        var alertKinds: [Int]?
        /// Whether its last registration succeeded, so the server pushes to it.
        var serverBacked = false
        var started: Date?
        /// Registrations failed in a row, and when to try again.
        var failures = 0
        var retryAfter: Date?
    }

    private static let recordsKey = "activityPushRecords"
    /// Tokens to delete that the server couldn't be told about yet.
    private static let deletesKey = "activityPushDeletes"

    private static var records: [String: Record] = {
        guard let data = UserDefaults.standard.data(forKey: recordsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: recordsKey) }
    }

    private static var pendingDeletes: [String] {
        get { UserDefaults.standard.stringArray(forKey: deletesKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: deletesKey) }
    }

    /// Each countdown's token and state watchers.
    private static var watchers: [String: [Task<Void, Never>]] = [:]
    /// Countdowns registered (or tried) since launch, so a token iOS gives again isn't sent again.
    private static var tried: Set<String> = []
    /// Activity ID and token of registrations under way.
    private static var inFlight: Set<String> = []
    private static var loggedUnsupported = false

    private static var running: [Activity<TrainActivityAttributes>] {
        Activity<TrainActivityAttributes>.activities.filter { [.active, .stale].contains($0.activityState) }
    }

    /// Registers `activity` with each push token iOS gives it, and forgets it if it ends by
    /// itself (swiped away, or ended by the push server after 30 minutes). `started`: when the
    /// app started it.
    static func watch(_ activity: Activity<TrainActivityAttributes>, started: Date? = nil) {
        let id = activity.id
        if let started, records[id]?.started == nil { records[id, default: Record()].started = started }
        guard watchers[id] == nil else { return }
        let tokens = Task {
            for await token in activity.pushTokenUpdates {
                await tokenChanged(activity, to: CountdownLookup.hex(token))
            }
        }
        let states = Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                ended(id)
                break
            }
        }
        watchers[id] = [tokens, states]
    }

    /// Stops pushes to a countdown the app is ending, without waiting for the server.
    static func ended(_ id: String) {
        watchers.removeValue(forKey: id)?.forEach { $0.cancel() }
        guard let token = records.removeValue(forKey: id)?.token else { return }
        Task { await unregister(token) }
    }

    /// At launch and on becoming active: watches countdowns still running, forgets ended ones,
    /// and registers any the server doesn't have yet.
    static func resume() {
        let running = running
        let ids = Set(running.map(\.id))
        for id in records.keys where !ids.contains(id) { ended(id) }
        for activity in running { watch(activity) }
        Task { await retry() }
    }

    /// Registers running countdowns the server doesn't have, or not yet since launch, and sends
    /// deletes that failed. `force` ignores the backoff, for the background refresh.
    static func retry(force: Bool = false) async {
        for token in pendingDeletes {
            pendingDeletes.removeAll { $0 == token }
            await unregister(token)
        }
        let now = Date.now
        let widgetToken = await currentWidgetToken()
        let alertKinds = currentAlertKinds()
        for activity in running {
            let id = activity.id
            guard let token = records[id]?.token ?? activity.pushToken.map(CountdownLookup.hex) else { continue }
            let record = records[id]
            if tried.contains(id) && record?.serverBacked == true && record?.token == token
                && record?.widgetToken == widgetToken && record?.alertKinds == alertKinds { continue }
            if !force, tried.contains(id), let retryAfter = record?.retryAfter, retryAfter > now { continue }
            records[id, default: Record()].token = token
            await register(activity, token: token)
        }
    }

    /// The background refresh: new times straight from the MTA, another try at the server, and
    /// another refresh later while that still hasn't worked.
    static func backgroundRefresh() async {
        await TrainActivityController.refresh()
        resume()
        await retry(force: true)
        scheduleRefreshIfNeeded()
    }

    /// Asks iOS for a background refresh while a countdown runs that the server doesn't have.
    static func scheduleRefreshIfNeeded() {
        guard running.contains(where: { records[$0.id]?.serverBacked != true }) else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        // iOS decides when, at most about every 15 minutes
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.notice("Couldn't schedule a background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func tokenChanged(_ activity: Activity<TrainActivityAttributes>, to token: String) async {
        let id = activity.id
        let old = records[id]?.token
        // For widgets showing its train, to find its state as the server last pushed it
        TrainActivityController.share(activity)
        // The token it already has, sent since launch: `retry` handles any failure
        if old == token && tried.contains(id) { return }
        records[id, default: Record()].token = token
        await register(activity, token: token)
        // Only after the new token's registered, so pushes don't stop in between
        if let old, old != token { await unregister(old) }
    }

    private static func register(_ activity: Activity<TrainActivityAttributes>, token: String) async {
        let id = activity.id
        let key = id + token
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        tried.insert(id)
        let widgetToken = await currentWidgetToken()
        let alertKinds = currentAlertKinds()
        let registration = PushRegistration(
            token: token,
            environment: PushServer.environment,
            selection: activity.attributes.selection,
            trip: activity.content.state.trip,
            started: records[id]?.started,
            alertKinds: alertKinds,
            state: activity.content.state,
            change: activity.attributes.change,
            widgetToken: widgetToken
        )
        let prefix = String(token.prefix(8))
        do {
            try await PushServer.shared.register(registration)
            guard records[id] != nil else {
                // Ended while registering
                await unregister(token)
                return
            }
            guard records[id]?.token == token else { return }
            records[id]?.serverBacked = true
            records[id]?.widgetToken = widgetToken
            records[id]?.alertKinds = alertKinds
            records[id]?.failures = 0
            records[id]?.retryAfter = nil
            log.info("Registered countdown \(prefix, privacy: .public)… (\(PushServer.environment, privacy: .public))")
        } catch {
            guard records[id]?.token == token else { return }
            let failures = (records[id]?.failures ?? 0) + 1
            records[id]?.serverBacked = false
            records[id]?.failures = failures
            // 1, 2, 4… minutes, up to 30
            records[id]?.retryAfter = .now.addingTimeInterval(min(60 * pow(2, Double(failures - 1)), 30 * 60))
            if case PushServer.Failure.unsupported = error {
                if !loggedUnsupported {
                    log.notice("No App Attest here (simulator?): countdowns refresh from the app only")
                    loggedUnsupported = true
                }
            } else {
                log.notice("Couldn't register countdown \(prefix, privacy: .public)…: \(String(describing: error), privacy: .public)")
            }
            scheduleRefreshIfNeeded()
        }
    }

    /// The phone's widget push token, in lowercase hex; nil before iOS gives one (or in a build
    /// without push notifications).
    private static func currentWidgetToken() async -> String? {
        await WidgetCenter.shared.currentPushInfo.map { CountdownLookup.hex($0.token) }
    }

    /// The alert kinds chosen in Settings, as registrations send them.
    private static func currentAlertKinds() -> [Int] {
        SharedStore.loadSettings().alertKinds.map(\.rawValue).sorted()
    }

    private static func unregister(_ token: String) async {
        let prefix = String(token.prefix(8))
        do {
            try await PushServer.shared.unregister(token: token)
            log.info("Unregistered countdown \(prefix, privacy: .public)…")
        } catch PushServer.Failure.unavailable {
            // Tell it later; meanwhile it ends the countdown after 30 minutes anyway
            if !pendingDeletes.contains(token) { pendingDeletes = Array((pendingDeletes + [token]).suffix(20)) }
        } catch {
            // Refused (another key's), or no server here: nothing to retry
            log.notice("Couldn't unregister countdown \(prefix, privacy: .public)…: \(String(describing: error), privacy: .public)")
        }
    }
}
