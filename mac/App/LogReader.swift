import Foundation

/// Follows server.log: the end of it at first, then what's added, starting
/// again on the new file once newsyslog has rotated it.
actor LogReader {
    /// How much of the end of the log to read at first.
    static let initialBytes: UInt64 = 2 * 1024 * 1024

    private let path: String
    private var offset: UInt64 = 0
    private var inode: UInt64?
    private var partial = ""
    private var nextID = 0

    init(path: String) {
        self.path = path
    }

    struct Chunk: Sendable {
        var lines: [LogLine]
        /// The file changed under it: what was read before is gone.
        var restarted: Bool
        var size: UInt64
    }

    /// The lines added since the last read.
    func read() throws -> Chunk {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fileInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        var restarted = false
        var skipFirstLine = false
        if inode == nil || fileInode != inode || size < offset {
            restarted = inode != nil
            // A file seen for the first time starts near its end; a rotated one at its start
            offset = inode == nil && size > Self.initialBytes ? size - Self.initialBytes : 0
            skipFirstLine = offset > 0
            partial = ""
            inode = fileInode
        }
        guard size > offset else { return Chunk(lines: [], restarted: restarted, size: size) }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(size - offset)) ?? Data()
        offset += UInt64(data.count)

        var text = partial + String(decoding: data, as: UTF8.self)
        if let lastNewline = text.lastIndex(of: "\n") {
            partial = String(text[text.index(after: lastNewline)...])
            text = String(text[..<lastNewline])
        } else {
            partial = text
            text = ""
        }
        var rawLines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if skipFirstLine, !rawLines.isEmpty { rawLines.removeFirst() }
        let lines = rawLines.map { raw -> LogLine in
            defer { nextID += 1 }
            return LogLine(id: nextID, text: String(raw))
        }
        return Chunk(lines: lines, restarted: restarted, size: size)
    }
}
