import Foundation
import NextStepDomain
import NextStepPersistence

/// SQLite is the authoritative store for the guided NextStep workspace.
///
/// The legacy JSON file remains a non-authoritative compatibility mirror. A
/// mirror write is represented by an outbox row in the same transaction as the
/// projection, so a crash can be repaired without treating a mirror failure as
/// a failed canonical save.
actor NextStepBetaSQLiteArchiveRepository {
    static let databaseFilename = "nextstep-beta-v1.sqlite3"
    static let migrationBackupDirectoryName = "MigrationBackups"
    static let migrationBackupFilename = "nextstep-beta-v1.backup.json"

    private static let projectionKind = "nextstep.beta.archive"
    private static let legacyMigrationKey = "nextstep.beta.json.v1"
    private static let legacyMigrationVersion = 1
    private static let maximumArchiveBytes = 64 * 1_024 * 1_024

    private let rootURL: URL
    private let fileManager: FileManager
    private var persistenceStore: NextStepPersistenceStore?
    private var didInitializeInThisProcess = false

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = FileManager()
    }

    func loadOrMigrate() async throws -> NextStepBetaArchive? {
        do {
            try ensureOwnedRoot()
            let store = try database()
            if let stored = try await store.loadProjection() {
                try await reconcileMigrationBackupIfNeeded(
                    stored: stored,
                    using: store
                )
                let archive = try decodeProjection(stored.payload)
                didInitializeInThisProcess = true
                await repairCompatibilityMirror(using: store)
                return archive
            }

            guard fileManager.fileExists(atPath: legacyArchiveURL.path) else {
                didInitializeInThisProcess = true
                return nil
            }

            let sourceBytes = try readBoundedRegularFile(at: legacyArchiveURL)
            let sourceSchemaVersion = try legacySchemaVersion(in: sourceBytes)
            let archive = try decodeArchive(sourceBytes)
            let canonicalBytes = try encodeArchive(archive)
            let projection = try CanonicalPayload(
                kind: Self.projectionKind,
                schemaVersion: archive.schemaVersion,
                bytes: canonicalBytes
            )
            let backupBytes = try installOrVerifyMigrationBackup(sourceBytes)
            let sourceDigest = ContentDigest(hashing: sourceBytes)
            let backupDigest = ContentDigest(hashing: backupBytes)
            let ledger = try MigrationLedgerDraft(
                key: Self.legacyMigrationKey,
                migrationVersion: Self.legacyMigrationVersion,
                sourceSchemaVersion: sourceSchemaVersion,
                sourceRevision: archive.workspace.revision,
                sourceByteCount: Int64(sourceBytes.count),
                sourceDigest: sourceDigest,
                backupByteCount: Int64(backupBytes.count),
                backupDigest: backupDigest
            )
            let installed = try await store.installMigration(
                projection: projection,
                ledger: ledger,
                committedAt: Date()
            )
            let installedArchive = try decodeProjection(installed.payload)
            didInitializeInThisProcess = true
            return installedArchive
        } catch let error as NextStepBetaArchiveError {
            throw error
        } catch let error as NextStepBetaStoreError {
            throw error
        } catch {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    func save(
        _ archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive?
    ) async throws {
        do {
            try archive.validate()
            try ensureOwnedRoot()
            let store = try database()
            let canonicalBytes = try encodeArchive(archive)
            let projection = try CanonicalPayload(
                kind: Self.projectionKind,
                schemaVersion: archive.schemaVersion,
                bytes: canonicalBytes
            )

            // Establish or migrate before checking the caller-carried parent.
            // The expected archive, not repository timing, defines CAS ancestry.
            if didInitializeInThisProcess == false {
                _ = try await loadOrMigrate()
            }
            let existing = try await store.loadProjection()
            if existing?.payload.digest == projection.digest {
                await repairCompatibilityMirror(using: store)
                return
            }

            let expectedDigest = try expectedArchive.map {
                ContentDigest(hashing: try encodeArchive($0))
            }
            guard existing?.payload.digest == expectedDigest else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }

            let committedAt = max(Date(), existing?.updatedAt ?? Date())
            let committed = try await store.commitLocalMutation(
                projection: projection,
                expected: existing?.token,
                // The outbox references the same canonical archive bytes. It is
                // a JSON-mirror publication intent, not an entity-sync operation.
                outbox: [OutboxIntentDraft(payload: projection)],
                committedAt: committedAt
            )
            _ = committed

            // Canonical SQLite commit is already durable. Mirror publication is
            // deliberately best-effort and remains recoverable through outbox.
            await repairCompatibilityMirror(using: store)
        } catch {
            if let error = error as? NextStepBetaArchiveError {
                throw error
            }
            if let error = error as? NextStepBetaStoreError {
                throw error
            }
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    func saveCompletionOperation(
        _ archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive,
        operation: NextStepBetaGuidedActionCompletionOperation
    ) async throws {
        do {
            try archive.validate()
            try expectedArchive.validate()
            let replay = try NextStepBetaCompletionOperationReducer().replay(
                operation,
                in: expectedArchive
            )
            guard replay.outcome == .applied else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }

            try ensureOwnedRoot()
            let store = try database()
            if didInitializeInThisProcess == false {
                _ = try await loadOrMigrate()
            }

            let canonicalBytes = try encodeArchive(archive)
            guard try encodeArchive(replay.archive) == canonicalBytes else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }
            let projection = try CanonicalPayload(
                kind: Self.projectionKind,
                schemaVersion: archive.schemaVersion,
                bytes: canonicalBytes
            )
            let operationPayload = try completionPayload(for: operation)
            let draft = ImmutableOperationDraft(
                id: operation.operationID.rawValue,
                payload: operationPayload
            )
            let existing = try await store.loadProjection()

            if existing?.payload.digest == projection.digest {
                _ = try await store.commitLocalOperation(
                    projection: projection,
                    expected: existing?.token,
                    operation: draft,
                    mirrorOutbox: [],
                    committedAt: max(
                        max(Date(), existing?.updatedAt ?? Date()),
                        operation.completedAt
                    )
                )
                guard let applied = try await store.appliedOperation(id: draft.id),
                      applied.payload.digest == draft.payload.digest else {
                    throw NextStepBetaStoreError.localPersistenceFailure
                }
                await repairCompatibilityMirror(using: store)
                return
            }

            let expectedDigest = ContentDigest(
                hashing: try encodeArchive(expectedArchive)
            )
            guard existing?.payload.digest == expectedDigest else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }
            let committedAt = max(
                max(Date(), existing?.updatedAt ?? Date()),
                operation.completedAt
            )
            _ = try await store.commitLocalOperation(
                projection: projection,
                expected: existing?.token,
                operation: draft,
                mirrorOutbox: [OutboxIntentDraft(payload: projection)],
                committedAt: committedAt
            )
            await repairCompatibilityMirror(using: store)
        } catch let error as NextStepBetaArchiveError {
            throw error
        } catch let error as NextStepBetaCompletionOperationError {
            throw error
        } catch let error as NextStepBetaStoreError {
            throw error
        } catch {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    func pendingCompletionOperations(
        limit: Int
    ) async throws -> [NextStepBetaPendingCompletionOperation] {
        do {
            try ensureOwnedRoot()
            let store = try database()
            if didInitializeInThisProcess == false {
                _ = try await loadOrMigrate()
            }
            let intents = try await store.pendingOutbox(
                kind: NextStepBetaGuidedActionCompletionOperation.payloadKind,
                limit: limit
            )
            return try intents.map { intent in
                let operation = try NextStepBetaGuidedActionCompletionOperation
                    .decodeCanonical(from: intent.payload.bytes)
                guard intent.id == operation.operationID.rawValue,
                      intent.payload.schemaVersion == operation.schemaVersion else {
                    throw NextStepBetaStoreError.localPersistenceFailure
                }
                return NextStepBetaPendingCompletionOperation(
                    operation: operation,
                    canonicalData: intent.payload.bytes,
                    createdAt: intent.createdAt
                )
            }
        } catch let error as NextStepBetaCompletionOperationError {
            throw error
        } catch let error as NextStepBetaStoreError {
            throw error
        } catch {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    func storedCompletionOperations(
        afterAppliedAt: Date?,
        afterOperationID: OperationID?,
        limit: Int
    ) async throws -> [NextStepBetaPendingCompletionOperation] {
        do {
            try ensureOwnedRoot()
            let store = try database()
            if didInitializeInThisProcess == false {
                _ = try await loadOrMigrate()
            }
            let records = try await store.appliedOperations(
                kind: NextStepBetaGuidedActionCompletionOperation.payloadKind,
                afterAppliedAt: afterAppliedAt,
                afterID: afterOperationID?.rawValue,
                limit: limit
            )
            return try records.map { record in
                let operation = try NextStepBetaGuidedActionCompletionOperation
                    .decodeCanonical(from: record.payload.bytes)
                guard record.id == operation.operationID.rawValue,
                      record.payload.schemaVersion == operation.schemaVersion else {
                    throw NextStepBetaStoreError.localPersistenceFailure
                }
                return NextStepBetaPendingCompletionOperation(
                    operation: operation,
                    canonicalData: record.payload.bytes,
                    createdAt: record.appliedAt
                )
            }
        } catch let error as NextStepBetaCompletionOperationError {
            throw error
        } catch let error as NextStepBetaStoreError {
            throw error
        } catch {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    func markCompletionOperationPublished(
        _ operation: NextStepBetaGuidedActionCompletionOperation,
        publishedAt: Date
    ) async throws {
        do {
            try ensureOwnedRoot()
            let store = try database()
            if didInitializeInThisProcess == false {
                _ = try await loadOrMigrate()
            }
            let payload = try completionPayload(for: operation)
            try await store.markOutboxPublished(
                id: operation.operationID.rawValue,
                expectedDigest: payload.digest,
                publishedAt: publishedAt
            )
        } catch let error as NextStepBetaCompletionOperationError {
            throw error
        } catch let error as NextStepBetaStoreError {
            throw error
        } catch {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    func applySyncedCompletionOperations(
        to archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive,
        operations: [NextStepBetaGuidedActionCompletionOperation],
        receivedAt: Date,
        appliedAt: Date
    ) async throws {
        do {
            guard operations.isEmpty == false,
                  Set(operations.map(\.operationID)).count == operations.count else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }
            try archive.validate()
            try expectedArchive.validate()
            var verifiedArchive = expectedArchive
            for operation in operations {
                verifiedArchive = try NextStepBetaCompletionOperationReducer()
                    .replay(operation, in: verifiedArchive)
                    .archive
            }
            guard try encodeArchive(verifiedArchive) == encodeArchive(archive) else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }

            try ensureOwnedRoot()
            let store = try database()
            if didInitializeInThisProcess == false {
                _ = try await loadOrMigrate()
            }
            let existing = try await store.loadProjection()
            let expectedDigest = ContentDigest(
                hashing: try encodeArchive(expectedArchive)
            )
            guard existing?.payload.digest == expectedDigest else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }

            var workingArchive = expectedArchive
            var storedProjection = existing
            var didChangeProjection = false
            var startIndex = 0
            while startIndex < operations.count {
                let endIndex = min(
                    startIndex + NextStepBetaStore.completionOperationPageSize,
                    operations.count
                )
                let chunk = Array(operations[startIndex ..< endIndex])
                for operation in chunk {
                    workingArchive = try NextStepBetaCompletionOperationReducer()
                        .replay(operation, in: workingArchive)
                        .archive
                }
                let projection = try CanonicalPayload(
                    kind: Self.projectionKind,
                    schemaVersion: workingArchive.schemaVersion,
                    bytes: try encodeArchive(workingArchive)
                )
                let drafts = try chunk.map { operation in
                    ImmutableOperationDraft(
                        id: operation.operationID.rawValue,
                        payload: try completionPayload(for: operation)
                    )
                }
                let effectiveAppliedAt = max(
                    appliedAt,
                    storedProjection?.updatedAt ?? appliedAt
                )
                let effectiveReceivedAt = min(receivedAt, effectiveAppliedAt)
                let projectionChanged = storedProjection?.payload.digest != projection.digest
                storedProjection = try await store.applyInboxOperations(
                    projection: projection,
                    expected: storedProjection?.token,
                    operations: drafts,
                    mirrorOutbox: projectionChanged
                        ? [OutboxIntentDraft(payload: projection)]
                        : [],
                    receivedAt: effectiveReceivedAt,
                    appliedAt: effectiveAppliedAt
                )
                didChangeProjection = didChangeProjection || projectionChanged
                startIndex = endIndex
            }
            guard try encodeArchive(workingArchive) == encodeArchive(archive) else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }
            if didChangeProjection {
                await repairCompatibilityMirror(using: store)
            }
        } catch let error as NextStepBetaArchiveError {
            throw error
        } catch let error as NextStepBetaCompletionOperationError {
            throw error
        } catch let error as NextStepBetaStoreError {
            throw error
        } catch {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    func saveActionReplanOperation(
        _ archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive,
        operation: NextStepBetaActionReplanOperationV1
    ) async throws {
        try archive.validate()
        try expectedArchive.validate()
        let replay = try NextStepBetaActionReplanOperationReducer().replay(
            operation,
            in: expectedArchive
        )
        guard replay.outcome == .applied,
              try encodeArchive(replay.archive) == encodeArchive(archive) else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }

        try ensureOwnedRoot()
        let store = try database()
        if didInitializeInThisProcess == false {
            _ = try await loadOrMigrate()
        }

        let projection = try CanonicalPayload(
            kind: Self.projectionKind,
            schemaVersion: archive.schemaVersion,
            bytes: try encodeArchive(archive)
        )
        let operationPayload = try actionReplanPayload(for: operation)
        let draft = ImmutableOperationDraft(
            id: operation.operationID.rawValue,
            payload: operationPayload
        )
        let existing = try await store.loadProjection()

        if existing?.payload.digest == projection.digest {
            _ = try await store.commitLocalOperation(
                projection: projection,
                expected: existing?.token,
                operation: draft,
                mirrorOutbox: [],
                committedAt: max(
                    max(Date(), existing?.updatedAt ?? Date()),
                    operation.occurredAt
                )
            )
            guard let applied = try await store.appliedOperation(id: draft.id),
                  applied.payload.digest == draft.payload.digest else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }
            await repairCompatibilityMirror(using: store)
            return
        }

        let expectedDigest = ContentDigest(
            hashing: try encodeArchive(expectedArchive)
        )
        guard existing?.payload.digest == expectedDigest else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        _ = try await store.commitLocalOperation(
            projection: projection,
            expected: existing?.token,
            operation: draft,
            mirrorOutbox: [OutboxIntentDraft(payload: projection)],
            committedAt: max(
                max(Date(), existing?.updatedAt ?? Date()),
                operation.occurredAt
            )
        )
        await repairCompatibilityMirror(using: store)
    }

    func pendingActionReplanOperations(
        limit: Int
    ) async throws -> [NextStepBetaPendingActionReplanOperation] {
        try ensureOwnedRoot()
        let store = try database()
        if didInitializeInThisProcess == false {
            _ = try await loadOrMigrate()
        }
        let intents = try await store.pendingOutbox(
            kind: NextStepBetaActionReplanOperationV1.payloadKind,
            limit: limit
        )
        return try intents.map { intent in
            let operation = try NextStepBetaActionReplanOperationV1
                .decodeCanonical(from: intent.payload.bytes)
            guard intent.id == operation.operationID.rawValue,
                  intent.payload.schemaVersion == operation.schemaVersion else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }
            return NextStepBetaPendingActionReplanOperation(
                operation: operation,
                canonicalData: intent.payload.bytes,
                createdAt: intent.createdAt
            )
        }
    }

    func storedActionReplanOperations(
        afterAppliedAt: Date?,
        afterOperationID: OperationID?,
        limit: Int
    ) async throws -> [NextStepBetaPendingActionReplanOperation] {
        try ensureOwnedRoot()
        let store = try database()
        if didInitializeInThisProcess == false {
            _ = try await loadOrMigrate()
        }
        let records = try await store.appliedOperations(
            kind: NextStepBetaActionReplanOperationV1.payloadKind,
            afterAppliedAt: afterAppliedAt,
            afterID: afterOperationID?.rawValue,
            limit: limit
        )
        return try records.map { record in
            let operation = try NextStepBetaActionReplanOperationV1
                .decodeCanonical(from: record.payload.bytes)
            guard record.id == operation.operationID.rawValue,
                  record.payload.schemaVersion == operation.schemaVersion else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }
            return NextStepBetaPendingActionReplanOperation(
                operation: operation,
                canonicalData: record.payload.bytes,
                createdAt: record.appliedAt
            )
        }
    }

    func markActionReplanOperationPublished(
        _ operation: NextStepBetaActionReplanOperationV1,
        publishedAt: Date
    ) async throws {
        try ensureOwnedRoot()
        let store = try database()
        if didInitializeInThisProcess == false {
            _ = try await loadOrMigrate()
        }
        let payload = try actionReplanPayload(for: operation)
        try await store.markOutboxPublished(
            id: operation.operationID.rawValue,
            expectedDigest: payload.digest,
            publishedAt: publishedAt
        )
    }

    func applySyncedActionReplanOperations(
        to archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive,
        operations: [NextStepBetaActionReplanOperationV1],
        receivedAt: Date,
        appliedAt: Date
    ) async throws {
        guard operations.isEmpty == false,
              Set(operations.map(\.operationID)).count == operations.count else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        try archive.validate()
        try expectedArchive.validate()

        var verifiedArchive = expectedArchive
        for operation in operations {
            verifiedArchive = try NextStepBetaActionReplanOperationReducer()
                .replay(operation, in: verifiedArchive)
                .archive
        }
        guard try encodeArchive(verifiedArchive) == encodeArchive(archive) else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }

        try ensureOwnedRoot()
        let store = try database()
        if didInitializeInThisProcess == false {
            _ = try await loadOrMigrate()
        }
        let existing = try await store.loadProjection()
        let expectedDigest = ContentDigest(
            hashing: try encodeArchive(expectedArchive)
        )
        guard existing?.payload.digest == expectedDigest else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }

        var workingArchive = expectedArchive
        var storedProjection = existing
        var didChangeProjection = false
        var startIndex = 0
        while startIndex < operations.count {
            let endIndex = min(
                startIndex + NextStepBetaStore.actionReplanOperationPageSize,
                operations.count
            )
            let chunk = Array(operations[startIndex ..< endIndex])
            for operation in chunk {
                workingArchive = try NextStepBetaActionReplanOperationReducer()
                    .replay(operation, in: workingArchive)
                    .archive
            }
            let projection = try CanonicalPayload(
                kind: Self.projectionKind,
                schemaVersion: workingArchive.schemaVersion,
                bytes: try encodeArchive(workingArchive)
            )
            let drafts = try chunk.map { operation in
                ImmutableOperationDraft(
                    id: operation.operationID.rawValue,
                    payload: try actionReplanPayload(for: operation)
                )
            }
            let effectiveAppliedAt = max(
                appliedAt,
                storedProjection?.updatedAt ?? appliedAt
            )
            let effectiveReceivedAt = min(receivedAt, effectiveAppliedAt)
            let projectionChanged = storedProjection?.payload.digest != projection.digest
            storedProjection = try await store.applyInboxOperations(
                projection: projection,
                expected: storedProjection?.token,
                operations: drafts,
                mirrorOutbox: projectionChanged
                    ? [OutboxIntentDraft(payload: projection)]
                    : [],
                receivedAt: effectiveReceivedAt,
                appliedAt: effectiveAppliedAt
            )
            didChangeProjection = didChangeProjection || projectionChanged
            startIndex = endIndex
        }
        guard try encodeArchive(workingArchive) == encodeArchive(archive) else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        if didChangeProjection {
            await repairCompatibilityMirror(using: store)
        }
    }

    /// Atomically installs one causally ordered mixed immutable-operation
    /// stream. Sync performs a pure preflight first; this repository repeats
    /// the replay and writes the final projection plus every inbox ledger row
    /// in a single SQLite transaction.
    func applySyncedExecutionOperations(
        to archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive,
        operations: [NextStepBetaSyncedExecutionOperation],
        receivedAt: Date,
        appliedAt: Date
    ) async throws {
        guard operations.isEmpty == false,
              Set(operations.map(\.operationID)).count == operations.count else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        try archive.validate()
        try expectedArchive.validate()

        var verifiedArchive = expectedArchive
        var drafts: [ImmutableOperationDraft] = []
        drafts.reserveCapacity(operations.count)
        for operation in operations {
            switch operation {
            case .completion(let value):
                verifiedArchive = try NextStepBetaCompletionOperationReducer()
                    .replay(value, in: verifiedArchive)
                    .archive
                drafts.append(ImmutableOperationDraft(
                    id: value.operationID.rawValue,
                    payload: try completionPayload(for: value)
                ))
            case .actionReplan(let value):
                verifiedArchive = try NextStepBetaActionReplanOperationReducer()
                    .replay(value, in: verifiedArchive)
                    .archive
                drafts.append(ImmutableOperationDraft(
                    id: value.operationID.rawValue,
                    payload: try actionReplanPayload(for: value)
                ))
            }
        }
        guard try encodeArchive(verifiedArchive) == encodeArchive(archive) else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }

        try ensureOwnedRoot()
        let store = try database()
        if didInitializeInThisProcess == false {
            _ = try await loadOrMigrate()
        }
        let existing = try await store.loadProjection()
        let expectedDigest = ContentDigest(
            hashing: try encodeArchive(expectedArchive)
        )
        guard existing?.payload.digest == expectedDigest else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        let projection = try CanonicalPayload(
            kind: Self.projectionKind,
            schemaVersion: archive.schemaVersion,
            bytes: try encodeArchive(archive)
        )
        let effectiveAppliedAt = max(
            appliedAt,
            existing?.updatedAt ?? appliedAt
        )
        let effectiveReceivedAt = min(receivedAt, effectiveAppliedAt)
        let projectionChanged = existing?.payload.digest != projection.digest
        _ = try await store.applyInboxOperations(
            projection: projection,
            expected: existing?.token,
            operations: drafts,
            mirrorOutbox: projectionChanged
                ? [OutboxIntentDraft(payload: projection)]
                : [],
            receivedAt: effectiveReceivedAt,
            appliedAt: effectiveAppliedAt
        )
        if projectionChanged {
            await repairCompatibilityMirror(using: store)
        }
    }

    private func repairCompatibilityMirror(
        using store: NextStepPersistenceStore
    ) async {
        await NextStepBetaAsyncLock.mirrorPublication.acquire()
        do {
            try await repairCompatibilityMirrorWhileLocked(using: store)
        } catch {
            // SQLite remains authoritative and every unacknowledged mirror
            // intent stays pending for the next launch/save repair attempt.
        }
        await NextStepBetaAsyncLock.mirrorPublication.release()
    }

    private func repairCompatibilityMirrorWhileLocked(
        using store: NextStepPersistenceStore
    ) async throws {
        let firstBatch = try await store.pendingOutbox(
            kind: Self.projectionKind,
            limit: 1
        )
        guard firstBatch.isEmpty == false else {
            if let projection = try await store.loadProjection() {
                _ = try await store.prunePublishedOutbox(
                    throughGeneration: projection.token.generation
                )
            }
            return
        }

        // Coalesce all historical mirror intents into the newest projection.
        // Holding the process-wide async lock prevents an older repository from
        // publishing after a newer repository in this App process.
        var publishedProjection = try await requiredProjection(from: store)
        while true {
            try writeVerifiedCompatibilityMirror(publishedProjection.payload.bytes)
            let latest = try await requiredProjection(from: store)
            guard latest.token == publishedProjection.token else {
                publishedProjection = latest
                continue
            }
            break
        }

        while true {
            let pending = try await store.pendingOutbox(
                kind: Self.projectionKind,
                limit: NextStepPersistenceStore.maximumPendingOutboxLimit
            )
            let publishable = pending.filter {
                $0.projectionGeneration <= publishedProjection.token.generation
            }
            guard publishable.isEmpty == false else {
                _ = try await store.prunePublishedOutbox(
                    throughGeneration: publishedProjection.token.generation
                )
                return
            }
            for intent in publishable {
                try await store.markOutboxPublished(
                    id: intent.id,
                    expectedDigest: intent.payload.digest,
                    publishedAt: max(Date(), intent.createdAt)
                )
            }
            if pending.count < NextStepPersistenceStore.maximumPendingOutboxLimit {
                _ = try await store.prunePublishedOutbox(
                    throughGeneration: publishedProjection.token.generation
                )
                return
            }
        }
    }

    private func reconcileMigrationBackupIfNeeded(
        stored: StoredProjection,
        using store: NextStepPersistenceStore
    ) async throws {
        guard let ledger = try await store.migrationLedger(
            key: Self.legacyMigrationKey
        ) else {
            return
        }
        guard ledger.migrationVersion == Self.legacyMigrationVersion,
              ledger.resultGeneration <= stored.token.generation else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        let backupBytes = try readBoundedRegularFile(at: migrationBackupURL)
        let backupDigest = ContentDigest(hashing: backupBytes)
        guard Int64(backupBytes.count) == ledger.backupByteCount,
              backupDigest == ledger.backupDigest else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }

        let migratedArchive = try decodeArchive(backupBytes)
        let migratedProjection = try CanonicalPayload(
            kind: Self.projectionKind,
            schemaVersion: migratedArchive.schemaVersion,
            bytes: try encodeArchive(migratedArchive)
        )
        let replayLedger = try MigrationLedgerDraft(
            key: ledger.key,
            migrationVersion: ledger.migrationVersion,
            sourceSchemaVersion: ledger.sourceSchemaVersion,
            sourceRevision: ledger.sourceRevision,
            sourceByteCount: ledger.sourceByteCount,
            sourceDigest: ledger.sourceDigest,
            backupByteCount: ledger.backupByteCount,
            backupDigest: ledger.backupDigest
        )
        let replayed = try await store.installMigration(
            projection: migratedProjection,
            ledger: replayLedger,
            committedAt: ledger.completedAt
        )
        guard replayed.token == stored.token else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    private func requiredProjection(
        from store: NextStepPersistenceStore
    ) async throws -> StoredProjection {
        guard let projection = try await store.loadProjection() else {
            throw PersistenceError.transactionInvariantViolation
        }
        _ = try decodeProjection(projection.payload)
        return projection
    }

    private func database() throws -> NextStepPersistenceStore {
        if let persistenceStore { return persistenceStore }
        let created = try NextStepPersistenceStore(
            localDatabaseURL: databaseURL
        )
        persistenceStore = created
        return created
    }

    private func ensureOwnedRoot() throws {
        if fileManager.fileExists(atPath: rootURL.path) == false {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        let values = try rootURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw NextStepBetaStoreError.unsafeLocalArchive
        }
    }

    private func installOrVerifyMigrationBackup(_ source: Data) throws -> Data {
        let directory = migrationBackupURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: nil
            )
        }
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw NextStepBetaStoreError.unsafeLocalArchive
        }

        if fileManager.fileExists(atPath: migrationBackupURL.path) {
            let existing = try readBoundedRegularFile(at: migrationBackupURL)
            guard existing == source else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }
            return existing
        }

        try source.write(
            to: migrationBackupURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        let installed = try readBoundedRegularFile(at: migrationBackupURL)
        guard installed == source else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        return installed
    }

    private func writeVerifiedCompatibilityMirror(_ data: Data) throws {
        guard (1 ... Self.maximumArchiveBytes).contains(data.count) else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        if fileManager.fileExists(atPath: legacyArchiveURL.path) {
            let values = try legacyArchiveURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw NextStepBetaStoreError.unsafeLocalArchive
            }
        }
        try data.write(
            to: legacyArchiveURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        let published = try readBoundedRegularFile(at: legacyArchiveURL)
        guard published == data else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    private func readBoundedRegularFile(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NextStepBetaStoreError.unsafeLocalArchive
        }
        if let fileSize = values.fileSize,
           !(1 ... Self.maximumArchiveBytes).contains(fileSize) {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard (1 ... Self.maximumArchiveBytes).contains(data.count) else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        return data
    }

    private func encodeArchive(_ archive: NextStepBetaArchive) throws -> Data {
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)
        guard (1 ... Self.maximumArchiveBytes).contains(data.count) else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        return data
    }

    private func decodeArchive(_ data: Data) throws -> NextStepBetaArchive {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let archive = try decoder.decode(NextStepBetaArchive.self, from: data)
            try archive.validate()
            return archive
        } catch let error as NextStepBetaArchiveError {
            throw error
        } catch {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    private func decodeProjection(
        _ payload: CanonicalPayload
    ) throws -> NextStepBetaArchive {
        guard payload.kind == Self.projectionKind,
              payload.schemaVersion == NextStepBetaArchive.currentSchemaVersion else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        return try decodeArchive(payload.bytes)
    }

    private func completionPayload(
        for operation: NextStepBetaGuidedActionCompletionOperation
    ) throws -> CanonicalPayload {
        try CanonicalPayload(
            kind: NextStepBetaGuidedActionCompletionOperation.payloadKind,
            schemaVersion: operation.schemaVersion,
            bytes: operation.canonicalData()
        )
    }

    private func actionReplanPayload(
        for operation: NextStepBetaActionReplanOperationV1
    ) throws -> CanonicalPayload {
        try CanonicalPayload(
            kind: NextStepBetaActionReplanOperationV1.payloadKind,
            schemaVersion: operation.schemaVersion,
            bytes: operation.canonicalData()
        )
    }

    private func legacySchemaVersion(in data: Data) throws -> Int {
        struct Header: Decodable {
            let schemaVersion: Int
        }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.schemaVersion > 0 else {
                throw NextStepBetaStoreError.localPersistenceFailure
            }
            return header.schemaVersion
        } catch let error as NextStepBetaStoreError {
            throw error
        } catch {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
    }

    private var databaseURL: URL {
        rootURL.appendingPathComponent(Self.databaseFilename, isDirectory: false)
    }

    private var legacyArchiveURL: URL {
        rootURL.appendingPathComponent(
            NextStepBetaStore.archiveFilename,
            isDirectory: false
        )
    }

    private var migrationBackupURL: URL {
        rootURL
            .appendingPathComponent(
                Self.migrationBackupDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                Self.migrationBackupFilename,
                isDirectory: false
            )
    }
}

/// A deliberately non-reentrant async mutex for mirror publication. Holding
/// this lease across database awaits is safe because commits never require the
/// mirror lock; another publisher queues instead of entering the actor body.
private actor NextStepBetaAsyncLock {
    static let mirrorPublication = NextStepBetaAsyncLock()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if isHeld == false {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
