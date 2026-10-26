import Foundation
import Testing
@testable import Train_Times_Server

@Suite struct DaemonStatusTests {
    /// Trimmed from `launchctl print system/com.traintimes.server`.
    let running = """
        system/com.traintimes.server = {
        \tactive count = 1
        \tpath = /Library/LaunchDaemons/com.traintimes.server.plist
        \ttype = LaunchDaemon
        \tstate = running

        \tprogram = /usr/local/traintimes/TrainTimesServer
        \tdefault environment = {
        \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
        \t}

        \tenvironment = {
        \t\tATTEST_ENVIRONMENT => both
        \t\tPORT => 8080
        \t\tPOLL_SECONDS => 30
        \t}

        \tdomain = system
        \truns = 3
        \tpid = 4127
        \timmediate reason = speculative
        \tlast exit code = 0
        \tspawn type = daemon (3)
        \tjob state = running
        }
        """

    @Test func readsStatePidAndTheEnvironment() {
        let status = DaemonStatus.parse(running)
        #expect(status.isLoaded)
        #expect(status.isRunning)
        #expect(status.state == "running")
        #expect(status.pid == 4127)
        #expect(status.lastExitCode == "0")
        // Not launchd's own PATH
        #expect(status.environment == ["ATTEST_ENVIRONMENT": "both", "PORT": "8080", "POLL_SECONDS": "30"])
    }

    @Test func aLoadedDaemonWithNoPidIsntRunning() {
        let status = DaemonStatus.parse("""
            system/com.traintimes.server = {
            \tstate = not running
            \tlast exit code = 78: EX_CONFIG
            }
            """)
        #expect(status.isLoaded)
        #expect(!status.isRunning)
        #expect(status.lastExitCode == "78: EX_CONFIG")
    }

    @Test func findsThisProcesssStart() throws {
        let start = try #require(DaemonStatus.startDate(of: ProcessInfo.processInfo.processIdentifier))
        #expect(start <= .now)
        #expect(start > .now.addingTimeInterval(-3600))
    }
}

@Suite struct LogLineTests {
    @Test func readsAPassWithItsKeys() throws {
        let line = LogLine(id: 0, text: "2026-10-21T17:37:25Z pass: 1284 countdowns, 37 updates, 112 refreshes, "
                           + "6 ended, 0 dropped, 2 failed, 1 without feeds, 412 attest keys")
        #expect(line.kind == .pass)
        #expect(line.date == Date(timeIntervalSince1970: 1_792_604_245))
        #expect(line.pass == PassStats(countdowns: 1284, updates: 37, refreshes: 112, ended: 6, dropped: 0,
                                       failed: 2, withoutFeeds: 1, keys: 412))
    }

    @Test func readsAnOlderPassWithoutKeys() {
        let line = LogLine(id: 0, text: "2026-10-21T17:37:25Z pass: 3 countdowns, 1 updates, 0 refreshes, "
                           + "0 ended, 0 dropped, 0 failed, 0 without feeds")
        #expect(line.pass?.countdowns == 3)
        #expect(line.pass?.pushes == 1)
        #expect(line.pass?.keys == nil)
    }

    @Test func sortsTheOtherLines() {
        func kind(_ message: String) -> LogLine.Kind { LogLine(id: 0, text: "2026-10-21T17:37:25Z \(message)").kind }
        #expect(kind("error: push 3f9a1c0e… (production) failed: APNs 500") == .error)
        #expect(kind("register 3f9a1c0e… production R34-N key #a81f0") == .registration)
        #expect(kind("attest: new key #19e40 (production) from #77c21") == .registration)
        #expect(kind("drop 9be0d4a2…: APNs Unregistered") == .drop)
        #expect(kind("listening on [IPv4]127.0.0.1/127.0.0.1:8080") == .lifecycle)
        #expect(kind("stop") == .lifecycle)
        #expect(kind("too many requests from #77c21") == .other)
        // Not a line the server wrote
        #expect(LogLine(id: 0, text: "Fatal error: something").date == nil)
    }

    @Test func countsKeysAtTheStart() {
        let line = LogLine(id: 0, text: "2026-10-21T13:40:12Z start: 3 registrations, 9 attest keys, polling every 30 s")
        #expect(line.kind == .lifecycle)
        #expect(line.startKeys == 9)
    }
}

@Suite struct LogEventTests {
    let stations = ["R34": StationName(name: "36 St", north: "Manhattan", south: "Bay Ridge")]

    func events(_ texts: [String]) -> [LogEvent] {
        LogEvent.group(texts.enumerated().map { LogLine(id: $0.offset, text: $0.element) }, stations: stations)
    }

    let idle = "pass: 0 countdowns, 0 updates, 0 refreshes, 0 ended, 0 dropped, 0 failed, 0 without feeds, 1 attest keys"
    let busy = "pass: 1 countdowns, 1 updates, 0 refreshes, 0 ended, 0 dropped, 0 failed, 0 without feeds, 1 attest keys"

    @Test func foldsQuietPassesIntoOneEvent() throws {
        let grouped = events(["2026-10-22T19:00:00Z \(idle)", "2026-10-22T19:00:30Z \(idle)",
                              "2026-10-22T21:42:00Z \(idle)"])
        let quiet = try #require(grouped.only)
        #expect(quiet.kind == .quiet)
        #expect(quiet.passes == 3)
        #expect(quiet.title == "Quiet for 2h 42m")
        #expect(quiet.detail == "3 passes, nothing to push · 1 attest key")
    }

    @Test func gathersACountdownsPushesUntilItsDropped() throws {
        let grouped = events([
            "2026-10-22T02:59:44Z register 800ef314… sandbox R34:N:R key #bc05c5a463",
            "2026-10-22T03:00:07Z push 800ef314… p10 train in 7m39s (N)",
            "2026-10-22T03:00:07Z \(busy)",
            "2026-10-22T03:00:37Z push 800ef314… p10 train in 7m44s (R) notice \"Delays\"",
            "2026-10-22T03:00:37Z \(busy)",
            "2026-10-22T03:01:13Z drop 800ef314…: deleted by the app",
            "2026-10-22T03:01:37Z \(idle)",
        ])
        #expect(grouped.map(\.kind) == [.countdown, .ended, .quiet])
        let countdown = try #require(grouped[0].countdown)
        #expect(grouped[0].title == "36 St · to Manhattan")
        #expect(grouped[0].token == "800ef314")
        #expect(countdown.routes == ["R"])
        #expect(countdown.environment == "sandbox")
        #expect(countdown.key == "#bc05c5a463")
        #expect(countdown.pushes.map(\.train) == ["in 7m39s", "in 7m44s"])
        #expect(countdown.pushes.map(\.route) == ["N", "R"])
        #expect(countdown.pushes.map(\.notice) == [nil, "Delays"])
        #expect(countdown.ended != nil)
        #expect(grouped[1].detail == "Deleted by the app · ran 1m 29s")
    }

    @Test func endsACountdownOnceNothingsRegistered() {
        let grouped = events(["2026-10-22T03:00:00Z register 800ef314… production R34:S:R key #bc05",
                              "2026-10-22T03:00:30Z \(busy)", "2026-10-22T03:05:00Z \(idle)"])
        #expect(grouped.map(\.kind) == [.countdown, .ended, .quiet])
        #expect(grouped[0].title == "36 St · to Bay Ridge")
        #expect(grouped[1].detail == "Ended by the server · ran 5m 0s")
        #expect(Set(grouped.map(\.id)).count == 3)
    }

    @Test func saysWhatFailed() {
        let grouped = events([
            "2026-10-22T03:00:00Z error: push 51a9e0c2… (production) failed: APNs 400 BadDeviceToken",
            "2026-10-22T03:00:30Z error: pass took 34.2 s, over POLL_SECONDS: skipping 1 tick",
            "2026-10-22T03:01:00Z error: something else",
        ])
        #expect(grouped.map(\.title) == ["Push failed", "Pass took 34.2 s", "Error"])
        #expect(grouped[0].token == "51a9e0c2")
        #expect(grouped[0].detail == "APNs 400 BadDeviceToken · production")
        #expect(grouped[1].detail == "Over POLL_SECONDS: skipping 1 tick")
        #expect(grouped.allSatisfy { $0.isProblem })
    }

    @Test func joinsTheStartLines() {
        let grouped = events(["2026-10-22T03:00:00Z listening on [IPv4]127.0.0.1/127.0.0.1:8080",
                              "2026-10-22T03:00:00Z start: 2 registrations, 1 attest keys, polling every 30 s"])
        #expect(grouped.count == 1)
        #expect(grouped.first?.title == "Server started")
        #expect(grouped.first?.detail
            == "Listening on [IPv4]127.0.0.1/127.0.0.1:8080 · 2 registrations, 1 attest keys, polling every 30 s")
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

@Suite struct LogReaderTests {
    @Test func followsTheFileAndStartsAgainOnceRotated() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "server.log")
        try Data("one\ntwo\nthr".utf8).write(to: file)

        let reader = LogReader(path: file.path)
        var chunk = try await reader.read()
        #expect(chunk.lines.map(\.text) == ["one", "two"])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ee\nfour\n".utf8))
        try handle.close()
        chunk = try await reader.read()
        #expect(chunk.lines.map(\.text) == ["three", "four"])
        #expect(!chunk.restarted)

        // newsyslog moves it aside and makes a new one
        try FileManager.default.moveItem(at: file, to: directory.appending(path: "server.log.0"))
        try Data("five\n".utf8).write(to: file)
        chunk = try await reader.read()
        #expect(chunk.restarted)
        #expect(chunk.lines.map(\.text) == ["five"])
    }
}

@Suite struct SettingTests {
    @Test func checksWholeNumbersInRange() {
        #expect(Setting.pushEarlier.problem(with: "15") == nil)
        #expect(Setting.pushEarlier.problem(with: "") == nil)
        #expect(Setting.pushEarlier.problem(with: nil) == nil)
        #expect(Setting.pushEarlier.problem(with: "0") != nil)
        #expect(Setting.pushEarlier.problem(with: "1.5") != nil)
        #expect(Setting.refresh.problem(with: "59") != nil)
        #expect(Setting.refresh.problem(with: "3600") == nil)
    }

    @Test func fillsInTheServersDefaults() {
        #expect(Setting.pushEarlier.effective(nil) == "15")
        #expect(Setting.pushLater.effective("  ") == "60")
        #expect(Setting.refresh.effective("600") == "600")
    }

    @Test func everyKeyIsListedOnce() {
        let keys = Setting.groups.flatMap(\.settings).map(\.key)
        #expect(Set(keys).count == keys.count)
    }
}

@Suite struct DaemonPlistTests {
    let plist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.traintimes.server</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>POLL_SECONDS</key>
                <string>30</string>
                <key>LOG_PUSHES</key>
                <string>0</string>
            </dict>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """.utf8)

    @Test func changesOnlyTheEnvironment() throws {
        let original = try DaemonPlist(data: plist)
        #expect(original.environment == ["POLL_SECONDS": "30", "LOG_PUSHES": "0"])

        let environment = DaemonPlist.applying(["PUSH_EARLIER_SECONDS": " 20 ", "LOG_PUSHES": "", "POLL_SECONDS": nil],
                                               to: original.environment)
        #expect(environment == ["PUSH_EARLIER_SECONDS": "20"])

        let written = try original.replacingEnvironment(with: environment)
        let root = try #require(try PropertyListSerialization.propertyList(from: written, format: nil) as? [String: Any])
        #expect(root["Label"] as? String == "com.traintimes.server")
        #expect(root["KeepAlive"] as? Bool == true)
        #expect(try DaemonPlist(data: written).environment == environment)
    }
}

@Suite struct RebuildTests {
    @Test func summarisesTheTestRun() {
        #expect(Rebuild.testSummary("✔ Test run with 379 tests in 41 suites passed after 0.429 seconds.") == "379 passed")
        #expect(Rebuild.testSummary("Build complete!") == "Passed")
    }

    @Test func quotesForBash() {
        #expect(Shell.quoted("/a b/it's") == #"'/a b/it'\''s'"#)
    }
}

@Suite struct ShellTests {
    @Test func utf8CutsBeforeASplitCharacter() {
        let train = Data("R → D".utf8)
        // "→" is three bytes, starting at 2
        #expect(UTF8Chunks.completePrefix(of: train) == train.count)
        #expect(UTF8Chunks.completePrefix(of: train.prefix(3)) == 2)
        #expect(UTF8Chunks.completePrefix(of: train.prefix(4)) == 2)
        #expect(UTF8Chunks.completePrefix(of: train.prefix(5)) == 5)
        #expect(UTF8Chunks.completePrefix(of: Data()) == 0)
    }

    @MainActor @Test func handsOnAllOutputInOrderBeforeReturning() async {
        final class Chunks: @unchecked Sendable { var text = "" }
        let chunks = Chunks()
        let result = await Shell.run("/bin/sh", ["-c", "for i in $(seq 1 2000); do echo line $i; done; echo done >&2; exit 3"]) {
            chunks.text += $0
        }
        #expect(result.status == 3)
        #expect(result.output.hasSuffix("line 2000\ndone\n"))
        #expect(chunks.text == result.output)
    }

    @Test func cancellingStopsTheProgram() async {
        let clock = ContinuousClock()
        let start = clock.now
        let run = Task { await Shell.run("/bin/sleep", ["30"]) }
        try? await Task.sleep(for: .milliseconds(200))
        run.cancel()
        let result = await run.value
        #expect(!result.succeeded)
        #expect(clock.now - start < .seconds(10))
    }
}
