import Foundation

/// Runs programs as this user, and scripts as root after macOS asks for an
/// admin password.
enum Shell {
    struct Result: Sendable {
        var status: Int32
        /// stdout and stderr together.
        var output: String
        var succeeded: Bool { status == 0 }
    }

    /// Runs `path` with `arguments`, handing each chunk of output to
    /// `onOutput` as it comes, in order. Returns once the program has exited
    /// and all its output is read and handed on. Cancelling the task stops
    /// the program as Control-C would, then for good after 5 seconds.
    static func run(_ path: String, _ arguments: [String] = [], in directory: String? = nil,
                    onOutput: (@MainActor @Sendable (String) -> Void)? = nil) async -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { process in
            exited.yield(process.terminationStatus)
            exited.finish()
        }
        let running = RunningProcess(process)
        return await withTaskCancellationHandler {
            do {
                guard try running.launch() else { return Result(status: -1, output: "Cancelled.") }
            } catch {
                return Result(status: -1, output: error.localizedDescription)
            }
            // Read on a thread of its own until EOF, which comes once the
            // program, and anything it started that shares the pipe, is done
            let (chunks, sink) = AsyncStream.makeStream(of: Data.self)
            let reader = pipe.fileHandleForReading
            Thread.detachNewThread {
                while let data = try? reader.read(upToCount: 64 * 1024), !data.isEmpty {
                    sink.yield(data)
                }
                sink.finish()
            }
            var output = Data()
            var pending = Data()
            for await data in chunks {
                output += data
                guard let onOutput else { continue }
                // A character split between two chunks is handed on whole
                pending += data
                let complete = UTF8Chunks.completePrefix(of: pending)
                if complete > 0 {
                    let text = String(decoding: pending.prefix(complete), as: UTF8.self)
                    pending = Data(pending.dropFirst(complete))
                    await onOutput(text)
                }
            }
            if let onOutput, !pending.isEmpty { await onOutput(String(decoding: pending, as: UTF8.self)) }
            var status: Int32 = -1
            for await code in exits { status = code }
            return Result(status: status, output: String(decoding: output, as: UTF8.self))
        } onCancel: {
            running.cancel()
        }
    }

    struct AdminError: LocalizedError {
        var message: String
        var cancelled: Bool
        var errorDescription: String? { message }
    }

    /// Runs `script` with bash as root. macOS asks for an admin password,
    /// with `prompt`, unless it was given in the last few minutes. Its
    /// output, stderr included.
    @discardableResult
    static func runAsAdmin(_ script: String, prompt: String) async throws -> String {
        let file = FileManager.default.temporaryDirectory.appending(path: "traintimes-\(UUID().uuidString).sh")
        try Data("exec 2>&1\n\(script)\n".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }
        let source = "do shell script \"/bin/bash \" & quoted form of \"\(file.path)\" "
            + "with prompt \"\(prompt.replacingOccurrences(of: "\"", with: "'"))\" with administrator privileges"
        let result = await run("/usr/bin/osascript", ["-e", source])
        // do shell script ends lines with returns
        let output = result.output.replacingOccurrences(of: "\r", with: "\n")
        guard result.succeeded else {
            let cancelled = output.contains("(-128)")
            throw AdminError(message: cancelled ? "Cancelled." : cleanedError(output), cancelled: cancelled)
        }
        return output
    }

    /// osascript's "0:94: execution error: … (1)" as just the message.
    private static func cleanedError(_ output: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "execution error: ") { text = String(text[range.upperBound...]) }
        if let range = text.range(of: #"\s*\(-?\d+\)$"#, options: .regularExpression) { text.removeSubrange(range) }
        return text.isEmpty ? "The command failed." : text
    }

    /// `text` in single quotes for bash.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A program `Shell.run` starts, which a cancel stops: before it starts, it
/// then never does.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false

    init(_ process: Process) {
        self.process = process
    }

    /// Starts it; false if it was cancelled first.
    func launch() throws -> Bool {
        try lock.withLock {
            guard !cancelled else { return false }
            try process.run()
            return true
        }
    }

    /// Control-C, which `swift build` and `swift test` stop their own
    /// programs for, then SIGTERM if it's still running 5 seconds on.
    func cancel() {
        lock.withLock {
            cancelled = true
            guard process.isRunning else { return }
            process.interrupt()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
            lock.withLock {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Where output can be cut so no character is split.
enum UTF8Chunks {
    /// How many of `data`'s bytes end on a whole character: all of them
    /// unless the last character's bytes haven't all come yet.
    static func completePrefix(of data: Data) -> Int {
        let bytes = Array(data.suffix(4))
        guard !bytes.isEmpty else { return 0 }
        // From the end, find the lead byte of the last character
        for back in 1...bytes.count {
            let byte = bytes[bytes.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue }
            let length = byte >= 0b1111_0000 ? 4 : byte >= 0b1110_0000 ? 3 : byte >= 0b1100_0000 ? 2 : 1
            return length > back ? data.count - back : data.count
        }
        // Only continuation bytes: not UTF-8, so hand it on as it is
        return data.count
    }
}
