import Foundation
import SQLite3

/// A small wrapper around the system's libsqlite3: one connection, used by
/// one actor at a time (it isn't Sendable), with prepared statements cached.
final class SQLite {
    enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)

        var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
        var real: Double? { if case .real(let v) = self { return v }; if case .integer(let v) = self { return Double(v) }; return nil }
        var text: String? { if case .text(let v) = self { return v }; return nil }
        var blob: Data? { if case .blob(let v) = self { return v }; return nil }
    }

    struct Problem: Error, CustomStringConvertible {
        let description: String
    }

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// ":memory:" for a database that lasts as long as this.
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            // deinit still runs, and mustn't close it again
            handle = nil
            throw Problem(description: "can't open the database: \(message)")
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(handle)
    }

    private var message: String { String(cString: sqlite3_errmsg(handle)) }

    /// Runs `sql`, which may hold several statements and takes no parameters.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Problem(description: message) }
    }

    /// Runs one statement, returning its rows.
    @discardableResult
    func query(_ sql: String, _ parameters: [Value] = []) throws -> [[Value]] {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, position)
            case .integer(let v): result = sqlite3_bind_int64(statement, position, v)
            case .real(let v): result = sqlite3_bind_double(statement, position, v)
            case .text(let v): result = sqlite3_bind_text(statement, position, v, -1, Self.transient)
            case .blob(let v):
                result = v.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), Self.transient) }
            }
            guard result == SQLITE_OK else { throw Problem(description: message) }
        }
        var rows: [[Value]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
            case SQLITE_DONE:
                return rows
            default:
                throw Problem(description: message)
            }
        }
    }

    /// Rows changed by the last INSERT, UPDATE or DELETE.
    var changes: Int { Int(sqlite3_changes(handle)) }

    /// `body` in one transaction, rolled back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Problem(description: message)
        }
        statements[sql] = statement
        return statement
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> Value {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    /// SQLITE_TRANSIENT: SQLite copies what's bound.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
