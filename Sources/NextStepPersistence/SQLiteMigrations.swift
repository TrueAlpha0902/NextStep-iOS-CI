import Foundation

enum SQLiteMigrations {
    static let applicationID: Int64 = 1_314_411_348 // ASCII "NXST"
    private static let v1Version = 1
    private static let v2Version = 2
    static let currentVersion = v2Version
    static let expectedV1ChecksumHex =
        "d2390a8ce1352d61b04af63bfa7142610e009569ed839c112e7a8089b2315025"
    static let expectedV2ChecksumHex =
        "0e8fd1ebf566fe614965437940830c73db65d44f23131c9a9a6346f47e15b07e"

    private static let v1Name = "initial_projection_outbox_v1"
    private static let v1Statements = [
        "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY NOT NULL CHECK(version BETWEEN 1 AND 2147483647), name TEXT NOT NULL UNIQUE CHECK(length(name) BETWEEN 1 AND 128 AND name = trim(name) AND name NOT GLOB '*[^a-z0-9._-]*'), checksum BLOB NOT NULL CHECK(length(checksum) = 32), applied_at_ms INTEGER NOT NULL CHECK(applied_at_ms >= 0)) STRICT;",
        "CREATE TABLE canonical_payloads (sha256 BLOB PRIMARY KEY NOT NULL CHECK(length(sha256) = 32), payload_kind TEXT NOT NULL CHECK(length(payload_kind) BETWEEN 1 AND 64 AND payload_kind NOT GLOB '*[^a-z0-9._-]*'), schema_version INTEGER NOT NULL CHECK(schema_version BETWEEN 1 AND 2147483647), canonical_bytes BLOB NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 67108864 AND byte_count = length(canonical_bytes)), created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0)) STRICT;",
        "CREATE TABLE workspace_projection (singleton_id INTEGER PRIMARY KEY NOT NULL CHECK(singleton_id = 1), generation INTEGER NOT NULL CHECK(generation BETWEEN 1 AND 9223372036854775807), payload_sha256 BLOB NOT NULL, created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0), updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= created_at_ms), FOREIGN KEY(payload_sha256) REFERENCES canonical_payloads(sha256) ON UPDATE RESTRICT ON DELETE RESTRICT) STRICT;",
        "CREATE TABLE outbox_intents (intent_id TEXT PRIMARY KEY NOT NULL CHECK(length(intent_id) = 36 AND intent_id = lower(intent_id) AND substr(intent_id, 9, 1) = '-' AND substr(intent_id, 14, 1) = '-' AND substr(intent_id, 19, 1) = '-' AND substr(intent_id, 24, 1) = '-' AND intent_id NOT GLOB '*[^0-9a-f-]*'), projection_generation INTEGER NOT NULL CHECK(projection_generation > 0), payload_sha256 BLOB NOT NULL, created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0), published_at_ms INTEGER, CHECK(published_at_ms IS NULL OR published_at_ms >= created_at_ms), FOREIGN KEY(payload_sha256) REFERENCES canonical_payloads(sha256) ON UPDATE RESTRICT ON DELETE RESTRICT) STRICT;",
        "CREATE INDEX outbox_pending_idx ON outbox_intents(created_at_ms, intent_id) WHERE published_at_ms IS NULL;",
        "CREATE TABLE migration_ledger (migration_key TEXT PRIMARY KEY NOT NULL CHECK(length(migration_key) BETWEEN 1 AND 128 AND migration_key NOT GLOB '*[^a-z0-9._-]*'), migration_version INTEGER NOT NULL CHECK(migration_version > 0), source_schema_version INTEGER NOT NULL CHECK(source_schema_version > 0), source_revision INTEGER NOT NULL CHECK(source_revision >= 0), source_byte_count INTEGER NOT NULL CHECK(source_byte_count BETWEEN 1 AND 67108864), source_sha256 BLOB NOT NULL CHECK(length(source_sha256) = 32), backup_byte_count INTEGER NOT NULL CHECK(backup_byte_count = source_byte_count), backup_sha256 BLOB NOT NULL CHECK(length(backup_sha256) = 32 AND backup_sha256 = source_sha256), result_payload_sha256 BLOB NOT NULL, result_generation INTEGER NOT NULL CHECK(result_generation > 0), completed_at_ms INTEGER NOT NULL CHECK(completed_at_ms >= 0), FOREIGN KEY(result_payload_sha256) REFERENCES canonical_payloads(sha256) ON UPDATE RESTRICT ON DELETE RESTRICT) STRICT;"
    ]

    private static let v2Name = "immutable_operation_ledgers_v2"
    private static let v2Statements = [
        "CREATE TABLE sync_inbox_operations (operation_id TEXT PRIMARY KEY NOT NULL CHECK(length(operation_id) = 36 AND operation_id = lower(operation_id) AND substr(operation_id, 9, 1) = '-' AND substr(operation_id, 14, 1) = '-' AND substr(operation_id, 19, 1) = '-' AND substr(operation_id, 24, 1) = '-' AND operation_id NOT GLOB '*[^0-9a-f-]*'), payload_sha256 BLOB NOT NULL, received_at_ms INTEGER NOT NULL CHECK(received_at_ms >= 0), FOREIGN KEY(payload_sha256) REFERENCES canonical_payloads(sha256) ON UPDATE RESTRICT ON DELETE RESTRICT) STRICT;",
        "CREATE INDEX sync_inbox_received_idx ON sync_inbox_operations(received_at_ms, operation_id);",
        "CREATE TABLE sync_applied_operations (operation_id TEXT PRIMARY KEY NOT NULL CHECK(length(operation_id) = 36 AND operation_id = lower(operation_id) AND substr(operation_id, 9, 1) = '-' AND substr(operation_id, 14, 1) = '-' AND substr(operation_id, 19, 1) = '-' AND substr(operation_id, 24, 1) = '-' AND operation_id NOT GLOB '*[^0-9a-f-]*'), payload_sha256 BLOB NOT NULL, result_generation INTEGER NOT NULL CHECK(result_generation > 0), applied_at_ms INTEGER NOT NULL CHECK(applied_at_ms >= 0), FOREIGN KEY(payload_sha256) REFERENCES canonical_payloads(sha256) ON UPDATE RESTRICT ON DELETE RESTRICT) STRICT;"
    ]

    private static let expectedV1SchemaObjects: [String: String] = [
        "table:schema_migrations": storedSchemaSQL(v1Statements[0]),
        "table:canonical_payloads": storedSchemaSQL(v1Statements[1]),
        "table:workspace_projection": storedSchemaSQL(v1Statements[2]),
        "table:outbox_intents": storedSchemaSQL(v1Statements[3]),
        "index:outbox_pending_idx": storedSchemaSQL(v1Statements[4]),
        "table:migration_ledger": storedSchemaSQL(v1Statements[5])
    ]

    private static let expectedV2SchemaObjects: [String: String] = {
        var result = expectedV1SchemaObjects
        result["table:sync_inbox_operations"] = storedSchemaSQL(v2Statements[0])
        result["index:sync_inbox_received_idx"] = storedSchemaSQL(v2Statements[1])
        result["table:sync_applied_operations"] = storedSchemaSQL(v2Statements[2])
        return result
    }()

    static var v1Checksum: ContentDigest {
        migrationChecksum(
            version: v1Version,
            name: v1Name,
            statements: v1Statements
        )
    }

    static var v2Checksum: ContentDigest {
        migrationChecksum(
            version: v2Version,
            name: v2Name,
            statements: v2Statements
        )
    }

    static func prepare(
        _ connection: SQLiteConnection,
        appliedAt: Date = Date()
    ) throws -> PersistencePragmas {
        guard v1Checksum.hex == expectedV1ChecksumHex else {
            throw PersistenceError.migrationChecksumMismatch(version: v1Version)
        }
        guard v2Checksum.hex == expectedV2ChecksumHex else {
            throw PersistenceError.migrationChecksumMismatch(version: v2Version)
        }

        let applicationID = try connection.scalarInt64("PRAGMA application_id")
        let userVersion = try connection.scalarInt64("PRAGMA user_version")
        let objectCount = try connection.scalarInt64(
            "SELECT COUNT(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'"
        )

        let isNewDatabase: Bool
        if applicationID == 0, userVersion == 0, objectCount == 0 {
            isNewDatabase = true
        } else {
            guard applicationID == Self.applicationID else {
                throw PersistenceError.incompatibleDatabase
            }
            guard userVersion <= Int64(currentVersion) else {
                throw PersistenceError.unsupportedDatabaseVersion(Int(userVersion))
            }
            guard userVersion >= Int64(v1Version) else {
                throw PersistenceError.incompatibleDatabase
            }
            isNewDatabase = false
        }

        // Persistent PRAGMAs, especially journal_mode=WAL, are applied only
        // after ownership has been proven or an entirely empty file is adopted.
        let configuration = try configure(connection)
        guard configuration.isHardened,
              configuration.busyTimeoutMilliseconds
                == Int(SQLiteConnection.defaultBusyTimeoutMilliseconds) else {
            throw PersistenceError.incompatibleDatabase
        }
        if isNewDatabase {
            try installV1(connection, appliedAt: appliedAt)
        }

        switch try connection.scalarInt64("PRAGMA user_version") {
        case Int64(v1Version):
            try verifyV1(connection)
            try installV2(connection, appliedAt: appliedAt)
            try verifyV2(connection)
        case Int64(v2Version):
            try verifyV2(connection)
        default:
            throw PersistenceError.incompatibleDatabase
        }
        return configuration
    }

    static func inspectPragmas(_ connection: SQLiteConnection) throws -> PersistencePragmas {
        try PersistencePragmas(
            foreignKeysEnabled: try connection.scalarInt64("PRAGMA foreign_keys") == 1,
            writeAheadLoggingEnabled: try connection.scalarText("PRAGMA journal_mode")
                .lowercased() == "wal",
            fullSynchronousEnabled: try connection.scalarInt64("PRAGMA synchronous") == 2,
            trustedSchemaDisabled: try connection.scalarInt64("PRAGMA trusted_schema") == 0,
            cellSizeCheckEnabled: try connection.scalarInt64("PRAGMA cell_size_check") == 1,
            busyTimeoutMilliseconds: Int(try connection.scalarInt64("PRAGMA busy_timeout"))
        )
    }

    private static func configure(
        _ connection: SQLiteConnection
    ) throws -> PersistencePragmas {
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("PRAGMA trusted_schema = OFF")
        try connection.execute("PRAGMA cell_size_check = ON")
        let journalMode = try connection.scalarText("PRAGMA journal_mode = WAL")
        guard journalMode.lowercased() == "wal" else {
            throw PersistenceError.incompatibleDatabase
        }
        try connection.execute("PRAGMA synchronous = FULL")
        return try inspectPragmas(connection)
    }

    static func installV1(
        _ connection: SQLiteConnection,
        appliedAt: Date
    ) throws {
        let appliedAtMilliseconds = try milliseconds(appliedAt)
        do {
            try connection.withImmediateTransaction {
                for statement in v1Statements {
                    try connection.execute(statement)
                }

                let insert = try connection.prepare(
                    "INSERT INTO schema_migrations(version, name, checksum, applied_at_ms) VALUES(?, ?, ?, ?)"
                )
                try insert.bind(Int64(v1Version), at: 1)
                try insert.bind(v1Name, at: 2)
                try insert.bind(v1Checksum.rawBytes, at: 3)
                try insert.bind(appliedAtMilliseconds, at: 4)
                guard try insert.step() == .done else {
                    throw PersistenceError.transactionInvariantViolation
                }

                try connection.execute("PRAGMA application_id = \(applicationID)")
                try connection.execute("PRAGMA user_version = \(v1Version)")
            }
        } catch let error as PersistenceError {
            throw error
        } catch let error as SQLiteInternalError {
            if case .commitOutcomeUnknown(let code) = error {
                throw PersistenceError.commitOutcomeUnknown(code: code)
            }
            throw PersistenceError.migrationFailed(
                version: v1Version,
                code: error.resultCode
            )
        } catch {
            throw PersistenceError.migrationFailed(version: v1Version, code: nil)
        }
    }

    private static func installV2(
        _ connection: SQLiteConnection,
        appliedAt: Date
    ) throws {
        let appliedAtMilliseconds = try milliseconds(appliedAt)
        do {
            try connection.withImmediateTransaction {
                for statement in v2Statements {
                    try connection.execute(statement)
                }

                let insert = try connection.prepare(
                    "INSERT INTO schema_migrations(version, name, checksum, applied_at_ms) VALUES(?, ?, ?, ?)"
                )
                try insert.bind(Int64(v2Version), at: 1)
                try insert.bind(v2Name, at: 2)
                try insert.bind(v2Checksum.rawBytes, at: 3)
                try insert.bind(appliedAtMilliseconds, at: 4)
                guard try insert.step() == .done else {
                    throw PersistenceError.transactionInvariantViolation
                }
                try connection.execute("PRAGMA user_version = \(v2Version)")
            }
        } catch let error as PersistenceError {
            throw error
        } catch let error as SQLiteInternalError {
            if case .commitOutcomeUnknown(let code) = error {
                throw PersistenceError.commitOutcomeUnknown(code: code)
            }
            throw PersistenceError.migrationFailed(
                version: v2Version,
                code: error.resultCode
            )
        } catch {
            throw PersistenceError.migrationFailed(version: v2Version, code: nil)
        }
    }

    private static func verifyV1(_ connection: SQLiteConnection) throws {
        try verifyMigrations(
            [(v1Version, v1Name, v1Checksum)],
            connection: connection
        )
        try verifySchema(
            expectedObjects: expectedV1SchemaObjects,
            expectedTables: [
                "schema_migrations",
                "canonical_payloads",
                "workspace_projection",
                "outbox_intents",
                "migration_ledger"
            ],
            connection: connection
        )
    }

    private static func verifyV2(_ connection: SQLiteConnection) throws {
        try verifyMigrations(
            [
                (v1Version, v1Name, v1Checksum),
                (v2Version, v2Name, v2Checksum)
            ],
            connection: connection
        )
        try verifySchema(
            expectedObjects: expectedV2SchemaObjects,
            expectedTables: [
                "schema_migrations",
                "canonical_payloads",
                "workspace_projection",
                "outbox_intents",
                "migration_ledger",
                "sync_inbox_operations",
                "sync_applied_operations"
            ],
            connection: connection
        )
        guard try connection.scalarInt64(
            "SELECT COUNT(*) FROM (SELECT i.operation_id FROM sync_inbox_operations i JOIN sync_applied_operations a ON a.operation_id = i.operation_id WHERE i.payload_sha256 != a.payload_sha256 UNION ALL SELECT i.operation_id FROM sync_inbox_operations i JOIN outbox_intents o ON o.intent_id = i.operation_id WHERE i.payload_sha256 != o.payload_sha256 UNION ALL SELECT a.operation_id FROM sync_applied_operations a JOIN outbox_intents o ON o.intent_id = a.operation_id WHERE a.payload_sha256 != o.payload_sha256)"
        ) == 0 else {
            throw PersistenceError.incompatibleDatabase
        }
        guard try connection.scalarInt64(
            "SELECT COUNT(*) FROM sync_applied_operations a LEFT JOIN workspace_projection p ON p.singleton_id = 1 WHERE p.generation IS NULL OR a.result_generation > p.generation"
        ) == 0 else {
            throw PersistenceError.incompatibleDatabase
        }
        guard try connection.scalarInt64(
            "SELECT COUNT(*) FROM (SELECT o.intent_id AS identifier FROM outbox_intents o LEFT JOIN workspace_projection p ON p.singleton_id = 1 WHERE p.generation IS NULL OR o.projection_generation > p.generation UNION ALL SELECT m.migration_key AS identifier FROM migration_ledger m LEFT JOIN workspace_projection p ON p.singleton_id = 1 WHERE p.generation IS NULL OR m.result_generation > p.generation)"
        ) == 0 else {
            throw PersistenceError.incompatibleDatabase
        }
    }

    private static func verifyMigrations(
        _ expected: [(version: Int, name: String, checksum: ContentDigest)],
        connection: SQLiteConnection
    ) throws {
        let migrationRows = try connection.prepare(
            "SELECT version, name, checksum FROM schema_migrations ORDER BY version"
        )
        for item in expected {
            guard try migrationRows.step() == .row else {
                throw PersistenceError.incompatibleDatabase
            }
            let version = try migrationRows.requiredInt64(at: 0)
            let name = try migrationRows.requiredText(at: 1)
            let checksum = try ContentDigest(rawBytes: migrationRows.requiredData(at: 2))
            guard version == Int64(item.version), name == item.name else {
                throw PersistenceError.incompatibleDatabase
            }
            guard checksum == item.checksum else {
                throw PersistenceError.migrationChecksumMismatch(version: item.version)
            }
        }
        guard try migrationRows.step() == .done else {
            throw PersistenceError.incompatibleDatabase
        }
    }

    private static func verifySchema(
        expectedObjects: [String: String],
        expectedTables: Set<String>,
        connection: SQLiteConnection
    ) throws {

        var actualSchemaObjects: [String: String] = [:]
        let schema = try connection.prepare(
            "SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
        )
        while try schema.step() == .row {
            let type = try schema.requiredText(at: 0)
            let name = try schema.requiredText(at: 1)
            let sql = try schema.requiredText(at: 2)
            let key = "\(type):\(name)"
            guard actualSchemaObjects.updateValue(sql, forKey: key) == nil else {
                throw PersistenceError.incompatibleDatabase
            }
        }
        guard actualSchemaObjects == expectedObjects else {
            throw PersistenceError.incompatibleDatabase
        }

        var strictTables = Set<String>()
        let tables = try connection.prepare("PRAGMA table_list")
        while try tables.step() == .row {
            let type = try tables.requiredText(at: 2)
            guard type == "table" else { continue }
            let name = try tables.requiredText(at: 1)
            if expectedTables.contains(name) {
                guard try tables.requiredInt64(at: 5) == 1 else {
                    throw PersistenceError.incompatibleDatabase
                }
                strictTables.insert(name)
            }
        }
        guard strictTables == expectedTables else {
            throw PersistenceError.incompatibleDatabase
        }

        let foreignKeyCheck = try connection.prepare("PRAGMA foreign_key_check")
        guard try foreignKeyCheck.step() == .done else {
            throw PersistenceError.incompatibleDatabase
        }
        guard try connection.scalarText("PRAGMA quick_check").lowercased() == "ok" else {
            throw PersistenceError.incompatibleDatabase
        }
    }

    private static func migrationChecksum(
        version: Int,
        name: String,
        statements: [String]
    ) -> ContentDigest {
        var material = Data()
        append(UInt32(version), to: &material)
        appendLengthPrefixed(Data(name.utf8), to: &material)
        append(UInt32(statements.count), to: &material)
        for statement in statements {
            appendLengthPrefixed(Data(statement.utf8), to: &material)
        }
        return ContentDigest(hashing: material)
    }

    private static func storedSchemaSQL(_ statement: String) -> String {
        guard statement.last == ";" else { return statement }
        return String(statement.dropLast())
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else {
            throw PersistenceError.invalidValue(field: "date")
        }
        return Int64(value.rounded(.down))
    }
}
