import Foundation
import ServiceLifecycle

/// Crash and hang reports from phones sharing diagnostics (`POST /diagnostics`): each a JSON
/// file in `DATA_DIR/diagnostics/`, readable only by the server's user, named by when it came
/// and what kind it is. Kept for `retention`, and at most `maxReports`, the oldest going first;
/// with no directory (tests), in memory. Nothing says which phone sent one.
actor DiagnosticStore {
    static let directoryName = "diagnostics"

    /// What the app sends (ios/App/Diagnostics.swift, `Diagnostics.report`).
    static let kinds: Set<String> = ["crash", "hang", "cpu", "disk", "launch"]

    private let directory: URL?
    private let maxReports: Int
    private let retention: TimeInterval
    private var inMemory: [(name: String, saved: Date, body: [UInt8])] = []

    /// In memory, for tests.
    init(maxReports: Int = 1000, retention: TimeInterval = 30 * 86400) {
        self.maxReports = maxReports
        self.retention = retention
        directory = nil
    }

    init(directory: URL?, maxReports: Int = 1000, retention: TimeInterval = 30 * 86400) throws {
        self.maxReports = maxReports
        self.retention = retention
        self.directory = directory?.appendingPathComponent(Self.directoryName, isDirectory: true)
        if let folder = self.directory {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    /// The report's kind if `body` is one as the app sends: a JSON object with a known `kind`,
    /// MetricKit's report as `metricKit`, and short `app`, `os` and `device` strings.
    static func kind(of body: some Sequence<UInt8>) -> String? {
        guard let report = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
              let kind = report["kind"] as? String, kinds.contains(kind),
              report["metricKit"] is [String: Any],
              ["app", "os", "device"].allSatisfy({ ((report[$0] as? String)?.utf8.count ?? .max) <= 200 }),
              report["log"] == nil || report["log"] is String else { return nil }
        return kind
    }

    /// Saves a report checked by `kind(of:)`, then prunes; its name.
    func save(_ body: [UInt8], kind: String, now: Date = .now) throws -> String {
        let name = Self.name(kind: kind, at: now)
        if let directory {
            let path = directory.appendingPathComponent(name).path
            guard FileManager.default.createFile(atPath: path, contents: Data(body),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        } else {
            inMemory.append((name, now, body))
        }
        try prune(now: now)
        return name
    }

    /// Deletes reports older than `retention`, then the oldest over `maxReports`; how many.
    @discardableResult
    func prune(now: Date = .now) throws -> Int {
        let reports = try saved().sorted { $0.saved < $1.saved }
        let old = reports.filter { now.timeIntervalSince($0.saved) > retention }
        let over = reports.dropFirst(old.count).dropLast(maxReports)
        let gone = Set((old + over).map(\.name))
        guard !gone.isEmpty else { return 0 }
        if let directory {
            for name in gone {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        } else {
            inMemory.removeAll { gone.contains($0.name) }
        }
        return gone.count
    }

    /// Every report kept, oldest first.
    var names: [String] {
        get throws { try saved().sorted { $0.saved < $1.saved }.map(\.name) }
    }

    /// A report's body, for tests.
    func body(named name: String) throws -> [UInt8]? {
        if let directory {
            return try? Array(Data(contentsOf: directory.appendingPathComponent(name)))
        }
        return inMemory.first { $0.name == name }?.body
    }

    private func saved() throws -> [(name: String, saved: Date)] {
        guard let directory else { return inMemory.map { ($0.name, $0.saved) } }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey])
        return files.filter { $0.pathExtension == "json" }.map { file in
            (file.lastPathComponent,
             (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
    }

    /// As "20261101-140322-crash-1a2b3c4d.json", in UTC.
    static func name(kind: String, at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return "\(stamp)-\(kind)-\(String(format: "%08x", UInt32.random(in: .min ... .max))).json"
    }
}

/// Prunes `DiagnosticStore` at start and every hour, so reports go after 30 days even when no
/// new one comes.
struct DiagnosticPruner: Service {
    let store: DiagnosticStore

    func run() async throws {
        while !Task.isCancelled && !Task.isShuttingDownGracefully {
            do {
                let gone = try await store.prune()
                if gone > 0 { Log.info("diagnostics: deleted \(gone) old reports") }
            } catch {
                Log.error("diagnostics: couldn't prune: \(error)")
            }
            do {
                try await cancelWhenGracefulShutdown { try await Task.sleep(for: .seconds(60 * 60)) }
            } catch {
                break
            }
        }
    }
}
