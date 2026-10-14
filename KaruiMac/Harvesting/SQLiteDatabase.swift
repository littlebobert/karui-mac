import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A read-only SQLite connection: just enough to query the databases other apps keep.
final class SQLiteDatabase {
    enum Value: Equatable, Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)

        var text: String? {
            switch self {
            case .text(let text): text
            case .integer(let integer): String(integer)
            default: nil
            }
        }

        var integer: Int64? {
            if case .integer(let integer) = self { return integer }
            return nil
        }

        var real: Double? {
            switch self {
            case .real(let real): real
            case .integer(let integer): Double(integer)
            default: nil
            }
        }

        var blob: Data? {
            if case .blob(let data) = self { return data }
            return nil
        }
    }

    struct Error: Swift.Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private var handle: OpaquePointer?

    /// With `immutable`, SQLite takes no locks and ignores a write-ahead log: for a
    /// copy of a database, or one whose folder this process may not write in.
    init(readingFrom url: URL, immutable: Bool = false) throws {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        if immutable {
            components.queryItems?.append(URLQueryItem(name: "immutable", value: "1"))
        }
        guard let uri = components.string else { throw Error(message: "bad path") }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
            if let database { sqlite3_close(database) }
            throw Error(message: message)
        }
        handle = database
    }

    /// A live database first, so rows still in its write-ahead log are seen; failing
    /// that, the file alone.
    static func opening(_ url: URL) throws -> SQLiteDatabase {
        do {
            return try SQLiteDatabase(readingFrom: url)
        } catch {
            return try SQLiteDatabase(readingFrom: url, immutable: true)
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func rows(_ sql: String, _ bindings: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Error(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            bind(value, at: Int32(offset + 1), to: statement)
        }
        var rows: [[Value]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map { column($0, of: statement) })
            case SQLITE_DONE:
                return rows
            default:
                throw Error(message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func bind(_ value: Value, at index: Int32, to statement: OpaquePointer) {
        switch value {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer(let integer):
            sqlite3_bind_int64(statement, index, integer)
        case .real(let real):
            sqlite3_bind_double(statement, index, real)
        case .text(let text):
            sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
        case .blob(let data):
            data.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
        }
    }

    private func column(_ index: Int32, of statement: OpaquePointer) -> Value {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}
