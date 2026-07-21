import Foundation

public actor NextStepPersistenceStore {
    public static let maximumPendingOutboxLimit = 1_000

    public nonisolated let configuredPragmas: PersistencePragmas

    private var connection: SQLiteConnection?

    private struct OperationIdentity {
        let inInbox: Bool
        let isApplied: Bool
        let inOutbox: Bool
    }

    private struct ProjectionWriteResult {
        let projection: StoredProjection
        let didAdvance: Bool
    }

    public init(localDatabaseURL: URL) throws {
        do {
            let openedConnection = try SQLiteConnection(
                localDatabaseURL: localDatabaseURL
            )
            let pragmas = try SQLiteMigrations.prepare(openedConnection)
            connection = openedConnection
            configuredPragmas = pragmas
        } catch {
            throw Self.publicError(error)
        }
    }

    public func inspectPragmas() throws -> PersistencePragmas {
        try withConnection { connection in
            try SQLiteMigrations.inspectPragmas(connection)
        }
    }

    public func loadProjection() throws -> StoredProjection? {
        try withConnection(Self.readProjection)
    }

    public func migrationLedger(
        key: String
    ) throws -> MigrationLedgerRecord? {
        guard PersistenceModelLimits.isSafeKey(
            key,
            maximumBytes: PersistenceModelLimits.maximumMigrationKeyBytes
        ) else {
            throw PersistenceError.invalidValue(field: "migrationKey")
        }
        return try withConnection { connection in
            try Self.readMigrationLedger(key, connection: connection)
        }
    }

    public func commitLocalMutation(
        projection: CanonicalPayload,
        expected: ProjectionToken?,
        outbox: [OutboxIntentDraft],
        committedAt: Date
    ) throws -> StoredProjection {
        guard outbox.isEmpty == false else {
            throw PersistenceError.emptyOutbox
        }
        guard outbox.count <= 10_000 else {
            throw PersistenceError.invalidLimit
        }
        guard Set(outbox.map(\.id)).count == outbox.count else {
            throw PersistenceError.duplicateOutboxIntent
        }
        let committedAtMilliseconds = try Self.milliseconds(committedAt)
        let normalizedCommittedAt = Self.date(milliseconds: committedAtMilliseconds)

        return try withConnection { connection in
            try connection.withImmediateTransaction {
                let existing = try Self.readProjection(connection)
                guard existing?.token == expected else {
                    throw PersistenceError.staleProjection(
                        expected: expected,
                        actual: existing?.token
                    )
                }
                if existing?.payload.digest == projection.digest {
                    throw PersistenceError.unchangedPayload
                }
                if let existing,
                   normalizedCommittedAt < existing.updatedAt {
                    throw PersistenceError.invalidValue(field: "committedAt")
                }

                try Self.ensureGloballyUnusedOutboxIdentifiers(
                    outbox,
                    connection: connection
                )

                let generation: Int64
                if let existing {
                    guard existing.token.generation < Int64.max else {
                        throw PersistenceError.generationOverflow
                    }
                    generation = existing.token.generation + 1
                } else {
                    generation = 1
                }

                try Self.insertCanonicalPayload(
                    projection,
                    createdAtMilliseconds: committedAtMilliseconds,
                    connection: connection
                )
                for draft in outbox {
                    try Self.insertCanonicalPayload(
                        draft.payload,
                        createdAtMilliseconds: committedAtMilliseconds,
                        connection: connection
                    )
                }

                let createdAt: Date
                if let existing {
                    let update = try connection.prepare(
                        "UPDATE workspace_projection SET generation = ?, payload_sha256 = ?, updated_at_ms = ? WHERE singleton_id = 1 AND generation = ? AND payload_sha256 = ?"
                    )
                    try update.bind(generation, at: 1)
                    try update.bind(projection.digest.rawBytes, at: 2)
                    try update.bind(committedAtMilliseconds, at: 3)
                    try update.bind(existing.token.generation, at: 4)
                    try update.bind(existing.token.payloadDigest.rawBytes, at: 5)
                    guard try update.step() == .done,
                          try connection.changes() == 1 else {
                        throw PersistenceError.staleProjection(
                            expected: expected,
                            actual: try Self.readProjection(connection)?.token
                        )
                    }
                    createdAt = existing.createdAt
                } else {
                    let insert = try connection.prepare(
                        "INSERT INTO workspace_projection(singleton_id, generation, payload_sha256, created_at_ms, updated_at_ms) VALUES(1, ?, ?, ?, ?)"
                    )
                    try insert.bind(generation, at: 1)
                    try insert.bind(projection.digest.rawBytes, at: 2)
                    try insert.bind(committedAtMilliseconds, at: 3)
                    try insert.bind(committedAtMilliseconds, at: 4)
                    guard try insert.step() == .done else {
                        throw PersistenceError.transactionInvariantViolation
                    }
                    createdAt = normalizedCommittedAt
                }

                for draft in outbox {
                    let insert = try connection.prepare(
                        "INSERT INTO outbox_intents(intent_id, projection_generation, payload_sha256, created_at_ms, published_at_ms) VALUES(?, ?, ?, ?, NULL)"
                    )
                    try insert.bind(draft.id.uuidString.lowercased(), at: 1)
                    try insert.bind(generation, at: 2)
                    try insert.bind(draft.payload.digest.rawBytes, at: 3)
                    try insert.bind(committedAtMilliseconds, at: 4)
                    guard try insert.step() == .done else {
                        throw PersistenceError.transactionInvariantViolation
                    }
                }

                return try StoredProjection(
                    token: ProjectionToken(
                        generation: generation,
                        payloadDigest: projection.digest
                    ),
                    payload: projection,
                    createdAt: createdAt,
                    updatedAt: normalizedCommittedAt
                )
            }
        }
    }

    public func installMigration(
        projection: CanonicalPayload,
        ledger: MigrationLedgerDraft,
        committedAt: Date
    ) throws -> StoredProjection {
        let committedAtMilliseconds = try Self.milliseconds(committedAt)
        let normalizedCommittedAt = Self.date(milliseconds: committedAtMilliseconds)

        return try withConnection { connection in
            try connection.withImmediateTransaction {
                let existing = try Self.readProjection(connection)
                let existingLedger = try Self.readMigrationLedger(
                    ledger.key,
                    connection: connection
                )
                if let existingLedger {
                    let installedPayload = try Self.readCanonicalPayload(
                        projection.digest,
                        connection: connection
                    )
                    guard existingLedger.matches(ledger),
                          existingLedger.resultPayloadDigest == projection.digest,
                          existingLedger.resultGeneration == 1,
                          installedPayload == projection,
                          let existing,
                          existing.token.generation >= existingLedger.resultGeneration else {
                        throw PersistenceError.transactionInvariantViolation
                    }
                    return existing
                }

                guard existing == nil else {
                    throw PersistenceError.staleProjection(
                        expected: nil,
                        actual: existing?.token
                    )
                }
                guard try connection.scalarInt64(
                    "SELECT COUNT(*) FROM outbox_intents"
                ) == 0,
                try connection.scalarInt64(
                    "SELECT COUNT(*) FROM migration_ledger"
                ) == 0,
                try connection.scalarInt64(
                    "SELECT COUNT(*) FROM canonical_payloads"
                ) == 0,
                try connection.scalarInt64(
                    "SELECT COUNT(*) FROM sync_inbox_operations"
                ) == 0,
                try connection.scalarInt64(
                    "SELECT COUNT(*) FROM sync_applied_operations"
                ) == 0 else {
                    throw PersistenceError.transactionInvariantViolation
                }

                try Self.insertCanonicalPayload(
                    projection,
                    createdAtMilliseconds: committedAtMilliseconds,
                    connection: connection
                )

                let projectionInsert = try connection.prepare(
                    "INSERT INTO workspace_projection(singleton_id, generation, payload_sha256, created_at_ms, updated_at_ms) VALUES(1, 1, ?, ?, ?)"
                )
                try projectionInsert.bind(projection.digest.rawBytes, at: 1)
                try projectionInsert.bind(committedAtMilliseconds, at: 2)
                try projectionInsert.bind(committedAtMilliseconds, at: 3)
                guard try projectionInsert.step() == .done else {
                    throw PersistenceError.transactionInvariantViolation
                }

                let ledgerInsert = try connection.prepare(
                    "INSERT INTO migration_ledger(migration_key, migration_version, source_schema_version, source_revision, source_byte_count, source_sha256, backup_byte_count, backup_sha256, result_payload_sha256, result_generation, completed_at_ms) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)"
                )
                try ledgerInsert.bind(ledger.key, at: 1)
                try ledgerInsert.bind(ledger.migrationVersion, at: 2)
                try ledgerInsert.bind(ledger.sourceSchemaVersion, at: 3)
                try ledgerInsert.bind(ledger.sourceRevision, at: 4)
                try ledgerInsert.bind(ledger.sourceByteCount, at: 5)
                try ledgerInsert.bind(ledger.sourceDigest.rawBytes, at: 6)
                try ledgerInsert.bind(ledger.backupByteCount, at: 7)
                try ledgerInsert.bind(ledger.backupDigest.rawBytes, at: 8)
                try ledgerInsert.bind(projection.digest.rawBytes, at: 9)
                try ledgerInsert.bind(committedAtMilliseconds, at: 10)
                guard try ledgerInsert.step() == .done else {
                    throw PersistenceError.transactionInvariantViolation
                }

                return try StoredProjection(
                    token: ProjectionToken(
                        generation: 1,
                        payloadDigest: projection.digest
                    ),
                    payload: projection,
                    createdAt: normalizedCommittedAt,
                    updatedAt: normalizedCommittedAt
                )
            }
        }
    }

    /// Records a verified immutable remote operation without applying it to
    /// the projection. Replaying the same UUID and digest preserves the first
    /// receipt timestamp; rebinding the UUID to any other digest fails closed.
    public func stageInboxOperation(
        _ operation: ImmutableOperationDraft,
        receivedAt: Date
    ) throws -> PersistedInboxOperation {
        let receivedAtMilliseconds = try Self.milliseconds(receivedAt)
        let normalizedReceivedAt = Self.date(milliseconds: receivedAtMilliseconds)

        return try withConnection { connection in
            try connection.withImmediateTransaction {
                let identity = try Self.readOperationIdentity(
                    operation.id,
                    incomingDigest: operation.payload.digest,
                    connection: connection
                )
                if identity.inInbox {
                    guard let existing = try Self.readInboxOperation(
                        operation.id,
                        connection: connection
                    ), existing.payload == operation.payload else {
                        throw PersistenceError.transactionInvariantViolation
                    }
                    return existing
                }

                try Self.insertCanonicalPayload(
                    operation.payload,
                    createdAtMilliseconds: receivedAtMilliseconds,
                    connection: connection
                )
                try Self.insertInboxOperation(
                    operation,
                    receivedAtMilliseconds: receivedAtMilliseconds,
                    connection: connection
                )
                return try PersistedInboxOperation(
                    id: operation.id,
                    payload: operation.payload,
                    receivedAt: normalizedReceivedAt
                )
            }
        }
    }

    public func pendingInboxOperations(
        limit: Int
    ) throws -> [PersistedInboxOperation] {
        guard (1 ... Self.maximumPendingOutboxLimit).contains(limit) else {
            throw PersistenceError.invalidLimit
        }
        return try withConnection { connection in
            let query = try connection.prepare(
                "SELECT i.operation_id, c.sha256, c.payload_kind, c.schema_version, c.canonical_bytes, c.byte_count, i.received_at_ms FROM sync_inbox_operations i JOIN canonical_payloads c ON c.sha256 = i.payload_sha256 LEFT JOIN sync_applied_operations a ON a.operation_id = i.operation_id WHERE a.operation_id IS NULL ORDER BY i.received_at_ms, i.operation_id LIMIT ?"
            )
            try query.bind(limit, at: 1)
            var result: [PersistedInboxOperation] = []
            result.reserveCapacity(limit)
            while try query.step() == .row {
                result.append(try Self.readInboxOperationRow(query))
            }
            return result
        }
    }

    public func appliedOperation(
        id: UUID
    ) throws -> AppliedOperationRecord? {
        try withConnection { connection in
            try Self.readAppliedOperation(id, connection: connection)
        }
    }

    /// Returns durable applied operations of one canonical kind. This is
    /// intentionally independent from outbox publication state so a newly
    /// selected sync destination can be repaired from the immutable ledger.
    public func appliedOperations(
        kind: String,
        afterAppliedAt: Date? = nil,
        afterID: UUID? = nil,
        limit: Int
    ) throws -> [AppliedOperationRecord] {
        guard PersistenceModelLimits.isSafeKey(
            kind,
            maximumBytes: PersistenceModelLimits.maximumPayloadKindBytes
        ) else {
            throw PersistenceError.invalidValue(field: "kind")
        }
        guard (1 ... Self.maximumPendingOutboxLimit).contains(limit) else {
            throw PersistenceError.invalidLimit
        }
        guard (afterAppliedAt == nil) == (afterID == nil) else {
            throw PersistenceError.invalidValue(field: "appliedOperationCursor")
        }
        let cursorMilliseconds: Int64?
        if let afterAppliedAt {
            cursorMilliseconds = try Self.persistedCursorMilliseconds(afterAppliedAt)
        } else {
            cursorMilliseconds = nil
        }

        return try withConnection { connection in
            let query: SQLiteStatement
            if let cursorMilliseconds, let afterID {
                query = try connection.prepare(
                    "SELECT a.operation_id, c.sha256, c.payload_kind, c.schema_version, c.canonical_bytes, c.byte_count, a.result_generation, a.applied_at_ms FROM sync_applied_operations a JOIN canonical_payloads c ON c.sha256 = a.payload_sha256 WHERE c.payload_kind = ? AND (a.applied_at_ms > ? OR (a.applied_at_ms = ? AND a.operation_id > ?)) ORDER BY a.applied_at_ms, a.operation_id LIMIT ?"
                )
                try query.bind(kind, at: 1)
                try query.bind(cursorMilliseconds, at: 2)
                try query.bind(cursorMilliseconds, at: 3)
                try query.bind(afterID.uuidString.lowercased(), at: 4)
                try query.bind(limit, at: 5)
            } else {
                query = try connection.prepare(
                    "SELECT a.operation_id, c.sha256, c.payload_kind, c.schema_version, c.canonical_bytes, c.byte_count, a.result_generation, a.applied_at_ms FROM sync_applied_operations a JOIN canonical_payloads c ON c.sha256 = a.payload_sha256 WHERE c.payload_kind = ? ORDER BY a.applied_at_ms, a.operation_id LIMIT ?"
                )
                try query.bind(kind, at: 1)
                try query.bind(limit, at: 2)
            }
            var result: [AppliedOperationRecord] = []
            result.reserveCapacity(limit)
            while try query.step() == .row {
                result.append(try Self.readAppliedOperationRow(query))
            }
            return result
        }
    }

    /// Atomically advances (or CAS-verifies) the projection, records the
    /// immutable operation as locally applied, and emits the operation itself.
    /// Projection mirror intents are required and emitted only when the
    /// projection digest advances.
    public func commitLocalOperation(
        projection: CanonicalPayload,
        expected: ProjectionToken?,
        operation: ImmutableOperationDraft,
        mirrorOutbox: [OutboxIntentDraft],
        committedAt: Date
    ) throws -> StoredProjection {
        try Self.validateMirrorOutbox(
            mirrorOutbox,
            excluding: Set([operation.id])
        )
        guard mirrorOutbox.count < PersistenceModelLimits.maximumOperationBatchCount else {
            throw PersistenceError.invalidLimit
        }
        let committedAtMilliseconds = try Self.milliseconds(committedAt)

        return try withConnection { connection in
            try connection.withImmediateTransaction {
                let identity = try Self.readOperationIdentity(
                    operation.id,
                    incomingDigest: operation.payload.digest,
                    connection: connection
                )

                let projectionWrite = try Self.writeOrReuseProjection(
                    projection,
                    expected: expected,
                    committedAtMilliseconds: committedAtMilliseconds,
                    connection: connection
                )
                let stored = projectionWrite.projection
                if projectionWrite.didAdvance {
                    guard mirrorOutbox.isEmpty == false else {
                        throw PersistenceError.emptyOutbox
                    }
                    guard mirrorOutbox.allSatisfy({ $0.payload == projection }) else {
                        throw PersistenceError.invalidValue(field: "mirrorOutboxPayload")
                    }
                    try Self.ensureGloballyUnusedOutboxIdentifiers(
                        mirrorOutbox,
                        connection: connection
                    )
                    for draft in mirrorOutbox {
                        try Self.insertOutboxIntent(
                            draft,
                            generation: stored.token.generation,
                            createdAtMilliseconds: committedAtMilliseconds,
                            connection: connection
                        )
                    }
                }

                try Self.insertCanonicalPayload(
                    operation.payload,
                    createdAtMilliseconds: committedAtMilliseconds,
                    connection: connection
                )
                if identity.isApplied {
                    guard let applied = try Self.readAppliedOperation(
                        operation.id,
                        connection: connection
                    ),
                    applied.payload == operation.payload,
                    applied.resultGeneration <= stored.token.generation else {
                        throw PersistenceError.transactionInvariantViolation
                    }
                }
                if identity.inOutbox == false, identity.isApplied == false {
                    try Self.insertOutboxIntent(
                        OutboxIntentDraft(id: operation.id, payload: operation.payload),
                        generation: stored.token.generation,
                        createdAtMilliseconds: committedAtMilliseconds,
                        connection: connection
                    )
                }
                if identity.isApplied == false {
                    try Self.insertAppliedOperation(
                        operation,
                        resultGeneration: stored.token.generation,
                        appliedAtMilliseconds: committedAtMilliseconds,
                        connection: connection
                    )
                }
                return stored
            }
        }
    }

    public func applyInboxOperation(
        projection: CanonicalPayload,
        expected: ProjectionToken?,
        operation: ImmutableOperationDraft,
        mirrorOutbox: [OutboxIntentDraft],
        receivedAt: Date,
        appliedAt: Date
    ) throws -> StoredProjection {
        try applyInboxOperations(
            projection: projection,
            expected: expected,
            operations: [operation],
            mirrorOutbox: mirrorOutbox,
            receivedAt: receivedAt,
            appliedAt: appliedAt
        )
    }

    /// Applies a remote operation batch after the caller has overlaid every
    /// operation into one final projection. Projection CAS, inbox receipt,
    /// applied ledgers and any required mirror intents commit or roll back
    /// together. An unchanged projection repairs ledgers at the existing
    /// generation without emitting a redundant mirror.
    public func applyInboxOperations(
        projection: CanonicalPayload,
        expected: ProjectionToken?,
        operations: [ImmutableOperationDraft],
        mirrorOutbox: [OutboxIntentDraft],
        receivedAt: Date,
        appliedAt: Date
    ) throws -> StoredProjection {
        let normalizedOperations = try Self.normalizedOperations(operations)
        try Self.validateMirrorOutbox(
            mirrorOutbox,
            excluding: Set(normalizedOperations.map(\.id))
        )
        guard normalizedOperations.count + mirrorOutbox.count
            <= PersistenceModelLimits.maximumOperationBatchCount else {
            throw PersistenceError.invalidLimit
        }
        let receivedAtMilliseconds = try Self.milliseconds(receivedAt)
        let appliedAtMilliseconds = try Self.milliseconds(appliedAt)
        let normalizedAppliedAt = Self.date(milliseconds: appliedAtMilliseconds)
        guard appliedAtMilliseconds >= receivedAtMilliseconds else {
            throw PersistenceError.invalidValue(field: "appliedAt")
        }

        return try withConnection { connection in
            try connection.withImmediateTransaction {
                var identities: [UUID: OperationIdentity] = [:]
                identities.reserveCapacity(normalizedOperations.count)
                for operation in normalizedOperations {
                    let identity = try Self.readOperationIdentity(
                        operation.id,
                        incomingDigest: operation.payload.digest,
                        connection: connection
                    )
                    if identity.inInbox {
                        guard let existingInbox = try Self.readInboxOperation(
                            operation.id,
                            connection: connection
                        ) else {
                            throw PersistenceError.transactionInvariantViolation
                        }
                        guard normalizedAppliedAt >= existingInbox.receivedAt else {
                            throw PersistenceError.invalidValue(field: "appliedAt")
                        }
                    }
                    identities[operation.id] = identity
                }

                let projectionWrite = try Self.writeOrReuseProjection(
                    projection,
                    expected: expected,
                    committedAtMilliseconds: appliedAtMilliseconds,
                    connection: connection
                )
                let stored = projectionWrite.projection
                if projectionWrite.didAdvance {
                    guard mirrorOutbox.isEmpty == false else {
                        throw PersistenceError.emptyOutbox
                    }
                    guard mirrorOutbox.allSatisfy({ $0.payload == projection }) else {
                        throw PersistenceError.invalidValue(field: "mirrorOutboxPayload")
                    }
                    try Self.ensureGloballyUnusedOutboxIdentifiers(
                        mirrorOutbox,
                        connection: connection
                    )
                    for draft in mirrorOutbox {
                        try Self.insertOutboxIntent(
                            draft,
                            generation: stored.token.generation,
                            createdAtMilliseconds: appliedAtMilliseconds,
                            connection: connection
                        )
                    }
                }

                for operation in normalizedOperations {
                    guard let identity = identities[operation.id] else {
                        throw PersistenceError.transactionInvariantViolation
                    }
                    try Self.insertCanonicalPayload(
                        operation.payload,
                        createdAtMilliseconds: receivedAtMilliseconds,
                        connection: connection
                    )
                    if identity.isApplied {
                        guard let applied = try Self.readAppliedOperation(
                            operation.id,
                            connection: connection
                        ),
                        applied.payload == operation.payload,
                        applied.resultGeneration <= stored.token.generation else {
                            throw PersistenceError.transactionInvariantViolation
                        }
                    }
                    if identity.inInbox == false {
                        try Self.insertInboxOperation(
                            operation,
                            receivedAtMilliseconds: receivedAtMilliseconds,
                            connection: connection
                        )
                    }
                    if identity.isApplied == false {
                        try Self.insertAppliedOperation(
                            operation,
                            resultGeneration: stored.token.generation,
                            appliedAtMilliseconds: appliedAtMilliseconds,
                            connection: connection
                        )
                    }
                }
                return stored
            }
        }
    }

    public func pendingOutbox(limit: Int) throws -> [PersistedOutboxIntent] {
        guard (1 ... Self.maximumPendingOutboxLimit).contains(limit) else {
            throw PersistenceError.invalidLimit
        }

        return try withConnection { connection in
            let query = try connection.prepare(
                "SELECT o.intent_id, o.projection_generation, c.sha256, c.payload_kind, c.schema_version, c.canonical_bytes, c.byte_count, o.created_at_ms, o.published_at_ms FROM outbox_intents o JOIN canonical_payloads c ON c.sha256 = o.payload_sha256 WHERE o.published_at_ms IS NULL ORDER BY o.created_at_ms, o.intent_id LIMIT ?"
            )
            try query.bind(limit, at: 1)

            var result: [PersistedOutboxIntent] = []
            result.reserveCapacity(limit)
            while try query.step() == .row {
                let identifier = try query.requiredText(at: 0)
                guard let id = UUID(uuidString: identifier),
                      id.uuidString.lowercased() == identifier else {
                    throw PersistenceError.transactionInvariantViolation
                }
                let payload = try Self.readPayload(
                    digestData: query.requiredData(at: 2),
                    kind: query.requiredText(at: 3),
                    schemaVersion: query.requiredInt64(at: 4),
                    bytes: query.requiredData(at: 5),
                    byteCount: query.requiredInt64(at: 6)
                )
                let publishedAtMilliseconds = try query.optionalInt64(at: 8)
                result.append(try PersistedOutboxIntent(
                    id: id,
                    projectionGeneration: query.requiredInt64(at: 1),
                    payload: payload,
                    createdAt: Self.date(milliseconds: query.requiredInt64(at: 7)),
                    publishedAt: publishedAtMilliseconds.map {
                        Self.date(milliseconds: $0)
                    }
                ))
            }
            return result
        }
    }

    /// Filters by canonical payload kind before applying the SQL limit so a
    /// large snapshot queue cannot starve immutable operation publication.
    public func pendingOutbox(
        kind: String,
        limit: Int
    ) throws -> [PersistedOutboxIntent] {
        guard PersistenceModelLimits.isSafeKey(
            kind,
            maximumBytes: PersistenceModelLimits.maximumPayloadKindBytes
        ) else {
            throw PersistenceError.invalidValue(field: "kind")
        }
        guard (1 ... Self.maximumPendingOutboxLimit).contains(limit) else {
            throw PersistenceError.invalidLimit
        }

        return try withConnection { connection in
            let query = try connection.prepare(
                "SELECT o.intent_id, o.projection_generation, c.sha256, c.payload_kind, c.schema_version, c.canonical_bytes, c.byte_count, o.created_at_ms, o.published_at_ms FROM outbox_intents o JOIN canonical_payloads c ON c.sha256 = o.payload_sha256 WHERE o.published_at_ms IS NULL AND c.payload_kind = ? ORDER BY o.created_at_ms, o.intent_id LIMIT ?"
            )
            try query.bind(kind, at: 1)
            try query.bind(limit, at: 2)

            var result: [PersistedOutboxIntent] = []
            result.reserveCapacity(limit)
            while try query.step() == .row {
                let identifier = try query.requiredText(at: 0)
                guard let id = UUID(uuidString: identifier),
                      id.uuidString.lowercased() == identifier else {
                    throw PersistenceError.transactionInvariantViolation
                }
                let payload = try Self.readPayload(
                    digestData: query.requiredData(at: 2),
                    kind: query.requiredText(at: 3),
                    schemaVersion: query.requiredInt64(at: 4),
                    bytes: query.requiredData(at: 5),
                    byteCount: query.requiredInt64(at: 6)
                )
                let publishedAtMilliseconds = try query.optionalInt64(at: 8)
                result.append(try PersistedOutboxIntent(
                    id: id,
                    projectionGeneration: query.requiredInt64(at: 1),
                    payload: payload,
                    createdAt: Self.date(milliseconds: query.requiredInt64(at: 7)),
                    publishedAt: publishedAtMilliseconds.map {
                        Self.date(milliseconds: $0)
                    }
                ))
            }
            return result
        }
    }

    public func markOutboxPublished(
        id: UUID,
        expectedDigest: ContentDigest,
        publishedAt: Date
    ) throws {
        let publishedAtMilliseconds = try Self.milliseconds(publishedAt)

        try withConnection { connection in
            try connection.withImmediateTransaction {
                let identifier = id.uuidString.lowercased()
                let query = try connection.prepare(
                    "SELECT payload_sha256, created_at_ms, published_at_ms FROM outbox_intents WHERE intent_id = ?"
                )
                try query.bind(identifier, at: 1)
                guard try query.step() == .row else {
                    throw PersistenceError.notFound
                }
                let actualDigest = try ContentDigest(rawBytes: query.requiredData(at: 0))
                let createdAtMilliseconds = try query.requiredInt64(at: 1)
                let existingPublishedAt = try query.optionalInt64(at: 2)
                guard try query.step() == .done else {
                    throw PersistenceError.transactionInvariantViolation
                }
                guard actualDigest == expectedDigest else {
                    throw PersistenceError.digestMismatch(
                        expected: expectedDigest,
                        actual: actualDigest
                    )
                }
                if existingPublishedAt != nil { return }
                guard publishedAtMilliseconds >= createdAtMilliseconds else {
                    throw PersistenceError.invalidValue(field: "publishedAt")
                }

                let update = try connection.prepare(
                    "UPDATE outbox_intents SET published_at_ms = ? WHERE intent_id = ? AND payload_sha256 = ? AND published_at_ms IS NULL"
                )
                try update.bind(publishedAtMilliseconds, at: 1)
                try update.bind(identifier, at: 2)
                try update.bind(expectedDigest.rawBytes, at: 3)
                guard try update.step() == .done,
                      try connection.changes() == 1 else {
                    throw PersistenceError.transactionInvariantViolation
                }
            }
        }
    }

    /// Removes acknowledged outbox rows through a known published projection
    /// and then garbage-collects canonical payloads that are no longer
    /// referenced by the projection, outbox, or migration ledger.
    public func prunePublishedOutbox(
        throughGeneration: Int64
    ) throws -> Int {
        guard throughGeneration > 0 else {
            throw PersistenceError.invalidValue(field: "throughGeneration")
        }
        return try withConnection { connection in
            try connection.withImmediateTransaction {
                let countQuery = try connection.prepare(
                    "SELECT COUNT(*) FROM outbox_intents WHERE published_at_ms IS NOT NULL AND projection_generation <= ?"
                )
                try countQuery.bind(throughGeneration, at: 1)
                guard try countQuery.step() == .row else {
                    throw PersistenceError.transactionInvariantViolation
                }
                let rawCount = try countQuery.requiredInt64(at: 0)
                guard try countQuery.step() == .done,
                      rawCount >= 0,
                      rawCount <= Int64(Int32.max) else {
                    throw PersistenceError.transactionInvariantViolation
                }

                let deleteOutbox = try connection.prepare(
                    "DELETE FROM outbox_intents WHERE published_at_ms IS NOT NULL AND projection_generation <= ?"
                )
                try deleteOutbox.bind(throughGeneration, at: 1)
                guard try deleteOutbox.step() == .done,
                      try connection.changes() == Int32(rawCount) else {
                    throw PersistenceError.transactionInvariantViolation
                }

                try connection.execute(
                    "DELETE FROM canonical_payloads WHERE NOT EXISTS (SELECT 1 FROM workspace_projection p WHERE p.payload_sha256 = canonical_payloads.sha256) AND NOT EXISTS (SELECT 1 FROM outbox_intents o WHERE o.payload_sha256 = canonical_payloads.sha256) AND NOT EXISTS (SELECT 1 FROM migration_ledger m WHERE m.result_payload_sha256 = canonical_payloads.sha256) AND NOT EXISTS (SELECT 1 FROM sync_inbox_operations i WHERE i.payload_sha256 = canonical_payloads.sha256) AND NOT EXISTS (SELECT 1 FROM sync_applied_operations a WHERE a.payload_sha256 = canonical_payloads.sha256)"
                )
                return Int(rawCount)
            }
        }
    }

    private static func normalizedOperations(
        _ operations: [ImmutableOperationDraft]
    ) throws -> [ImmutableOperationDraft] {
        guard operations.isEmpty == false else {
            throw PersistenceError.emptyOperations
        }
        guard operations.count <= PersistenceModelLimits.maximumOperationBatchCount else {
            throw PersistenceError.invalidLimit
        }

        var byID: [UUID: ImmutableOperationDraft] = [:]
        var result: [ImmutableOperationDraft] = []
        result.reserveCapacity(operations.count)
        for operation in operations {
            if let existing = byID[operation.id] {
                guard existing.payload.digest == operation.payload.digest else {
                    throw PersistenceError.operationIdentityCollision(
                        id: operation.id,
                        expected: existing.payload.digest,
                        actual: operation.payload.digest
                    )
                }
                guard existing.payload == operation.payload else {
                    throw PersistenceError.transactionInvariantViolation
                }
                continue
            }
            byID[operation.id] = operation
            result.append(operation)
        }
        return result
    }

    private static func validateMirrorOutbox(
        _ drafts: [OutboxIntentDraft],
        excluding operationIDs: Set<UUID>
    ) throws {
        guard drafts.count <= PersistenceModelLimits.maximumOperationBatchCount else {
            throw PersistenceError.invalidLimit
        }
        let IDs = drafts.map(\.id)
        guard Set(IDs).count == IDs.count,
              Set(IDs).isDisjoint(with: operationIDs) else {
            throw PersistenceError.duplicateOutboxIntent
        }
    }

    /// Generic projection/mirror intents must never reuse an identifier from
    /// any immutable-operation ledger. Operation insertion has a separate
    /// exact-digest idempotency path; mirrors have no such exception.
    private static func ensureGloballyUnusedOutboxIdentifiers(
        _ drafts: [OutboxIntentDraft],
        connection: SQLiteConnection
    ) throws {
        for draft in drafts {
            let identity = try readOperationIdentity(
                draft.id,
                incomingDigest: draft.payload.digest,
                connection: connection
            )
            if identity.inInbox || identity.isApplied || identity.inOutbox {
                throw PersistenceError.duplicateOutboxIntent
            }
        }
    }

    private static func writeOrReuseProjection(
        _ projection: CanonicalPayload,
        expected: ProjectionToken?,
        committedAtMilliseconds: Int64,
        connection: SQLiteConnection
    ) throws -> ProjectionWriteResult {
        let existing = try readProjection(connection)
        guard existing?.token == expected else {
            throw PersistenceError.staleProjection(
                expected: expected,
                actual: existing?.token
            )
        }
        if let existing, existing.payload.digest == projection.digest {
            guard existing.payload == projection else {
                throw PersistenceError.transactionInvariantViolation
            }
            return ProjectionWriteResult(
                projection: existing,
                didAdvance: false
            )
        }
        return ProjectionWriteResult(
            projection: try writeProjection(
                projection,
                expected: expected,
                committedAtMilliseconds: committedAtMilliseconds,
                connection: connection
            ),
            didAdvance: true
        )
    }

    private static func writeProjection(
        _ projection: CanonicalPayload,
        expected: ProjectionToken?,
        committedAtMilliseconds: Int64,
        connection: SQLiteConnection
    ) throws -> StoredProjection {
        let normalizedCommittedAt = date(milliseconds: committedAtMilliseconds)
        let existing = try readProjection(connection)
        guard existing?.token == expected else {
            throw PersistenceError.staleProjection(
                expected: expected,
                actual: existing?.token
            )
        }
        if existing?.payload.digest == projection.digest {
            throw PersistenceError.unchangedPayload
        }
        if let existing, normalizedCommittedAt < existing.updatedAt {
            throw PersistenceError.invalidValue(field: "committedAt")
        }

        let generation: Int64
        if let existing {
            guard existing.token.generation < Int64.max else {
                throw PersistenceError.generationOverflow
            }
            generation = existing.token.generation + 1
        } else {
            generation = 1
        }
        try insertCanonicalPayload(
            projection,
            createdAtMilliseconds: committedAtMilliseconds,
            connection: connection
        )

        let createdAt: Date
        if let existing {
            let update = try connection.prepare(
                "UPDATE workspace_projection SET generation = ?, payload_sha256 = ?, updated_at_ms = ? WHERE singleton_id = 1 AND generation = ? AND payload_sha256 = ?"
            )
            try update.bind(generation, at: 1)
            try update.bind(projection.digest.rawBytes, at: 2)
            try update.bind(committedAtMilliseconds, at: 3)
            try update.bind(existing.token.generation, at: 4)
            try update.bind(existing.token.payloadDigest.rawBytes, at: 5)
            guard try update.step() == .done,
                  try connection.changes() == 1 else {
                throw PersistenceError.staleProjection(
                    expected: expected,
                    actual: try readProjection(connection)?.token
                )
            }
            createdAt = existing.createdAt
        } else {
            let insert = try connection.prepare(
                "INSERT INTO workspace_projection(singleton_id, generation, payload_sha256, created_at_ms, updated_at_ms) VALUES(1, ?, ?, ?, ?)"
            )
            try insert.bind(generation, at: 1)
            try insert.bind(projection.digest.rawBytes, at: 2)
            try insert.bind(committedAtMilliseconds, at: 3)
            try insert.bind(committedAtMilliseconds, at: 4)
            guard try insert.step() == .done else {
                throw PersistenceError.transactionInvariantViolation
            }
            createdAt = normalizedCommittedAt
        }

        return try StoredProjection(
            token: ProjectionToken(
                generation: generation,
                payloadDigest: projection.digest
            ),
            payload: projection,
            createdAt: createdAt,
            updatedAt: normalizedCommittedAt
        )
    }

    private static func insertOutboxIntent(
        _ draft: OutboxIntentDraft,
        generation: Int64,
        createdAtMilliseconds: Int64,
        connection: SQLiteConnection
    ) throws {
        try insertCanonicalPayload(
            draft.payload,
            createdAtMilliseconds: createdAtMilliseconds,
            connection: connection
        )
        let insert = try connection.prepare(
            "INSERT INTO outbox_intents(intent_id, projection_generation, payload_sha256, created_at_ms, published_at_ms) VALUES(?, ?, ?, ?, NULL)"
        )
        try insert.bind(draft.id.uuidString.lowercased(), at: 1)
        try insert.bind(generation, at: 2)
        try insert.bind(draft.payload.digest.rawBytes, at: 3)
        try insert.bind(createdAtMilliseconds, at: 4)
        guard try insert.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
    }

    private static func readOperationIdentity(
        _ id: UUID,
        incomingDigest: ContentDigest,
        connection: SQLiteConnection
    ) throws -> OperationIdentity {
        let identifier = id.uuidString.lowercased()
        let query = try connection.prepare(
            "SELECT ledger, payload_sha256 FROM (SELECT 'inbox' AS ledger, payload_sha256 FROM sync_inbox_operations WHERE operation_id = ? UNION ALL SELECT 'applied' AS ledger, payload_sha256 FROM sync_applied_operations WHERE operation_id = ? UNION ALL SELECT 'outbox' AS ledger, payload_sha256 FROM outbox_intents WHERE intent_id = ?) ORDER BY ledger"
        )
        try query.bind(identifier, at: 1)
        try query.bind(identifier, at: 2)
        try query.bind(identifier, at: 3)
        var inInbox = false
        var isApplied = false
        var inOutbox = false
        while try query.step() == .row {
            let ledger = try query.requiredText(at: 0)
            let existingDigest = try ContentDigest(rawBytes: query.requiredData(at: 1))
            guard existingDigest == incomingDigest else {
                throw PersistenceError.operationIdentityCollision(
                    id: id,
                    expected: existingDigest,
                    actual: incomingDigest
                )
            }
            switch ledger {
            case "inbox":
                guard inInbox == false else {
                    throw PersistenceError.transactionInvariantViolation
                }
                inInbox = true
            case "applied":
                guard isApplied == false else {
                    throw PersistenceError.transactionInvariantViolation
                }
                isApplied = true
            case "outbox":
                guard inOutbox == false else {
                    throw PersistenceError.transactionInvariantViolation
                }
                inOutbox = true
            default:
                throw PersistenceError.transactionInvariantViolation
            }
        }
        return OperationIdentity(
            inInbox: inInbox,
            isApplied: isApplied,
            inOutbox: inOutbox
        )
    }

    private static func insertInboxOperation(
        _ operation: ImmutableOperationDraft,
        receivedAtMilliseconds: Int64,
        connection: SQLiteConnection
    ) throws {
        let insert = try connection.prepare(
            "INSERT INTO sync_inbox_operations(operation_id, payload_sha256, received_at_ms) VALUES(?, ?, ?)"
        )
        try insert.bind(operation.id.uuidString.lowercased(), at: 1)
        try insert.bind(operation.payload.digest.rawBytes, at: 2)
        try insert.bind(receivedAtMilliseconds, at: 3)
        guard try insert.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
    }

    private static func insertAppliedOperation(
        _ operation: ImmutableOperationDraft,
        resultGeneration: Int64,
        appliedAtMilliseconds: Int64,
        connection: SQLiteConnection
    ) throws {
        let insert = try connection.prepare(
            "INSERT INTO sync_applied_operations(operation_id, payload_sha256, result_generation, applied_at_ms) VALUES(?, ?, ?, ?)"
        )
        try insert.bind(operation.id.uuidString.lowercased(), at: 1)
        try insert.bind(operation.payload.digest.rawBytes, at: 2)
        try insert.bind(resultGeneration, at: 3)
        try insert.bind(appliedAtMilliseconds, at: 4)
        guard try insert.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
    }

    private static func readInboxOperation(
        _ id: UUID,
        connection: SQLiteConnection
    ) throws -> PersistedInboxOperation? {
        let query = try connection.prepare(
            "SELECT i.operation_id, c.sha256, c.payload_kind, c.schema_version, c.canonical_bytes, c.byte_count, i.received_at_ms FROM sync_inbox_operations i JOIN canonical_payloads c ON c.sha256 = i.payload_sha256 WHERE i.operation_id = ?"
        )
        try query.bind(id.uuidString.lowercased(), at: 1)
        guard try query.step() == .row else { return nil }
        let result = try readInboxOperationRow(query)
        guard result.id == id,
              try query.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
        return result
    }

    private static func readInboxOperationRow(
        _ query: SQLiteStatement
    ) throws -> PersistedInboxOperation {
        let identifier = try query.requiredText(at: 0)
        guard let id = UUID(uuidString: identifier),
              id.uuidString.lowercased() == identifier else {
            throw PersistenceError.transactionInvariantViolation
        }
        let payload = try readPayload(
            digestData: query.requiredData(at: 1),
            kind: query.requiredText(at: 2),
            schemaVersion: query.requiredInt64(at: 3),
            bytes: query.requiredData(at: 4),
            byteCount: query.requiredInt64(at: 5)
        )
        return try PersistedInboxOperation(
            id: id,
            payload: payload,
            receivedAt: date(milliseconds: query.requiredInt64(at: 6))
        )
    }

    private static func readAppliedOperation(
        _ id: UUID,
        connection: SQLiteConnection
    ) throws -> AppliedOperationRecord? {
        let query = try connection.prepare(
            "SELECT a.operation_id, c.sha256, c.payload_kind, c.schema_version, c.canonical_bytes, c.byte_count, a.result_generation, a.applied_at_ms FROM sync_applied_operations a JOIN canonical_payloads c ON c.sha256 = a.payload_sha256 WHERE a.operation_id = ?"
        )
        try query.bind(id.uuidString.lowercased(), at: 1)
        guard try query.step() == .row else { return nil }
        let result = try readAppliedOperationRow(query)
        guard result.id == id,
              try query.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
        return result
    }

    private static func readAppliedOperationRow(
        _ query: SQLiteStatement
    ) throws -> AppliedOperationRecord {
        let identifier = try query.requiredText(at: 0)
        guard let storedID = UUID(uuidString: identifier),
              storedID.uuidString.lowercased() == identifier else {
            throw PersistenceError.transactionInvariantViolation
        }
        let payload = try readPayload(
            digestData: query.requiredData(at: 1),
            kind: query.requiredText(at: 2),
            schemaVersion: query.requiredInt64(at: 3),
            bytes: query.requiredData(at: 4),
            byteCount: query.requiredInt64(at: 5)
        )
        return try AppliedOperationRecord(
            id: storedID,
            payload: payload,
            resultGeneration: query.requiredInt64(at: 6),
            appliedAt: date(milliseconds: query.requiredInt64(at: 7))
        )
    }

    public func close() throws {
        guard let connection else { return }
        do {
            try connection.close()
            self.connection = nil
        } catch {
            throw Self.publicError(error)
        }
    }

    private func withConnection<Value>(
        _ body: (SQLiteConnection) throws -> Value
    ) throws -> Value {
        guard let connection else { throw PersistenceError.closed }
        do {
            return try body(connection)
        } catch {
            throw Self.publicError(error)
        }
    }

    private static func readProjection(
        _ connection: SQLiteConnection
    ) throws -> StoredProjection? {
        let query = try connection.prepare(
            "SELECT p.generation, c.sha256, c.payload_kind, c.schema_version, c.canonical_bytes, c.byte_count, p.created_at_ms, p.updated_at_ms FROM workspace_projection p JOIN canonical_payloads c ON c.sha256 = p.payload_sha256 WHERE p.singleton_id = 1"
        )
        guard try query.step() == .row else { return nil }

        let payload = try readPayload(
            digestData: query.requiredData(at: 1),
            kind: query.requiredText(at: 2),
            schemaVersion: query.requiredInt64(at: 3),
            bytes: query.requiredData(at: 4),
            byteCount: query.requiredInt64(at: 5)
        )
        let stored = try StoredProjection(
            token: ProjectionToken(
                generation: query.requiredInt64(at: 0),
                payloadDigest: payload.digest
            ),
            payload: payload,
            createdAt: date(milliseconds: query.requiredInt64(at: 6)),
            updatedAt: date(milliseconds: query.requiredInt64(at: 7))
        )
        guard try query.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
        return stored
    }

    private static func readPayload(
        digestData: Data,
        kind: String,
        schemaVersion: Int64,
        bytes: Data,
        byteCount: Int64
    ) throws -> CanonicalPayload {
        guard byteCount == Int64(bytes.count),
              let schemaVersion = Int(exactly: schemaVersion) else {
            throw PersistenceError.transactionInvariantViolation
        }
        let digest = try ContentDigest(rawBytes: digestData)
        return try CanonicalPayload(
            kind: kind,
            schemaVersion: schemaVersion,
            bytes: bytes,
            validating: digest
        )
    }

    private static func insertCanonicalPayload(
        _ payload: CanonicalPayload,
        createdAtMilliseconds: Int64,
        connection: SQLiteConnection
    ) throws {
        let insert = try connection.prepare(
            "INSERT OR IGNORE INTO canonical_payloads(sha256, payload_kind, schema_version, canonical_bytes, byte_count, created_at_ms) VALUES(?, ?, ?, ?, ?, ?)"
        )
        try insert.bind(payload.digest.rawBytes, at: 1)
        try insert.bind(payload.kind, at: 2)
        try insert.bind(payload.schemaVersion, at: 3)
        try insert.bind(payload.bytes, at: 4)
        try insert.bind(payload.bytes.count, at: 5)
        try insert.bind(createdAtMilliseconds, at: 6)
        guard try insert.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }

        let verify = try connection.prepare(
            "SELECT payload_kind, schema_version, canonical_bytes, byte_count FROM canonical_payloads WHERE sha256 = ?"
        )
        try verify.bind(payload.digest.rawBytes, at: 1)
        guard try verify.step() == .row,
              try verify.requiredText(at: 0) == payload.kind,
              try verify.requiredInt64(at: 1) == Int64(payload.schemaVersion),
              try verify.requiredData(at: 2) == payload.bytes,
              try verify.requiredInt64(at: 3) == Int64(payload.bytes.count),
              try verify.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
    }

    private static func outboxIntentExists(
        _ id: UUID,
        connection: SQLiteConnection
    ) throws -> Bool {
        let query = try connection.prepare(
            "SELECT EXISTS(SELECT 1 FROM outbox_intents WHERE intent_id = ?)"
        )
        try query.bind(id.uuidString.lowercased(), at: 1)
        guard try query.step() == .row else {
            throw PersistenceError.transactionInvariantViolation
        }
        let exists = try query.requiredInt64(at: 0) == 1
        guard try query.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
        return exists
    }

    private static func readMigrationLedger(
        _ key: String,
        connection: SQLiteConnection
    ) throws -> MigrationLedgerRecord? {
        let query = try connection.prepare(
            "SELECT migration_version, source_schema_version, source_revision, source_byte_count, source_sha256, backup_byte_count, backup_sha256, result_payload_sha256, result_generation, completed_at_ms FROM migration_ledger WHERE migration_key = ?"
        )
        try query.bind(key, at: 1)
        guard try query.step() == .row else { return nil }
        let rawMigrationVersion = try query.requiredInt64(at: 0)
        let rawSourceSchemaVersion = try query.requiredInt64(at: 1)
        guard let migrationVersion = Int(exactly: rawMigrationVersion),
              let sourceSchemaVersion = Int(exactly: rawSourceSchemaVersion) else {
            throw PersistenceError.transactionInvariantViolation
        }
        let result = try MigrationLedgerRecord(
            key: key,
            migrationVersion: migrationVersion,
            sourceSchemaVersion: sourceSchemaVersion,
            sourceRevision: query.requiredInt64(at: 2),
            sourceByteCount: query.requiredInt64(at: 3),
            sourceDigest: ContentDigest(rawBytes: query.requiredData(at: 4)),
            backupByteCount: query.requiredInt64(at: 5),
            backupDigest: ContentDigest(rawBytes: query.requiredData(at: 6)),
            resultPayloadDigest: ContentDigest(rawBytes: query.requiredData(at: 7)),
            resultGeneration: query.requiredInt64(at: 8),
            completedAt: date(milliseconds: query.requiredInt64(at: 9))
        )
        guard try query.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
        return result
    }

    private static func readCanonicalPayload(
        _ digest: ContentDigest,
        connection: SQLiteConnection
    ) throws -> CanonicalPayload? {
        let query = try connection.prepare(
            "SELECT sha256, payload_kind, schema_version, canonical_bytes, byte_count FROM canonical_payloads WHERE sha256 = ?"
        )
        try query.bind(digest.rawBytes, at: 1)
        guard try query.step() == .row else { return nil }
        let payload = try readPayload(
            digestData: query.requiredData(at: 0),
            kind: query.requiredText(at: 1),
            schemaVersion: query.requiredInt64(at: 2),
            bytes: query.requiredData(at: 3),
            byteCount: query.requiredInt64(at: 4)
        )
        guard try query.step() == .done else {
            throw PersistenceError.transactionInvariantViolation
        }
        return payload
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else {
            throw PersistenceError.invalidValue(field: "date")
        }
        return Int64(value.rounded(.down))
    }

    /// Dates returned from SQLite originate from an exact integer millisecond,
    /// but `Date` stores seconds as binary floating point. Converting that value
    /// back with floor can move the keyset cursor one millisecond backwards.
    private static func persistedCursorMilliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else {
            throw PersistenceError.invalidValue(field: "date")
        }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        guard rounded < Double(Int64.max) else {
            throw PersistenceError.invalidValue(field: "date")
        }
        return Int64(rounded)
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func publicError(_ error: Error) -> PersistenceError {
        if let persistenceError = error as? PersistenceError {
            return persistenceError
        }
        guard let sqliteError = error as? SQLiteInternalError else {
            return .transactionInvariantViolation
        }
        switch sqliteError {
        case .closed:
            return .closed
        case .commitOutcomeUnknown(let code):
            return .commitOutcomeUnknown(code: code)
        default:
            return .sqliteFailure(code: sqliteError.resultCode)
        }
    }
}
