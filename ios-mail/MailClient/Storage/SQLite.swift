import Foundation
import SQLite3

/// Small wrapper over the SQLite C API (FTS5 is built into iOS's SQLite).
final class SQLiteDatabase {
    enum Value {
        case text(String)
        case int(Int64)
        case double(Double)
        case blob(Data)
        case null
    }

    struct Row {
        fileprivate let values: [String: Value]

        func string(_ column: String) -> String? {
            if case .text(let value) = values[column] { return value }
            return nil
        }

        func int(_ column: String) -> Int? {
            switch values[column] {
            case .int(let value): return Int(value)
            case .double(let value): return Int(value)
            default: return nil
            }
        }

        func double(_ column: String) -> Double? {
            switch values[column] {
            case .double(let value): return value
            case .int(let value): return Double(value)
            default: return nil
            }
        }

        func data(_ column: String) -> Data? {
            switch values[column] {
            case .blob(let value): return value
            case .text(let value): return Data(value.utf8)
            default: return nil
            }
        }
    }

    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { "Database error: \(message)" }
    }

    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw Error(message: message)
        }
        // Readable after first unlock so background refresh can sync; encrypted by iOS otherwise.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, _ arguments: [Value] = []) throws {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw lastError() }
    }

    func query(_ sql: String, _ arguments: [Value] = []) throws -> [Row] {
        let statement = try prepare(sql, arguments)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw lastError() }
            var values: [String: Value] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: values[name] = .double(sqlite3_column_double(statement, index))
                case SQLITE_TEXT: values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let bytes = sqlite3_column_blob(statement, index), count > 0 {
                        values[name] = .blob(Data(bytes: bytes, count: count))
                    } else {
                        values[name] = .blob(Data())
                    }
                default: values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ arguments: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .int(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .blob(let value):
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func lastError() -> Error {
        Error(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
    }
}

extension SQLiteDatabase.Value {
    init(_ string: String?) { self = string.map { .text($0) } ?? .null }
    init(_ int: Int) { self = .int(Int64(int)) }
}
