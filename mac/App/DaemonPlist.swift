import Foundation

/// The LaunchDaemon's plist, whose EnvironmentVariables are the server's
/// settings. install.sh makes it readable by admins; writing it needs root.
struct DaemonPlist: Sendable {
    struct Problem: LocalizedError {
        var errorDescription: String?
    }

    /// The file as read.
    let data: Data
    let environment: [String: String]

    init(data: Data) throws {
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Problem(errorDescription: "The plist isn't a dictionary.")
        }
        self.data = data
        environment = (root["EnvironmentVariables"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    }

    static func read(at path: String = Server.plistPath) throws -> DaemonPlist {
        try DaemonPlist(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// The plist with `environment` as its EnvironmentVariables, and everything
    /// else as it was. Its comments don't survive.
    func replacingEnvironment(with environment: [String: String]) throws -> Data {
        guard var root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Problem(errorDescription: "The plist isn't a dictionary.")
        }
        root["EnvironmentVariables"] = environment
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    /// `environment` with `changes` made: a value of nil or blank removes the key,
    /// so the server uses its default.
    static func applying(_ changes: [String: String?], to environment: [String: String]) -> [String: String] {
        var result = environment
        for (key, value) in changes {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result[key] = trimmed.isEmpty ? nil : trimmed
        }
        return result
    }
}
