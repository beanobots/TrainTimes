import Foundation
import Observation

/// What's known about the server, refreshed every few seconds, and what can
/// be done to it.
@MainActor @Observable
final class ServerModel {
    enum Health: Equatable {
        case unknown
        case ok(milliseconds: Int)
        case failing(String)
    }

    private(set) var status: DaemonStatus?
    private(set) var startDate: Date?
    private(set) var installedDate: Date?
    private(set) var health: Health = .unknown
    private(set) var tunnelRunning: Bool?

    /// The end of the log, oldest first.
    private(set) var lines: [LogLine] = []
    /// `lines` grouped for the Logs tab's readable view.
    private(set) var events: [LogEvent] = []
    private(set) var logSize: UInt64?
    private(set) var logProblem: String?

    private(set) var plist: DaemonPlist?
    private(set) var plistProblem: String?

    /// What's being done now, such as "Restarting…".
    private(set) var activity: String?
    var actionError: String?

    /// How many lines of the log are kept.
    static let maxLines = 20_000

    @ObservationIgnored private var logReader: LogReader?
    @ObservationIgnored private var logPath: String?

    /// Refreshes until the task is cancelled.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh() async {
        let status = await DaemonStatus.current()
        self.status = status
        startDate = status.pid.flatMap(DaemonStatus.startDate(of:))
        installedDate = (try? FileManager.default.attributesOfItem(atPath: Server.binaryPath))?[.modificationDate] as? Date

        do {
            plist = try DaemonPlist.read()
            plistProblem = nil
        } catch {
            plist = nil
            plistProblem = Self.describe(error, path: Server.plistPath)
        }

        async let health = Self.checkHealth(port: Int(environment["PORT"] ?? "") ?? Server.defaultPort)
        async let tunnel = Shell.run("/usr/bin/pgrep", ["-x", "cloudflared"]).succeeded
        await readLog()
        (self.health, tunnelRunning) = await (health, tunnel)
    }

    /// The environment the server runs with, as launchd has it; or as the plist
    /// has it when it isn't loaded.
    var environment: [String: String] {
        if let status, status.isLoaded { return status.environment }
        return plist?.environment ?? [:]
    }

    /// `setting`'s value as the server runs with it, defaults included.
    func value(of setting: Setting) -> String? {
        setting.effective(environment[setting.key])
    }

    // MARK: The log

    private func readLog() async {
        let path = environment["LOG_FILE"] ?? Server.defaultLogPath
        if path != logPath {
            logPath = path
            logReader = LogReader(path: path)
            lines = []
            events = []
        }
        guard let logReader else { return }
        do {
            let chunk = try await logReader.read()
            if chunk.restarted { lines = [] }
            if !chunk.lines.isEmpty {
                lines.append(contentsOf: chunk.lines)
                if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
            }
            if chunk.restarted || !chunk.lines.isEmpty { events = LogEvent.group(lines) }
            logSize = chunk.size
            logProblem = nil
        } catch {
            logProblem = Self.describe(error, path: path)
        }
    }

    var lastPass: LogLine? { lines.last { $0.pass != nil } }

    /// Passes in the hour before the last one.
    var recentPasses: [(date: Date, stats: PassStats)] {
        guard let last = lastPass?.date else { return [] }
        let start = last.addingTimeInterval(-3600)
        return lines.compactMap { line in
            guard let date = line.date, date >= start, let stats = line.pass else { return nil }
            return (date, stats)
        }
    }

    /// When a pass last pushed anything.
    var lastPush: Date? { lines.last { ($0.pass?.pushes ?? 0) > 0 }?.date }

    /// From the last pass that counted them, or the server's start.
    var keyCount: Int? {
        for line in lines.reversed() {
            if let keys = line.pass?.keys ?? line.startKeys { return keys }
        }
        return nil
    }

    // MARK: Actions, as root

    func start() async {
        await perform("Starting…", "launchctl bootstrap system \(Shell.quoted(Server.plistPath))",
                      prompt: "Train Times Server wants to start the server.")
    }

    func stop() async {
        await perform("Stopping…", "launchctl bootout \(Server.service)",
                      prompt: "Train Times Server wants to stop the server.")
    }

    func restart() async {
        await perform("Restarting…", "launchctl kickstart -k \(Server.service)",
                      prompt: "Train Times Server wants to restart the server.")
    }

    /// Writes the plist with `changes` (nil or blank: left out, for the default),
    /// then loads it again, which a restart alone doesn't. Whether it did.
    @discardableResult
    func save(_ changes: [String: String?]) async -> Bool {
        guard let plist else {
            actionError = plistProblem ?? "The plist couldn't be read."
            return false
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "\(Server.label)-\(UUID().uuidString).plist")
        do {
            let environment = DaemonPlist.applying(changes, to: plist.environment)
            try plist.replacingEnvironment(with: environment).write(to: file, options: .atomic)
        } catch {
            actionError = error.localizedDescription
            return false
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let plistPath = Shell.quoted(Server.plistPath)
        // launchd only reads the environment as it loads the plist; it takes a moment to let go of the old one
        let script = """
            set -euo pipefail
            plutil -lint -s \(Shell.quoted(file.path))
            install -o root -g admin -m 640 \(Shell.quoted(file.path)) \(plistPath)
            launchctl bootout \(Server.service) 2>/dev/null || true
            for _ in $(seq 1 40); do launchctl print \(Server.service) >/dev/null 2>&1 || break; sleep 0.25; done
            launchctl bootstrap system \(plistPath)
            """
        return await perform("Saving and restarting…", script,
                             prompt: "Train Times Server wants to change the server's settings and restart it.")
    }

    /// Runs `script` as root, then refreshes. Whether it succeeded.
    @discardableResult
    func perform(_ description: String, _ script: String, prompt: String) async -> Bool {
        activity = description
        defer { activity = nil }
        do {
            try await Shell.runAsAdmin(script, prompt: prompt)
            await refresh()
            return true
        } catch let error as Shell.AdminError where error.cancelled {
            return false
        } catch {
            actionError = error.localizedDescription
            await refresh()
            return false
        }
    }

    // MARK: Helpers

    nonisolated static func checkHealth(port: Int) async -> Health {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return .unknown }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "GET"
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = clock.now - start
            guard (response as? HTTPURLResponse)?.statusCode == 200, String(decoding: data, as: UTF8.self) == "ok" else {
                return .failing("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            return .ok(milliseconds: Int(elapsed.components.seconds * 1000
                                         + elapsed.components.attoseconds / 1_000_000_000_000_000))
        } catch {
            return .failing((error as? URLError)?.code == .cannotConnectToHost ? "Not listening" : error.localizedDescription)
        }
    }

    private static func describe(_ error: Error, path: String) -> String {
        let code = (error as NSError).code
        if code == NSFileReadNoPermissionError || (error as NSError).underlyingErrors.contains(where: { ($0 as NSError).code == Int(EACCES) }) {
            return "\(path) isn't readable by admins yet. Rebuild once to run the new install.sh, which makes it so."
        }
        if code == NSFileReadNoSuchFileError { return "\(path) doesn't exist." }
        return error.localizedDescription
    }
}
