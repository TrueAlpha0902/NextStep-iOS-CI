import Foundation
@testable import NextStepPersistence
import XCTest

final class PersistenceStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLocalCommitPersistsProjectionAndOrderedOutboxAcrossReopen() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try payload("workspace-v1", kind: "workspace.archive")
        let operationA = try payload("operation-a", kind: "sync.operation")
        let operationB = try payload("operation-b", kind: "sync.operation")
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let committed = try await store.commitLocalMutation(
            projection: projection,
            expected: nil,
            outbox: [
                OutboxIntentDraft(id: secondID, payload: operationB),
                OutboxIntentDraft(id: firstID, payload: operationA)
            ],
            committedAt: now
        )

        XCTAssertEqual(committed.token.generation, 1)
        XCTAssertEqual(committed.token.payloadDigest, projection.digest)
        XCTAssertEqual(committed.createdAt, now)
        XCTAssertEqual(committed.updatedAt, now)
        let loaded = try await store.loadProjection()
        XCTAssertEqual(loaded, committed)
        let pending = try await store.pendingOutbox(limit: 10)
        XCTAssertEqual(pending.map(\.id), [firstID, secondID])
        XCTAssertEqual(pending.map(\.projectionGeneration), [1, 1])
        XCTAssertEqual(pending.map(\.payload), [operationA, operationB])
        try await store.close()

        let reopened = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let reopenedProjection = try await reopened.loadProjection()
        let reopenedPending = try await reopened.pendingOutbox(limit: 10)
        XCTAssertEqual(reopenedProjection, committed)
        XCTAssertEqual(reopenedPending, pending)
        try await reopened.close()
    }

    func testCASRejectsMissingOrWrongTokenAndAdvancesExactToken() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let firstPayload = try payload("workspace-v1", kind: "workspace.archive")
        let first = try await store.commitLocalMutation(
            projection: firstPayload,
            expected: nil,
            outbox: [OutboxIntentDraft(payload: firstPayload)],
            committedAt: now
        )

        do {
            _ = try await store.commitLocalMutation(
                projection: try payload("workspace-v2", kind: "workspace.archive"),
                expected: nil,
                outbox: [OutboxIntentDraft(payload: firstPayload)],
                committedAt: now.addingTimeInterval(1)
            )
            XCTFail("A nil expected token must never overwrite an existing projection.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .staleProjection(expected: nil, actual: first.token)
            )
        }

        let wrongToken = try ProjectionToken(
            generation: first.token.generation,
            payloadDigest: ContentDigest(hashing: Data("wrong".utf8))
        )
        do {
            _ = try await store.commitLocalMutation(
                projection: try payload("workspace-v2", kind: "workspace.archive"),
                expected: wrongToken,
                outbox: [OutboxIntentDraft(payload: firstPayload)],
                committedAt: now.addingTimeInterval(1)
            )
            XCTFail("A digest-mismatched CAS token must fail.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .staleProjection(expected: wrongToken, actual: first.token)
            )
        }

        let secondPayload = try payload("workspace-v2", kind: "workspace.archive")
        let second = try await store.commitLocalMutation(
            projection: secondPayload,
            expected: first.token,
            outbox: [OutboxIntentDraft(payload: secondPayload)],
            committedAt: now.addingTimeInterval(1)
        )
        XCTAssertEqual(second.token.generation, 2)
        XCTAssertEqual(second.token.payloadDigest, secondPayload.digest)

        do {
            _ = try await store.commitLocalMutation(
                projection: secondPayload,
                expected: second.token,
                outbox: [OutboxIntentDraft(payload: secondPayload)],
                committedAt: now.addingTimeInterval(2)
            )
            XCTFail("An unchanged projection must not create an outbox intent.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .unchangedPayload)
        }
        let pendingAfterUnchanged = try await store.pendingOutbox(limit: 10)
        XCTAssertEqual(pendingAfterUnchanged.count, 2)
        try await store.close()
    }

    func testCommitReturnsThePersistedMillisecondTimestamp() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try payload("workspace-v1", kind: "workspace.archive")
        let fractionalDate = Date(timeIntervalSince1970: 1_800_000_000.123_456)
        let expectedMilliseconds = Int64(
            (fractionalDate.timeIntervalSince1970 * 1_000).rounded(.down)
        )
        let expectedPersistedDate = Date(
            timeIntervalSince1970: Double(expectedMilliseconds) / 1_000
        )
        let committed = try await store.commitLocalMutation(
            projection: projection,
            expected: nil,
            outbox: [OutboxIntentDraft(payload: projection)],
            committedAt: fractionalDate
        )
        let immediatelyLoaded = try await store.loadProjection()
        XCTAssertEqual(committed.createdAt, expectedPersistedDate)
        XCTAssertEqual(committed.updatedAt, expectedPersistedDate)
        XCTAssertEqual(immediatelyLoaded, committed)
        try await store.close()

        let reopened = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let reopenedProjection = try await reopened.loadProjection()
        XCTAssertEqual(reopenedProjection, committed)
        try await reopened.close()
    }

    func testDuplicateOutboxRollsBackProjectionAndCanonicalPayload() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let firstPayload = try payload("workspace-v1", kind: "workspace.archive")
        let reusedID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let first = try await store.commitLocalMutation(
            projection: firstPayload,
            expected: nil,
            outbox: [OutboxIntentDraft(id: reusedID, payload: firstPayload)],
            committedAt: now
        )

        do {
            _ = try await store.commitLocalMutation(
                projection: try payload("workspace-v2", kind: "workspace.archive"),
                expected: first.token,
                outbox: [OutboxIntentDraft(id: reusedID, payload: firstPayload)],
                committedAt: now.addingTimeInterval(1)
            )
            XCTFail("A reused immutable outbox ID must fail atomically.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .duplicateOutboxIntent)
        }

        let projectionAfterDuplicate = try await store.loadProjection()
        let outboxAfterDuplicate = try await store.pendingOutbox(limit: 10)
        XCTAssertEqual(projectionAfterDuplicate, first)
        XCTAssertEqual(outboxAfterDuplicate.count, 1)
        try await store.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM canonical_payloads"), 1)
        try raw.close()
    }

    func testTamperedCanonicalBytesAreRejectedOnLoad() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try payload("workspace-v1", kind: "workspace.archive")
        _ = try await store.commitLocalMutation(
            projection: projection,
            expected: nil,
            outbox: [OutboxIntentDraft(payload: projection)],
            committedAt: now
        )
        try await store.close()

        let tamperedBytes = Data("tampered-workspace".utf8)
        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        do {
            let update = try raw.prepare(
                "UPDATE canonical_payloads SET canonical_bytes = ?, byte_count = ? WHERE sha256 = ?"
            )
            try update.bind(tamperedBytes, at: 1)
            try update.bind(tamperedBytes.count, at: 2)
            try update.bind(projection.digest.rawBytes, at: 3)
            XCTAssertEqual(try update.step(), .done)
            XCTAssertEqual(try raw.changes(), 1)
        }
        try raw.close()

        let reopened = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        do {
            _ = try await reopened.loadProjection()
            XCTFail("Canonical payload bytes must remain bound to their SHA-256 digest.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .digestMismatch(
                    expected: projection.digest,
                    actual: ContentDigest(hashing: tamperedBytes)
                )
            )
        }
        try await reopened.close()
    }

    func testLegacyMigrationInstallsProjectionLedgerWithoutOutbox() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let source = Data("legacy-archive".utf8)
        let sourceDigest = ContentDigest(hashing: source)
        let projection = try payload("canonical-workspace", kind: "workspace.archive")
        let ledger = try MigrationLedgerDraft(
            key: "notes.archive.v1",
            migrationVersion: 1,
            sourceSchemaVersion: 1,
            sourceRevision: 42,
            sourceByteCount: Int64(source.count),
            sourceDigest: sourceDigest,
            backupByteCount: Int64(source.count),
            backupDigest: sourceDigest
        )

        let installed = try await store.installMigration(
            projection: projection,
            ledger: ledger,
            committedAt: now
        )
        XCTAssertEqual(installed.token.generation, 1)
        let recordedLedger = try await store.migrationLedger(key: ledger.key)
        XCTAssertEqual(recordedLedger?.key, ledger.key)
        XCTAssertEqual(recordedLedger?.sourceDigest, sourceDigest)
        XCTAssertEqual(recordedLedger?.backupDigest, sourceDigest)
        XCTAssertEqual(recordedLedger?.resultPayloadDigest, projection.digest)
        XCTAssertEqual(recordedLedger?.resultGeneration, installed.token.generation)
        XCTAssertEqual(recordedLedger?.completedAt, now)
        let replayed = try await store.installMigration(
            projection: projection,
            ledger: ledger,
            committedAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(replayed, installed)
        do {
            _ = try await store.installMigration(
                projection: try payload("changed-result", kind: "workspace.archive"),
                ledger: ledger,
                committedAt: now.addingTimeInterval(60)
            )
            XCTFail("A migration retry with a different result must fail closed.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .transactionInvariantViolation)
        }
        let changedSource = Data("different-legacy-archive".utf8)
        let changedSourceDigest = ContentDigest(hashing: changedSource)
        let changedLedger = try MigrationLedgerDraft(
            key: ledger.key,
            migrationVersion: ledger.migrationVersion,
            sourceSchemaVersion: ledger.sourceSchemaVersion,
            sourceRevision: ledger.sourceRevision,
            sourceByteCount: Int64(changedSource.count),
            sourceDigest: changedSourceDigest,
            backupByteCount: Int64(changedSource.count),
            backupDigest: changedSourceDigest
        )
        do {
            _ = try await store.installMigration(
                projection: projection,
                ledger: changedLedger,
                committedAt: now.addingTimeInterval(60)
            )
            XCTFail("A migration retry with different source evidence must fail closed.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .transactionInvariantViolation)
        }
        let loaded = try await store.loadProjection()
        let pending = try await store.pendingOutbox(limit: 10)
        XCTAssertEqual(loaded, installed)
        XCTAssertTrue(pending.isEmpty)
        try await store.close()

        let reopened = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let replayedAfterReopen = try await reopened.installMigration(
            projection: projection,
            ledger: ledger,
            committedAt: now.addingTimeInterval(120)
        )
        XCTAssertEqual(replayedAfterReopen, installed)
        try await reopened.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM migration_ledger"), 1)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM canonical_payloads"), 1)
        try raw.close()
    }

    func testMigrationRequiresACompletelyEmptyOutboxState() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)

        let orphanPayload = try payload("orphan-operation", kind: "sync.operation")
        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        do {
            let payloadInsert = try raw.prepare(
                "INSERT INTO canonical_payloads(sha256, payload_kind, schema_version, canonical_bytes, byte_count, created_at_ms) VALUES(?, ?, ?, ?, ?, 0)"
            )
            try payloadInsert.bind(orphanPayload.digest.rawBytes, at: 1)
            try payloadInsert.bind(orphanPayload.kind, at: 2)
            try payloadInsert.bind(orphanPayload.schemaVersion, at: 3)
            try payloadInsert.bind(orphanPayload.bytes, at: 4)
            try payloadInsert.bind(orphanPayload.bytes.count, at: 5)
            XCTAssertEqual(try payloadInsert.step(), .done)
        }
        do {
            let outboxInsert = try raw.prepare(
                "INSERT INTO outbox_intents(intent_id, projection_generation, payload_sha256, created_at_ms, published_at_ms) VALUES(?, 1, ?, 0, NULL)"
            )
            try outboxInsert.bind(
                "40000000-0000-0000-0000-000000000001",
                at: 1
            )
            try outboxInsert.bind(orphanPayload.digest.rawBytes, at: 2)
            XCTAssertEqual(try outboxInsert.step(), .done)
        }
        try raw.close()

        let source = Data("legacy".utf8)
        let sourceDigest = ContentDigest(hashing: source)
        let ledger = try MigrationLedgerDraft(
            key: "notes.archive.v1",
            migrationVersion: 1,
            sourceSchemaVersion: 1,
            sourceRevision: 0,
            sourceByteCount: Int64(source.count),
            sourceDigest: sourceDigest,
            backupByteCount: Int64(source.count),
            backupDigest: sourceDigest
        )
        do {
            _ = try await store.installMigration(
                projection: try payload("workspace", kind: "workspace.archive"),
                ledger: ledger,
                committedAt: now
            )
            XCTFail("Migration must not install over any existing outbox state.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .transactionInvariantViolation)
        }
        let projectionAfterFailure = try await store.loadProjection()
        XCTAssertNil(projectionAfterFailure)
        try await store.close()

        let verify = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try verify.scalarInt64("SELECT COUNT(*) FROM workspace_projection"), 0)
        XCTAssertEqual(try verify.scalarInt64("SELECT COUNT(*) FROM migration_ledger"), 0)
        XCTAssertEqual(try verify.scalarInt64("SELECT COUNT(*) FROM canonical_payloads"), 1)
        XCTAssertEqual(try verify.scalarInt64("SELECT COUNT(*) FROM outbox_intents"), 1)
        try verify.close()
    }

    func testEmptyOutboxAndInvalidLimitsLeaveDatabaseEmpty() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try payload("workspace-v1", kind: "workspace.archive")

        do {
            _ = try await store.commitLocalMutation(
                projection: projection,
                expected: nil,
                outbox: [],
                committedAt: now
            )
            XCTFail("A local mutation without an outbox intent must fail.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .emptyOutbox)
        }
        do {
            _ = try await store.pendingOutbox(limit: 0)
            XCTFail("An unbounded or empty outbox query must fail.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .invalidLimit)
        }
        let loaded = try await store.loadProjection()
        XCTAssertNil(loaded)
        try await store.close()
    }

    func testPublishingOutboxIsDigestBoundAndIdempotent() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try payload("workspace-v1", kind: "workspace.archive")
        let operation = try payload("operation-v1", kind: "sync.operation")
        let intentID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        _ = try await store.commitLocalMutation(
            projection: projection,
            expected: nil,
            outbox: [OutboxIntentDraft(id: intentID, payload: operation)],
            committedAt: now
        )

        let wrongDigest = ContentDigest(hashing: Data("wrong".utf8))
        do {
            try await store.markOutboxPublished(
                id: intentID,
                expectedDigest: wrongDigest,
                publishedAt: now.addingTimeInterval(1)
            )
            XCTFail("Publishing must be bound to the immutable payload digest.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .digestMismatch(expected: wrongDigest, actual: operation.digest)
            )
        }
        let pendingAfterMismatch = try await store.pendingOutbox(limit: 10)
        XCTAssertEqual(pendingAfterMismatch.count, 1)

        try await store.markOutboxPublished(
            id: intentID,
            expectedDigest: operation.digest,
            publishedAt: now.addingTimeInterval(1)
        )
        let pendingAfterPublish = try await store.pendingOutbox(limit: 10)
        XCTAssertTrue(pendingAfterPublish.isEmpty)

        try await store.markOutboxPublished(
            id: intentID,
            expectedDigest: operation.digest,
            publishedAt: now.addingTimeInterval(2)
        )
        let pendingAfterReplay = try await store.pendingOutbox(limit: 10)
        XCTAssertTrue(pendingAfterReplay.isEmpty)
        try await store.close()
    }

    func testPruningPublishedOutboxBoundsCanonicalSnapshotRetention() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let firstPayload = try payload("workspace-v1", kind: "workspace.archive")
        let secondPayload = try payload("workspace-v2", kind: "workspace.archive")
        let thirdPayload = try payload("workspace-v3", kind: "workspace.archive")
        let firstID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "50000000-0000-0000-0000-000000000003")!
        let first = try await store.commitLocalMutation(
            projection: firstPayload,
            expected: nil,
            outbox: [OutboxIntentDraft(id: firstID, payload: firstPayload)],
            committedAt: now
        )
        let second = try await store.commitLocalMutation(
            projection: secondPayload,
            expected: first.token,
            outbox: [OutboxIntentDraft(id: secondID, payload: secondPayload)],
            committedAt: now.addingTimeInterval(1)
        )
        let third = try await store.commitLocalMutation(
            projection: thirdPayload,
            expected: second.token,
            outbox: [OutboxIntentDraft(id: thirdID, payload: thirdPayload)],
            committedAt: now.addingTimeInterval(2)
        )
        try await store.markOutboxPublished(
            id: firstID,
            expectedDigest: firstPayload.digest,
            publishedAt: now.addingTimeInterval(3)
        )
        try await store.markOutboxPublished(
            id: secondID,
            expectedDigest: secondPayload.digest,
            publishedAt: now.addingTimeInterval(3)
        )

        let firstPruneCount = try await store.prunePublishedOutbox(
            throughGeneration: first.token.generation
        )
        XCTAssertEqual(firstPruneCount, 1)
        try await store.close()

        do {
            let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
            XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM outbox_intents"), 2)
            XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM canonical_payloads"), 2)
            try raw.close()
        }

        let reopened = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let reopenedProjection = try await reopened.loadProjection()
        XCTAssertEqual(reopenedProjection?.token, third.token)
        let secondPruneCount = try await reopened.prunePublishedOutbox(
            throughGeneration: second.token.generation
        )
        let replayedPruneCount = try await reopened.prunePublishedOutbox(
            throughGeneration: second.token.generation
        )
        XCTAssertEqual(secondPruneCount, 1)
        XCTAssertEqual(replayedPruneCount, 0)
        let remainingPending = try await reopened.pendingOutbox(limit: 10)
        XCTAssertEqual(remainingPending.map(\.id), [thirdID])
        try await reopened.close()

        do {
            let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
            XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM outbox_intents"), 1)
            XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM canonical_payloads"), 1)
            try raw.close()
        }
    }

    func testLocalImmutableOperationCommitIsAtomicKindFilteredAndGCRetained() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try payload("workspace-with-completion", kind: "workspace.archive")
        let operationPayload = try payload(
            "guided-action-completed",
            kind: "nextstep.beta.guided-action-completion"
        )
        let operationID = UUID(
            uuidString: "f0000000-0000-0000-0000-000000000001"
        )!
        let mirrorID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000010"
        )!
        let operation = ImmutableOperationDraft(
            id: operationID,
            payload: operationPayload
        )

        let committed = try await store.commitLocalOperation(
            projection: projection,
            expected: nil,
            operation: operation,
            mirrorOutbox: [OutboxIntentDraft(id: mirrorID, payload: projection)],
            committedAt: now
        )

        XCTAssertEqual(committed.token.generation, 1)
        let operationOnly = try await store.pendingOutbox(
            kind: operationPayload.kind,
            limit: 1
        )
        XCTAssertEqual(operationOnly.map(\.id), [operationID])
        XCTAssertEqual(operationOnly.first?.payload, operationPayload)
        let mirrorOnly = try await store.pendingOutbox(
            kind: projection.kind,
            limit: 1
        )
        XCTAssertEqual(mirrorOnly.map(\.id), [mirrorID])
        let applied = try await store.appliedOperation(id: operationID)
        XCTAssertEqual(applied?.payload, operationPayload)
        XCTAssertEqual(applied?.resultGeneration, committed.token.generation)
        XCTAssertEqual(applied?.appliedAt, now)
        let durableByKind = try await store.appliedOperations(
            kind: operationPayload.kind,
            limit: 10
        )
        XCTAssertEqual(durableByKind.map(\.id), [operationID])
        XCTAssertEqual(durableByKind.first?.payload, operationPayload)
        let afterOnlyRecord = try await store.appliedOperations(
            kind: operationPayload.kind,
            afterAppliedAt: now,
            afterID: operationID,
            limit: 10
        )
        XCTAssertTrue(afterOnlyRecord.isEmpty)
        let unrelatedKind = try await store.appliedOperations(
            kind: projection.kind,
            limit: 10
        )
        XCTAssertTrue(unrelatedKind.isEmpty)
        do {
            _ = try await store.appliedOperations(
                kind: operationPayload.kind,
                afterAppliedAt: now,
                limit: 10
            )
            XCTFail("A partial applied-operation cursor must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .invalidValue(field: "appliedOperationCursor")
            )
        }
        let pendingInbox = try await store.pendingInboxOperations(limit: 10)
        XCTAssertTrue(pendingInbox.isEmpty)

        try await store.markOutboxPublished(
            id: mirrorID,
            expectedDigest: projection.digest,
            publishedAt: now.addingTimeInterval(1)
        )
        try await store.markOutboxPublished(
            id: operationID,
            expectedDigest: operationPayload.digest,
            publishedAt: now.addingTimeInterval(1)
        )
        let pruned = try await store.prunePublishedOutbox(
            throughGeneration: committed.token.generation
        )
        XCTAssertEqual(pruned, 2)
        try await store.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        do {
            let retained = try raw.prepare(
                "SELECT COUNT(*) FROM canonical_payloads WHERE sha256 = ?"
            )
            try retained.bind(operationPayload.digest.rawBytes, at: 1)
            XCTAssertEqual(try retained.step(), .row)
            XCTAssertEqual(try retained.requiredInt64(at: 0), 1)
            XCTAssertEqual(try retained.step(), .done)
        }
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM outbox_intents"), 0)
        XCTAssertEqual(
            try raw.scalarInt64("SELECT COUNT(*) FROM sync_applied_operations"),
            1
        )
        try raw.close()
    }

    func testGenericOutboxIdentifierCannotCollideWithOperationLedgers() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let collidingID = UUID(
            uuidString: "5f000000-0000-0000-0000-000000000001"
        )!
        let remoteOperation = ImmutableOperationDraft(
            id: collidingID,
            payload: try payload(
                "remote-completion",
                kind: "nextstep.beta.guided-action-completion"
            )
        )
        _ = try await store.stageInboxOperation(remoteOperation, receivedAt: now)

        let initialProjection = try payload("workspace-v1", kind: "workspace.archive")
        do {
            _ = try await store.commitLocalMutation(
                projection: initialProjection,
                expected: nil,
                outbox: [
                    OutboxIntentDraft(
                        id: collidingID,
                        payload: remoteOperation.payload
                    )
                ],
                committedAt: now
            )
            XCTFail("A generic outbox must not use the exact ID/digest of an operation.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .duplicateOutboxIntent)
        }
        do {
            _ = try await store.commitLocalMutation(
                projection: initialProjection,
                expected: nil,
                outbox: [
                    OutboxIntentDraft(id: collidingID, payload: initialProjection)
                ],
                committedAt: now
            )
            XCTFail("A projection outbox ID must not reuse an inbox operation ID.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .operationIdentityCollision(
                    id: collidingID,
                    expected: remoteOperation.payload.digest,
                    actual: initialProjection.digest
                )
            )
        }
        let projectionAfterInboxCollision = try await store.loadProjection()
        XCTAssertNil(projectionAfterInboxCollision)
        let outboxAfterInboxCollision = try await store.pendingOutbox(limit: 10)
        XCTAssertTrue(outboxAfterInboxCollision.isEmpty)

        let safeMirrorID = UUID(
            uuidString: "5f000000-0000-0000-0000-000000000002"
        )!
        let initial = try await store.commitLocalMutation(
            projection: initialProjection,
            expected: nil,
            outbox: [
                OutboxIntentDraft(id: safeMirrorID, payload: initialProjection)
            ],
            committedAt: now
        )
        _ = try await store.applyInboxOperations(
            projection: initialProjection,
            expected: initial.token,
            operations: [remoteOperation],
            mirrorOutbox: [],
            receivedAt: now,
            appliedAt: now
        )

        let nextProjection = try payload("workspace-v2", kind: "workspace.archive")
        let localOperation = ImmutableOperationDraft(
            id: UUID(uuidString: "5f000000-0000-0000-0000-000000000003")!,
            payload: try payload(
                "local-completion",
                kind: "nextstep.beta.guided-action-completion"
            )
        )
        do {
            _ = try await store.commitLocalOperation(
                projection: nextProjection,
                expected: initial.token,
                operation: localOperation,
                mirrorOutbox: [
                    OutboxIntentDraft(id: collidingID, payload: nextProjection)
                ],
                committedAt: now.addingTimeInterval(1)
            )
            XCTFail("A mirror outbox ID must not reuse an applied operation ID.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .operationIdentityCollision(
                    id: collidingID,
                    expected: remoteOperation.payload.digest,
                    actual: nextProjection.digest
                )
            )
        }

        let projectionAfterAppliedCollision = try await store.loadProjection()
        XCTAssertEqual(projectionAfterAppliedCollision, initial)
        let rejectedApplied = try await store.appliedOperation(id: localOperation.id)
        XCTAssertNil(rejectedApplied)
        let pendingAfterAppliedCollision = try await store.pendingOutbox(limit: 10)
        XCTAssertEqual(pendingAfterAppliedCollision.map(\.id), [safeMirrorID])
        try await store.close()

        let reopened = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let reopenedProjection = try await reopened.loadProjection()
        XCTAssertEqual(reopenedProjection, initial)
        let reopenedApplied = try await reopened.appliedOperation(id: collidingID)
        XCTAssertEqual(reopenedApplied?.payload, remoteOperation.payload)
        let reopenedPending = try await reopened.pendingOutbox(limit: 10)
        XCTAssertEqual(reopenedPending.map(\.id), [safeMirrorID])
        try await reopened.close()
    }

    func testInboxStagingIsIdempotentAndIDCollisionFailsClosed() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let operationID = UUID(
            uuidString: "60000000-0000-0000-0000-000000000001"
        )!
        let operation = ImmutableOperationDraft(
            id: operationID,
            payload: try payload(
                "remote-completion",
                kind: "nextstep.beta.guided-action-completion"
            )
        )

        let staged = try await store.stageInboxOperation(operation, receivedAt: now)
        let replayed = try await store.stageInboxOperation(
            operation,
            receivedAt: now.addingTimeInterval(60)
        )
        XCTAssertEqual(replayed, staged)

        let metadataRebinding = ImmutableOperationDraft(
            id: operationID,
            payload: try CanonicalPayload(
                kind: "nextstep.beta.other-operation",
                schemaVersion: operation.payload.schemaVersion,
                bytes: operation.payload.bytes
            )
        )
        do {
            _ = try await store.stageInboxOperation(
                metadataRebinding,
                receivedAt: now.addingTimeInterval(90)
            )
            XCTFail("Equal bytes must not rebind an operation payload kind.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .transactionInvariantViolation)
        }
        let pending = try await store.pendingInboxOperations(limit: 10)
        XCTAssertEqual(pending, [staged])

        let colliding = ImmutableOperationDraft(
            id: operationID,
            payload: try payload(
                "different-completion",
                kind: "nextstep.beta.guided-action-completion"
            )
        )
        do {
            _ = try await store.stageInboxOperation(
                colliding,
                receivedAt: now.addingTimeInterval(120)
            )
            XCTFail("One operation UUID must never be rebound to another digest.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .operationIdentityCollision(
                    id: operationID,
                    expected: operation.payload.digest,
                    actual: colliding.payload.digest
                )
            )
        }
        let pendingAfterCollision = try await store.pendingInboxOperations(limit: 10)
        XCTAssertEqual(pendingAfterCollision, [staged])
        try await store.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM canonical_payloads"), 1)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM sync_inbox_operations"), 1)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM sync_applied_operations"), 0)
        try raw.close()
    }

    func testAppliedOperationCursorPagesSameMillisecondByIdentifier() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try payload("completed-workspace", kind: "workspace.archive")
        let identifiers = [1, 2, 3].map { suffix in
            UUID(uuidString: String(
                format: "65000000-0000-0000-0000-%012d",
                suffix
            ))!
        }
        // This value is known to read back from Date microscopically below the
        // stored integer millisecond on IEEE-754 binary floating point.
        let sharedAppliedAt = Date(
            timeIntervalSince1970: (Double(1_083_266_354_376) + 0.5) / 1_000
        )
        var token: ProjectionToken?
        for (index, identifier) in identifiers.enumerated() {
            let operation = ImmutableOperationDraft(
                id: identifier,
                payload: try payload(
                    "completion-\(index)",
                    kind: "nextstep.beta.guided-action-completion"
                )
            )
            let stored = try await store.commitLocalOperation(
                projection: projection,
                expected: token,
                operation: operation,
                mirrorOutbox: index == 0
                    ? [OutboxIntentDraft(payload: projection)]
                    : [],
                committedAt: sharedAppliedAt
            )
            token = stored.token
        }

        let firstPage = try await store.appliedOperations(
            kind: "nextstep.beta.guided-action-completion",
            limit: 1
        )
        XCTAssertEqual(firstPage.map(\.id), [identifiers[0]])
        let firstCursor = try XCTUnwrap(firstPage.last)
        let secondPage = try await store.appliedOperations(
            kind: "nextstep.beta.guided-action-completion",
            afterAppliedAt: firstCursor.appliedAt,
            afterID: firstCursor.id,
            limit: 1
        )
        XCTAssertEqual(secondPage.map(\.id), [identifiers[1]])
        let secondCursor = try XCTUnwrap(secondPage.last)
        let thirdPage = try await store.appliedOperations(
            kind: "nextstep.beta.guided-action-completion",
            afterAppliedAt: secondCursor.appliedAt,
            afterID: secondCursor.id,
            limit: 1
        )
        XCTAssertEqual(thirdPage.map(\.id), [identifiers[2]])
        let thirdCursor = try XCTUnwrap(thirdPage.last)
        let terminalPage = try await store.appliedOperations(
            kind: "nextstep.beta.guided-action-completion",
            afterAppliedAt: thirdCursor.appliedAt,
            afterID: thirdCursor.id,
            limit: 1
        )
        XCTAssertTrue(terminalPage.isEmpty)
    }

    func testLocalOperationRepairsSameProjectionWithoutGenerationOrMirrorIntent() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try payload("already-completed", kind: "workspace.archive")
        let originalMirrorID = UUID(
            uuidString: "74000000-0000-0000-0000-000000000001"
        )!
        let initial = try await store.commitLocalMutation(
            projection: projection,
            expected: nil,
            outbox: [OutboxIntentDraft(id: originalMirrorID, payload: projection)],
            committedAt: now
        )
        let operation = ImmutableOperationDraft(
            id: UUID(uuidString: "74000000-0000-0000-0000-000000000002")!,
            payload: try payload(
                "completion-ledger-repair",
                kind: "nextstep.beta.guided-action-completion"
            )
        )

        let changedProjection = try payload(
            "changed-without-mirror",
            kind: "workspace.archive"
        )
        do {
            _ = try await store.commitLocalOperation(
                projection: changedProjection,
                expected: initial.token,
                operation: operation,
                mirrorOutbox: [],
                committedAt: now.addingTimeInterval(1)
            )
            XCTFail("A changed projection still requires an explicit mirror intent.")
        } catch {
            XCTAssertEqual(error as? PersistenceError, .emptyOutbox)
        }
        let afterRejectedChange = try await store.loadProjection()
        let appliedAfterRejectedChange = try await store.appliedOperation(id: operation.id)
        XCTAssertEqual(afterRejectedChange, initial)
        XCTAssertNil(appliedAfterRejectedChange)

        do {
            _ = try await store.commitLocalOperation(
                projection: changedProjection,
                expected: initial.token,
                operation: operation,
                mirrorOutbox: [OutboxIntentDraft(payload: projection)],
                committedAt: now.addingTimeInterval(1)
            )
            XCTFail("A mirror intent must contain the projection it publishes.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .invalidValue(field: "mirrorOutboxPayload")
            )
        }
        let afterMismatchedMirror = try await store.loadProjection()
        let appliedAfterMismatchedMirror = try await store.appliedOperation(id: operation.id)
        XCTAssertEqual(afterMismatchedMirror, initial)
        XCTAssertNil(appliedAfterMismatchedMirror)

        let repaired = try await store.commitLocalOperation(
            projection: projection,
            expected: initial.token,
            operation: operation,
            mirrorOutbox: [],
            committedAt: now.addingTimeInterval(1)
        )
        let replayedRepair = try await store.commitLocalOperation(
            projection: projection,
            expected: initial.token,
            operation: operation,
            mirrorOutbox: [],
            committedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(repaired, initial)
        XCTAssertEqual(replayedRepair, initial)
        let applied = try await store.appliedOperation(id: operation.id)
        XCTAssertEqual(applied?.resultGeneration, initial.token.generation)
        let outbox = try await store.pendingOutbox(limit: 10)
        XCTAssertEqual(Set(outbox.map(\.id)), Set([originalMirrorID, operation.id]))
        XCTAssertEqual(outbox.count, 2)
        try await store.close()
    }

    func testRemoteNoOpProjectionRepairsLedgersWithoutMirrorOrGeneration() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let projection = try payload("already-completed", kind: "workspace.archive")
        let existingMirrorID = UUID(
            uuidString: "75000000-0000-0000-0000-000000000001"
        )!
        let initial = try await store.commitLocalMutation(
            projection: projection,
            expected: nil,
            outbox: [OutboxIntentDraft(id: existingMirrorID, payload: projection)],
            committedAt: now
        )
        let operation = ImmutableOperationDraft(
            id: UUID(uuidString: "75000000-0000-0000-0000-000000000002")!,
            payload: try payload(
                "remote-completion-ledger-repair",
                kind: "nextstep.beta.guided-action-completion"
            )
        )

        let repaired = try await store.applyInboxOperations(
            projection: projection,
            expected: initial.token,
            operations: [operation],
            mirrorOutbox: [],
            receivedAt: now.addingTimeInterval(1),
            appliedAt: now.addingTimeInterval(2)
        )
        let exactReplay = try await store.applyInboxOperations(
            projection: projection,
            expected: initial.token,
            operations: [operation],
            mirrorOutbox: [],
            receivedAt: now.addingTimeInterval(3),
            appliedAt: now.addingTimeInterval(4)
        )

        XCTAssertEqual(repaired, initial)
        XCTAssertEqual(exactReplay, initial)
        let applied = try await store.appliedOperation(id: operation.id)
        let pendingInbox = try await store.pendingInboxOperations(limit: 10)
        XCTAssertEqual(applied?.resultGeneration, initial.token.generation)
        XCTAssertTrue(pendingInbox.isEmpty)
        let outbox = try await store.pendingOutbox(limit: 10)
        XCTAssertEqual(outbox.map(\.id), [existingMirrorID])
        try await store.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try raw.scalarInt64("SELECT generation FROM workspace_projection"), 1)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM sync_inbox_operations"), 1)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM sync_applied_operations"), 1)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM outbox_intents"), 1)
        try raw.close()
    }

    func testBatchInboxApplyCommitsFinalProjectionLedgersAndMirrorAtomically() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let initialPayload = try payload("workspace-v1", kind: "workspace.archive")
        let initial = try await store.commitLocalMutation(
            projection: initialPayload,
            expected: nil,
            outbox: [OutboxIntentDraft(
                id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
                payload: initialPayload
            )],
            committedAt: now
        )
        let firstOperation = ImmutableOperationDraft(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
            payload: try payload(
                "completion-one",
                kind: "nextstep.beta.guided-action-completion"
            )
        )
        let secondOperation = ImmutableOperationDraft(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!,
            payload: try payload(
                "completion-two",
                kind: "nextstep.beta.guided-action-completion"
            )
        )
        let mergedPayload = try payload("workspace-v2-merged", kind: "workspace.archive")
        let firstMirrorID = UUID(
            uuidString: "72000000-0000-0000-0000-000000000001"
        )!

        let merged = try await store.applyInboxOperations(
            projection: mergedPayload,
            expected: initial.token,
            operations: [firstOperation, secondOperation, firstOperation],
            mirrorOutbox: [OutboxIntentDraft(
                id: firstMirrorID,
                payload: mergedPayload
            )],
            receivedAt: now.addingTimeInterval(1),
            appliedAt: now.addingTimeInterval(2)
        )
        XCTAssertEqual(merged.token.generation, 2)
        let pendingAfterMerge = try await store.pendingInboxOperations(limit: 10)
        let firstApplied = try await store.appliedOperation(id: firstOperation.id)
        let secondApplied = try await store.appliedOperation(id: secondOperation.id)
        XCTAssertTrue(pendingAfterMerge.isEmpty)
        XCTAssertEqual(firstApplied?.resultGeneration, 2)
        XCTAssertEqual(secondApplied?.resultGeneration, 2)

        let replayProjection = try payload("workspace-v3-reconciled", kind: "workspace.archive")
        let replayed = try await store.applyInboxOperations(
            projection: replayProjection,
            expected: merged.token,
            operations: [secondOperation, firstOperation],
            mirrorOutbox: [OutboxIntentDraft(
                id: UUID(uuidString: "72000000-0000-0000-0000-000000000002")!,
                payload: replayProjection
            )],
            receivedAt: now.addingTimeInterval(3),
            appliedAt: now.addingTimeInterval(4)
        )
        XCTAssertEqual(replayed.token.generation, 3)
        let replayedFirstApplied = try await store.appliedOperation(
            id: firstOperation.id
        )
        XCTAssertEqual(
            replayedFirstApplied?.resultGeneration,
            2,
            "A same-ID/same-digest replay must not rewrite the applied ledger."
        )

        let colliding = ImmutableOperationDraft(
            id: firstOperation.id,
            payload: try payload(
                "collision",
                kind: "nextstep.beta.guided-action-completion"
            )
        )
        let newOperation = ImmutableOperationDraft(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000003")!,
            payload: try payload(
                "completion-three",
                kind: "nextstep.beta.guided-action-completion"
            )
        )
        let rejectedMirrorID = UUID(
            uuidString: "72000000-0000-0000-0000-000000000003"
        )!
        do {
            _ = try await store.applyInboxOperations(
                projection: try payload("must-rollback", kind: "workspace.archive"),
                expected: replayed.token,
                operations: [newOperation, colliding],
                mirrorOutbox: [OutboxIntentDraft(
                    id: rejectedMirrorID,
                    payload: replayProjection
                )],
                receivedAt: now.addingTimeInterval(5),
                appliedAt: now.addingTimeInterval(6)
            )
            XCTFail("An operation identity collision must roll back the whole batch.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .operationIdentityCollision(
                    id: firstOperation.id,
                    expected: firstOperation.payload.digest,
                    actual: colliding.payload.digest
                )
            )
        }
        let projectionAfterCollision = try await store.loadProjection()
        let rejectedApplied = try await store.appliedOperation(id: newOperation.id)
        let outboxAfterCollision = try await store.pendingOutbox(limit: 20)
        XCTAssertEqual(projectionAfterCollision, replayed)
        XCTAssertNil(rejectedApplied)
        XCTAssertFalse(outboxAfterCollision.contains { $0.id == rejectedMirrorID })
        try await store.close()

        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM sync_inbox_operations"), 2)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM sync_applied_operations"), 2)
        try raw.close()
    }

    func testBatchInboxApplyStaleCASRollsBackEveryLedgerAndOutboxWrite() async throws {
        let databaseURL = try makeDatabaseURL()
        let store = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let initialPayload = try payload("workspace-v1", kind: "workspace.archive")
        let initial = try await store.commitLocalMutation(
            projection: initialPayload,
            expected: nil,
            outbox: [OutboxIntentDraft(payload: initialPayload)],
            committedAt: now
        )
        let wrongToken = try ProjectionToken(
            generation: initial.token.generation,
            payloadDigest: ContentDigest(hashing: Data("wrong".utf8))
        )
        let operation = ImmutableOperationDraft(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!,
            payload: try payload(
                "remote-completion",
                kind: "nextstep.beta.guided-action-completion"
            )
        )
        let mirrorID = UUID(
            uuidString: "73000000-0000-0000-0000-000000000002"
        )!

        do {
            _ = try await store.applyInboxOperation(
                projection: try payload("workspace-v2", kind: "workspace.archive"),
                expected: wrongToken,
                operation: operation,
                mirrorOutbox: [OutboxIntentDraft(id: mirrorID, payload: initialPayload)],
                receivedAt: now.addingTimeInterval(1),
                appliedAt: now.addingTimeInterval(2)
            )
            XCTFail("A stale projection token must roll back the remote apply transaction.")
        } catch {
            XCTAssertEqual(
                error as? PersistenceError,
                .staleProjection(expected: wrongToken, actual: initial.token)
            )
        }
        let projectionAfterStaleCAS = try await store.loadProjection()
        let inboxAfterStaleCAS = try await store.pendingInboxOperations(limit: 10)
        let appliedAfterStaleCAS = try await store.appliedOperation(id: operation.id)
        let outboxAfterStaleCAS = try await store.pendingOutbox(limit: 10)
        XCTAssertEqual(projectionAfterStaleCAS, initial)
        XCTAssertTrue(inboxAfterStaleCAS.isEmpty)
        XCTAssertNil(appliedAfterStaleCAS)
        XCTAssertFalse(outboxAfterStaleCAS.contains { $0.id == mirrorID })
        try await store.close()
    }

    func testTwoStoresUsingOneCASTokenProduceOneWinnerAndOneStaleWriter() async throws {
        let databaseURL = try makeDatabaseURL()
        let storeA = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let initialPayload = try payload("workspace-v1", kind: "workspace.archive")
        let initial = try await storeA.commitLocalMutation(
            projection: initialPayload,
            expected: nil,
            outbox: [OutboxIntentDraft(payload: initialPayload)],
            committedAt: now
        )
        let storeB = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let storeBToken = try await storeB.loadProjection()?.token
        XCTAssertEqual(storeBToken, initial.token)

        let payloadA = try payload("workspace-from-a", kind: "workspace.archive")
        let payloadB = try payload("workspace-from-b", kind: "workspace.archive")
        let concurrentCommitDate = now.addingTimeInterval(1)
        async let resultA = Self.commitResult(
            store: storeA,
            projection: payloadA,
            expected: initial.token,
            intentID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            committedAt: concurrentCommitDate
        )
        async let resultB = Self.commitResult(
            store: storeB,
            projection: payloadB,
            expected: initial.token,
            intentID: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
            committedAt: concurrentCommitDate
        )
        let firstResult = await resultA
        let secondResult = await resultB
        let results = [firstResult, secondResult]

        let successes = results.compactMap { result -> StoredProjection? in
            guard case .success(let projection) = result else { return nil }
            return projection
        }
        let failures = results.compactMap { result -> PersistenceError? in
            guard case .failure(let error) = result else { return nil }
            return error
        }
        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(successes.first?.token.generation, 2)
        XCTAssertEqual(failures.count, 1)
        guard let failure = failures.first,
              case .staleProjection(let expected, let actual) = failure else {
            return XCTFail("The losing writer must fail with the exact stale CAS token.")
        }
        XCTAssertEqual(expected, initial.token)
        XCTAssertEqual(actual?.generation, 2)
        let finalPending = try await storeA.pendingOutbox(limit: 10)
        XCTAssertEqual(finalPending.count, 2)
        try await storeA.close()
        try await storeB.close()
    }

    private func payload(_ value: String, kind: String) throws -> CanonicalPayload {
        try CanonicalPayload(
            kind: kind,
            schemaVersion: 1,
            bytes: Data(value.utf8)
        )
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

    private static func commitResult(
        store: NextStepPersistenceStore,
        projection: CanonicalPayload,
        expected: ProjectionToken,
        intentID: UUID,
        committedAt: Date
    ) async -> Result<StoredProjection, PersistenceError> {
        do {
            return .success(try await store.commitLocalMutation(
                projection: projection,
                expected: expected,
                outbox: [OutboxIntentDraft(id: intentID, payload: projection)],
                committedAt: committedAt
            ))
        } catch let error as PersistenceError {
            return .failure(error)
        } catch {
            return .failure(.transactionInvariantViolation)
        }
    }
}
