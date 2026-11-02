import Foundation
import MetricKit
import os

/// The app's log: each line goes to the system log, public, and to `DiagnosticLog` on the phone,
/// so a crash report can bring the lines before it. Nothing written here should say where
/// someone is or is going.
struct AppLog: Sendable {
    private let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Leeway", category: category)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        DiagnosticLog.append("info", category, message)
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        DiagnosticLog.append("notice", category, message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        DiagnosticLog.append("error", category, message)
    }
}

/// The last `maxBytes` or so of `AppLog`'s lines, in a file kept across launches, so the lines
/// before a crash are still there when MetricKit reports it on the next. Written one line at a
/// time on its own queue; kept whether or not diagnostics are shared, and only ever sent if they are.
enum DiagnosticLog {
    /// Over this, the oldest lines go, down to half of it.
    static let maxBytes = 256 * 1024

    static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Diagnostics/log.txt", directoryHint: .notDirectory)
    }

    private static let queue = DispatchQueue(label: "dev.dctp.leeway.diagnostic-log", qos: .utility)
    /// Only touched on `queue`.
    nonisolated(unsafe) private static var handle: FileHandle?

    /// A line with the time, level and category, as "2026-11-01T14:03:22Z notice PushServer: …".
    static func append(_ level: String, _ category: String, _ message: String) {
        let line = "\(Date.now.formatted(.iso8601)) \(level) \(category): \(message)\n"
        queue.async { write(Data(line.utf8)) }
    }

    /// A line for each launch, with the build and system, to tell runs apart.
    static func launched() {
        append("launch", "App", "\(Diagnostics.appVersion), \(Diagnostics.osVersion), \(Diagnostics.deviceModel)")
    }

    /// Everything kept, oldest first; at most `bytes` from the end, starting on a whole line.
    static func contents(lastBytes bytes: Int = maxBytes) -> String {
        queue.sync {
            try? handle?.synchronize()
            guard let data = try? Data(contentsOf: fileURL) else { return "" }
            return String(decoding: wholeLines(data.suffix(bytes), dropFirst: data.count > bytes), as: UTF8.self)
        }
    }

    private static func write(_ data: Data) {
        if handle == nil { open() }
        guard let handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if try handle.offset() > UInt64(maxBytes) { trim() }
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private static func open() {
        let url = fileURL
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forUpdating: url)
    }

    /// Keeps the newest half, from a whole line.
    private static func trim() {
        try? handle?.close()
        handle = nil
        guard let data = try? Data(contentsOf: fileURL) else { return }
        try? wholeLines(data.suffix(maxBytes / 2), dropFirst: true).write(to: fileURL, options: .atomic)
        open()
    }

    /// `data` from just after its first newline, when its start may be partway through a line.
    private static func wholeLines(_ data: Data, dropFirst: Bool) -> Data {
        guard dropFirst, let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data(data) }
        return Data(data[data.index(after: newline)...])
    }
}

/// Crash, hang and other reports MetricKit gives the app on the launch after, sent to the push
/// server (`POST /diagnostics`) with the log's last lines (`DiagnosticLog`), for anyone who's
/// turned on Share Diagnostics in Settings. Kept on the phone until the server has them, for up
/// to `pendingLifetime`.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Diagnostics()

    /// Settings' Share Diagnostics, in the app's own defaults: off until turned on.
    static let sharesKey = "sharesDiagnostics"
    static var isSharing: Bool { UserDefaults.standard.bool(forKey: sharesKey) }

    /// The server's limit on a report (server/Sources/TrainCore/HTTP.swift, `diagnosticsBodyLimit`).
    static let bodyLimit = 512 * 1024
    /// Reports the server hasn't taken by then are dropped.
    private static let pendingLifetime: TimeInterval = 7 * 86400

    private static let log = AppLog(category: "Diagnostics")

    private static var pendingDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Diagnostics/Pending", directoryHint: .isDirectory)
    }

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }()

    static let osVersion = "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"

    /// The hardware's model, as "iPhone17,1".
    static let deviceModel: String = {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    /// At launch: marks the log, listens for MetricKit's reports, and sends any still waiting.
    func start() {
        DiagnosticLog.launched()
        MXMetricManager.shared.add(self)
        Task { await Self.sendPending() }
    }

    /// MetricKit's reports: dropped unless diagnostics are shared, as MetricKit gives each once.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard Self.isSharing else { return }
        let log = DiagnosticLog.contents()
        for payload in payloads {
            guard let body = Self.report(payload, log: log) else { continue }
            Self.keep(body)
        }
        Task { await Self.sendPending() }
    }

    /// When Share Diagnostics is turned off: what hasn't gone yet won't.
    static func discardPending() {
        try? FileManager.default.removeItem(at: pendingDirectory)
    }

    /// `POST /diagnostics`'s body: what kind of report, the build, system and model, MetricKit's
    /// own JSON, and as much of `log`'s end as fits under `bodyLimit`. Nil for an empty report,
    /// or one too big even without the log.
    static func report(_ payload: MXDiagnosticPayload, log: String) -> Data? {
        let kind: String
        if !(payload.crashDiagnostics ?? []).isEmpty { kind = "crash" }
        else if !(payload.hangDiagnostics ?? []).isEmpty { kind = "hang" }
        else if !(payload.cpuExceptionDiagnostics ?? []).isEmpty { kind = "cpu" }
        else if !(payload.diskWriteExceptionDiagnostics ?? []).isEmpty { kind = "disk" }
        else if !(payload.appLaunchDiagnostics ?? []).isEmpty { kind = "launch" }
        else { return nil }
        guard let metricKit = try? JSONSerialization.jsonObject(with: payload.jsonRepresentation()) else { return nil }
        var report: [String: Any] = [
            "kind": kind, "app": appVersion, "os": osVersion, "device": deviceModel,
            "metricKit": metricKit, "log": "",
        ]
        guard let bare = try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys) else { return nil }
        // Room for the log, less a little for the escaping its quotes and newlines need
        let room = (bodyLimit - bare.count) * 9 / 10
        guard room >= 0 else {
            Self.log.notice("A \(kind) report was too big to send")
            return nil
        }
        let logData = Data(log.utf8)
        if logData.count > room {
            let tail = logData.suffix(room)
            let start = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail.index(after: $0) } ?? tail.startIndex
            report["log"] = String(decoding: tail[start...], as: UTF8.self)
        } else {
            report["log"] = log
        }
        return try? JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
    }

    /// Saved until the server has it.
    private static func keep(_ body: Data) {
        let manager = FileManager.default
        try? manager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try? body.write(to: pendingDirectory.appending(path: "\(UUID().uuidString).json"), options: .atomic)
    }

    /// Whether `sendPending` is going, so two don't send the same report.
    @MainActor private static var sending = false

    /// Sends the reports waiting, oldest first, stopping at the first the server can't take now
    /// for the next launch or return to the app to try again. Drops all of them once diagnostics
    /// aren't shared, and any older than `pendingLifetime`.
    @MainActor static func sendPending() async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: [.creationDateKey]),
              !files.isEmpty else { return }
        guard isSharing else { return discardPending() }
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        for (file, created) in dated.sorted(by: { $0.1 < $1.1 }) {
            guard Date.now.timeIntervalSince(created) < pendingLifetime, let body = try? Data(contentsOf: file) else {
                try? manager.removeItem(at: file)
                continue
            }
            do {
                try await PushServer.shared.sendDiagnostics(body)
                log.info("Sent a report")
            } catch PushServer.Failure.unavailable, PushServer.Failure.refused(404) {
                // Out of reach, over today's limit, or a server from before reports: later
                return
            } catch {
                // Refused outright, or no App Attest here (the simulator): it never will be taken
                log.notice("Report not taken: \(String(describing: error))")
            }
            try? manager.removeItem(at: file)
        }
    }
}
