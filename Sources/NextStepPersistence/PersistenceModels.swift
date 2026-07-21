import Foundation

enum PersistenceModelLimits {
    static let maximumPayloadBytes = 64 * 1_024 * 1_024
    static let maximumPayloadKindBytes = 64
    static let maximumMigrationKeyBytes = 128
    static let maximumOperationBatchCount = 10_000
    static let maximumSchemaVersion = Int(Int32.max)

    static func isSafeKey(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.utf8.allSatisfy { character in
                (0x61 ... 0x7a).contains(character)
                    || (0x30 ... 0x39).contains(character)
                    || character == 0x2e
                    || character == 0x5f
                    || character == 0x2d
            }
    }

    static func isPersistableDate(_ value: Date) -> Bool {
        let milliseconds = value.timeIntervalSince1970 * 1_000
        return milliseconds.isFinite
            && milliseconds >= 0
            && milliseconds < Double(Int64.max)
    }
}

public struct CanonicalPayload: Hashable, Sendable {
    public let kind: String
    public let schemaVersion: Int
    public let bytes: Data
    public let digest: ContentDigest

    public init(
        kind: String,
        schemaVersion: Int,
        bytes: Data
    ) throws {
        try Self.validate(kind: kind, schemaVersion: schemaVersion, bytes: bytes)
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.bytes = bytes
        digest = ContentDigest(hashing: bytes)
    }

    public init(
        kind: String,
        schemaVersion: Int,
        bytes: Data,
        validating digest: ContentDigest
    ) throws {
        try Self.validate(kind: kind, schemaVersion: schemaVersion, bytes: bytes)
        let actualDigest = ContentDigest(hashing: bytes)
        guard actualDigest == digest else {
            throw PersistenceError.digestMismatch(
                expected: digest,
                actual: actualDigest
            )
        }
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.bytes = bytes
        self.digest = actualDigest
    }

    private static func validate(
        kind: String,
        schemaVersion: Int,
        bytes: Data
    ) throws {
        guard PersistenceModelLimits.isSafeKey(
            kind,
            maximumBytes: PersistenceModelLimits.maximumPayloadKindBytes
        ) else {
            throw PersistenceError.invalidValue(field: "kind")
        }
        guard (1 ... PersistenceModelLimits.maximumSchemaVersion)
            .contains(schemaVersion) else {
            throw PersistenceError.invalidValue(field: "schemaVersion")
        }
        guard (1 ... PersistenceModelLimits.maximumPayloadBytes).contains(bytes.count) else {
            throw PersistenceError.invalidLimit
        }
    }
}

public struct ProjectionToken: Hashable, Sendable {
    public let generation: Int64
    public let payloadDigest: ContentDigest

    public init(generation: Int64, payloadDigest: ContentDigest) throws {
        guard generation > 0 else {
            throw PersistenceError.invalidValue(field: "generation")
        }
        self.generation = generation
        self.payloadDigest = payloadDigest
    }
}

public struct StoredProjection: Hashable, Sendable {
    public let token: ProjectionToken
    public let payload: CanonicalPayload
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        token: ProjectionToken,
        payload: CanonicalPayload,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        guard token.payloadDigest == payload.digest else {
            throw PersistenceError.digestMismatch(
                expected: token.payloadDigest,
                actual: payload.digest
            )
        }
        guard PersistenceModelLimits.isPersistableDate(createdAt),
              PersistenceModelLimits.isPersistableDate(updatedAt),
              updatedAt >= createdAt else {
            throw PersistenceError.invalidValue(field: "projectionChronology")
        }
        self.token = token
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct OutboxIntentDraft: Hashable, Sendable {
    public let id: UUID
    public let payload: CanonicalPayload

    public init(id: UUID = UUID(), payload: CanonicalPayload) {
        self.id = id
        self.payload = payload
    }
}

public struct PersistedOutboxIntent: Hashable, Sendable {
    public let id: UUID
    public let projectionGeneration: Int64
    public let payload: CanonicalPayload
    public let createdAt: Date
    public let publishedAt: Date?

    public init(
        id: UUID,
        projectionGeneration: Int64,
        payload: CanonicalPayload,
        createdAt: Date,
        publishedAt: Date? = nil
    ) throws {
        guard projectionGeneration > 0 else {
            throw PersistenceError.invalidValue(field: "projectionGeneration")
        }
        guard PersistenceModelLimits.isPersistableDate(createdAt),
              publishedAt.map({
                  PersistenceModelLimits.isPersistableDate($0) && $0 >= createdAt
              }) ?? true else {
            throw PersistenceError.invalidValue(field: "outboxChronology")
        }
        self.id = id
        self.projectionGeneration = projectionGeneration
        self.payload = payload
        self.createdAt = createdAt
        self.publishedAt = publishedAt
    }
}

/// An immutable, content-addressed sync operation. The UUID is the stable
/// idempotency key; reusing it with any other payload digest is a hard error.
public struct ImmutableOperationDraft: Hashable, Sendable {
    public let id: UUID
    public let payload: CanonicalPayload

    public init(id: UUID = UUID(), payload: CanonicalPayload) {
        self.id = id
        self.payload = payload
    }
}

public struct PersistedInboxOperation: Hashable, Sendable {
    public let id: UUID
    public let payload: CanonicalPayload
    public let receivedAt: Date

    public init(
        id: UUID,
        payload: CanonicalPayload,
        receivedAt: Date
    ) throws {
        guard PersistenceModelLimits.isPersistableDate(receivedAt) else {
            throw PersistenceError.invalidValue(field: "receivedAt")
        }
        self.id = id
        self.payload = payload
        self.receivedAt = receivedAt
    }
}

public struct AppliedOperationRecord: Hashable, Sendable {
    public let id: UUID
    public let payload: CanonicalPayload
    public let resultGeneration: Int64
    public let appliedAt: Date

    public init(
        id: UUID,
        payload: CanonicalPayload,
        resultGeneration: Int64,
        appliedAt: Date
    ) throws {
        guard resultGeneration > 0 else {
            throw PersistenceError.invalidValue(field: "resultGeneration")
        }
        guard PersistenceModelLimits.isPersistableDate(appliedAt) else {
            throw PersistenceError.invalidValue(field: "appliedAt")
        }
        self.id = id
        self.payload = payload
        self.resultGeneration = resultGeneration
        self.appliedAt = appliedAt
    }
}

public struct MigrationLedgerDraft: Hashable, Sendable {
    public let key: String
    public let migrationVersion: Int
    public let sourceSchemaVersion: Int
    public let sourceRevision: Int64
    public let sourceByteCount: Int64
    public let sourceDigest: ContentDigest
    public let backupByteCount: Int64
    public let backupDigest: ContentDigest

    public init(
        key: String,
        migrationVersion: Int,
        sourceSchemaVersion: Int,
        sourceRevision: Int64,
        sourceByteCount: Int64,
        sourceDigest: ContentDigest,
        backupByteCount: Int64,
        backupDigest: ContentDigest
    ) throws {
        guard PersistenceModelLimits.isSafeKey(
            key,
            maximumBytes: PersistenceModelLimits.maximumMigrationKeyBytes
        ) else {
            throw PersistenceError.invalidValue(field: "migrationKey")
        }
        guard (1 ... PersistenceModelLimits.maximumSchemaVersion)
            .contains(migrationVersion) else {
            throw PersistenceError.invalidValue(field: "migrationVersion")
        }
        guard (1 ... PersistenceModelLimits.maximumSchemaVersion)
            .contains(sourceSchemaVersion) else {
            throw PersistenceError.invalidValue(field: "sourceSchemaVersion")
        }
        guard sourceRevision >= 0 else {
            throw PersistenceError.invalidValue(field: "sourceRevision")
        }
        guard (1 ... Int64(PersistenceModelLimits.maximumPayloadBytes))
            .contains(sourceByteCount),
              (1 ... Int64(PersistenceModelLimits.maximumPayloadBytes))
            .contains(backupByteCount) else {
            throw PersistenceError.invalidLimit
        }
        guard sourceByteCount == backupByteCount else {
            throw PersistenceError.invalidValue(field: "backupByteCount")
        }
        guard sourceDigest == backupDigest else {
            throw PersistenceError.digestMismatch(
                expected: sourceDigest,
                actual: backupDigest
            )
        }
        self.key = key
        self.migrationVersion = migrationVersion
        self.sourceSchemaVersion = sourceSchemaVersion
        self.sourceRevision = sourceRevision
        self.sourceByteCount = sourceByteCount
        self.sourceDigest = sourceDigest
        self.backupByteCount = backupByteCount
        self.backupDigest = backupDigest
    }
}

public struct MigrationLedgerRecord: Hashable, Sendable {
    public let key: String
    public let migrationVersion: Int
    public let sourceSchemaVersion: Int
    public let sourceRevision: Int64
    public let sourceByteCount: Int64
    public let sourceDigest: ContentDigest
    public let backupByteCount: Int64
    public let backupDigest: ContentDigest
    public let resultPayloadDigest: ContentDigest
    public let resultGeneration: Int64
    public let completedAt: Date

    public init(
        key: String,
        migrationVersion: Int,
        sourceSchemaVersion: Int,
        sourceRevision: Int64,
        sourceByteCount: Int64,
        sourceDigest: ContentDigest,
        backupByteCount: Int64,
        backupDigest: ContentDigest,
        resultPayloadDigest: ContentDigest,
        resultGeneration: Int64,
        completedAt: Date
    ) throws {
        guard PersistenceModelLimits.isSafeKey(
            key,
            maximumBytes: PersistenceModelLimits.maximumMigrationKeyBytes
        ),
        (1 ... PersistenceModelLimits.maximumSchemaVersion).contains(migrationVersion),
        (1 ... PersistenceModelLimits.maximumSchemaVersion).contains(sourceSchemaVersion),
        sourceRevision >= 0,
        (1 ... Int64(PersistenceModelLimits.maximumPayloadBytes)).contains(sourceByteCount),
        sourceByteCount == backupByteCount,
        sourceDigest == backupDigest,
        resultGeneration > 0,
        PersistenceModelLimits.isPersistableDate(completedAt) else {
            throw PersistenceError.transactionInvariantViolation
        }
        self.key = key
        self.migrationVersion = migrationVersion
        self.sourceSchemaVersion = sourceSchemaVersion
        self.sourceRevision = sourceRevision
        self.sourceByteCount = sourceByteCount
        self.sourceDigest = sourceDigest
        self.backupByteCount = backupByteCount
        self.backupDigest = backupDigest
        self.resultPayloadDigest = resultPayloadDigest
        self.resultGeneration = resultGeneration
        self.completedAt = completedAt
    }

    func matches(_ draft: MigrationLedgerDraft) -> Bool {
        key == draft.key
            && migrationVersion == draft.migrationVersion
            && sourceSchemaVersion == draft.sourceSchemaVersion
            && sourceRevision == draft.sourceRevision
            && sourceByteCount == draft.sourceByteCount
            && sourceDigest == draft.sourceDigest
            && backupByteCount == draft.backupByteCount
            && backupDigest == draft.backupDigest
    }
}

public struct PersistencePragmas: Hashable, Sendable {
    public let foreignKeysEnabled: Bool
    public let writeAheadLoggingEnabled: Bool
    public let fullSynchronousEnabled: Bool
    public let trustedSchemaDisabled: Bool
    public let cellSizeCheckEnabled: Bool
    public let busyTimeoutMilliseconds: Int

    public init(
        foreignKeysEnabled: Bool,
        writeAheadLoggingEnabled: Bool,
        fullSynchronousEnabled: Bool,
        trustedSchemaDisabled: Bool,
        cellSizeCheckEnabled: Bool,
        busyTimeoutMilliseconds: Int
    ) throws {
        guard (0 ... Int(Int32.max)).contains(busyTimeoutMilliseconds) else {
            throw PersistenceError.invalidValue(field: "busyTimeoutMilliseconds")
        }
        self.foreignKeysEnabled = foreignKeysEnabled
        self.writeAheadLoggingEnabled = writeAheadLoggingEnabled
        self.fullSynchronousEnabled = fullSynchronousEnabled
        self.trustedSchemaDisabled = trustedSchemaDisabled
        self.cellSizeCheckEnabled = cellSizeCheckEnabled
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    }

    public var isHardened: Bool {
        foreignKeysEnabled
            && writeAheadLoggingEnabled
            && fullSynchronousEnabled
            && trustedSchemaDisabled
            && cellSizeCheckEnabled
            && busyTimeoutMilliseconds > 0
    }
}
