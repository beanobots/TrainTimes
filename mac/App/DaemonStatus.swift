import Darwin
import Foundation

/// What `launchctl print system/com.traintimes.server` says, which needs no
/// admin rights: whether it's loaded and running, and the environment it runs with.
struct DaemonStatus: Equatable, Sendable {
    var isLoaded: Bool
    /// "running", "not running", "spawn scheduled" and so on.
    var state: String?
    var pid: Int32?
    var lastExitCode: String?
    var environment: [String: String]

    static let notLoaded = DaemonStatus(isLoaded: false, state: nil, pid: nil, lastExitCode: nil, environment: [:])

    var isRunning: Bool { state == "running" && pid != nil }

    static func parse(_ output: String) -> DaemonStatus {
        var status = DaemonStatus(isLoaded: true, state: nil, pid: nil, lastExitCode: nil, environment: [:])
        var inEnvironment = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inEnvironment {
                if trimmed == "}" {
                    inEnvironment = false
                } else if let arrow = trimmed.range(of: " => ") {
                    status.environment[String(trimmed[..<arrow.lowerBound])] = String(trimmed[arrow.upperBound...])
                }
                continue
            }
            // Not "default environment = {", which is launchd's own PATH
            if trimmed == "environment = {" {
                inEnvironment = true
            } else if let value = value(of: "state", in: trimmed), status.state == nil {
                status.state = value
            } else if let value = value(of: "pid", in: trimmed) {
                status.pid = Int32(value)
            } else if let value = value(of: "last exit code", in: trimmed) {
                status.lastExitCode = value
            }
        }
        return status
    }

    private static func value(of key: String, in line: String) -> String? {
        let prefix = "\(key) = "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// Asks launchd. A status of 113 is launchctl's "Could not find service".
    static func current() async -> DaemonStatus {
        let result = await Shell.run("/bin/launchctl", ["print", Server.service])
        guard result.succeeded else { return .notLoaded }
        return parse(result.output)
    }

    /// When the process `pid` started.
    static func startDate(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
