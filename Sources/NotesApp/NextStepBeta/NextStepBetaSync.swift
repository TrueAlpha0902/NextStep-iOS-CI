import Foundation
import NextStepDomain
import NextStepGrounding
import NextStepSync

public struct NextStepBetaSyncReview: Equatable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case protectedDeadline
        case immutableSource
        case immutableCompletion
        case actionReplan
    }

    public let id: String
    public let kind: Kind
    public let localDescription: String
    public let syncedDescription: String

    init(
        id: String,
        kind: Kind,
        localDescription: String,
        syncedDescription: String
    ) {
        self.id = id
        self.kind = kind
        self.localDescription = localDescription
        self.syncedDescription = syncedDescription
    }
}

public enum NextStepBetaSyncState: Equatable, Sendable {
    case notConfigured
    case restoring
    case connecting
    case syncing(lastSyncedAt: Date?)
    case ready(lastSyncedAt: Date)
    case offline(lastSyncedAt: Date?, message: String)
    case reviewRequired(NextStepBetaSyncReview)
    case failed(String)

    var isConfigured: Bool {
        switch self {
        case .notConfigured, .connecting:
            false
        case .restoring, .syncing, .ready, .offline, .reviewRequired, .failed:
            true
        }
    }

    var lastSyncedAt: Date? {
        switch self {
        case .syncing(let date), .offline(let date, _): date
        case .ready(let date): date
        case .notConfigured, .restoring, .connecting, .reviewRequired, .failed: nil
        }
    }
}

enum NextStepBetaSyncFailureClassifier {
    static func state(for error: Error, lastSyncedAt: Date?) -> NextStepBetaSyncState {
        if let replanError = error as? NextStepBetaActionReplanOperationError {
            switch replanError {
            case .contextRequiresReview(let reason):
                return .reviewRequired(NextStepBetaSyncReview(
                    id: "action-replan-\(String(describing: reason))",
                    kind: .actionReplan,
                    localDescription: "保留目前的 Today 與受保護期限",
                    syncedDescription: "另一台裝置有無法自動套用的重新安排"
                ))
            case .derivedRecordConflict(let kind, let id):
                return .reviewRequired(NextStepBetaSyncReview(
                    id: "action-replan-\(id.uuidString.lowercased())",
                    kind: .actionReplan,
                    localDescription: "保留目前的 \(String(describing: kind))",
                    syncedDescription: "同步資料包含競爭的重新安排結果"
                ))
            default:
                return .failed(replanError.localizedDescription)
            }
        }
        if let syncError = error as? NextStepSyncError {
            switch syncError {
            case .transportUnavailable, .notFound(_), .ioFailure(_):
                return .offline(
                    lastSyncedAt: lastSyncedAt,
                    message: syncError.localizedDescription
                )
            case .unresolvedConflict(_):
                return .failed("受保護資料仍有未確認的同步衝突。")
            default:
                return .failed(syncError.localizedDescription)
            }
        }
        return .failed(error.localizedDescription)
    }
}

struct NextStepBetaSyncSettings: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let bookmarkData: Data
    let libraryID: SyncLibraryID

    init(bookmarkData: Data, libraryID: SyncLibraryID) {
        self.schemaVersion = Self.currentSchemaVersion
        self.bookmarkData = bookmarkData
        self.libraryID = libraryID
    }
}

actor NextStepBetaSyncSettingsStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(rootURL: URL) {
        self.fileURL = rootURL.appendingPathComponent(
            "sync-folder-bookmark-v1.json",
            isDirectory: false
        )
        self.fileManager = FileManager()
    }

    func load() throws -> NextStepBetaSyncSettings? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let value = try JSONDecoder().decode(NextStepBetaSyncSettings.self, from: data)
        guard value.schemaVersion == NextStepBetaSyncSettings.currentSchemaVersion else {
            throw NextStepSyncError.unsupportedSchemaVersion(value.schemaVersion)
        }
        return value
    }

    func save(bookmark: SecurityScopedSyncFolderBookmark, libraryID: SyncLibraryID) throws {
        let value = NextStepBetaSyncSettings(
            bookmarkData: bookmark.data,
            libraryID: libraryID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}

private struct NextStepBetaProtectedDeadlineSet: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let ownerKind: String
        let ownerID: String
        let day: String
        let authority: String
        let mutability: String
        let evidenceLinkIDs: [String]
        let confirmedAt: Date?
    }

    let schemaVersion: Int
    let entries: [Entry]
}

private struct NextStepBetaGroundingCollisionRecords: Sendable {
    let audits: [SourceFactReviewAudit]
    let facts: [ConfirmedSourceDateFact]
    let evidence: [EvidenceLink]
}

/// Device identity is deliberately excluded. The same logical workspace must
/// have the same digest on iPhone and iPad, while newly created records keep
/// using the receiving device's local domain identity.
private struct NextStepBetaSyncPayload: Codable, Sendable {
    let schemaVersion: Int
    let workspace: NextStepWorkspaceSnapshot
    let currentDecisionID: PlanningDecisionID?
    let grounding: NextStepBetaGroundingState?
    let completionApplicationReceipts: [NextStepBetaCompletionApplicationReceipt]?
    let actionReplanApplicationReceipts: [NextStepBetaActionReplanApplicationReceipt]?
}

struct NextStepBetaPendingSyncReview: Sendable {
    let summary: NextStepBetaSyncReview
    let conflict: ConflictRecord
    let localArchive: NextStepBetaArchive
    let syncedArchive: NextStepBetaArchive
    let localFingerprint: String
    let syncedFingerprint: String
}

struct NextStepBetaSyncAdapterResult: Sendable {
    let archive: NextStepBetaArchive
    let didReplaceLocalArchive: Bool
    let report: SyncReport
    let pendingReview: NextStepBetaPendingSyncReview?
}

enum NextStepBetaImmutableMergeError: Error, Equatable, LocalizedError, Sendable {
    case conflictingUserResponse(UserResponseID)
    case conflictingCompletionEvidence(CompletionEvidenceID)
    case conflictingGroundingAudit(UUID)
    case conflictingGroundingCandidate(UUID)
    case conflictingConfirmedSourceDateFact(UUID)
    case conflictingGroundingEvidence(EvidenceLinkID)

    var errorDescription: String? {
        switch self {
        case .conflictingUserResponse(let id):
            "同步中發現相同 ID 但內容不同的作答紀錄：\(id)。已停止合併。"
        case .conflictingCompletionEvidence(let id):
            "同步中發現相同 ID 但內容不同的完成證據：\(id)。已停止合併。"
        case .conflictingGroundingAudit(let id):
            "同步中發現相同 ID 但內容不同的來源核對紀錄：\(id)。已停止合併。"
        case .conflictingGroundingCandidate(let id):
            "同步中發現同一來源候選已有不同核對結果：\(id)。已停止合併。"
        case .conflictingConfirmedSourceDateFact(let id):
            "同步中發現相同 ID 但內容不同的已確認日期事實：\(id)。已停止合併。"
        case .conflictingGroundingEvidence(let id):
            "同步中發現相同 ID 但內容不同的來源核對證據：\(id)。已停止合併。"
        }
    }
}

enum NextStepBetaCompletionDependencySyncError: Error, Equatable, LocalizedError, Sendable {
    case localWorkspaceRequiresReview

    var errorDescription: String? {
        switch self {
        case .localWorkspaceRequiresReview:
            "遠端包含不可變的任務完成紀錄，但這個裝置的本機工作區缺少對應任務或學習包。"
                + "本機已有資料，為避免覆蓋尚未合併的內容，本次同步已停止。"
        }
    }
}

/// Maps the Beta's structured JSON snapshot onto NextStepSync's immutable
/// operation log. The archive itself is a content-addressed blob selected by
/// deterministic HLC LWW, while user-confirmed hard deadlines are published as
/// a separate `.confirmed` field. Consequently a whole-snapshot winner can never
/// be applied while a deadline conflict is unresolved. Imported files are one
/// immutable blob per SourceDocument ID and are materialized only after both the
/// transport digest and SourceDocument SHA-256 match.
///
/// V1 intentionally synchronizes at launch, after a local atomic save, and when
/// the user taps Sync. It does not claim push delivery or merge arbitrary
/// concurrent JSON fields. When the complete mutable base and grounding batches
/// are identical, immutable execution records plus source-fact review audits,
/// ordinary confirmed dates, and their dedicated evidence are conservatively
/// unioned by ID before HLC convergence. Candidate or ID mismatches fail closed.
/// A confirmed deadline changes the mutable goal/replan base and is therefore
/// never auto-merged through this path; structurally different workspaces keep
/// the existing deadline-review and whole-snapshot LWW behavior.
struct NextStepBetaSyncArchiveAdapter: Sendable {
    private static let maximumImmutableMergeRounds = 4
    private static let workspaceUUID = UUID(
        uuidString: "0f8d9ea7-d17d-4f09-b566-09e3a3ec17b1"
    )!

    let engine: NextStepSyncEngine
    let store: NextStepBetaStore

    private enum ImmutableExecutionOperation {
        case completion(NextStepBetaGuidedActionCompletionOperation)
        case actionReplan(NextStepBetaActionReplanOperationV1)

        var occurredAt: Date {
            switch self {
            case .completion(let operation): operation.completedAt
            case .actionReplan(let operation): operation.occurredAt
            }
        }

        var operationID: OperationID {
            switch self {
            case .completion(let operation): operation.operationID
            case .actionReplan(let operation): operation.operationID
            }
        }

        var producedDecisionID: PlanningDecisionID {
            switch self {
            case .completion(let operation): operation.planningDecisionID
            case .actionReplan(let operation): operation.decisionID
            }
        }

        var previousDecisionID: PlanningDecisionID? {
            switch self {
            case .completion: nil
            case .actionReplan(let operation): operation.previousDecisionID
            }
        }

        /// A replan is replayed before an otherwise unrelated completion at
        /// the same timestamp. Completion operations are context-adaptive,
        /// while a replan binds its exact previous decision and proposal.
        var stableTypeRank: Int {
            switch self {
            case .actionReplan: 0
            case .completion: 1
            }
        }
    }

    func reconcileInitial(
        localArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncAdapterResult {
        let snapshotBeforeInitialSync = try await engine.snapshot()
        try await enqueueCompletionOperationsIfNeeded(in: snapshotBeforeInitialSync)
        try await enqueueActionReplanOperationsIfNeeded(in: snapshotBeforeInitialSync)
        var report = try await engine.synchronize()
        var snapshot = try await engine.snapshot()
        try await markPublishedCompletionOperations(in: snapshot, publishedAt: now)
        try await markPublishedActionReplanOperations(in: snapshot, publishedAt: now)
        let rawSyncedArchive = try await winningArchive(
            in: snapshot,
            localDeviceID: localArchive.deviceID
        )

        guard let rawSyncedArchive else {
            try await enqueueFullArchive(localArchive, in: snapshot, includeDeadline: true)
            report = try await engine.synchronize()
            return try await resultAfterSynchronization(
                localArchive: localArchive,
                report: report,
                now: now
            )
        }

        if let pending = try await pendingReview(
            localArchive: localArchive,
            fallbackSyncedArchive: rawSyncedArchive,
            snapshot: snapshot
        ) {
            return .init(
                archive: localArchive,
                didReplaceLocalArchive: false,
                report: report,
                pendingReview: pending
            )
        }

        let completionOperations = try await completionOperations(in: snapshot)
        let actionReplanOperations = try await actionReplanOperations(in: snapshot)
        let archivedHistory = try await archivedCandidates(
            in: snapshot,
            localDeviceID: localArchive.deviceID
        )
        try Self.rejectUnprojectedCompetingActionOperations(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations,
            projectedArchives: [localArchive, rawSyncedArchive] + archivedHistory
        )
        let localHasCompletionDependencies = hasCompletionReplayDependencies(
            completionOperations,
            in: localArchive
        )
        let localHasActionReplanDependencies = hasActionReplanDependencies(
            actionReplanOperations,
            in: localArchive
        )
        let syncedArchive = try replayExecutionOperations(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations,
            onto: rawSyncedArchive
        )
        let localCanReplayAllOperations =
            localHasCompletionDependencies && localHasActionReplanDependencies
        let effectiveLocalArchive = localCanReplayAllOperations
            ? try await persistExecutionOverlay(
                completionOperations: completionOperations,
                actionReplanOperations: actionReplanOperations,
                onto: localArchive,
                replacing: localArchive,
                now: now
            )
            : localArchive

        let localMeaningful = Self.containsUserData(effectiveLocalArchive)
        let syncedMeaningful = Self.containsUserData(syncedArchive)
        if localMeaningful && syncedMeaningful,
           try Self.deadlineFingerprint(effectiveLocalArchive)
            != Self.deadlineFingerprint(syncedArchive) {
            try await enqueueProtectedDeadlineIfNeeded(effectiveLocalArchive, in: snapshot)
            report = try await engine.synchronize()
            snapshot = try await engine.snapshot()
            guard let pending = try await pendingReview(
                localArchive: effectiveLocalArchive,
                fallbackSyncedArchive: syncedArchive,
                snapshot: snapshot
            ) else {
                throw NextStepSyncError.malformedDocument(
                    "A protected deadline mismatch did not produce a review record."
                )
            }
            return .init(
                archive: effectiveLocalArchive,
                didReplaceLocalArchive: false,
                report: report,
                pendingReview: pending
            )
        }

        if (completionOperations.isEmpty == false
                && localHasCompletionDependencies == false)
            || (actionReplanOperations.isEmpty == false
                && localHasActionReplanDependencies == false) {
            guard Self.isPristineArchive(effectiveLocalArchive) else {
                if localHasCompletionDependencies == false {
                    throw NextStepBetaCompletionDependencySyncError
                        .localWorkspaceRequiresReview
                }
                throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                    .actionChanged
                )
            }
            let installedArchive = try await installAndSaveExecutionOverlay(
                syncedArchive,
                replacing: effectiveLocalArchive,
                snapshot: snapshot,
                completionOperations: completionOperations,
                actionReplanOperations: actionReplanOperations,
                now: now
            )
            return .init(
                archive: installedArchive,
                didReplaceLocalArchive: true,
                report: report,
                pendingReview: nil
            )
        }

        if let mergedArchive = try await mergedImmutableExecutionHistory(
            localArchive: effectiveLocalArchive,
            winningArchive: syncedArchive,
            snapshot: snapshot,
            now: now
        ) {
            try await store.save(mergedArchive, replacing: effectiveLocalArchive)
            try await enqueueFullArchive(
                mergedArchive,
                in: snapshot,
                includeDeadline: true
            )
            report = try await engine.synchronize()
            return try await resultAfterSynchronization(
                localArchive: mergedArchive,
                report: report,
                now: now,
                immutableMergeRound: 1
            )
        }

        if localMeaningful && !syncedMeaningful {
            try await enqueueFullArchive(
                effectiveLocalArchive,
                in: snapshot,
                includeDeadline: true
            )
            report = try await engine.synchronize()
            return try await resultAfterSynchronization(
                localArchive: effectiveLocalArchive,
                report: report,
                now: now
            )
        }

        if !localMeaningful && syncedMeaningful {
            try await installAndSave(
                syncedArchive,
                replacing: effectiveLocalArchive,
                snapshot: snapshot
            )
            return .init(
                archive: syncedArchive,
                didReplaceLocalArchive: true,
                report: report,
                pendingReview: nil
            )
        }

        let localData = try Self.encodePayload(effectiveLocalArchive)
        let syncedData = try Self.encodePayload(syncedArchive)
        guard SyncDigest(data: localData) != SyncDigest(data: syncedData) else {
            return .init(
                archive: effectiveLocalArchive,
                didReplaceLocalArchive: false,
                report: report,
                pendingReview: nil
            )
        }

        if Self.archivePrecedes(syncedArchive, effectiveLocalArchive) {
            try await enqueueFullArchive(
                effectiveLocalArchive,
                in: snapshot,
                includeDeadline: true
            )
            report = try await engine.synchronize()
            return try await resultAfterSynchronization(
                localArchive: effectiveLocalArchive,
                report: report,
                now: now
            )
        }

        try await installAndSave(
            syncedArchive,
            replacing: effectiveLocalArchive,
            snapshot: snapshot
        )
        return .init(
            archive: syncedArchive,
            didReplaceLocalArchive: true,
            report: report,
            pendingReview: nil
        )
    }

    func publishLocalAndSynchronize(
        _ localArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncAdapterResult {
        let snapshot = try await engine.snapshot()
        try await enqueueFullArchive(localArchive, in: snapshot, includeDeadline: true)
        let report = try await engine.synchronize()
        return try await resultAfterSynchronization(
            localArchive: localArchive,
            report: report,
            now: now
        )
    }

    private func resultAfterSynchronization(
        localArchive: NextStepBetaArchive,
        report: SyncReport,
        now: Date,
        immutableMergeRound: Int = 0
    ) async throws -> NextStepBetaSyncAdapterResult {
        let snapshot = try await engine.snapshot()
        try await markPublishedCompletionOperations(in: snapshot, publishedAt: now)
        try await markPublishedActionReplanOperations(in: snapshot, publishedAt: now)
        let rawWinner = try await winningArchive(
            in: snapshot,
            localDeviceID: localArchive.deviceID
        )
        if let pending = try await pendingReview(
            localArchive: localArchive,
            fallbackSyncedArchive: rawWinner ?? localArchive,
            snapshot: snapshot
        ) {
            return .init(
                archive: localArchive,
                didReplaceLocalArchive: false,
                report: report,
                pendingReview: pending
            )
        }

        guard let rawWinner else {
            throw NextStepSyncError.malformedDocument("The synchronized archive head is missing.")
        }
        let completionOperations = try await completionOperations(in: snapshot)
        let actionReplanOperations = try await actionReplanOperations(in: snapshot)
        let archivedHistory = try await archivedCandidates(
            in: snapshot,
            localDeviceID: localArchive.deviceID
        )
        try Self.rejectUnprojectedCompetingActionOperations(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations,
            projectedArchives: [localArchive, rawWinner] + archivedHistory
        )
        let localHasCompletionDependencies = hasCompletionReplayDependencies(
            completionOperations,
            in: localArchive
        )
        let localHasActionReplanDependencies = hasActionReplanDependencies(
            actionReplanOperations,
            in: localArchive
        )
        let winner = try replayExecutionOperations(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations,
            onto: rawWinner
        )
        let localCanReplayAllOperations =
            localHasCompletionDependencies && localHasActionReplanDependencies
        let effectiveLocalArchive = localCanReplayAllOperations
            ? try await persistExecutionOverlay(
                completionOperations: completionOperations,
                actionReplanOperations: actionReplanOperations,
                onto: localArchive,
                replacing: localArchive,
                now: now
            )
            : localArchive

        if (completionOperations.isEmpty == false
                && localHasCompletionDependencies == false)
            || (actionReplanOperations.isEmpty == false
                && localHasActionReplanDependencies == false) {
            guard Self.isPristineArchive(effectiveLocalArchive) else {
                if localHasCompletionDependencies == false {
                    throw NextStepBetaCompletionDependencySyncError
                        .localWorkspaceRequiresReview
                }
                throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                    .actionChanged
                )
            }
            let installedArchive = try await installAndSaveExecutionOverlay(
                winner,
                replacing: effectiveLocalArchive,
                snapshot: snapshot,
                completionOperations: completionOperations,
                actionReplanOperations: actionReplanOperations,
                now: now
            )
            return .init(
                archive: installedArchive,
                didReplaceLocalArchive: true,
                report: report,
                pendingReview: nil
            )
        }
        if let mergedArchive = try await mergedImmutableExecutionHistory(
            localArchive: effectiveLocalArchive,
            winningArchive: winner,
            snapshot: snapshot,
            now: now
        ) {
            guard immutableMergeRound < Self.maximumImmutableMergeRounds else {
                throw NextStepSyncError.malformedDocument(
                    "Immutable execution-record merge did not converge."
                )
            }
            try await store.save(mergedArchive, replacing: effectiveLocalArchive)
            try await enqueueFullArchive(
                mergedArchive,
                in: snapshot,
                includeDeadline: true
            )
            let mergedReport = try await engine.synchronize()
            return try await resultAfterSynchronization(
                localArchive: mergedArchive,
                report: mergedReport,
                now: now,
                immutableMergeRound: immutableMergeRound + 1
            )
        }
        let localData = try Self.encodePayload(effectiveLocalArchive)
        let winnerData = try Self.encodePayload(winner)
        if SyncDigest(data: localData) == SyncDigest(data: winnerData) {
            return .init(
                archive: effectiveLocalArchive,
                didReplaceLocalArchive: false,
                report: report,
                pendingReview: nil
            )
        }
        try await installAndSave(
            winner,
            replacing: effectiveLocalArchive,
            snapshot: snapshot
        )
        return .init(
            archive: winner,
            didReplaceLocalArchive: true,
            report: report,
            pendingReview: nil
        )
    }

    func resolve(
        _ pending: NextStepBetaPendingSyncReview,
        useSyncedArchive: Bool,
        now: Date
    ) async throws -> NextStepBetaSyncAdapterResult {
        guard pending.summary.kind == .protectedDeadline else {
            throw NextStepSyncError.unresolvedConflict(pending.conflict.id.description)
        }
        let chosenArchive = useSyncedArchive
            ? pending.syncedArchive
            : pending.localArchive
        let chosenFingerprint = useSyncedArchive
            ? pending.syncedFingerprint
            : pending.localFingerprint
        guard let chosenRevision = pending.conflict.contenders.first(where: {
            $0.value == .string(chosenFingerprint)
        }) else {
            throw NextStepSyncError.malformedDocument(
                "The selected deadline is not one of the protected contenders."
            )
        }

        // Preserve merge-safe immutable history before resolving the external
        // protected field. Once the contender is selected, the losing archive
        // head may no longer be discoverable as the current value.
        let snapshotBeforeResolution = try await engine.snapshot()
        let operationsBeforeResolution = try await completionOperations(
            in: snapshotBeforeResolution
        )
        let replansBeforeResolution = try await actionReplanOperations(
            in: snapshotBeforeResolution
        )
        let archivedHistory = try await archivedCandidates(
            in: snapshotBeforeResolution,
            localDeviceID: chosenArchive.deviceID
        )
        try Self.rejectUnprojectedCompetingActionOperations(
            completionOperations: operationsBeforeResolution,
            actionReplanOperations: replansBeforeResolution,
            projectedArchives: [
                chosenArchive,
                pending.localArchive,
                pending.syncedArchive
            ] + archivedHistory
        )
        guard hasCompletionReplayDependencies(
            operationsBeforeResolution,
            in: chosenArchive
        ) else {
            // Carry-forward includes immutable responses and evidence. Validate
            // their Action/Package graph against the side the user selected
            // before attempting that merge, so an incompatible local choice
            // fails with the actionable dependency-review error instead of a
            // lower-level archive-validation failure.
            throw NextStepBetaCompletionDependencySyncError
                .localWorkspaceRequiresReview
        }
        guard hasActionReplanDependencies(
            replansBeforeResolution,
            in: chosenArchive
        ) else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                .actionChanged
            )
        }
        let resolvedArchive = try Self.carryForwardMergeSafeRecords(
            onto: chosenArchive,
            from: [pending.localArchive, pending.syncedArchive] + archivedHistory,
            now: now
        )
        guard hasCompletionReplayDependencies(
            operationsBeforeResolution,
            in: resolvedArchive
        ) else {
            // The protected conflict is intentionally left unresolved. Choosing
            // the local deadline does not authorize replacing a meaningful
            // local workspace with an unrelated operation dependency graph.
            throw NextStepBetaCompletionDependencySyncError
                .localWorkspaceRequiresReview
        }
        guard hasActionReplanDependencies(
            replansBeforeResolution,
            in: resolvedArchive
        ) else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                .actionChanged
            )
        }
        let preflightResolvedArchive = try replayExecutionOperations(
            completionOperations: operationsBeforeResolution,
            actionReplanOperations: replansBeforeResolution,
            onto: resolvedArchive
        )

        _ = try await engine.resolveConflict(
            pending.conflict.id,
            choosing: chosenRevision.operationID,
            entity: pending.conflict.entity
        )
        let snapshotBeforeArchive = try await engine.snapshot()
        try await enqueueFullArchive(
            preflightResolvedArchive,
            in: snapshotBeforeArchive,
            includeDeadline: false
        )
        let report = try await engine.synchronize()
        let finalSnapshot = try await engine.snapshot()
        let deadlineField = try Self.deadlineField()
        if finalSnapshot.conflicts.contains(where: {
            $0.field == deadlineField && $0.status == .unresolved
        }) {
            throw NextStepSyncError.unresolvedConflict(pending.conflict.id.description)
        }

        if let remainingReview = try await pendingReview(
            localArchive: preflightResolvedArchive,
            fallbackSyncedArchive: preflightResolvedArchive,
            snapshot: finalSnapshot
        ) {
            return .init(
                archive: preflightResolvedArchive,
                didReplaceLocalArchive: false,
                report: report,
                pendingReview: remainingReview
            )
        }

        let completionOperations = try await completionOperations(in: finalSnapshot)
        let actionReplanOperations = try await actionReplanOperations(in: finalSnapshot)
        let finalArchivedHistory = try await archivedCandidates(
            in: finalSnapshot,
            localDeviceID: preflightResolvedArchive.deviceID
        )
        try Self.rejectUnprojectedCompetingActionOperations(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations,
            projectedArchives: [preflightResolvedArchive] + finalArchivedHistory
        )
        guard hasCompletionReplayDependencies(
            completionOperations,
            in: preflightResolvedArchive
        ) else {
            throw NextStepBetaCompletionDependencySyncError
                .localWorkspaceRequiresReview
        }
        guard hasActionReplanDependencies(
            actionReplanOperations,
            in: preflightResolvedArchive
        ) else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                .actionChanged
            )
        }
        let effectiveResolvedArchive = try replayExecutionOperations(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations,
            onto: preflightResolvedArchive
        )

        let persistedArchive: NextStepBetaArchive
        if useSyncedArchive {
            persistedArchive = try await installAndSaveExecutionOverlay(
                effectiveResolvedArchive,
                replacing: pending.localArchive,
                snapshot: finalSnapshot,
                completionOperations: completionOperations,
                actionReplanOperations: actionReplanOperations,
                now: now
            )
        } else if completionOperations.isEmpty && actionReplanOperations.isEmpty {
            try await store.save(
                effectiveResolvedArchive,
                replacing: pending.localArchive
            )
            persistedArchive = effectiveResolvedArchive
        } else {
            // Conflict-history carry-forward may have added immutable records
            // that cannot be reproduced by replaying the completion operation
            // against pending.localArchive alone. Persist that fully validated
            // projection first, then repair the operation ledgers idempotently
            // against the exact same archive. A crash between these two writes
            // is recoverable because the remote operation remains immutable.
            try await store.save(
                effectiveResolvedArchive,
                replacing: pending.localArchive
            )
            persistedArchive = try await persistExecutionOverlay(
                completionOperations: completionOperations,
                actionReplanOperations: actionReplanOperations,
                onto: effectiveResolvedArchive,
                replacing: effectiveResolvedArchive,
                now: now
            )
        }
        return .init(
            archive: persistedArchive,
            didReplaceLocalArchive: useSyncedArchive,
            report: report,
            pendingReview: nil
        )
    }

    private func enqueueFullArchive(
        _ archive: NextStepBetaArchive,
        in snapshot: SyncSnapshot,
        includeDeadline: Bool
    ) async throws {
        try await enqueueCompletionOperationsIfNeeded(in: snapshot)
        try await enqueueActionReplanOperationsIfNeeded(in: snapshot)
        try await enqueueSourcesIfNeeded(archive, in: snapshot)
        try await enqueueArchiveIfNeeded(archive, in: snapshot)
        if includeDeadline {
            try await enqueueProtectedDeadlineIfNeeded(archive, in: snapshot)
        }
    }

    private func enqueueCompletionOperationsIfNeeded(
        in snapshot: SyncSnapshot
    ) async throws {
        // Read the durable applied ledger, not only the pending outbox. A user
        // may select a new sync destination after an earlier destination
        // acknowledged publication; immutable operations must remain repairable.
        let field = try Self.completionOperationField()
        var afterAppliedAt: Date?
        var afterOperationID: OperationID?
        while true {
            let page = try await store.storedCompletionOperations(
                afterAppliedAt: afterAppliedAt,
                afterOperationID: afterOperationID
            )
            for item in page {
                let entity = try Self.completionEntity(item.operation.actionID.rawValue)
                let digest = SyncDigest(data: item.canonicalData)
                let history = snapshot.entity(entity)?.field(field)?.history ?? []
                if history.contains(where: { revision in
                    guard case .blob(let reference) = revision.value else { return false }
                    return reference.digest == digest
                }) {
                    continue
                }
                _ = try await engine.enqueueBlob(
                    entity: entity,
                    field: field,
                    data: item.canonicalData,
                    mediaType: "application/vnd.nextstep.guided-action-completion+json",
                    policy: .immutable
                )
            }
            guard page.count == NextStepBetaStore.completionOperationPageSize,
                  let last = page.last else { return }
            afterAppliedAt = last.createdAt
            afterOperationID = last.operation.operationID
        }
    }

    private func markPublishedCompletionOperations(
        in snapshot: SyncSnapshot,
        publishedAt: Date
    ) async throws {
        let pending = try await store.pendingCompletionOperations()
        let field = try Self.completionOperationField()
        for item in pending {
            let entity = try Self.completionEntity(item.operation.actionID.rawValue)
            let digest = SyncDigest(data: item.canonicalData)
            let history = snapshot.entity(entity)?.field(field)?.history ?? []
            guard history.contains(where: { revision in
                guard case .blob(let reference) = revision.value else { return false }
                return reference.digest == digest
            }) else { continue }
            try await store.markCompletionOperationPublished(
                item.operation,
                publishedAt: max(publishedAt, item.createdAt)
            )
        }
    }

    private func completionOperations(
        in snapshot: SyncSnapshot
    ) async throws -> [NextStepBetaGuidedActionCompletionOperation] {
        let entityKind = try Self.completionEntityKind()
        let field = try Self.completionOperationField()
        var byID: [OperationID: NextStepBetaGuidedActionCompletionOperation] = [:]
        for entity in snapshot.entities where entity.reference.kind == entityKind {
            if snapshot.conflicts.contains(where: {
                $0.entity == entity.reference
                    && $0.field == field
                    && $0.status == .unresolved
            }) {
                throw NextStepSyncError.unresolvedConflict(
                    entity.reference.id.uuidString.lowercased()
                )
            }
            guard case .blob(let reference)? = entity.field(field)?.value,
                  let data = try await engine.blobData(for: reference) else {
                throw NextStepSyncError.malformedDocument(
                    "A guided-action completion payload is missing."
                )
            }
            let operation = try NextStepBetaGuidedActionCompletionOperation
                .decodeCanonical(from: data)
            guard operation.actionID.rawValue == entity.reference.id else {
                throw NextStepSyncError.malformedDocument(
                    "A guided-action completion entity does not match its action."
                )
            }
            if let existing = byID[operation.operationID], existing != operation {
                throw NextStepSyncError.malformedDocument(
                    "A guided-action completion operation ID has multiple payloads."
                )
            }
            byID[operation.operationID] = operation
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.completedAt != rhs.completedAt {
                return lhs.completedAt < rhs.completedAt
            }
            return lhs.operationID < rhs.operationID
        }
    }

    private func hasCompletionReplayDependencies(
        _ operations: [NextStepBetaGuidedActionCompletionOperation],
        in archive: NextStepBetaArchive
    ) -> Bool {
        let actionIDs = Set(archive.workspace.dailyActions.map(\.metadata.id))
        let packageIDs = Set(archive.workspace.guidedPackages.map(\.metadata.id))
        return operations.allSatisfy {
            actionIDs.contains($0.actionID) && packageIDs.contains($0.packageID)
        }
    }

    private func enqueueActionReplanOperationsIfNeeded(
        in snapshot: SyncSnapshot
    ) async throws {
        let field = try Self.actionReplanOperationField()
        var afterAppliedAt: Date?
        var afterOperationID: OperationID?
        while true {
            let page = try await store.storedActionReplanOperations(
                afterAppliedAt: afterAppliedAt,
                afterOperationID: afterOperationID
            )
            for item in page {
                let entity = try Self.actionReplanEntity(
                    item.operation.operationID.rawValue
                )
                let digest = SyncDigest(data: item.canonicalData)
                let history = snapshot.entity(entity)?.field(field)?.history ?? []
                if history.contains(where: { revision in
                    guard case .blob(let reference) = revision.value else { return false }
                    return reference.digest == digest
                }) {
                    continue
                }
                _ = try await engine.enqueueBlob(
                    entity: entity,
                    field: field,
                    data: item.canonicalData,
                    mediaType: "application/vnd.nextstep.action-replan+json",
                    policy: .immutable
                )
            }
            guard page.count == NextStepBetaStore.actionReplanOperationPageSize,
                  let last = page.last else { return }
            afterAppliedAt = last.createdAt
            afterOperationID = last.operation.operationID
        }
    }

    private func markPublishedActionReplanOperations(
        in snapshot: SyncSnapshot,
        publishedAt: Date
    ) async throws {
        let pending = try await store.pendingActionReplanOperations()
        let field = try Self.actionReplanOperationField()
        for item in pending {
            let entity = try Self.actionReplanEntity(
                item.operation.operationID.rawValue
            )
            let digest = SyncDigest(data: item.canonicalData)
            let history = snapshot.entity(entity)?.field(field)?.history ?? []
            guard history.contains(where: { revision in
                guard case .blob(let reference) = revision.value else { return false }
                return reference.digest == digest
            }) else { continue }
            try await store.markActionReplanOperationPublished(
                item.operation,
                publishedAt: max(publishedAt, item.createdAt)
            )
        }
    }

    private func actionReplanOperations(
        in snapshot: SyncSnapshot
    ) async throws -> [NextStepBetaActionReplanOperationV1] {
        let entityKind = try Self.actionReplanEntityKind()
        let field = try Self.actionReplanOperationField()
        var byID: [OperationID: NextStepBetaActionReplanOperationV1] = [:]
        for entity in snapshot.entities where entity.reference.kind == entityKind {
            if snapshot.conflicts.contains(where: {
                $0.entity == entity.reference
                    && $0.field == field
                    && $0.status == .unresolved
            }) {
                throw NextStepSyncError.unresolvedConflict(
                    entity.reference.id.uuidString.lowercased()
                )
            }
            guard case .blob(let reference)? = entity.field(field)?.value,
                  let data = try await engine.blobData(for: reference) else {
                throw NextStepSyncError.malformedDocument(
                    "An action-replan operation payload is missing."
                )
            }
            let operation = try NextStepBetaActionReplanOperationV1
                .decodeCanonical(from: data)
            guard operation.operationID.rawValue == entity.reference.id else {
                throw NextStepSyncError.malformedDocument(
                    "An action-replan entity does not match its operation."
                )
            }
            if let existing = byID[operation.operationID], existing != operation {
                throw NextStepSyncError.malformedDocument(
                    "An action-replan operation ID has multiple payloads."
                )
            }
            byID[operation.operationID] = operation
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt {
                return lhs.occurredAt < rhs.occurredAt
            }
            return lhs.operationID < rhs.operationID
        }
    }

    private func hasActionReplanDependencies(
        _ operations: [NextStepBetaActionReplanOperationV1],
        in archive: NextStepBetaArchive
    ) -> Bool {
        let actionIDs = Set(archive.workspace.dailyActions.map(\.metadata.id))
        return operations.allSatisfy { actionIDs.contains($0.actionID) }
    }

    private func orderedExecutionOperations(
        completionOperations: [NextStepBetaGuidedActionCompletionOperation],
        actionReplanOperations: [NextStepBetaActionReplanOperationV1]
    ) throws -> [ImmutableExecutionOperation] {
        let all = completionOperations.map(ImmutableExecutionOperation.completion)
            + actionReplanOperations.map(ImmutableExecutionOperation.actionReplan)
        guard Set(all.map(\.operationID)).count == all.count else {
            throw NextStepSyncError.malformedDocument(
                "Immutable execution operation IDs must be unique across payload kinds."
            )
        }
        var ordered: [ImmutableExecutionOperation] = []
        ordered.reserveCapacity(all.count)
        var remaining = Set(all.indices)
        var dependencies: [Int: Set<Int>] = [:]
        for targetIndex in all.indices {
            guard let previousDecisionID = all[targetIndex].previousDecisionID else {
                continue
            }
            for sourceIndex in all.indices
                where all[sourceIndex].producedDecisionID == previousDecisionID {
                dependencies[targetIndex, default: []].insert(sourceIndex)
            }
        }

        while remaining.isEmpty == false {
            let next = remaining
                .filter { index in
                    dependencies[index, default: []].isDisjoint(with: remaining)
                }
                .sorted { lhs, rhs in
                    let left = all[lhs]
                    let right = all[rhs]
                    if left.occurredAt != right.occurredAt {
                        return left.occurredAt < right.occurredAt
                    }
                    if left.stableTypeRank != right.stableTypeRank {
                        return left.stableTypeRank < right.stableTypeRank
                    }
                    return left.operationID < right.operationID
                }
                .first
            guard let next else {
                throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                    .planningContextChanged
                )
            }
            ordered.append(all[next])
            remaining.remove(next)
        }
        return ordered
    }

    private func replayExecutionOperations(
        completionOperations: [NextStepBetaGuidedActionCompletionOperation],
        actionReplanOperations: [NextStepBetaActionReplanOperationV1],
        onto archive: NextStepBetaArchive
    ) throws -> NextStepBetaArchive {
        var result = archive
        for operation in try orderedExecutionOperations(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations
        ) {
            switch operation {
            case .completion(let value):
                result = try NextStepBetaCompletionOperationReducer()
                    .replay(value, in: result)
                    .archive
            case .actionReplan(let value):
                result = try NextStepBetaActionReplanOperationReducer()
                    .replay(value, in: result)
                    .archive
            }
        }
        return result
    }

    private func persistExecutionOverlay(
        completionOperations: [NextStepBetaGuidedActionCompletionOperation],
        actionReplanOperations: [NextStepBetaActionReplanOperationV1],
        onto archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaArchive {
        let ordered = try orderedExecutionOperations(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations
        )
        guard ordered.isEmpty == false else { return archive }

        // Complete the entire pure replay before the durable transaction. This
        // keeps a later replan-context failure from committing only the earlier
        // half of a mixed completion/replan stream.
        let preflight = try replayExecutionOperations(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations,
            onto: archive
        )
        let durableOperations = ordered.map { operation in
            switch operation {
            case .completion(let value):
                NextStepBetaSyncedExecutionOperation.completion(value)
            case .actionReplan(let value):
                NextStepBetaSyncedExecutionOperation.actionReplan(value)
            }
        }
        try await store.applySyncedExecutionOperations(
            to: preflight,
            replacing: expectedArchive,
            operations: durableOperations,
            receivedAt: now,
            appliedAt: now
        )
        return preflight
    }

    /// Completion and deferral are both immutable intents, but their mutable
    /// projections cannot be partially interleaved. If the same action appears
    /// in both ledgers, continue only when at least one validated archive
    /// already contains the complete receipt set. Otherwise stop before either
    /// overlay is persisted and let the user review the competing intent.
    private static func rejectUnprojectedCompetingActionOperations(
        completionOperations: [NextStepBetaGuidedActionCompletionOperation],
        actionReplanOperations: [NextStepBetaActionReplanOperationV1],
        projectedArchives: [NextStepBetaArchive]
    ) throws {
        let completionActionIDs = Set(completionOperations.map(\.actionID))
        let replanActionIDs = Set(actionReplanOperations.map(\.actionID))
        for actionID in completionActionIDs.intersection(replanActionIDs) {
            let completionOperationIDs = Set(
                completionOperations
                    .filter { $0.actionID == actionID }
                    .map(\.operationID)
            )
            let replanOperationIDs = Set(
                actionReplanOperations
                    .filter { $0.actionID == actionID }
                    .map(\.operationID)
            )
            let hasCompleteProjection = projectedArchives.contains { archive in
                let completed = Set(
                    archive.completionApplicationReceipts
                        .filter { $0.actionID == actionID }
                        .map(\.operationID)
                )
                let replanned = Set(
                    archive.actionReplanApplicationReceipts
                        .filter { $0.actionID == actionID }
                        .map(\.operationID)
                )
                return completionOperationIDs.isSubset(of: completed)
                    && replanOperationIDs.isSubset(of: replanned)
            }
            guard hasCompleteProjection else {
                throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                    .actionChanged
                )
            }
        }
    }

    private func enqueueArchiveIfNeeded(
        _ archive: NextStepBetaArchive,
        in snapshot: SyncSnapshot
    ) async throws {
        let data = try Self.encodePayload(archive)
        let digest = SyncDigest(data: data)
        let entity = try Self.workspaceEntity()
        let field = try Self.archiveField()
        if case .blob(let existing)? = snapshot.entity(entity)?.field(field)?.value,
           existing.digest == digest {
            return
        }
        _ = try await engine.enqueueBlob(
            entity: entity,
            field: field,
            data: data,
            mediaType: "application/vnd.nextstep.beta-archive+json",
            policy: .flexibleLastWriterWins
        )
    }

    private func enqueueProtectedDeadlineIfNeeded(
        _ archive: NextStepBetaArchive,
        in snapshot: SyncSnapshot
    ) async throws {
        let fingerprint = try Self.deadlineFingerprint(archive)
        guard Self.containsProtectedDeadline(archive) else { return }
        let entity = try Self.workspaceEntity()
        let field = try Self.deadlineField()
        if snapshot.entity(entity)?.field(field)?.value == .string(fingerprint) {
            return
        }
        _ = try await engine.enqueueSet(
            entity: entity,
            field: field,
            value: .string(fingerprint),
            policy: .confirmed
        )
    }

    private func enqueueSourcesIfNeeded(
        _ archive: NextStepBetaArchive,
        in snapshot: SyncSnapshot
    ) async throws {
        let field = try Self.sourceContentField()
        for document in archive.workspace.sourceDocuments {
            guard let relativePath = document.localRelativePath else { continue }
            guard let expectedSHA256 = document.contentSHA256,
                  expectedSHA256.isEmpty == false else {
                throw NextStepBetaStoreError.sourceIntegrityMismatch
            }
            let expectedDigest = try SyncDigest(validating: expectedSHA256)
            let entity = try Self.sourceEntity(document.metadata.id.rawValue)
            if case .blob(let existing)? = snapshot.entity(entity)?.field(field)?.value,
               existing.digest == expectedDigest {
                // The immutable source is already present in this sync
                // destination. A device resolving to the synced archive may
                // not have installed its local copy yet; do not require that
                // copy merely to republish an already-addressed remote blob.
                continue
            }
            let data = try await store.storedSourceData(relativePath: relativePath)
            let digest = SyncDigest(data: data)
            guard digest == expectedDigest else {
                throw NextStepBetaStoreError.sourceIntegrityMismatch
            }
            _ = try await engine.enqueueBlob(
                entity: entity,
                field: field,
                data: data,
                mediaType: Self.mediaType(for: relativePath),
                policy: .immutable
            )
        }
    }

    private func winningArchive(
        in snapshot: SyncSnapshot,
        localDeviceID: NextStepDomain.DeviceID
    ) async throws -> NextStepBetaArchive? {
        let entity = try Self.workspaceEntity()
        let field = try Self.archiveField()
        guard case .blob(let reference)? = snapshot.entity(entity)?.field(field)?.value,
              let data = try await engine.blobData(for: reference) else {
            return nil
        }
        return try Self.decodePayload(data, localDeviceID: localDeviceID)
    }

    private func archivedCandidates(
        in snapshot: SyncSnapshot,
        localDeviceID: NextStepDomain.DeviceID
    ) async throws -> [NextStepBetaArchive] {
        let entity = try Self.workspaceEntity()
        let field = try Self.archiveField()
        let revisions = snapshot.entity(entity)?.field(field)?.history ?? []
        var seen: Set<SyncDigest> = []
        var result: [NextStepBetaArchive] = []
        for revision in revisions.reversed() {
            guard case .blob(let reference) = revision.value,
                  seen.insert(reference.digest).inserted,
                  let data = try await engine.blobData(for: reference) else {
                continue
            }
            result.append(try Self.decodePayload(data, localDeviceID: localDeviceID))
        }
        return result
    }

    private func mergedImmutableExecutionHistory(
        localArchive: NextStepBetaArchive,
        winningArchive: NextStepBetaArchive,
        snapshot: SyncSnapshot,
        now: Date
    ) async throws -> NextStepBetaArchive? {
        let candidates = try await archivedCandidates(
            in: snapshot,
            localDeviceID: localArchive.deviceID
        )
        return try Self.mergeImmutableExecutionRecords(
            localArchive: localArchive,
            winningArchive: winningArchive,
            candidates: candidates,
            now: now
        )
    }

    /// Returns nil when the mutable base or grounding batches differ, or when no
    /// union is needed. This function never chooses between goal/action/replan
    /// mutations; confirmed deadlines therefore remain outside this merge path.
    static func mergeImmutableExecutionRecords(
        localArchive: NextStepBetaArchive,
        syncedArchive: NextStepBetaArchive,
        now: Date
    ) throws -> NextStepBetaArchive? {
        try mergeImmutableExecutionRecords(
            localArchive: localArchive,
            winningArchive: syncedArchive,
            candidates: [syncedArchive],
            now: now
        )
    }

    private static func mergeImmutableExecutionRecords(
        localArchive: NextStepBetaArchive,
        winningArchive: NextStepBetaArchive,
        candidates: [NextStepBetaArchive],
        now: Date
    ) throws -> NextStepBetaArchive? {
        let allCandidates = [localArchive, winningArchive] + candidates
        try assertNoGroundingRecordConflict(in: allCandidates)
        try assertNoImmutableExecutionRecordConflict(in: allCandidates)
        let baseDigest = try immutableExecutionBaseDigest(localArchive)
        guard try immutableExecutionBaseDigest(winningArchive) == baseDigest else {
            return nil
        }

        var responseByID = Dictionary(
            uniqueKeysWithValues: localArchive.workspace.userResponses.map {
                ($0.metadata.id, $0)
            }
        )
        var completionEvidenceByID = Dictionary(
            uniqueKeysWithValues: localArchive.workspace.completionEvidence.map {
                ($0.metadata.id, $0)
            }
        )
        var reviewAuditByID = Dictionary(
            uniqueKeysWithValues: mergeableReviewAudits(in: localArchive).map {
                ($0.id, $0)
            }
        )
        var reviewAuditByCandidateID = Dictionary(
            uniqueKeysWithValues: mergeableReviewAudits(in: localArchive).map {
                ($0.candidateID, $0)
            }
        )
        var confirmedFactByID = Dictionary(
            uniqueKeysWithValues: mergeableConfirmedDateFacts(in: localArchive).map {
                ($0.id, $0)
            }
        )
        var confirmedFactByCandidateID = Dictionary(
            uniqueKeysWithValues: mergeableConfirmedDateFacts(in: localArchive).map {
                ($0.candidateID, $0)
            }
        )
        var groundingEvidenceByID = Dictionary(
            uniqueKeysWithValues: mergeableGroundingEvidence(in: localArchive).map {
                ($0.metadata.id, $0)
            }
        )
        let localGroundingEvidenceIDs = mergeableGroundingEvidenceIDs(in: localArchive)
        let baseEvidence = localArchive.workspace.evidenceLinks.filter {
            localGroundingEvidenceIDs.contains($0.metadata.id) == false
        }
        let localMergeableAuditIDs = Set(mergeableReviewAudits(in: localArchive).map(\.id))
        let baseReviewAudits = localArchive.grounding.reviewAudits.filter {
            localMergeableAuditIDs.contains($0.id) == false
        }
        let localMergeableFactIDs = Set(
            mergeableConfirmedDateFacts(in: localArchive).map(\.id)
        )
        let baseConfirmedFacts = localArchive.grounding.confirmedDateFacts.filter {
            localMergeableFactIDs.contains($0.id) == false
        }
        var maximumRevision = localArchive.workspace.revision
        var maximumSavedAt = localArchive.workspace.savedAt
        let compatibleCandidates = [winningArchive] + candidates

        for candidate in compatibleCandidates {
            try candidate.validate()
            guard try immutableExecutionBaseDigest(candidate) == baseDigest else {
                continue
            }
            maximumRevision = max(maximumRevision, candidate.workspace.revision)
            maximumSavedAt = max(maximumSavedAt, candidate.workspace.savedAt)
            for response in candidate.workspace.userResponses {
                if let existing = responseByID[response.metadata.id], existing != response {
                    throw NextStepBetaImmutableMergeError.conflictingUserResponse(
                        response.metadata.id
                    )
                }
                responseByID[response.metadata.id] = response
            }
            for evidence in candidate.workspace.completionEvidence {
                if let existing = completionEvidenceByID[evidence.metadata.id],
                   existing != evidence {
                    throw NextStepBetaImmutableMergeError.conflictingCompletionEvidence(
                        evidence.metadata.id
                    )
                }
                completionEvidenceByID[evidence.metadata.id] = evidence
            }
            for audit in mergeableReviewAudits(in: candidate) {
                if let existing = reviewAuditByID[audit.id], existing != audit {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingAudit(audit.id)
                }
                if let existing = reviewAuditByCandidateID[audit.candidateID],
                   existing != audit {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingCandidate(
                        audit.candidateID
                    )
                }
                reviewAuditByID[audit.id] = audit
                reviewAuditByCandidateID[audit.candidateID] = audit
            }
            for fact in mergeableConfirmedDateFacts(in: candidate) {
                if let existing = confirmedFactByID[fact.id], existing != fact {
                    throw NextStepBetaImmutableMergeError.conflictingConfirmedSourceDateFact(
                        fact.id
                    )
                }
                if let existing = confirmedFactByCandidateID[fact.candidateID],
                   existing != fact {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingCandidate(
                        fact.candidateID
                    )
                }
                confirmedFactByID[fact.id] = fact
                confirmedFactByCandidateID[fact.candidateID] = fact
            }
            for evidence in mergeableGroundingEvidence(in: candidate) {
                if let existing = groundingEvidenceByID[evidence.metadata.id],
                   existing != evidence {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingEvidence(
                        evidence.metadata.id
                    )
                }
                groundingEvidenceByID[evidence.metadata.id] = evidence
            }
        }

        let mergedResponses = responseByID.values.sorted { $0.metadata.id < $1.metadata.id }
        let mergedCompletionEvidence = completionEvidenceByID.values.sorted {
            $0.metadata.id < $1.metadata.id
        }
        let mergedReviewAudits = reviewAuditByID.values.sorted {
            $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        let mergedConfirmedFacts = confirmedFactByID.values.sorted {
            $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        let mergedGroundingEvidence = groundingEvidenceByID.values.sorted {
            $0.metadata.id < $1.metadata.id
        }
        let winnerAlreadyContainsUnion =
            Set(winningArchive.workspace.userResponses) == Set(mergedResponses)
            && Set(winningArchive.workspace.completionEvidence)
                == Set(mergedCompletionEvidence)
            && Set(mergeableReviewAudits(in: winningArchive)) == Set(mergedReviewAudits)
            && Set(mergeableConfirmedDateFacts(in: winningArchive))
                == Set(mergedConfirmedFacts)
            && Set(mergeableGroundingEvidence(in: winningArchive))
                == Set(mergedGroundingEvidence)
        let localAlreadyContainsUnion =
            Set(localArchive.workspace.userResponses) == Set(mergedResponses)
            && Set(localArchive.workspace.completionEvidence)
                == Set(mergedCompletionEvidence)
            && Set(mergeableReviewAudits(in: localArchive)) == Set(mergedReviewAudits)
            && Set(mergeableConfirmedDateFacts(in: localArchive))
                == Set(mergedConfirmedFacts)
            && Set(mergeableGroundingEvidence(in: localArchive))
                == Set(mergedGroundingEvidence)
        guard winnerAlreadyContainsUnion == false || localAlreadyContainsUnion == false else {
            return nil
        }
        guard maximumRevision < Int64.max else {
            throw NextStepSyncError.malformedDocument(
                "Workspace revision overflow during immutable record merge."
            )
        }

        var mergedArchive = localArchive
        mergedArchive.workspace.userResponses = mergedResponses
        mergedArchive.workspace.completionEvidence = mergedCompletionEvidence
        mergedArchive.workspace.evidenceLinks = baseEvidence + mergedGroundingEvidence
        // Retained deadline records are part of the mutable-base preimage, so
        // preserve their relative order. Only the merge-safe union is sorted.
        // This keeps a second union eligible after the first one is published.
        mergedArchive.grounding.reviewAudits = baseReviewAudits + mergedReviewAudits
        mergedArchive.grounding.confirmedDateFacts = baseConfirmedFacts + mergedConfirmedFacts
        mergedArchive.workspace.revision = maximumRevision + 1
        mergedArchive.workspace.savedAt = max(now, maximumSavedAt)
        try mergedArchive.validate()
        return mergedArchive
    }

    /// Applies only immutable records that are safe across mutable-base
    /// differences. The selected archive remains authoritative for goals,
    /// actions, replans, and confirmed deadline facts. If any carried record
    /// cannot be validated against that base, the resolution stops before the
    /// sync conflict is mutated.
    private static func carryForwardMergeSafeRecords(
        onto chosenArchive: NextStepBetaArchive,
        from candidates: [NextStepBetaArchive],
        now: Date
    ) throws -> NextStepBetaArchive {
        let allCandidates = [chosenArchive] + candidates
        let groundingRecords = try resolveAwareGroundingRecords(
            chosenArchive: chosenArchive,
            candidates: candidates
        )
        try assertNoGroundingRecordCollision(in: groundingRecords)
        try assertNoImmutableExecutionRecordConflict(in: allCandidates)

        var responseByID: [UserResponseID: UserResponse] = [:]
        var completionEvidenceByID: [CompletionEvidenceID: CompletionEvidence] = [:]
        var reviewAuditByID: [UUID: SourceFactReviewAudit] = [:]
        var reviewAuditByCandidateID: [UUID: SourceFactReviewAudit] = [:]
        var confirmedFactByID: [UUID: ConfirmedSourceDateFact] = [:]
        var confirmedFactByCandidateID: [UUID: ConfirmedSourceDateFact] = [:]
        var groundingEvidenceByID: [EvidenceLinkID: EvidenceLink] = [:]
        var maximumRevision = chosenArchive.workspace.revision
        var maximumSavedAt = chosenArchive.workspace.savedAt

        for (archive, records) in zip(allCandidates, groundingRecords) {
            maximumRevision = max(maximumRevision, archive.workspace.revision)
            maximumSavedAt = max(maximumSavedAt, archive.workspace.savedAt)
            for response in archive.workspace.userResponses {
                responseByID[response.metadata.id] = response
            }
            for evidence in archive.workspace.completionEvidence {
                completionEvidenceByID[evidence.metadata.id] = evidence
            }
            for audit in mergeableReviewAudits(in: records) {
                if let existing = reviewAuditByID[audit.id], existing != audit {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingAudit(audit.id)
                }
                if let existing = reviewAuditByCandidateID[audit.candidateID],
                   existing != audit {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingCandidate(
                        audit.candidateID
                    )
                }
                reviewAuditByID[audit.id] = audit
                reviewAuditByCandidateID[audit.candidateID] = audit
            }
            for fact in mergeableConfirmedDateFacts(in: records) {
                if let existing = confirmedFactByID[fact.id], existing != fact {
                    throw NextStepBetaImmutableMergeError.conflictingConfirmedSourceDateFact(
                        fact.id
                    )
                }
                if let existing = confirmedFactByCandidateID[fact.candidateID],
                   existing != fact {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingCandidate(
                        fact.candidateID
                    )
                }
                confirmedFactByID[fact.id] = fact
                confirmedFactByCandidateID[fact.candidateID] = fact
            }
            for evidence in mergeableGroundingEvidence(in: records) {
                if let existing = groundingEvidenceByID[evidence.metadata.id],
                   existing != evidence {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingEvidence(
                        evidence.metadata.id
                    )
                }
                groundingEvidenceByID[evidence.metadata.id] = evidence
            }
        }

        let mergedResponses = responseByID.values.sorted { $0.metadata.id < $1.metadata.id }
        let mergedCompletionEvidence = completionEvidenceByID.values.sorted {
            $0.metadata.id < $1.metadata.id
        }
        let mergedReviewAudits = reviewAuditByID.values.sorted {
            $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        let mergedConfirmedFacts = confirmedFactByID.values.sorted {
            $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }
        let mergedGroundingEvidence = groundingEvidenceByID.values.sorted {
            $0.metadata.id < $1.metadata.id
        }
        let chosenGroundingRecords = groundingRecords[0]
        let chosenAlreadyContainsUnion =
            Set(chosenArchive.workspace.userResponses) == Set(mergedResponses)
            && Set(chosenArchive.workspace.completionEvidence)
                == Set(mergedCompletionEvidence)
            && Set(mergeableReviewAudits(in: chosenGroundingRecords))
                == Set(mergedReviewAudits)
            && Set(mergeableConfirmedDateFacts(in: chosenGroundingRecords))
                == Set(mergedConfirmedFacts)
            && Set(mergeableGroundingEvidence(in: chosenGroundingRecords))
                == Set(mergedGroundingEvidence)
        if chosenAlreadyContainsUnion {
            try chosenArchive.validate()
            return chosenArchive
        }
        guard maximumRevision < Int64.max else {
            throw NextStepSyncError.malformedDocument(
                "Workspace revision overflow during conflict-history carry-forward."
            )
        }

        let chosenGroundingEvidenceIDs = mergeableGroundingEvidenceIDs(
            in: chosenGroundingRecords
        )
        let chosenMergeableAuditIDs = Set(
            mergeableReviewAudits(in: chosenGroundingRecords).map(\.id)
        )
        let chosenMergeableFactIDs = Set(
            mergeableConfirmedDateFacts(in: chosenGroundingRecords).map(\.id)
        )
        var result = chosenArchive
        result.workspace.userResponses = mergedResponses
        result.workspace.completionEvidence = mergedCompletionEvidence
        result.workspace.evidenceLinks.removeAll {
            chosenGroundingEvidenceIDs.contains($0.metadata.id)
        }
        result.workspace.evidenceLinks.append(contentsOf: mergedGroundingEvidence)
        // Keep the chosen side's confirmed deadline records and their evidence
        // exactly as the mutable base selected by the user. Only non-deadline
        // rejections and confirmed ordinary-date records cross from a losing side.
        result.grounding.reviewAudits.removeAll {
            chosenMergeableAuditIDs.contains($0.id)
        }
        result.grounding.reviewAudits.append(contentsOf: mergedReviewAudits)
        result.grounding.confirmedDateFacts.removeAll {
            chosenMergeableFactIDs.contains($0.id)
        }
        result.grounding.confirmedDateFacts.append(contentsOf: mergedConfirmedFacts)
        result.workspace.revision = maximumRevision + 1
        result.workspace.savedAt = max(now, maximumSavedAt)
        try result.validate()
        return result
    }

    private static func assertNoImmutableExecutionRecordConflict(
        in archives: [NextStepBetaArchive]
    ) throws {
        var responseByID: [UserResponseID: UserResponse] = [:]
        var evidenceByID: [CompletionEvidenceID: CompletionEvidence] = [:]
        for archive in archives {
            for response in archive.workspace.userResponses {
                if let existing = responseByID[response.metadata.id], existing != response {
                    throw NextStepBetaImmutableMergeError.conflictingUserResponse(
                        response.metadata.id
                    )
                }
                responseByID[response.metadata.id] = response
            }
            for evidence in archive.workspace.completionEvidence {
                if let existing = evidenceByID[evidence.metadata.id], existing != evidence {
                    throw NextStepBetaImmutableMergeError.conflictingCompletionEvidence(
                        evidence.metadata.id
                    )
                }
                evidenceByID[evidence.metadata.id] = evidence
            }
        }
    }

    /// A protected-deadline resolution is the user's explicit choice between
    /// competing snapshots. Every unselected deadline-candidate outcome
    /// (including evidence used only by that outcome) must not veto the choice.
    /// The chosen deadline outcome and every merge-safe or cross-kind record
    /// remain collision checked before the combined archive is validated.
    private static func resolveAwareGroundingRecords(
        chosenArchive: NextStepBetaArchive,
        candidates: [NextStepBetaArchive]
    ) throws -> [NextStepBetaGroundingCollisionRecords] {
        let allCandidates = [chosenArchive] + candidates
        for archive in allCandidates {
            try archive.validate()
        }

        let chosenFactByID: [UUID: ConfirmedSourceDateFact] = Dictionary(
            uniqueKeysWithValues: chosenArchive.grounding.confirmedDateFacts.map {
                ($0.id, $0)
            }
        )
        let chosenAuditByCandidateID: [UUID: SourceFactReviewAudit] = Dictionary(
            uniqueKeysWithValues: chosenArchive.grounding.reviewAudits.map {
                ($0.candidateID, $0)
            }
        )

        return try allCandidates.enumerated().map { index, archive in
            guard index > 0 else {
                return groundingCollisionRecords(in: archive)
            }
            let candidateKindByID: [UUID: DocumentFactKind] = Dictionary(
                uniqueKeysWithValues: archive.grounding.batches.flatMap {
                    $0.parseResult.factCandidates.map { ($0.candidateID, $0.kind) }
                }
            )
            let factByID: [UUID: ConfirmedSourceDateFact] = Dictionary(
                uniqueKeysWithValues: archive.grounding.confirmedDateFacts.map {
                    ($0.id, $0)
                }
            )
            var excludedAuditIDs: Set<UUID> = []
            var excludedFactIDs: Set<UUID> = []
            var potentiallyExclusiveEvidenceIDs: Set<EvidenceLinkID> = []

            for audit in archive.grounding.reviewAudits {
                guard let candidateKind = candidateKindByID[audit.candidateID] else {
                    throw NextStepBetaGroundingError.invalidArchiveState
                }
                guard candidateKind == .deadline else {
                    continue
                }
                let fact = audit.confirmedFactID.flatMap { factByID[$0] }
                let chosenAudit = chosenAuditByCandidateID[audit.candidateID]
                let chosenFact: ConfirmedSourceDateFact?
                if let chosenFactID = chosenAudit?.confirmedFactID {
                    chosenFact = chosenFactByID[chosenFactID]
                } else {
                    chosenFact = nil
                }
                if let chosenAudit, audit == chosenAudit, fact == chosenFact {
                    continue
                }
                excludedAuditIDs.insert(audit.id)
                if let fact {
                    excludedFactIDs.insert(fact.id)
                }
                potentiallyExclusiveEvidenceIDs.formUnion(audit.evidenceLinkIDs)
            }

            let includedAudits = archive.grounding.reviewAudits.filter {
                excludedAuditIDs.contains($0.id) == false
            }
            let includedFacts = archive.grounding.confirmedDateFacts.filter {
                excludedFactIDs.contains($0.id) == false
            }
            let includedEvidenceIDs = Set(includedAudits.flatMap(\.evidenceLinkIDs))
            let exclusiveEvidenceIDs = potentiallyExclusiveEvidenceIDs.subtracting(
                includedEvidenceIDs
            )
            let includedEvidence = groundingEvidence(in: archive).filter {
                exclusiveEvidenceIDs.contains($0.metadata.id) == false
            }
            return NextStepBetaGroundingCollisionRecords(
                audits: includedAudits,
                facts: includedFacts,
                evidence: includedEvidence
            )
        }
    }

    /// Grounding decisions are immutable user records. A conflicting identity
    /// or a second outcome for the same candidate must stop sync even when a
    /// mutable deadline/replan difference makes the archives ineligible for
    /// automatic union.
    private static func assertNoGroundingRecordConflict(
        in archives: [NextStepBetaArchive]
    ) throws {
        var records: [NextStepBetaGroundingCollisionRecords] = []
        records.reserveCapacity(archives.count)
        for archive in archives {
            try archive.validate()
            records.append(groundingCollisionRecords(in: archive))
        }
        try assertNoGroundingRecordCollision(in: records)
    }

    private static func groundingCollisionRecords(
        in archive: NextStepBetaArchive
    ) -> NextStepBetaGroundingCollisionRecords {
        NextStepBetaGroundingCollisionRecords(
            audits: archive.grounding.reviewAudits,
            facts: archive.grounding.confirmedDateFacts,
            evidence: groundingEvidence(in: archive)
        )
    }

    private static func assertNoGroundingRecordCollision(
        in records: [NextStepBetaGroundingCollisionRecords]
    ) throws {
        var auditByID: [UUID: SourceFactReviewAudit] = [:]
        var auditByCandidateID: [UUID: SourceFactReviewAudit] = [:]
        var factByID: [UUID: ConfirmedSourceDateFact] = [:]
        var factByCandidateID: [UUID: ConfirmedSourceDateFact] = [:]
        var evidenceByID: [EvidenceLinkID: EvidenceLink] = [:]

        for record in records {
            for audit in record.audits {
                if let existing = auditByID[audit.id], existing != audit {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingAudit(audit.id)
                }
                if let existing = auditByCandidateID[audit.candidateID], existing != audit {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingCandidate(
                        audit.candidateID
                    )
                }
                auditByID[audit.id] = audit
                auditByCandidateID[audit.candidateID] = audit
            }
            for fact in record.facts {
                if let existing = factByID[fact.id], existing != fact {
                    throw NextStepBetaImmutableMergeError.conflictingConfirmedSourceDateFact(
                        fact.id
                    )
                }
                if let existing = factByCandidateID[fact.candidateID], existing != fact {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingCandidate(
                        fact.candidateID
                    )
                }
                factByID[fact.id] = fact
                factByCandidateID[fact.candidateID] = fact
            }
            for evidence in record.evidence {
                if let existing = evidenceByID[evidence.metadata.id], existing != evidence {
                    throw NextStepBetaImmutableMergeError.conflictingGroundingEvidence(
                        evidence.metadata.id
                    )
                }
                evidenceByID[evidence.metadata.id] = evidence
            }
        }
    }

    private static func groundingEvidenceIDs(
        in archive: NextStepBetaArchive
    ) -> Set<EvidenceLinkID> {
        Set(archive.grounding.reviewAudits.flatMap(\.evidenceLinkIDs))
    }

    private static func groundingEvidence(
        in archive: NextStepBetaArchive
    ) -> [EvidenceLink] {
        let ids = groundingEvidenceIDs(in: archive)
        return archive.workspace.evidenceLinks.filter {
            ids.contains($0.metadata.id)
        }
    }

    private static func mergeableConfirmedDateFacts(
        in archive: NextStepBetaArchive
    ) -> [ConfirmedSourceDateFact] {
        archive.grounding.confirmedDateFacts.filter { $0.kind == .date }
    }

    private static func mergeableConfirmedDateFacts(
        in records: NextStepBetaGroundingCollisionRecords
    ) -> [ConfirmedSourceDateFact] {
        records.facts.filter { $0.kind == .date }
    }

    private static func mergeableReviewAudits(
        in archive: NextStepBetaArchive
    ) -> [SourceFactReviewAudit] {
        let ordinaryDateCandidateIDs = Set(
            mergeableConfirmedDateFacts(in: archive).map(\.candidateID)
        )
        return archive.grounding.reviewAudits.filter {
            $0.disposition == .rejected
                || ordinaryDateCandidateIDs.contains($0.candidateID)
        }
    }

    private static func mergeableReviewAudits(
        in records: NextStepBetaGroundingCollisionRecords
    ) -> [SourceFactReviewAudit] {
        let ordinaryDateCandidateIDs = Set(
            mergeableConfirmedDateFacts(in: records).map(\.candidateID)
        )
        return records.audits.filter {
            $0.disposition == .rejected
                || ordinaryDateCandidateIDs.contains($0.candidateID)
        }
    }

    private static func mergeableGroundingEvidenceIDs(
        in archive: NextStepBetaArchive
    ) -> Set<EvidenceLinkID> {
        Set(mergeableReviewAudits(in: archive).flatMap(\.evidenceLinkIDs))
    }

    private static func mergeableGroundingEvidenceIDs(
        in records: NextStepBetaGroundingCollisionRecords
    ) -> Set<EvidenceLinkID> {
        Set(mergeableReviewAudits(in: records).flatMap(\.evidenceLinkIDs))
    }

    private static func mergeableGroundingEvidence(
        in archive: NextStepBetaArchive
    ) -> [EvidenceLink] {
        let ids = mergeableGroundingEvidenceIDs(in: archive)
        return archive.workspace.evidenceLinks.filter {
            ids.contains($0.metadata.id)
        }
    }

    private static func mergeableGroundingEvidence(
        in records: NextStepBetaGroundingCollisionRecords
    ) -> [EvidenceLink] {
        let ids = mergeableGroundingEvidenceIDs(in: records)
        return records.evidence.filter {
            ids.contains($0.metadata.id)
        }
    }

    private static func immutableExecutionBaseDigest(
        _ archive: NextStepBetaArchive
    ) throws -> SyncDigest {
        try archive.validate()
        var normalized = archive
        let normalizedGroundingEvidenceIDs = mergeableGroundingEvidenceIDs(in: normalized)
        let normalizedAuditIDs = Set(mergeableReviewAudits(in: normalized).map(\.id))
        let normalizedFactIDs = Set(
            mergeableConfirmedDateFacts(in: normalized).map(\.id)
        )
        normalized.workspace.userResponses = []
        normalized.workspace.completionEvidence = []
        normalized.workspace.evidenceLinks.removeAll {
            normalizedGroundingEvidenceIDs.contains($0.metadata.id)
        }
        normalized.grounding.reviewAudits.removeAll {
            normalizedAuditIDs.contains($0.id)
        }
        normalized.grounding.confirmedDateFacts.removeAll {
            normalizedFactIDs.contains($0.id)
        }
        normalized.workspace.revision = 0
        normalized.workspace.savedAt = Date(timeIntervalSince1970: 0)
        return SyncDigest(data: try encodePayload(normalized))
    }

    private func pendingReview(
        localArchive: NextStepBetaArchive,
        fallbackSyncedArchive: NextStepBetaArchive,
        snapshot: SyncSnapshot
    ) async throws -> NextStepBetaPendingSyncReview? {
        let deadlineField = try Self.deadlineField()
        if let conflict = snapshot.conflicts.first(where: {
            $0.field == deadlineField && $0.status == .unresolved
        }) {
            let localFingerprint = try Self.deadlineFingerprint(localArchive)
            let candidates = try await archivedCandidates(
                in: snapshot,
                localDeviceID: localArchive.deviceID
            )
            let syncedArchive = try candidates.first(where: {
                try Self.deadlineFingerprint($0) != localFingerprint
            }) ?? fallbackSyncedArchive
            let syncedFingerprint = try Self.deadlineFingerprint(syncedArchive)
            let summary = NextStepBetaSyncReview(
                id: conflict.id.description,
                kind: .protectedDeadline,
                localDescription: Self.deadlineDescription(localArchive),
                syncedDescription: Self.deadlineDescription(syncedArchive)
            )
            return .init(
                summary: summary,
                conflict: conflict,
                localArchive: localArchive,
                syncedArchive: syncedArchive,
                localFingerprint: localFingerprint,
                syncedFingerprint: syncedFingerprint
            )
        }

        let sourceField = try Self.sourceContentField()
        let completionField = try Self.completionOperationField()
        let completionKind = try Self.completionEntityKind()
        let actionReplanField = try Self.actionReplanOperationField()
        let actionReplanKind = try Self.actionReplanEntityKind()
        if let conflict = snapshot.conflicts.first(where: {
            $0.entity.kind == completionKind
                && $0.field == completionField
                && $0.status == .unresolved
        }) {
            let actionTitle = localArchive.workspace.dailyActions.first {
                $0.metadata.id.rawValue == conflict.entity.id
            }?.title ?? fallbackSyncedArchive.workspace.dailyActions.first {
                $0.metadata.id.rawValue == conflict.entity.id
            }?.title ?? "未知任務"
            let summary = NextStepBetaSyncReview(
                id: conflict.id.description,
                kind: .immutableCompletion,
                localDescription: "這台裝置保留的完成證據：\(actionTitle)",
                syncedDescription: "同步資料夾中的另一份完成證據：\(actionTitle)"
            )
            return .init(
                summary: summary,
                conflict: conflict,
                localArchive: localArchive,
                syncedArchive: fallbackSyncedArchive,
                localFingerprint: "",
                syncedFingerprint: ""
            )
        }

        if let conflict = snapshot.conflicts.first(where: {
            $0.entity.kind == actionReplanKind
                && $0.field == actionReplanField
                && $0.status == .unresolved
        }) {
            let summary = NextStepBetaSyncReview(
                id: conflict.id.description,
                kind: .actionReplan,
                localDescription: "保留這台裝置目前的 Today 與任務狀態",
                syncedDescription: "同步資料夾中的重新安排操作需要人工檢查"
            )
            return .init(
                summary: summary,
                conflict: conflict,
                localArchive: localArchive,
                syncedArchive: fallbackSyncedArchive,
                localFingerprint: "",
                syncedFingerprint: ""
            )
        }

        if let conflict = snapshot.conflicts.first(where: {
            $0.field == sourceField && $0.status == .unresolved
        }) {
            let summary = NextStepBetaSyncReview(
                id: conflict.id.description,
                kind: .immutableSource,
                localDescription: "保留這台裝置目前的來源檔",
                syncedDescription: "採用同步資料夾中的來源檔"
            )
            return .init(
                summary: summary,
                conflict: conflict,
                localArchive: localArchive,
                syncedArchive: fallbackSyncedArchive,
                localFingerprint: "",
                syncedFingerprint: ""
            )
        }
        return nil
    }

    private func installAndSave(
        _ archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive,
        snapshot: SyncSnapshot
    ) async throws {
        let field = try Self.sourceContentField()
        for document in archive.workspace.sourceDocuments {
            guard let relativePath = document.localRelativePath else { continue }
            guard let expectedSHA256 = document.contentSHA256,
                  expectedSHA256.isEmpty == false else {
                throw NextStepBetaStoreError.sourceIntegrityMismatch
            }
            let entity = try Self.sourceEntity(document.metadata.id.rawValue)
            guard case .blob(let reference)? = snapshot.entity(entity)?.field(field)?.value,
                  reference.digest.hex == expectedSHA256.lowercased(),
                  let data = try await engine.blobData(for: reference) else {
                throw NextStepSyncError.notFound(expectedSHA256)
            }
            try await store.installSyncedSource(
                data,
                relativePath: relativePath,
                expectedSHA256: expectedSHA256
            )
        }
        try await store.save(archive, replacing: expectedArchive)
    }

    /// A fresh or genuinely older device may not yet have the Action/Package
    /// needed to replay an immutable completion. Install the authoritative
    /// snapshot (and source blobs) first, then atomically repair the operation
    /// inbox/applied ledgers against that now-complete projection. A crash
    /// between the two steps is recoverable because exact replay is idempotent.
    private func installAndSaveExecutionOverlay(
        _ archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive,
        snapshot: SyncSnapshot,
        completionOperations: [NextStepBetaGuidedActionCompletionOperation],
        actionReplanOperations: [NextStepBetaActionReplanOperationV1],
        now: Date
    ) async throws -> NextStepBetaArchive {
        try await installAndSave(
            archive,
            replacing: expectedArchive,
            snapshot: snapshot
        )
        return try await persistExecutionOverlay(
            completionOperations: completionOperations,
            actionReplanOperations: actionReplanOperations,
            onto: archive,
            replacing: archive,
            now: now
        )
    }

    private static func encodePayload(_ archive: NextStepBetaArchive) throws -> Data {
        try archive.validate()
        let payload = NextStepBetaSyncPayload(
            schemaVersion: archive.schemaVersion,
            workspace: archive.workspace,
            currentDecisionID: archive.currentDecisionID,
            grounding: archive.grounding,
            completionApplicationReceipts: archive.completionApplicationReceipts.isEmpty
                ? nil
                : archive.completionApplicationReceipts,
            actionReplanApplicationReceipts: archive.actionReplanApplicationReceipts.isEmpty
                ? nil
                : archive.actionReplanApplicationReceipts
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func decodePayload(
        _ data: Data,
        localDeviceID: NextStepDomain.DeviceID
    ) throws -> NextStepBetaArchive {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let payload = try decoder.decode(NextStepBetaSyncPayload.self, from: data)
            let grounding: NextStepBetaGroundingState
            switch payload.schemaVersion {
            case 1:
                grounding = .empty
            case NextStepBetaArchive.currentSchemaVersion:
                guard let decodedGrounding = payload.grounding else {
                    throw NextStepBetaStoreError.malformedSyncArchive
                }
                grounding = decodedGrounding
            default:
                throw NextStepBetaArchiveError.unsupportedSchema(payload.schemaVersion)
            }
            return try NextStepBetaArchive(
                schemaVersion: NextStepBetaArchive.currentSchemaVersion,
                deviceID: localDeviceID,
                workspace: payload.workspace,
                currentDecisionID: payload.currentDecisionID,
                grounding: grounding,
                completionApplicationReceipts:
                    payload.completionApplicationReceipts ?? [],
                actionReplanApplicationReceipts:
                    payload.actionReplanApplicationReceipts ?? []
            )
        } catch let error as NextStepBetaArchiveError {
            throw error
        } catch {
            throw NextStepBetaStoreError.malformedSyncArchive
        }
    }

    private static func deadlineFingerprint(_ archive: NextStepBetaArchive) throws -> String {
        var entries: [NextStepBetaProtectedDeadlineSet.Entry] = []
        for value in archive.workspace.ultimateGoals {
            if let fact = value.targetDay, fact.mutability == .immutable {
                entries.append(deadlineEntry(
                    ownerKind: "ultimateGoal",
                    ownerID: value.metadata.id.description,
                    fact: fact
                ))
            }
        }
        for value in archive.workspace.goals {
            if let fact = value.targetDay, fact.mutability == .immutable {
                entries.append(deadlineEntry(
                    ownerKind: "goal",
                    ownerID: value.metadata.id.description,
                    fact: fact
                ))
            }
        }
        for value in archive.workspace.milestones {
            if let fact = value.targetDay, fact.mutability == .immutable {
                entries.append(deadlineEntry(
                    ownerKind: "milestone",
                    ownerID: value.metadata.id.description,
                    fact: fact
                ))
            }
        }
        entries.sort {
            ($0.ownerKind, $0.ownerID) < ($1.ownerKind, $1.ownerID)
        }
        let envelope = NextStepBetaProtectedDeadlineSet(schemaVersion: 2, entries: entries)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard let value = String(data: data, encoding: .utf8) else {
            throw NextStepSyncError.malformedDocument("Deadline fingerprint is not UTF-8.")
        }
        return value
    }

    private static func deadlineEntry(
        ownerKind: String,
        ownerID: String,
        fact: FactValue<LocalDay>
    ) -> NextStepBetaProtectedDeadlineSet.Entry {
        NextStepBetaProtectedDeadlineSet.Entry(
            ownerKind: ownerKind,
            ownerID: ownerID,
            day: fact.value.description,
            authority: fact.authority.rawValue,
            mutability: fact.mutability.rawValue,
            evidenceLinkIDs: fact.evidenceLinkIDs.map(\.description).sorted(),
            confirmedAt: fact.confirmedAt
        )
    }

    private static func deadlineDescription(_ archive: NextStepBetaArchive) -> String {
        let evidenceByID = Dictionary(uniqueKeysWithValues: archive.workspace.evidenceLinks.map {
            ($0.metadata.id, $0)
        })
        let anchorByID = Dictionary(uniqueKeysWithValues: archive.workspace.sourceAnchors.map {
            ($0.metadata.id, $0)
        })
        let sourceByID = Dictionary(uniqueKeysWithValues: archive.workspace.sourceDocuments.map {
            ($0.metadata.id, $0)
        })
        let formatter = ISO8601DateFormatter()

        func describe(
            kind: String,
            title: String,
            ownerID: String,
            fact: FactValue<LocalDay>
        ) -> String {
            let evidenceSummary: String
            if fact.evidenceLinkIDs.isEmpty {
                evidenceSummary = "無"
            } else {
                evidenceSummary = fact.evidenceLinkIDs.sorted().map { evidenceID in
                    guard let evidence = evidenceByID[evidenceID],
                          let anchor = anchorByID[evidence.anchorID],
                          let source = sourceByID[anchor.sourceDocumentID] else {
                        return evidenceID.description
                    }
                    return "\(source.displayTitle) [\(evidenceID.description)]"
                }.joined(separator: "、")
            }
            let confirmedAt = fact.confirmedAt.map { formatter.string(from: $0) } ?? "未記錄"
            return "\(kind)「\(title)」[\(ownerID)]｜期限：\(fact.value.description)"
                + "｜\(fact.authority.rawValue)/\(fact.mutability.rawValue)"
                + "｜來源證據：\(evidenceSummary)｜確認時間：\(confirmedAt)"
        }

        var descriptions: [String] = []
        for value in archive.workspace.ultimateGoals {
            if let fact = value.targetDay, fact.mutability == .immutable {
                descriptions.append(describe(
                    kind: "最終目標",
                    title: value.title,
                    ownerID: value.metadata.id.description,
                    fact: fact
                ))
            }
        }
        for value in archive.workspace.goals {
            if let fact = value.targetDay, fact.mutability == .immutable {
                descriptions.append(describe(
                    kind: "目標",
                    title: value.title,
                    ownerID: value.metadata.id.description,
                    fact: fact
                ))
            }
        }
        for value in archive.workspace.milestones {
            if let fact = value.targetDay, fact.mutability == .immutable {
                descriptions.append(describe(
                    kind: "里程碑",
                    title: value.title,
                    ownerID: value.metadata.id.description,
                    fact: fact
                ))
            }
        }
        return descriptions.isEmpty ? "尚未設定硬期限" : descriptions.joined(separator: "\n")
    }

    private static func containsProtectedDeadline(_ archive: NextStepBetaArchive) -> Bool {
        archive.workspace.ultimateGoals.contains { $0.targetDay?.mutability == .immutable }
            || archive.workspace.goals.contains { $0.targetDay?.mutability == .immutable }
            || archive.workspace.milestones.contains { $0.targetDay?.mutability == .immutable }
    }

    private static func containsUserData(_ archive: NextStepBetaArchive) -> Bool {
        isPristineArchive(archive) == false
    }

    private static func isPristineArchive(_ archive: NextStepBetaArchive) -> Bool {
        let workspace = archive.workspace
        let profile = workspace.userProfile
        let hasBootstrapAvailability = profile.weeklyAvailability.count == 7
            && zip(profile.weeklyAvailability, 1...7).allSatisfy { availability, weekday in
                availability.isoWeekday == weekday
                    && availability.availableMinutes == 35
                    && availability.preferredStartMinute == nil
            }
        return workspace.revision == 0
            && profile.localeIdentifier == "zh-Hant-TW"
            && hasBootstrapAvailability
            && profile.preferredSessionMinutes == 35
            && profile.maximumDailyMinutes == 35
            && profile.onboardingState == .goalsNeeded
            && profile.reduceMotion == false
            && profile.prefersMoreExamples == false
            && profile.metadata.revision == 0
            && profile.metadata.createdAt == workspace.savedAt
            && profile.metadata.updatedAt == workspace.savedAt
            && profile.metadata.deletedAt == nil
            && profile.metadata.originDeviceID == archive.deviceID
            && profile.metadata.lastOperationID == nil
            && profile.metadata.provenance == .user
            && workspace.ultimateGoals.isEmpty
            && workspace.goals.isEmpty
            && workspace.milestones.isEmpty
            && workspace.weeklyOutcomes.isEmpty
            && workspace.dailyActions.isEmpty
            && workspace.guidedPackages.isEmpty
            && workspace.sourceDocuments.isEmpty
            && workspace.paperSources.isEmpty
            && workspace.sourceAnchors.isEmpty
            && workspace.citations.isEmpty
            && workspace.highlights.isEmpty
            && workspace.extractedClaims.isEmpty
            && workspace.evidenceLinks.isEmpty
            && workspace.completionEvidence.isEmpty
            && workspace.userResponses.isEmpty
            && workspace.calendarConstraints.isEmpty
            && workspace.planningDecisions.isEmpty
            && workspace.replanEvents.isEmpty
            && workspace.progressSnapshots.isEmpty
            && archive.currentDecisionID == nil
            && archive.grounding == .empty
            && archive.completionApplicationReceipts.isEmpty
            && archive.actionReplanApplicationReceipts.isEmpty
    }

    private static func archivePrecedes(
        _ lhs: NextStepBetaArchive,
        _ rhs: NextStepBetaArchive
    ) -> Bool {
        if lhs.workspace.revision != rhs.workspace.revision {
            return lhs.workspace.revision < rhs.workspace.revision
        }
        if lhs.workspace.savedAt != rhs.workspace.savedAt {
            return lhs.workspace.savedAt < rhs.workspace.savedAt
        }
        return lhs.deviceID.description < rhs.deviceID.description
    }

    private static func workspaceEntity() throws -> SyncEntityReference {
        SyncEntityReference(kind: try SyncKey("betaWorkspace"), id: workspaceUUID)
    }

    private static func sourceEntity(_ id: UUID) throws -> SyncEntityReference {
        SyncEntityReference(kind: try SyncKey("betaSource"), id: id)
    }

    private static func completionEntityKind() throws -> SyncKey {
        try SyncKey("betaActionCompletion")
    }

    private static func completionEntity(_ id: UUID) throws -> SyncEntityReference {
        SyncEntityReference(kind: try completionEntityKind(), id: id)
    }

    private static func actionReplanEntityKind() throws -> SyncKey {
        try SyncKey("betaActionReplan")
    }

    private static func actionReplanEntity(_ id: UUID) throws -> SyncEntityReference {
        SyncEntityReference(kind: try actionReplanEntityKind(), id: id)
    }

    private static func archiveField() throws -> SyncKey { try SyncKey("archive") }
    private static func deadlineField() throws -> SyncKey { try SyncKey("hardDeadlines") }
    private static func sourceContentField() throws -> SyncKey { try SyncKey("content") }
    private static func completionOperationField() throws -> SyncKey {
        try SyncKey("operation")
    }

    private static func actionReplanOperationField() throws -> SyncKey {
        try SyncKey("operation")
    }

    private static func mediaType(for relativePath: String) -> String? {
        switch URL(fileURLWithPath: relativePath).pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "heic": "image/heic"
        default: nil
        }
    }
}

struct NextStepBetaSyncCoordinatorResult: Sendable {
    let archive: NextStepBetaArchive
    let didReplaceLocalArchive: Bool
    let state: NextStepBetaSyncState
}

protocol NextStepBetaSyncCoordinating: Sendable {
    func restoreIfConfigured(
        localArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult?

    func connectSelectedFolder(
        _ folderURL: URL,
        localArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult

    func publishLocalAndSynchronize(
        _ archive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult?

    func synchronizeNow(
        localArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult?

    func resolvePendingReview(
        useSyncedArchive: Bool,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult

    func disconnect() async throws
}

enum NextStepBetaSyncCoordinatorError: LocalizedError, Equatable {
    case operationInProgress

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "另一個同步作業尚未完成，請稍後再試。"
        }
    }
}

actor NextStepBetaSyncCoordinator: NextStepBetaSyncCoordinating {
    private let applicationSupportRoot: URL
    private let store: NextStepBetaStore
    private let settingsStore: NextStepBetaSyncSettingsStore
    private var session: FileFolderSyncSession?
    private var pendingReview: NextStepBetaPendingSyncReview?
    private var operationInFlight = false

    init(
        applicationSupportRoot: URL,
        store: NextStepBetaStore
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.store = store
        self.settingsStore = NextStepBetaSyncSettingsStore(
            rootURL: applicationSupportRoot
        )
    }

    func restoreIfConfigured(
        localArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult? {
        try beginOperation()
        defer { finishOperation() }
        guard let settings = try await settingsStore.load() else { return nil }
        let connected = try await NextStepSyncBootstrap.connectFileFolder(
            bookmark: SecurityScopedSyncFolderBookmark(data: settings.bookmarkData),
            applicationSupportRoot: applicationSupportRoot,
            preferredLibraryID: settings.libraryID
        )
        session = connected
        try await settingsStore.save(
            bookmark: connected.bookmarkToPersist,
            libraryID: connected.libraryID
        )
        return try await reconcileInitial(localArchive: localArchive, now: now)
    }

    func connectSelectedFolder(
        _ folderURL: URL,
        localArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult {
        try beginOperation()
        defer { finishOperation() }
        let connected = try await NextStepSyncBootstrap.connectSelectedFolder(
            folderURL,
            applicationSupportRoot: applicationSupportRoot
        )
        session = connected
        pendingReview = nil
        try await settingsStore.save(
            bookmark: connected.bookmarkToPersist,
            libraryID: connected.libraryID
        )
        return try await reconcileInitial(localArchive: localArchive, now: now)
    }

    func publishLocalAndSynchronize(
        _ archive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult? {
        try beginOperation()
        defer { finishOperation() }
        return try await publishLocalAndSynchronizeImplementation(archive, now: now)
    }

    private func publishLocalAndSynchronizeImplementation(
        _ archive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult? {
        guard let session else { return nil }
        if let pendingReview {
            return .init(
                archive: archive,
                didReplaceLocalArchive: false,
                state: .reviewRequired(pendingReview.summary)
            )
        }
        let result = try await NextStepBetaSyncArchiveAdapter(
            engine: session.engine,
            store: store
        ).publishLocalAndSynchronize(archive, now: now)
        return consume(result, now: now)
    }

    func synchronizeNow(
        localArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult? {
        try beginOperation()
        defer { finishOperation() }
        return try await publishLocalAndSynchronizeImplementation(localArchive, now: now)
    }

    func resolvePendingReview(
        useSyncedArchive: Bool,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult {
        try beginOperation()
        defer { finishOperation() }
        guard let session, let pendingReview else {
            throw NextStepSyncError.malformedDocument("There is no pending sync review.")
        }
        let result = try await NextStepBetaSyncArchiveAdapter(
            engine: session.engine,
            store: store
        ).resolve(pendingReview, useSyncedArchive: useSyncedArchive, now: now)
        self.pendingReview = nil
        return consume(result, now: now)
    }

    func disconnect() async throws {
        try beginOperation()
        defer { finishOperation() }
        session = nil
        pendingReview = nil
        try await settingsStore.clear()
    }

    private func reconcileInitial(
        localArchive: NextStepBetaArchive,
        now: Date
    ) async throws -> NextStepBetaSyncCoordinatorResult {
        guard let session else {
            throw NextStepSyncError.transportUnavailable
        }
        let result = try await NextStepBetaSyncArchiveAdapter(
            engine: session.engine,
            store: store
        ).reconcileInitial(localArchive: localArchive, now: now)
        return consume(result, now: now)
    }

    private func consume(
        _ result: NextStepBetaSyncAdapterResult,
        now: Date
    ) -> NextStepBetaSyncCoordinatorResult {
        pendingReview = result.pendingReview
        let state: NextStepBetaSyncState = result.pendingReview.map {
            .reviewRequired($0.summary)
        } ?? .ready(lastSyncedAt: now)
        return .init(
            archive: result.archive,
            didReplaceLocalArchive: result.didReplaceLocalArchive,
            state: state
        )
    }

    private func beginOperation() throws {
        guard operationInFlight == false else {
            throw NextStepBetaSyncCoordinatorError.operationInProgress
        }
        operationInFlight = true
    }

    private func finishOperation() {
        operationInFlight = false
    }
}
