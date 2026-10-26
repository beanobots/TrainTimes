import Foundation

/// Where deploy/install.sh puts the server, and how launchd knows it.
enum Server {
    static let label = "com.traintimes.server"
    static let service = "system/\(label)"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let prefix = "/usr/local/traintimes"
    static let binaryPath = "\(prefix)/TrainTimesServer"
    static let defaultLogPath = "\(prefix)/server.log"
    static let defaultPort = 8080

    /// The server's package in the checkout, as the Rebuild sheet starts with.
    static let defaultSourcePath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Documents/TrainTimes/server").path
}
