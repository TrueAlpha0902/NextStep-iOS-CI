import Foundation
@testable import NextStepPersistence
import XCTest

final class SQLiteMigrationTests: XCTestCase {
    func testV1MigrationChecksumIsLocked() {
        XCTAssertEqual(
            SQLiteMigrations.v1Checksum.hex,
            "d2390a8ce1352d61b04af63bfa7142610e009569ed839c112e7a8089b2315025"
        )
    }

    func testV2MigrationChecksumIsLocked() {
        XCTAssertEqual(
            SQLiteMigrations.v2Checksum.hex,
            "0e8fd1ebf566fe614965437940830c73db65d44f23131c9a9a6346f47e15b07e"
        )
    }

    func testOpeningCreatesHardenedStrictSchemaAndReopens() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)

        XCTAssertTrue(store.configuredPragmas.isHardened)
        XCTAssertEqual(store.configuredPragmas.busyTimeoutMilliseconds, 5_000)
        let inspectedPragmas = try await store.inspectPragmas()
        let initialProjection = try await store.loadProjection()
        XCTAssertEqual(inspectedPragmas, store.configuredPragmas)
        XCTAssertNil(initialProjection)
        try await store.close()

        let reopened = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        XCTAssertTrue(reopened.configuredPragmas.isHardened)
        let reopenedProjection = try await reopened.loadProjection()
        XCTAssertNil(reopenedProjection)
        try await reopened.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try raw.scalarInt64("PRAGMA application_id"), SQLiteMigrations.applicationID)
        XCTAssertEqual(try raw.scalarInt64("PRAGMA user_version"), 2)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM schema_migrations"), 2)
        XCTAssertEqual(
            try raw.scalarInt64(
                "SELECT COUNT(*) FROM pragma_table_list WHERE name IN ('schema_migrations', 'canonical_payloads', 'workspace_projection', 'outbox_intents', 'migration_ledger', 'sync_inbox_operations', 'sync_applied_operations') AND strict = 1"
            ),
            7
        )
        try raw.close()
    }

    func testExistingV1DatabaseMigratesTransactionallyToV2() async throws {
        let databaseURL = try makeDatabaseURL()
        let rawV1 = try SQLiteConnection(localDatabaseURL: databaseURL)
        try SQLiteMigrations.installV1(
            rawV1,
            appliedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(try rawV1.scalarInt64("PRAGMA user_version"), 1)
        try rawV1.close()

        let migrated = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let migratedProjection = try await migrated.loadProjection()
        XCTAssertNil(migratedProjection)
        try await migrated.close()

        let verify = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try verify.scalarInt64("PRAGMA user_version"), 2)
        XCTAssertEqual(try verify.scalarInt64("SELECT COUNT(*) FROM schema_migrations"), 2)
        XCTAssertEqual(
            try verify.scalarInt64(
                "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name IN ('sync_inbox_operations', 'sync_applied_operations')"
            ),
            2
        )
        try verify.close()
    }

    func testEmptyBlobBindingRemainsBlobInsteadOfNull() throws {
        let databaseURL = try makeDatabaseURL()
        let connection = try SQLiteConnection(localDatabaseURL: databaseURL)
        try connection.execute("CREATE TABLE binder_test(value BLOB NOT NULL) STRICT")
        do {
            let insert = try connection.prepare("INSERT INTO binder_test(value) VALUES(?)")
            try insert.bind(Data(), at: 1)
            XCTAssertEqual(try insert.step(), .done)
        }

        XCTAssertEqual(try connection.scalarText("SELECT typeof(value) FROM binder_test"), "blob")
        XCTAssertEqual(try connection.scalarInt64("SELECT length(value) FROM binder_test"), 0)
        do {
            let query = try connection.prepare("SELECT value FROM binder_test")
            XCTAssertEqual(try query.step(), .row)
            XCTAssertEqual(try query.requiredData(at: 0), Data())
            XCTAssertEqual(try query.step(), .done)
        }
        try connection.close()
    }

    func testChecksumTamperFailsClosed() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        try await store.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        try raw.execute("UPDATE schema_migrations SET checksum = zeroblob(32) WHERE version = 1")
        try raw.close()

        XCTAssertThrowsError(
            try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        ) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .migrationChecksumMismatch(version: 1)
            )
        }
    }

    func testV2CrossLedgerOperationDigestCollisionFailsOpenVerification() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try CanonicalPayload(
            kind: "workspace.archive",
            schemaVersion: 1,
            bytes: Data("workspace".utf8)
        )
        let operationPayload = try CanonicalPayload(
            kind: "nextstep.beta.guided-action-completion",
            schemaVersion: 1,
            bytes: Data("completion".utf8)
        )
        let operationID = UUID(
            uuidString: "81000000-0000-0000-0000-000000000001"
        )!
        _ = try await store.commitLocalOperation(
            projection: projection,
            expected: nil,
            operation: ImmutableOperationDraft(
                id: operationID,
                payload: operationPayload
            ),
            mirrorOutbox: [OutboxIntentDraft(payload: projection)],
            committedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        do {
            let update = try raw.prepare(
                "UPDATE sync_applied_operations SET payload_sha256 = ? WHERE operation_id = ?"
            )
            try update.bind(projection.digest.rawBytes, at: 1)
            try update.bind(operationID.uuidString.lowercased(), at: 2)
            XCTAssertEqual(try update.step(), .done)
            XCTAssertEqual(try raw.changes(), 1)
        }
        try raw.close()

        XCTAssertThrowsError(
            try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .incompatibleDatabase)
        }
    }

    func testV2FutureOutboxGenerationFailsOpenVerification() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try CanonicalPayload(
            kind: "workspace.archive",
            schemaVersion: 1,
            bytes: Data("workspace".utf8)
        )
        _ = try await store.commitLocalMutation(
            projection: projection,
            expected: nil,
            outbox: [OutboxIntentDraft(payload: projection)],
            committedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await store.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        try raw.execute("UPDATE outbox_intents SET projection_generation = 2")
        try raw.close()

        XCTAssertThrowsError(
            try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .incompatibleDatabase)
        }
    }

    func testWrongApplicationIDAndFutureVersionFailClosed() async throws {
        let foreignDatabaseURL = try makeDatabaseURL()
        let foreign = try SQLiteConnection(localDatabaseURL: foreignDatabaseURL)
        try foreign.execute("PRAGMA application_id = 42")
        try foreign.close()

        XCTAssertThrowsError(
            try NextStepPersistenceStore(localDatabaseURL: foreignDatabaseURL)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .incompatibleDatabase)
        }

        let futureDatabaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: futureDatabaseURL)
        try await store.close()
        let future = try SQLiteConnection(localDatabaseURL: futureDatabaseURL)
        try future.execute("PRAGMA user_version = 3")
        try future.close()

        XCTAssertThrowsError(
            try NextStepPersistenceStore(localDatabaseURL: futureDatabaseURL)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .unsupportedDatabaseVersion(3))
        }
    }

    func testNonEmptyUnclaimedDatabaseIsNeverAdopted() throws {
        let databaseURL = try makeDatabaseURL()
        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        try raw.execute("CREATE TABLE unrelated(value TEXT) STRICT")
        let originalJournalMode = try raw.scalarText("PRAGMA journal_mode")
        try raw.close()

        XCTAssertThrowsError(
            try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .incompatibleDatabase)
        }

        let verify = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(
            try verify.scalarInt64(
                "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = 'unrelated'"
            ),
            1
        )
        XCTAssertEqual(try verify.scalarInt64("PRAGMA application_id"), 0)
        XCTAssertEqual(try verify.scalarText("PRAGMA journal_mode"), originalJournalMode)
        try verify.close()
    }

    func testSchemaFingerprintRejectsMissingIndexAndExtraTrigger() async throws {
        let missingIndexURL = try makeDatabaseURL()
        let firstStore = try NextStepPersistenceStore(localDatabaseURL: missingIndexURL)
        try await firstStore.close()
        let missingIndex = try SQLiteConnection(localDatabaseURL: missingIndexURL)
        try missingIndex.execute("DROP INDEX outbox_pending_idx")
        try missingIndex.close()
        XCTAssertThrowsError(
            try NextStepPersistenceStore(localDatabaseURL: missingIndexURL)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .incompatibleDatabase)
        }

        let extraTriggerURL = try makeDatabaseURL()
        let secondStore = try NextStepPersistenceStore(localDatabaseURL: extraTriggerURL)
        try await secondStore.close()
        let extraTrigger = try SQLiteConnection(localDatabaseURL: extraTriggerURL)
        try extraTrigger.execute(
            "CREATE TRIGGER unexpected_trigger AFTER INSERT ON canonical_payloads BEGIN SELECT 1; END"
        )
        try extraTrigger.close()
        XCTAssertThrowsError(
            try NextStepPersistenceStore(localDatabaseURL: extraTriggerURL)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .incompatibleDatabase)
        }
    }

    func testCommitFailureWithSuccessfulRollbackLeavesConnectionReusable() throws {
        let databaseURL = try makeDatabaseURL()
        let connection = try SQLiteConnection(localDatabaseURL: databaseURL)
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("CREATE TABLE parent(id INTEGER PRIMARY KEY) STRICT")
        try connection.execute(
            "CREATE TABLE child(parent_id INTEGER NOT NULL REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED) STRICT"
        )

        XCTAssertThrowsError(try connection.withImmediateTransaction {
            try connection.execute("INSERT INTO child(parent_id) VALUES(7)")
        }) { error in
            guard let sqliteError = error as? SQLiteInternalError,
                  case .operationFailed = sqliteError else {
                return XCTFail("A deferred constraint must report a known commit failure.")
            }
        }
        XCTAssertEqual(try connection.scalarInt64("SELECT COUNT(*) FROM child"), 0)
        try connection.withImmediateTransaction {
            try connection.execute("INSERT INTO parent(id) VALUES(7)")
        }
        XCTAssertEqual(try connection.scalarInt64("SELECT COUNT(*) FROM parent"), 1)
        try connection.close()
    }

    func testConservativeRollbackFailureSimulationPoisonsConnection() throws {
        let databaseURL = try makeDatabaseURL()
        let connection = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertThrowsError(try connection.withImmediateTransaction {
            try connection.execute("ROLLBACK")
            throw PersistenceTestFailure.intentional
        }) { error in
            guard let sqliteError = error as? SQLiteInternalError,
                  case .commitOutcomeUnknown = sqliteError else {
                return XCTFail("A failed rollback must make the transaction outcome unknown.")
            }
        }
        XCTAssertThrowsError(try connection.scalarInt64("SELECT 1")) { error in
            guard let sqliteError = error as? SQLiteInternalError,
                  case .commitOutcomeUnknown = sqliteError else {
                return XCTFail("A poisoned connection must reject subsequent operations.")
            }
        }
        try connection.close()
    }

    func testDanglingForeignKeyFailsOpenVerification() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        try await store.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try raw.scalarInt64("PRAGMA foreign_keys"), 0)
        try raw.execute(
            "INSERT INTO workspace_projection(singleton_id, generation, payload_sha256, created_at_ms, updated_at_ms) VALUES(1, 1, zeroblob(32), 0, 0)"
        )
        try raw.close()

        XCTAssertThrowsError(
            try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .incompatibleDatabase)
        }
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextStepPersistenceTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("NextStep.sqlite")
    }
}

private enum PersistenceTestFailure: Error {
    case intentional
}
