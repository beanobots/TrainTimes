import Foundation
import Observation

/// Builds the server from the files on disk (it never pulls), tests it,
/// installs it with deploy/install.sh as root, and checks it's answering.
@MainActor @Observable
final class Rebuild {
    enum State: Equatable {
        case waiting, running, done(String), failed(String), skipped
    }

    enum Step: CaseIterable, Identifiable {
        case build, test, install, health
        var id: Self { self }

        var title: String {
            switch self {
            case .build: "Build release"
            case .test: "Run tests"
            case .install: "Install & restart"
            case .health: "Check health"
            }
        }

        var command: String {
            switch self {
            case .build: "swift build -c release"
            case .test: "swift test"
            case .install: "deploy/install.sh as administrator"
            case .health: "GET /health"
            }
        }
    }

    var sourcePath: String
    var runTests = true
    private(set) var states: [Step: State] = [:]
    private(set) var output = ""
    private(set) var isRunning = false
    private(set) var finished = false
    /// Cancel was pressed, and the step running is stopping.
    private(set) var isCancelling = false
    private var task: Task<Void, Never>?
    /// Files changed and not committed in the server and the app's Shared
    /// folder, which it builds with too.
    private(set) var uncommitted: Int?

    init(sourcePath: String) {
        self.sourcePath = sourcePath
    }

    func state(of step: Step) -> State { states[step] ?? .waiting }

    var succeeded: Bool { finished && Step.allCases.allSatisfy { if case .failed = state(of: $0) { false } else { true } } }

    func checkSource() async {
        let result = await Shell.run("/usr/bin/git", ["-C", sourcePath, "status", "--porcelain", "--", ".", "../ios/Shared"])
        uncommitted = result.succeeded
            ? result.output.split(separator: "\n").count
            : nil
    }

    var sourceProblem: String? {
        FileManager.default.fileExists(atPath: "\(sourcePath)/Package.swift")
            && FileManager.default.fileExists(atPath: "\(sourcePath)/deploy/install.sh")
            ? nil : "No server package (Package.swift and deploy/install.sh) here."
    }

    /// Whether Cancel can stop the run now: not while install.sh runs as
    /// root, which is left to finish so the server isn't half installed.
    var canCancel: Bool { isRunning && !isCancelling && state(of: .install) != .running }

    /// Runs the steps, unless they're running already.
    func start(model: ServerModel) {
        guard !isRunning else { return }
        task = Task { await run(model: model) }
    }

    /// Stops the step running, and skips the rest.
    func cancel() {
        guard canCancel else { return }
        isCancelling = true
        task?.cancel()
    }

    func run(model: ServerModel) async {
        isRunning = true
        finished = false
        isCancelling = false
        states = [:]
        output = ""
        defer {
            isRunning = false
            isCancelling = false
            finished = true
            task = nil
        }

        // As this user, so .build stays theirs
        guard await runSwift(.build, ["build", "-c", "release", "--package-path", sourcePath], summary: { _ in "Built" })
        else { return }
        if runTests {
            guard await runSwift(.test, ["test", "--package-path", sourcePath], summary: Self.testSummary) else { return }
        } else {
            states[.test] = .skipped
        }

        guard !Task.isCancelled else { return }
        states[.install] = .running
        // Root can't read ~/Documents (privacy protection doesn't pass to osascript's root shell), so it
        // runs a copy of deploy/ with the build beside it, and install.sh doesn't build again
        let staged: URL
        do {
            staged = try await stage()
        } catch {
            append("\nCouldn't copy the build for install.sh: \(error.localizedDescription)\n")
            states[.install] = .failed("Couldn't copy the build")
            return
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        let script = "PREBUILT_BIN_DIR=\(Shell.quoted(staged.appending(path: "bin").path)) "
            + "/bin/bash \(Shell.quoted(staged.appending(path: "deploy/install.sh").path))"
        do {
            // In a task of its own, which Cancel doesn't reach
            let installOutput = try await Task {
                try await Shell.runAsAdmin(script, prompt: "Train Times Server wants to install the new build.")
            }.value
            append("\n$ sudo ./deploy/install.sh\n" + installOutput)
            states[.install] = .done("Installed")
        } catch {
            append("\n$ sudo ./deploy/install.sh\n\(error.localizedDescription)\n")
            states[.install] = .failed((error as? Shell.AdminError)?.cancelled == true ? "Cancelled" : "install.sh failed")
            return
        }

        guard !Task.isCancelled else {
            await model.refresh()
            return
        }
        states[.health] = .running
        let port = Int(model.environment["PORT"] ?? "") ?? Server.defaultPort
        for _ in 0..<20 {
            if Task.isCancelled {
                states[.health] = .failed("Cancelled")
                await model.refresh()
                return
            }
            if case .ok(let milliseconds) = await ServerModel.checkHealth(port: port) {
                states[.health] = .done("ok in \(milliseconds) ms")
                await model.refresh()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        states[.health] = .failed("No answer in 20 s: see Logs")
        await model.refresh()
    }

    private func runSwift(_ step: Step, _ arguments: [String], summary: (String) -> String) async -> Bool {
        states[step] = .running
        append("$ swift \(arguments.joined(separator: " "))\n")
        let clock = ContinuousClock()
        let start = clock.now
        // Shell.run hands on all the output, in order, before it returns
        let result = await Shell.run("/usr/bin/swift", arguments, in: sourcePath) { [weak self] text in
            self?.append(text)
        }
        if Task.isCancelled {
            append("\nCancelled.\n")
            states[step] = .failed("Cancelled")
            return false
        }
        let seconds = Int((clock.now - start).components.seconds)
        let duration = seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
        if result.succeeded {
            states[step] = .done("\(summary(result.output)) · \(duration)")
            return true
        }
        states[step] = .failed("Failed (exit \(result.status)) · see output")
        return false
    }

    /// Copies deploy/ and the release build's program and resources to a new
    /// folder in this user's temporary directory, as deploy/ and bin/.
    private func stage() async throws -> URL {
        let result = await Shell.run("/usr/bin/swift", ["build", "-c", "release", "--package-path", sourcePath,
                                                        "--show-bin-path"], in: sourcePath)
        let binPath = result.output.split(separator: "\n").last.map(String.init) ?? ""
        guard result.succeeded, !binPath.isEmpty else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "No release build: \(result.output)"])
        }
        let fileManager = FileManager.default
        let staged = fileManager.temporaryDirectory.appending(path: "traintimes-install-\(UUID().uuidString)")
        let bin = staged.appending(path: "bin")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.copyItem(at: URL(fileURLWithPath: sourcePath).appending(path: "deploy"),
                                 to: staged.appending(path: "deploy"))
        for name in ["TrainTimesServer", "TrainTimesServer_TrainResources.bundle"] {
            try fileManager.copyItem(at: URL(fileURLWithPath: binPath).appending(path: name), to: bin.appending(path: name))
        }
        return staged
    }

    /// "Test run with 379 tests in 41 suites passed" as "379 passed".
    nonisolated static func testSummary(_ output: String) -> String {
        guard let range = output.range(of: #"Test run with (\d+) tests? .*passed"#, options: .regularExpression) else {
            return "Passed"
        }
        let words = output[range].split(separator: " ")
        return words.count > 3 ? "\(words[3]) passed" : "Passed"
    }

    private func append(_ text: String) {
        output += text
    }
}
