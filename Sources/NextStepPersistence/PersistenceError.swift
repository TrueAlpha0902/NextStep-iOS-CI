import Foundation

/// Public persistence failures intentionally exclude database paths, SQL text,
/// and raw SQLite messages. Integer result codes are retained for diagnostics
/// without exposing user content or filesystem details.
public enum PersistenceError: Error, Equatable, Sendable {
    case invalidDigest
    case digestMismatch(expected: ContentDigest, actual: ContentDigest)
    case invalidValue(field: String)
    case invalidLimit
    case sqliteFailure(code: Int32)
    case migrationFailed(version: Int, code: Int32?)
    case migrationChecksumMismatch(version: Int)
    case staleProjection(expected: ProjectionToken?, actual: ProjectionToken?)
    case payloadNotFound(ContentDigest)
    case transactionInvariantViolation
    case emptyOutbox
    case duplicateOutboxIntent
    case emptyOperations
    case operationIdentityCollision(
        id: UUID,
        expected: ContentDigest,
        actual: ContentDigest
    )
    case unchangedPayload
    case incompatibleDatabase
    case unsupportedDatabaseVersion(Int)
    case generationOverflow
    case commitOutcomeUnknown(code: Int32)
    case closed
    case notFound
}

extension PersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDigest:
            "The content digest is not a valid SHA-256 value."
        case .digestMismatch:
            "The content bytes do not match their expected digest."
        case .invalidValue:
            "A persistence value is invalid."
        case .invalidLimit:
            "The persistence limit is invalid."
        case let .sqliteFailure(code):
            "The database operation failed with code \(code)."
        case let .migrationFailed(version, code):
            if let code {
                "Database migration \(version) failed with code \(code)."
            } else {
                "Database migration \(version) failed."
            }
        case let .migrationChecksumMismatch(version):
            "Database migration \(version) does not match its recorded checksum."
        case .staleProjection:
            "The stored projection changed before the operation could commit."
        case .payloadNotFound:
            "The referenced canonical payload was not found."
        case .transactionInvariantViolation:
            "The persistence transaction violates an atomicity invariant."
        case .emptyOutbox:
            "A local mutation requires at least one outbox intent."
        case .duplicateOutboxIntent:
            "The persistence transaction contains a duplicate outbox intent."
        case .emptyOperations:
            "An operation transaction requires at least one immutable operation."
        case .operationIdentityCollision:
            "An immutable operation identifier is already bound to different content."
        case .unchangedPayload:
            "The new projection payload is unchanged."
        case .incompatibleDatabase:
            "The database is not compatible with this application."
        case let .unsupportedDatabaseVersion(version):
            "Database schema version \(version) is unsupported."
        case .generationOverflow:
            "The projection generation cannot advance."
        case let .commitOutcomeUnknown(code):
            "The database commit outcome is unknown after code \(code)."
        case .closed:
            "The database connection is closed."
        case .notFound:
            "The requested persistence record was not found."
        }
    }
}
