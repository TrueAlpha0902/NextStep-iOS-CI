import Foundation
import SQLite3

enum SQLiteInternalError: Error, Equatable {
    case invalidDatabaseLocation
    case openFailed(code: Int32)
    case operationFailed(code: Int32)
    case invalidResult
    case typeMismatch
    case closed
    case commitOutcomeUnknown(code: Int32)

    var resultCode: Int32 {
        switch self {
        case .openFailed(let code),
             .operationFailed(let code),
             .commitOutcomeUnknown(let code):
            code
        case .invalidDatabaseLocation:
            SQLITE_CANTOPEN
        case .invalidResult, .typeMismatch:
            SQLITE_MISMATCH
        case .closed:
            SQLITE_MISUSE
        }
    }
}

/// A synchronous connection intended to be owned by one actor.
///
/// This type deliberately does not conform to `Sendable`. SQLite handles and
/// prepared statements must never cross the persistence actor boundary.
final class SQLiteConnection {
    static let defaultBusyTimeoutMilliseconds: Int32 = 5_000

    private var database: OpaquePointer?
    private(set) var isPoisoned = false

    init(localDatabaseURL: URL) throws {
        guard localDatabaseURL.isFileURL else {
            throw SQLiteInternalError.invalidDatabaseLocation
        }

        let databaseURL = localDatabaseURL.standardizedFileURL
        guard databaseURL.lastPathComponent.isEmpty == false else {
            throw SQLiteInternalError.invalidDatabaseLocation
        }

        let parentURL = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw SQLiteInternalError.openFailed(code: SQLITE_CANTOPEN)
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: databaseURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            throw SQLiteInternalError.invalidDatabaseLocation
        }

        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_PRIVATECACHE
            | SQLITE_OPEN_NOFOLLOW
        let openResult = databaseURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return SQLITE_CANTOPEN }
            return sqlite3_open_v2(path, &openedDatabase, flags, nil)
        }

        guard openResult == SQLITE_OK, let openedDatabase else {
            let resultCode = openedDatabase.map { sqlite3_extended_errcode($0) }
                ?? openResult
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw SQLiteInternalError.openFailed(code: resultCode)
        }

        database = openedDatabase
        do {
            try requireOK(sqlite3_extended_result_codes(openedDatabase, 1))
            try requireOK(sqlite3_busy_timeout(
                openedDatabase,
                Self.defaultBusyTimeoutMilliseconds
            ))
        } catch {
            database = nil
            sqlite3_close_v2(openedDatabase)
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func close() throws {
        guard let database else { return }
        let result = sqlite3_close(database)
        guard result == SQLITE_OK else {
            throw SQLiteInternalError.operationFailed(
                code: sqlite3_extended_errcode(database)
            )
        }
        self.database = nil
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try checkUsable()
        guard let database else { throw SQLiteInternalError.closed }
        return try SQLiteStatement(database: database, sql: sql)
    }

    func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        guard try statement.step() == .done else {
            throw SQLiteInternalError.invalidResult
        }
    }

    func scalarInt64(_ sql: String) throws -> Int64 {
        let statement = try prepare(sql)
        guard try statement.step() == .row else {
            throw SQLiteInternalError.invalidResult
        }
        let value = try statement.requiredInt64(at: 0)
        guard try statement.step() == .done else {
            throw SQLiteInternalError.invalidResult
        }
        return value
    }

    func scalarText(_ sql: String) throws -> String {
        let statement = try prepare(sql)
        guard try statement.step() == .row else {
            throw SQLiteInternalError.invalidResult
        }
        let value = try statement.requiredText(at: 0)
        guard try statement.step() == .done else {
            throw SQLiteInternalError.invalidResult
        }
        return value
    }

    func changes() throws -> Int32 {
        try checkUsable()
        guard let database else { throw SQLiteInternalError.closed }
        return sqlite3_changes(database)
    }

    func withImmediateTransaction<Value>(_ body: () throws -> Value) throws -> Value {
        try execute("BEGIN IMMEDIATE")

        let value: Value
        do {
            value = try body()
        } catch {
            do {
                try execute("ROLLBACK")
            } catch let rollbackError {
                isPoisoned = true
                throw SQLiteInternalError.commitOutcomeUnknown(
                    code: Self.resultCode(from: rollbackError)
                )
            }
            throw error
        }

        do {
            try execute("COMMIT")
        } catch {
            let commitCode = Self.resultCode(from: error)
            do {
                try execute("ROLLBACK")
            } catch let rollbackError {
                isPoisoned = true
                throw SQLiteInternalError.commitOutcomeUnknown(
                    code: Self.resultCode(from: rollbackError)
                )
            }
            throw SQLiteInternalError.operationFailed(code: commitCode)
        }
        return value
    }

    private func checkUsable() throws {
        guard database != nil else { throw SQLiteInternalError.closed }
        guard isPoisoned == false else {
            throw SQLiteInternalError.commitOutcomeUnknown(code: SQLITE_IOERR)
        }
    }

    private func requireOK(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            let code = database.map { sqlite3_extended_errcode($0) } ?? result
            throw SQLiteInternalError.operationFailed(code: code)
        }
    }

    private static func resultCode(from error: Error) -> Int32 {
        (error as? SQLiteInternalError)?.resultCode ?? SQLITE_ERROR
    }
}
