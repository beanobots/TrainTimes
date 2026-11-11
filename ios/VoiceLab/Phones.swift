import Foundation

/// Where a mix can be sent: the booted simulator (simctl) or a paired iPhone (devicectl), into
/// Leeway's Documents/VoicePack, where debug builds look for the voice pack's files first.
enum Phones {
    static let app = "dev.dctp.leeway"

    struct Target: Hashable, Identifiable {
        /// Nil for the booted simulator; a device's devicectl identifier.
        var device: String?
        var name: String
        var id: String { device ?? "simulator" }

        static let simulator = Target(device: nil, name: "Booted Simulator")
    }

    /// The booted simulator, then each physical iPhone paired with this Mac.
    static func targets() async -> [Target] {
        let json = FileManager.default.temporaryDirectory.appending(path: "voicelab-devices.json")
        var targets = [Target.simulator]
        guard (try? await run(["devicectl", "list", "devices", "--json-output", json.path])) != nil,
              let data = try? Data(contentsOf: json),
              let list = try? JSONDecoder().decode(DeviceList.self, from: data) else { return targets }
        targets += list.result.devices
            .filter { $0.hardwareProperties.deviceType == "iPhone" && $0.hardwareProperties.reality == "physical" }
            .map { Target(device: $0.identifier, name: $0.deviceProperties.name) }
        return targets
    }

    static func send(_ data: Data, as file: String, to target: Target) async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: file)
        try data.write(to: source)
        if let device = target.device {
            try await run(["devicectl", "device", "copy", "to", "--device", device,
                           "--domain-type", "appDataContainer", "--domain-identifier", app,
                           "--source", source.path, "--destination", "Documents/VoicePack/\(file)"])
        } else {
            let container = try await run(["simctl", "get_app_container", "booted", app, "data"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let folder = URL(filePath: container).appending(path: "Documents/VoicePack", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appending(path: file)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// `xcrun` with `arguments`: what it printed, or what went wrong.
    @discardableResult
    private static func run(_ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcrun")
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let output = out.fileHandleForReading.readDataToEndOfFile()
            let error = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(errorDescription: message.isEmpty ? "xcrun \(arguments[0]) failed" : message)
            }
            return String(decoding: output, as: UTF8.self)
        }.value
    }

    /// devicectl's list, as far as it's needed.
    private struct DeviceList: Decodable {
        struct Result: Decodable { var devices: [Device] }
        struct Device: Decodable {
            struct Hardware: Decodable {
                var deviceType: String?
                var reality: String?
            }
            struct Properties: Decodable { var name: String }
            var identifier: String
            var hardwareProperties: Hardware
            var deviceProperties: Properties
        }
        var result: Result
    }
}
