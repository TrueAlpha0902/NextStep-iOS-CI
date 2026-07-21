import Foundation
import SQLite3

enum SQLiteStepResult: Equatable {
    case row
    case done
}

/// A prepared statement whose lifetime is scoped to its owning connection call.
/// This type deliberately does not conform to `Sendable`.
final class SQLiteStatement {
    private let database: OpaquePointer
    private var statement: OpaquePointer?

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        var preparedStatement: OpaquePointer?
        let result = sqlite3_prepare_v3(
            database,
            sql,
            -1,
            UInt32(SQLITE_PREPARE_PERSISTENT),
            &preparedStatement,
            nil
        )
        guard result == SQLITE_OK, let preparedStatement else {
            if let preparedStatement {
                sqlite3_finalize(preparedStatement)
            }
            throw SQLiteInternalError.operationFailed(
                code: sqlite3_extended_errcode(database)
            )
        }
        statement = preparedStatement
    }

    deinit {
        if let statement {
            sqlite3_finalize(statement)
        }
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try requireOK(sqlite3_bind_int64(try handle(), index, value))
    }

    func bind(_ value: Int, at index: Int32) throws {
        guard let value = Int64(exactly: value) else {
            throw SQLiteInternalError.typeMismatch
        }
        try bind(value, at: index)
    }

    func bind(_ value: String, at index: Int32) throws {
        let statement = try handle()
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        try requireOK(result)
    }

    func bind(_ value: Data, at index: Int32) throws {
        let statement = try handle()
        let result: Int32
        if value.isEmpty {
            result = sqlite3_bind_zeroblob(statement, index, 0)
        } else {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            result = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    Int32(bytes.count),
                    transient
                )
            }
        }
        try requireOK(result)
    }

    func bindNull(at index: Int32) throws {
        try requireOK(sqlite3_bind_null(try handle(), index))
    }

    func step() throws -> SQLiteStepResult {
        switch sqlite3_step(try handle()) {
        case SQLITE_ROW:
            return .row
        case SQLITE_DONE:
            return .done
        default:
            throw SQLiteInternalError.operationFailed(
                code: sqlite3_extended_errcode(database)
            )
        }
    }

    func reset() throws {
        let statement = try handle()
        try requireOK(sqlite3_reset(statement))
        try requireOK(sqlite3_clear_bindings(statement))
    }

    func requiredInt64(at index: Int32) throws -> Int64 {
        guard sqlite3_column_type(try handle(), index) == SQLITE_INTEGER else {
            throw SQLiteInternalError.typeMismatch
        }
        return sqlite3_column_int64(try handle(), index)
    }

    func optionalInt64(at index: Int32) throws -> Int64? {
        let type = sqlite3_column_type(try handle(), index)
        if type == SQLITE_NULL { return nil }
        guard type == SQLITE_INTEGER else {
            throw SQLiteInternalError.typeMismatch
        }
        return sqlite3_column_int64(try handle(), index)
    }

    func requiredText(at index: Int32) throws -> String {
        let statement = try handle()
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, index) else {
            throw SQLiteInternalError.typeMismatch
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    func requiredData(at index: Int32) throws -> Data {
        let statement = try handle()
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB else {
            throw SQLiteInternalError.typeMismatch
        }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(statement, index) else {
            throw SQLiteInternalError.typeMismatch
        }
        return Data(bytes: pointer, count: count)
    }

    private func handle() throws -> OpaquePointer {
        guard let statement else { throw SQLiteInternalError.closed }
        return statement
    }

    private func requireOK(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw SQLiteInternalError.operationFailed(
                code: sqlite3_extended_errcode(database)
            )
        }
    }
}
