import Foundation
import Testing
@testable import TrainCore

@Suite struct LogTests {
    @Test func refusalsAreLoggedOnlyAFewAMinute() async {
        let log = RefusalLog(perMinute: 2)
        let minute = Date(timeIntervalSince1970: 60 * 30_000_000)
        #expect(await log.info("one", now: minute))
        #expect(await log.error("two", now: minute + 10))
        #expect(await !log.info("three", now: minute + 59))
        #expect(await !log.error("four", now: minute + 59))
        // The next minute has its own
        #expect(await log.info("five", now: minute + 60))
        #expect(await log.info("six", now: minute + 61))
        #expect(await !log.info("seven", now: minute + 62))
    }

    @Test func relativeTimesNeverCrash() {
        #expect(Log.relative(now + 270, to: now) == "in 4m30s")
        #expect(Log.relative(now - 65, to: now) == "1m05s ago")
        // A malformed feed's time, read as 2^64 seconds since 1970, and its opposite
        #expect(Log.relative(Date(timeIntervalSince1970: 0x1p64), to: now).hasPrefix("in "))
        #expect(Log.relative(Date(timeIntervalSince1970: -0x1p64), to: now).hasSuffix(" ago"))
    }

    @Test func saturatesRatherThanTrapping() {
        #expect(Int(saturating: 12.9) == 12)
        #expect(Int(saturating: -12.9) == -12)
        #expect(Int(saturating: 0x1p62) == 1 << 62)
        #expect(Int(saturating: 0x1p63) == .max)
        #expect(Int(saturating: 0x1p64) == .max)
        #expect(Int(saturating: -0x1p63) == .min)
        #expect(Int(saturating: -0x1p70) == .min)
        #expect(Int(saturating: .infinity) == .max)
        #expect(Int(saturating: -.infinity) == .min)
        #expect(Int(saturating: .nan) == 0)
    }

    @Test func movesToTheNewLogOnceRotated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("traintimes-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("server.log").path
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
        // Stands in for stdout, as launchd opens it
        let output = open(path, O_WRONLY | O_APPEND)
        try #require(output >= 0)
        defer { close(output) }
        let handle = FileHandle(fileDescriptor: output)
        func append(_ line: String) { handle.write(Data("\(line)\n".utf8)) }

        append("one")
        #expect(!Log.reopen(path, onto: [output]))
        // As newsyslog rotates it: moved aside, then a new one made
        try FileManager.default.moveItem(atPath: path, toPath: path + ".0")
        #expect(!Log.reopen(path, onto: [output]))
        append("two")
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
        #expect(Log.reopen(path, onto: [output]))
        append("three")
        #expect(!Log.reopen(path, onto: [output]))
        #expect(try String(contentsOfFile: path + ".0", encoding: .utf8) == "one\ntwo\n")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "three\n")
    }
}
