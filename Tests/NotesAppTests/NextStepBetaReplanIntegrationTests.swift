import CryptoKit
import Foundation
import NextStepDomain
import NextStepPlanning
import NextStepSync
@testable import NotesApp
import XCTest

final class NextStepBetaReplanIntegrationTests: XCTestCase {
    func testOfflineLocalCommitSurvivesReopenAndLedgerReplayIsIdempotent() async throws {
        let root = temporaryRoot(named: "replan-local-reopen")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let store = NextStepBetaStore(rootURL: root)
        try await installFixtureSource(fixture, in: store)
        try await store.save(fixture.baseArchive, replacing: nil)

        try await store.saveActionReplanOperation(
            fixture.acceptance.archive,
            replacing: fixture.baseArchive,
            operation: fixture.acceptance.operation
        )

        let reopened = NextStepBetaStore(rootURL: root)
        let loadedValue = try await reopened.load()
        let loaded = try XCTUnwrap(loadedValue)
        try assertReplan(
            loaded,
            operation: fixture.acceptance.operation,
            expectedSourceBytes: fixture.sourceRecordBytes,
            expectedDeadlineBytes: fixture.deadlineBytes
        )
        let loadedBytes = try await reopened.encodeArchiveForSync(loaded)
        let acceptedBytes = try await reopened.encodeArchiveForSync(
            fixture.acceptance.archive
        )
        XCTAssertEqual(
            loadedBytes,
            acceptedBytes
        )

        let pending = try await reopened.pendingActionReplanOperations()
        XCTAssertEqual(pending.map(\.operation), [fixture.acceptance.operation])
        XCTAssertEqual(
            pending.first?.canonicalData,
            try fixture.acceptance.operation.canonicalData()
        )
        let applied = try await reopened.storedActionReplanOperations()
        XCTAssertEqual(applied.map(\.operation), [fixture.acceptance.operation])

        try await reopened.markActionReplanOperationPublished(
            fixture.acceptance.operation,
            publishedAt: fixture.occurredAt.addingTimeInterval(1)
        )
        let pendingAfterPublish = try await reopened.pendingActionReplanOperations()
        XCTAssertTrue(pendingAfterPublish.isEmpty)
        let appliedAfterPublish = try await reopened.storedActionReplanOperations()
        XCTAssertEqual(
            appliedAfterPublish.map(\.operation),
            [fixture.acceptance.operation]
        )
        let bytesBeforeReplay = try await reopened.encodeArchiveForSync(loaded)

        try await reopened.saveActionReplanOperation(
            fixture.acceptance.archive,
            replacing: fixture.baseArchive,
            operation: fixture.acceptance.operation
        )

        let replayedValue = try await reopened.load()
        let replayed = try XCTUnwrap(replayedValue)
        let replayedBytes = try await reopened.encodeArchiveForSync(replayed)
        XCTAssertEqual(
            replayedBytes,
            bytesBeforeReplay
        )
        let pendingAfterReplay = try await reopened.pendingActionReplanOperations()
        XCTAssertTrue(pendingAfterReplay.isEmpty)
        let appliedAfterReplay = try await reopened.storedActionReplanOperations()
        XCTAssertEqual(
            appliedAfterReplay.map(\.operation),
            [fixture.acceptance.operation]
        )
        XCTAssertEqual(replayed.actionReplanApplicationReceipts.count, 1)
        try await assertStoredSourceBytes(fixture, in: reopened)
        try assertReplan(
            replayed,
            operation: fixture.acceptance.operation,
            expectedSourceBytes: fixture.sourceRecordBytes,
            expectedDeadlineBytes: fixture.deadlineBytes
        )
    }

    func testStaleSQLiteCASCannotRegressDurableReplanOrRestoreOldSchedule() async throws {
        let root = temporaryRoot(named: "replan-stale-cas")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let store = NextStepBetaStore(rootURL: root)
        try await installFixtureSource(fixture, in: store)
        try await store.save(fixture.baseArchive, replacing: nil)
        try await store.saveActionReplanOperation(
            fixture.acceptance.archive,
            replacing: fixture.baseArchive,
            operation: fixture.acceptance.operation
        )

        do {
            try await store.save(
                fixture.baseArchive,
                replacing: fixture.baseArchive
            )
            XCTFail("A stale pre-deferral archive must not replace the durable replan.")
        } catch {
            XCTAssertEqual(
                error as? NextStepBetaStoreError,
                .localPersistenceFailure
            )
        }

        let durableValue = try await store.load()
        let durable = try XCTUnwrap(durableValue)
        try assertReplan(
            durable,
            operation: fixture.acceptance.operation,
            expectedSourceBytes: fixture.sourceRecordBytes,
            expectedDeadlineBytes: fixture.deadlineBytes
        )
        let durablePending = try await store.pendingActionReplanOperations()
        XCTAssertEqual(durablePending.map(\.operation), [fixture.acceptance.operation])
        try await assertStoredSourceBytes(fixture, in: store)
    }

    func testTwoFolderDevicesConvergeAndRepeatedReverseSyncDoesNotMutateProjection() async throws {
        let root = temporaryRoot(named: "replan-folder-convergence")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: remote,
            withIntermediateDirectories: true
        )
        let fixture = try makeFixture()
        let storeA = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-a", isDirectory: true)
        )
        let storeB = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-b", isDirectory: true)
        )
        let baseA = fixture.baseArchive
        var baseB = fixture.baseArchive
        baseB.deviceID = NextStepDomain.DeviceID(fixedUUID(2))
        try baseB.validate()
        try await installFixtureSource(fixture, in: storeA)
        try await installFixtureSource(fixture, in: storeB)
        try await storeA.save(baseA, replacing: nil)
        try await storeB.save(baseB, replacing: nil)

        let libraryID = SyncLibraryID(fixedUUID(900))
        let adapterA = NextStepBetaSyncArchiveAdapter(
            engine: try makeEngine(
                localRoot: root.appendingPathComponent("engine-a", isDirectory: true),
                remoteRoot: remote,
                deviceID: NextStepSync.DeviceID(fixedUUID(901)),
                now: fixture.occurredAt.addingTimeInterval(10),
                libraryID: libraryID
            ),
            store: storeA
        )
        let adapterB = NextStepBetaSyncArchiveAdapter(
            engine: try makeEngine(
                localRoot: root.appendingPathComponent("engine-b", isDirectory: true),
                remoteRoot: remote,
                deviceID: NextStepSync.DeviceID(fixedUUID(902)),
                now: fixture.occurredAt.addingTimeInterval(20),
                libraryID: libraryID
            ),
            store: storeB
        )
        _ = try await adapterA.reconcileInitial(
            localArchive: baseA,
            now: fixture.occurredAt.addingTimeInterval(2)
        )
        _ = try await adapterB.reconcileInitial(
            localArchive: baseB,
            now: fixture.occurredAt.addingTimeInterval(3)
        )

        try await storeA.saveActionReplanOperation(
            fixture.acceptance.archive,
            replacing: baseA,
            operation: fixture.acceptance.operation
        )
        let firstA = try await adapterA.publishLocalAndSynchronize(
            fixture.acceptance.archive,
            now: fixture.occurredAt.addingTimeInterval(10)
        )
        XCTAssertNil(firstA.pendingReview)

        let receivedB = try await adapterB.publishLocalAndSynchronize(
            baseB,
            now: fixture.occurredAt.addingTimeInterval(20)
        )
        XCTAssertNil(receivedB.pendingReview)
        try assertReplan(
            receivedB.archive,
            operation: fixture.acceptance.operation,
            expectedSourceBytes: fixture.sourceRecordBytes,
            expectedDeadlineBytes: fixture.deadlineBytes
        )

        let convergedA = try await adapterA.publishLocalAndSynchronize(
            firstA.archive,
            now: fixture.occurredAt.addingTimeInterval(30)
        )
        XCTAssertNil(convergedA.pendingReview)
        try assertReplan(
            convergedA.archive,
            operation: fixture.acceptance.operation,
            expectedSourceBytes: fixture.sourceRecordBytes,
            expectedDeadlineBytes: fixture.deadlineBytes
        )
        let stableA = projectionFingerprint(convergedA.archive)
        let stableB = projectionFingerprint(receivedB.archive)
        XCTAssertEqual(stableA, stableB)

        let reverseB = try await adapterB.publishLocalAndSynchronize(
            receivedB.archive,
            now: fixture.occurredAt.addingTimeInterval(40)
        )
        let reverseA = try await adapterA.publishLocalAndSynchronize(
            convergedA.archive,
            now: fixture.occurredAt.addingTimeInterval(50)
        )
        XCTAssertNil(reverseB.pendingReview)
        XCTAssertNil(reverseA.pendingReview)
        XCTAssertEqual(projectionFingerprint(reverseB.archive), stableB)
        XCTAssertEqual(projectionFingerprint(reverseA.archive), stableA)

        let persistedAValue = try await storeA.load()
        let persistedBValue = try await storeB.load()
        let persistedA = try XCTUnwrap(persistedAValue)
        let persistedB = try XCTUnwrap(persistedBValue)
        XCTAssertEqual(persistedA.workspace, persistedB.workspace)
        XCTAssertEqual(
            persistedA.actionReplanApplicationReceipts,
            persistedB.actionReplanApplicationReceipts
        )
        let operationsA = try await storeA.storedActionReplanOperations()
        let operationsB = try await storeB.storedActionReplanOperations()
        XCTAssertEqual(operationsA.map(\.operation), [fixture.acceptance.operation])
        XCTAssertEqual(operationsB.map(\.operation), [fixture.acceptance.operation])
        try await assertStoredSourceBytes(fixture, in: storeA)
        try await assertStoredSourceBytes(fixture, in: storeB)
    }

    func testCrossTypeCausalReplayConvergesWhenArchiveHeadPredatesBothOperations()
        async throws {
        let root = temporaryRoot(named: "replan-cross-type-causal-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: remote,
            withIntermediateDirectories: true
        )
        let fixture = try makeCrossTypeFixture()
        let libraryID = SyncLibraryID(fixedUUID(930))
        let publishingEngine = try makeEngine(
            localRoot: root.appendingPathComponent("engine-publisher", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(931)),
            now: fixture.completedAt.addingTimeInterval(10),
            libraryID: libraryID
        )
        let workspaceEntity = try SyncEntityReference(
            kind: SyncKey("betaWorkspace"),
            id: UUID(uuidString: "0f8d9ea7-d17d-4f09-b566-09e3a3ec17b1")!
        )
        let archiveField = try SyncKey("archive")
        let operationField = try SyncKey("operation")
        let replanEntity = try SyncEntityReference(
            kind: SyncKey("betaActionReplan"),
            id: fixture.replan.operation.operationID.rawValue
        )
        let completionEntity = try SyncEntityReference(
            kind: SyncKey("betaActionCompletion"),
            id: fixture.completion.operation.actionID.rawValue
        )
        let basePayload = try encodeSyncSeedPayload(fixture.baseArchive)
        let replanPayload = try fixture.replan.operation.canonicalData()
        let completionPayload = try fixture.completion.operation.canonicalData()

        _ = try await publishingEngine.enqueueBlob(
            entity: workspaceEntity,
            field: archiveField,
            data: basePayload,
            mediaType: "application/vnd.nextstep.beta-archive+json",
            policy: .flexibleLastWriterWins
        )
        _ = try await publishingEngine.enqueueBlob(
            entity: replanEntity,
            field: operationField,
            data: replanPayload,
            mediaType: "application/vnd.nextstep.action-replan+json",
            policy: .immutable
        )
        _ = try await publishingEngine.enqueueBlob(
            entity: completionEntity,
            field: operationField,
            data: completionPayload,
            mediaType: "application/vnd.nextstep.guided-action-completion+json",
            policy: .immutable
        )
        let pendingSeedCount = try await publishingEngine.pendingOperationCount()
        XCTAssertEqual(pendingSeedCount, 3)
        _ = try await publishingEngine.synchronize()
        let seededSnapshot = try await publishingEngine.snapshot()
        try await assertRemoteBlob(
            basePayload,
            entity: workspaceEntity,
            field: archiveField,
            snapshot: seededSnapshot,
            engine: publishingEngine
        )
        try await assertRemoteBlob(
            replanPayload,
            entity: replanEntity,
            field: operationField,
            snapshot: seededSnapshot,
            engine: publishingEngine
        )
        try await assertRemoteBlob(
            completionPayload,
            entity: completionEntity,
            field: operationField,
            snapshot: seededSnapshot,
            engine: publishingEngine
        )

        var receivingBase = fixture.baseArchive
        receivingBase.deviceID = NextStepDomain.DeviceID(fixedUUID(32))
        try receivingBase.validate()
        let receivingStore = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-receiver", isDirectory: true)
        )
        try await installFixtureSources(
            archive: receivingBase,
            sourceBytes: fixture.sourceBytes,
            in: receivingStore
        )
        try await receivingStore.save(receivingBase, replacing: nil)
        let receivingEngine = try makeEngine(
            localRoot: root.appendingPathComponent("engine-receiver", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(932)),
            now: fixture.completedAt.addingTimeInterval(20),
            libraryID: libraryID
        )
        let adapter = NextStepBetaSyncArchiveAdapter(
            engine: receivingEngine,
            store: receivingStore
        )
        let received = try await adapter.reconcileInitial(
            localArchive: receivingBase,
            now: fixture.completedAt.addingTimeInterval(20)
        )
        XCTAssertNil(received.pendingReview)
        XCTAssertEqual(received.archive.workspace, fixture.finalArchive.workspace)
        XCTAssertEqual(
            received.archive.currentDecisionID,
            fixture.finalArchive.currentDecisionID
        )
        XCTAssertEqual(
            received.archive.actionReplanApplicationReceipts,
            fixture.finalArchive.actionReplanApplicationReceipts
        )
        XCTAssertEqual(
            received.archive.completionApplicationReceipts,
            fixture.finalArchive.completionApplicationReceipts
        )
        XCTAssertEqual(
            canonicalSourceBytes(received.archive),
            fixture.sourceRecordBytes
        )
        XCTAssertEqual(
            canonicalDeadlineBytes(received.archive),
            fixture.deadlineBytes
        )
        try received.archive.validate()

        let storedReplans = try await receivingStore.storedActionReplanOperations()
        let storedCompletions = try await receivingStore.storedCompletionOperations()
        XCTAssertEqual(storedReplans.map(\.operation), [fixture.replan.operation])
        XCTAssertEqual(storedCompletions.map(\.operation), [fixture.completion.operation])
        let pendingReplans = try await receivingStore.pendingActionReplanOperations()
        let pendingCompletions = try await receivingStore.pendingCompletionOperations()
        XCTAssertTrue(pendingReplans.isEmpty)
        XCTAssertTrue(pendingCompletions.isEmpty)
        try await assertStoredSourceBytes(
            archive: receivingBase,
            expectedBytes: fixture.sourceBytes,
            in: receivingStore
        )

        _ = try await publishingEngine.synchronize()
        let beforeReverseSnapshot = try await publishingEngine.snapshot()
        try await assertRemoteBlob(
            basePayload,
            entity: workspaceEntity,
            field: archiveField,
            snapshot: beforeReverseSnapshot,
            engine: publishingEngine
        )

        let stableBytes = try await receivingStore.encodeArchiveForSync(
            received.archive
        )
        let firstReverse = try await adapter.publishLocalAndSynchronize(
            received.archive,
            now: fixture.completedAt.addingTimeInterval(30)
        )
        XCTAssertNil(firstReverse.pendingReview)
        let firstReverseBytes = try await receivingStore.encodeArchiveForSync(
            firstReverse.archive
        )
        XCTAssertEqual(firstReverseBytes, stableBytes)
        let secondReverse = try await adapter.publishLocalAndSynchronize(
            firstReverse.archive,
            now: fixture.completedAt.addingTimeInterval(40)
        )
        XCTAssertNil(secondReverse.pendingReview)
        let secondReverseBytes = try await receivingStore.encodeArchiveForSync(
            secondReverse.archive
        )
        XCTAssertEqual(secondReverseBytes, stableBytes)
        XCTAssertEqual(
            canonicalSourceBytes(secondReverse.archive),
            fixture.sourceRecordBytes
        )
        XCTAssertEqual(
            canonicalDeadlineBytes(secondReverse.archive),
            fixture.deadlineBytes
        )
        try await assertStoredSourceBytes(
            archive: receivingBase,
            expectedBytes: fixture.sourceBytes,
            in: receivingStore
        )
    }

    func testHistoricalProjectionAllowsSameActionReplanThenCompletionOverStaleHead()
        async throws {
        let root = temporaryRoot(named: "replan-history-projection")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: remote,
            withIntermediateDirectories: true
        )
        let fixture = try makeFixture()
        let actionAfterReplan = try XCTUnwrap(
            fixture.acceptance.archive.workspace.dailyActions.first {
                $0.metadata.id == fixture.action.metadata.id
            }
        )
        let packageAfterReplan = try XCTUnwrap(
            fixture.acceptance.archive.workspace.guidedPackages.first {
                $0.metadata.id == actionAfterReplan.packageID
            }
        )
        let completedAt = fixture.occurredAt.addingTimeInterval(60)
        let completionOperation = try makeCompletionOperation(
            action: actionAfterReplan,
            package: packageAfterReplan,
            archive: fixture.acceptance.archive,
            operationID: OperationID(fixedUUID(710)),
            attestationID: CompletionEvidenceID(fixedUUID(711)),
            completedAt: completedAt
        )
        let completedArchive = try NextStepBetaCompletionOperationReducer().replay(
            completionOperation,
            in: fixture.acceptance.archive
        ).archive
        try completedArchive.validate()

        let libraryID = SyncLibraryID(fixedUUID(940))
        let publisher = try makeEngine(
            localRoot: root.appendingPathComponent("engine-publisher", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(941)),
            now: completedAt.addingTimeInterval(10),
            libraryID: libraryID
        )
        let workspaceEntity = try SyncEntityReference(
            kind: SyncKey("betaWorkspace"),
            id: UUID(uuidString: "0f8d9ea7-d17d-4f09-b566-09e3a3ec17b1")!
        )
        let archiveField = try SyncKey("archive")
        let operationField = try SyncKey("operation")
        let replanEntity = try SyncEntityReference(
            kind: SyncKey("betaActionReplan"),
            id: fixture.acceptance.operation.operationID.rawValue
        )
        let completionEntity = try SyncEntityReference(
            kind: SyncKey("betaActionCompletion"),
            id: completionOperation.actionID.rawValue
        )
        let completePayload = try encodeSyncSeedPayload(completedArchive)
        let stalePayload = try encodeSyncSeedPayload(fixture.baseArchive)

        // Publish the valid complete R→C projection first so it remains in
        // immutable archive history, then deliberately make the older base the
        // current LWW head. A fresh receiver must consult that history before
        // classifying the two same-action intents as a conflict.
        _ = try await publisher.enqueueBlob(
            entity: workspaceEntity,
            field: archiveField,
            data: completePayload,
            mediaType: "application/vnd.nextstep.beta-archive+json",
            policy: .flexibleLastWriterWins
        )
        _ = try await publisher.synchronize()
        _ = try await publisher.enqueueBlob(
            entity: replanEntity,
            field: operationField,
            data: try fixture.acceptance.operation.canonicalData(),
            mediaType: "application/vnd.nextstep.action-replan+json",
            policy: .immutable
        )
        _ = try await publisher.enqueueBlob(
            entity: completionEntity,
            field: operationField,
            data: try completionOperation.canonicalData(),
            mediaType: "application/vnd.nextstep.guided-action-completion+json",
            policy: .immutable
        )
        _ = try await publisher.synchronize()
        _ = try await publisher.enqueueBlob(
            entity: workspaceEntity,
            field: archiveField,
            data: stalePayload,
            mediaType: "application/vnd.nextstep.beta-archive+json",
            policy: .flexibleLastWriterWins
        )
        _ = try await publisher.synchronize()
        let staleSnapshot = try await publisher.snapshot()
        try await assertRemoteBlob(
            stalePayload,
            entity: workspaceEntity,
            field: archiveField,
            snapshot: staleSnapshot,
            engine: publisher
        )

        var receivingBase = fixture.baseArchive
        receivingBase.deviceID = NextStepDomain.DeviceID(fixedUUID(42))
        try receivingBase.validate()
        let receivingStore = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-receiver", isDirectory: true)
        )
        try await installFixtureSources(
            archive: receivingBase,
            sourceBytes: fixture.sourceBytes,
            in: receivingStore
        )
        try await receivingStore.save(receivingBase, replacing: nil)
        let receiver = NextStepBetaSyncArchiveAdapter(
            engine: try makeEngine(
                localRoot: root.appendingPathComponent("engine-receiver", isDirectory: true),
                remoteRoot: remote,
                deviceID: NextStepSync.DeviceID(fixedUUID(942)),
                now: completedAt.addingTimeInterval(20),
                libraryID: libraryID
            ),
            store: receivingStore
        )

        let received = try await receiver.reconcileInitial(
            localArchive: receivingBase,
            now: completedAt.addingTimeInterval(20)
        )
        XCTAssertNil(received.pendingReview)
        XCTAssertEqual(received.archive.workspace, completedArchive.workspace)
        XCTAssertEqual(
            received.archive.currentDecisionID,
            completedArchive.currentDecisionID
        )
        XCTAssertEqual(
            received.archive.actionReplanApplicationReceipts,
            completedArchive.actionReplanApplicationReceipts
        )
        XCTAssertEqual(
            received.archive.completionApplicationReceipts,
            completedArchive.completionApplicationReceipts
        )
        XCTAssertEqual(canonicalSourceBytes(received.archive), fixture.sourceRecordBytes)
        XCTAssertEqual(canonicalDeadlineBytes(received.archive), fixture.deadlineBytes)
        let storedReplans = try await receivingStore.storedActionReplanOperations()
        let storedCompletions = try await receivingStore.storedCompletionOperations()
        XCTAssertEqual(storedReplans.map(\.operation), [fixture.acceptance.operation])
        XCTAssertEqual(storedCompletions.map(\.operation), [completionOperation])
        try received.archive.validate()
        try await assertStoredSourceBytes(fixture, in: receivingStore)
    }

    func testTwoCompetingDeferralIntentsFailClosedAndPreserveEachLocalBranch() async throws {
        let root = temporaryRoot(named: "replan-competing-deferrals")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: remote,
            withIntermediateDirectories: true
        )
        let fixture = try makeFixture()
        let storeA = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-a", isDirectory: true)
        )
        let storeB = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-b", isDirectory: true)
        )
        let baseA = fixture.baseArchive
        var baseB = fixture.baseArchive
        baseB.deviceID = NextStepDomain.DeviceID(fixedUUID(2))
        try baseB.validate()
        let competing = try makeReplanAcceptance(
            archive: baseB,
            operationID: OperationID(fixedUUID(501)),
            trigger: .insufficientTime,
            reasonCode: .insufficientTime,
            remainingMinutes: 10,
            occurredAt: fixture.occurredAt.addingTimeInterval(1)
        )
        try await installFixtureSource(fixture, in: storeA)
        try await installFixtureSource(fixture, in: storeB)
        try await storeA.save(baseA, replacing: nil)
        try await storeB.save(baseB, replacing: nil)

        let libraryID = SyncLibraryID(fixedUUID(910))
        let adapterA = NextStepBetaSyncArchiveAdapter(
            engine: try makeEngine(
                localRoot: root.appendingPathComponent("engine-a", isDirectory: true),
                remoteRoot: remote,
                deviceID: NextStepSync.DeviceID(fixedUUID(911)),
                now: fixture.occurredAt.addingTimeInterval(10),
                libraryID: libraryID
            ),
            store: storeA
        )
        let adapterB = NextStepBetaSyncArchiveAdapter(
            engine: try makeEngine(
                localRoot: root.appendingPathComponent("engine-b", isDirectory: true),
                remoteRoot: remote,
                deviceID: NextStepSync.DeviceID(fixedUUID(912)),
                now: fixture.occurredAt.addingTimeInterval(20),
                libraryID: libraryID
            ),
            store: storeB
        )
        _ = try await adapterA.reconcileInitial(
            localArchive: baseA,
            now: fixture.occurredAt.addingTimeInterval(2)
        )
        _ = try await adapterB.reconcileInitial(
            localArchive: baseB,
            now: fixture.occurredAt.addingTimeInterval(3)
        )
        try await storeA.saveActionReplanOperation(
            fixture.acceptance.archive,
            replacing: baseA,
            operation: fixture.acceptance.operation
        )
        try await storeB.saveActionReplanOperation(
            competing.archive,
            replacing: baseB,
            operation: competing.operation
        )
        let publishedA = try await adapterA.publishLocalAndSynchronize(
            fixture.acceptance.archive,
            now: fixture.occurredAt.addingTimeInterval(10)
        )
        XCTAssertNil(publishedA.pendingReview)

        try await assertActionReplanReview {
            try await adapterB.publishLocalAndSynchronize(
                competing.archive,
                now: fixture.occurredAt.addingTimeInterval(20)
            )
        }
        let durableBValue = try await storeB.load()
        let durableB = try XCTUnwrap(durableBValue)
        try assertReplan(
            durableB,
            operation: competing.operation,
            expectedSourceBytes: fixture.sourceRecordBytes,
            expectedDeadlineBytes: fixture.deadlineBytes
        )
        XCTAssertFalse(durableB.actionReplanApplicationReceipts.contains {
            $0.operationID == fixture.acceptance.operation.operationID
        })

        try await assertActionReplanReview {
            try await adapterA.publishLocalAndSynchronize(
                publishedA.archive,
                now: fixture.occurredAt.addingTimeInterval(30)
            )
        }
        let durableAValue = try await storeA.load()
        let durableA = try XCTUnwrap(durableAValue)
        try assertReplan(
            durableA,
            operation: fixture.acceptance.operation,
            expectedSourceBytes: fixture.sourceRecordBytes,
            expectedDeadlineBytes: fixture.deadlineBytes
        )
        XCTAssertFalse(durableA.actionReplanApplicationReceipts.contains {
            $0.operationID == competing.operation.operationID
        })
        try await assertStoredSourceBytes(fixture, in: storeA)
        try await assertStoredSourceBytes(fixture, in: storeB)
    }

    func testCompletionCompetingWithDeferralRequiresReviewWithoutCorruptingEitherLedger()
        async throws {
        let root = temporaryRoot(named: "replan-completion-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: remote,
            withIntermediateDirectories: true
        )
        let fixture = try makeFixture()
        let completionOperation = try makeCompletionOperation(fixture)
        let completedA = try NextStepBetaCompletionOperationReducer().replay(
            completionOperation,
            in: fixture.baseArchive
        ).archive
        var baseB = fixture.baseArchive
        baseB.deviceID = NextStepDomain.DeviceID(fixedUUID(2))
        try baseB.validate()
        let replanB = try makeReplanAcceptance(
            archive: baseB,
            operationID: OperationID(fixedUUID(501)),
            trigger: .actionDeferred,
            reasonCode: .userRequestedDeferral,
            remainingMinutes: nil,
            occurredAt: fixture.occurredAt
        )
        let storeA = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-a", isDirectory: true)
        )
        let storeB = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-b", isDirectory: true)
        )
        try await installFixtureSource(fixture, in: storeA)
        try await installFixtureSource(fixture, in: storeB)
        try await storeA.save(fixture.baseArchive, replacing: nil)
        try await storeB.save(baseB, replacing: nil)

        let libraryID = SyncLibraryID(fixedUUID(920))
        let adapterA = NextStepBetaSyncArchiveAdapter(
            engine: try makeEngine(
                localRoot: root.appendingPathComponent("engine-a", isDirectory: true),
                remoteRoot: remote,
                deviceID: NextStepSync.DeviceID(fixedUUID(921)),
                now: fixture.occurredAt.addingTimeInterval(10),
                libraryID: libraryID
            ),
            store: storeA
        )
        let adapterB = NextStepBetaSyncArchiveAdapter(
            engine: try makeEngine(
                localRoot: root.appendingPathComponent("engine-b", isDirectory: true),
                remoteRoot: remote,
                deviceID: NextStepSync.DeviceID(fixedUUID(922)),
                now: fixture.occurredAt.addingTimeInterval(20),
                libraryID: libraryID
            ),
            store: storeB
        )
        _ = try await adapterA.reconcileInitial(
            localArchive: fixture.baseArchive,
            now: fixture.occurredAt.addingTimeInterval(2)
        )
        _ = try await adapterB.reconcileInitial(
            localArchive: baseB,
            now: fixture.occurredAt.addingTimeInterval(3)
        )
        try await storeA.saveCompletionOperation(
            completedA,
            replacing: fixture.baseArchive,
            operation: completionOperation
        )
        try await storeB.saveActionReplanOperation(
            replanB.archive,
            replacing: baseB,
            operation: replanB.operation
        )
        let publishedA = try await adapterA.publishLocalAndSynchronize(
            completedA,
            now: fixture.occurredAt.addingTimeInterval(10)
        )
        XCTAssertNil(publishedA.pendingReview)

        try await assertActionReplanReview {
            try await adapterB.publishLocalAndSynchronize(
                replanB.archive,
                now: fixture.occurredAt.addingTimeInterval(20)
            )
        }
        let durableBValue = try await storeB.load()
        let durableB = try XCTUnwrap(durableBValue)
        XCTAssertEqual(
            canonicalSourceBytes(durableB),
            fixture.sourceRecordBytes
        )
        XCTAssertEqual(canonicalDeadlineBytes(durableB), fixture.deadlineBytes)
        XCTAssertTrue(durableB.actionReplanApplicationReceipts.contains {
            $0.operationID == replanB.operation.operationID
        })
        XCTAssertTrue(
            durableB.completionApplicationReceipts.isEmpty
                || durableB.completionApplicationReceipts.contains {
                    $0.operationID == completionOperation.operationID
                }
        )
        try durableB.validate()

        try await assertActionReplanReview {
            try await adapterA.publishLocalAndSynchronize(
                publishedA.archive,
                now: fixture.occurredAt.addingTimeInterval(30)
            )
        }
        let durableAValue = try await storeA.load()
        let durableA = try XCTUnwrap(durableAValue)
        XCTAssertTrue(durableA.completionApplicationReceipts.contains {
            $0.operationID == completionOperation.operationID
        })
        XCTAssertFalse(durableA.actionReplanApplicationReceipts.contains {
            $0.operationID == replanB.operation.operationID
        })
        XCTAssertEqual(canonicalSourceBytes(durableA), fixture.sourceRecordBytes)
        XCTAssertEqual(canonicalDeadlineBytes(durableA), fixture.deadlineBytes)
        try durableA.validate()
        try await assertStoredSourceBytes(fixture, in: storeA)
        try await assertStoredSourceBytes(fixture, in: storeB)
    }

    private struct Fixture {
        let baseArchive: NextStepBetaArchive
        let action: DailyAction
        let package: GuidedLearningPackage
        let sourceBytes: Data
        let occurredAt: Date
        let acceptance: NextStepBetaActionReplanAcceptance
        let sourceRecordBytes: Data
        let deadlineBytes: Data
    }

    private struct CrossTypeFixture {
        let baseArchive: NextStepBetaArchive
        let replan: NextStepBetaActionReplanAcceptance
        let completion: CompletionFixture
        let finalArchive: NextStepBetaArchive
        let sourceBytes: Data
        let completedAt: Date
        let sourceRecordBytes: Data
        let deadlineBytes: Data
    }

    private struct CompletionFixture {
        let operation: NextStepBetaGuidedActionCompletionOperation
        let archive: NextStepBetaArchive
    }

    private struct SyncSeedPayload: Encodable {
        let schemaVersion: Int
        let workspace: NextStepWorkspaceSnapshot
        let currentDecisionID: PlanningDecisionID?
        let grounding: NextStepBetaGroundingState?
        let completionApplicationReceipts: [NextStepBetaCompletionApplicationReceipt]?
        let actionReplanApplicationReceipts: [NextStepBetaActionReplanApplicationReceipt]?
    }

    private struct ProjectionFingerprint: Equatable {
        let revision: Int64
        let savedAt: Date
        let currentDecisionID: PlanningDecisionID?
        let decisionCount: Int
        let eventCount: Int
        let receiptCount: Int
        let actionStatus: ActionStatus?
        let actionEarliestDay: LocalDay?
        let actionScheduledDay: LocalDay?
        let sourceBytes: Data
        let deadlineBytes: Data
    }

    private struct DeadlineEnvelope: Encodable {
        let ultimate: [FactValue<LocalDay>?]
        let goals: [FactValue<LocalDay>?]
        let milestones: [FactValue<LocalDay>?]
        let actions: [FactValue<LocalDay>?]
    }

    private func makeFixture() throws -> Fixture {
        let createdAt = Date(timeIntervalSince1970: 1_820_000_000)
        let occurredAt = createdAt.addingTimeInterval(60)
        let deviceID = NextStepDomain.DeviceID(fixedUUID(1))
        let sourceBytes = Data(
            "A protected source remains byte-identical while a daily action is deferred."
                .utf8
        )
        let sourceDigest = SHA256.hash(data: sourceBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: createdAt,
            deviceID: deviceID,
            timeZoneIdentifier: "UTC"
        )
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "Complete the source-grounded finance milestone",
            deadline: try LocalDay(year: 2029, month: 12, day: 31),
            dailyMinutes: 35,
            to: archive,
            now: createdAt
        )
        let sourceID = SourceDocumentID(fixedUUID(100))
        let relativePath = "Sources/\(sourceID.description)/original.pdf"
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceID,
            displayTitle: "Verified deferral source",
            fileExtension: "pdf",
            relativePath: relativePath,
            contentSHA256: sourceDigest,
            now: createdAt,
            deviceID: deviceID,
            parserVersion: "replan-integration-tests-v1"
        )
        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: document,
                exactExtract: [
                    "Debt creates contractual interest obligations.",
                    "Cash flow supports debt service capacity.",
                    "Every conclusion remains linked to the verified source."
                ].joined(separator: "\n"),
                pageIndex: 0,
                usedVisionOCR: true,
                extractionNotice: "OCR text requires explicit confirmation."
            ),
            to: archive,
            now: createdAt
        )
        archive = try NextStepBetaPlanningBridge().replan(
            archive: archive,
            trigger: .sourceImported,
            now: createdAt.addingTimeInterval(10)
        )
        let action = try XCTUnwrap(archive.workspace.dailyActions.first)
        let package = try XCTUnwrap(archive.workspace.guidedPackages.first {
            $0.metadata.id == action.packageID
        })
        XCTAssertNil(package.quiz)
        let acceptance = try makeReplanAcceptance(
            archive: archive,
            operationID: OperationID(fixedUUID(500)),
            trigger: .actionDeferred,
            reasonCode: .userRequestedDeferral,
            remainingMinutes: nil,
            occurredAt: occurredAt
        )
        return Fixture(
            baseArchive: archive,
            action: action,
            package: package,
            sourceBytes: sourceBytes,
            occurredAt: occurredAt,
            acceptance: acceptance,
            sourceRecordBytes: canonicalSourceBytes(archive),
            deadlineBytes: canonicalDeadlineBytes(archive)
        )
    }

    private func makeCrossTypeFixture() throws -> CrossTypeFixture {
        let createdAt = Date(timeIntervalSince1970: 1_830_000_000)
        let replanAt = createdAt.addingTimeInterval(60)
        let completedAt = createdAt.addingTimeInterval(120)
        let deviceID = NextStepDomain.DeviceID(fixedUUID(31))
        let sourceBytes = Data(
            "Two grounded actions share protected source bytes while execution "
                .appending("operations advance in causal order.")
                .utf8
        )
        let sourceDigest = SHA256.hash(data: sourceBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: createdAt,
            deviceID: deviceID,
            timeZoneIdentifier: "UTC"
        )
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "Complete two causally ordered grounded actions",
            deadline: try LocalDay(year: 2030, month: 12, day: 31),
            dailyMinutes: 35,
            to: archive,
            now: createdAt
        )

        let sourceAID = SourceDocumentID(fixedUUID(200))
        let sourceA = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceAID,
            displayTitle: "Causal source A",
            fileExtension: "pdf",
            relativePath: "Sources/\(sourceAID.description)/original.pdf",
            contentSHA256: sourceDigest,
            now: createdAt,
            deviceID: deviceID,
            parserVersion: "cross-type-causal-integration-v1"
        )
        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: sourceA,
                exactExtract: [
                    "Action A establishes the first planning transition.",
                    "Its source and protected deadline remain immutable.",
                    "The accepted deferral precedes the independent completion."
                ].joined(separator: "\n"),
                pageIndex: 0,
                usedVisionOCR: true,
                extractionNotice: "OCR text requires explicit confirmation."
            ),
            to: archive,
            now: createdAt
        )

        let sourceBID = SourceDocumentID(fixedUUID(201))
        let sourceB = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceBID,
            displayTitle: "Causal source B",
            fileExtension: "pdf",
            relativePath: "Sources/\(sourceBID.description)/original.pdf",
            contentSHA256: sourceDigest,
            now: createdAt,
            deviceID: deviceID,
            parserVersion: "cross-type-causal-integration-v1"
        )
        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: sourceB,
                exactExtract: [
                    "Action B is completed only after action A is deferred.",
                    "The completion derives a later deterministic decision.",
                    "Both immutable operations must replay from the older head."
                ].joined(separator: "\n"),
                pageIndex: 1,
                usedVisionOCR: true,
                extractionNotice: "OCR text requires explicit confirmation."
            ),
            to: archive,
            now: createdAt
        )
        archive = try NextStepBetaPlanningBridge().replan(
            archive: archive,
            trigger: .sourceImported,
            now: createdAt.addingTimeInterval(10)
        )

        let actionA = try XCTUnwrap(archive.workspace.dailyActions.first {
            $0.sourceDocumentIDs.contains(sourceAID)
        })
        let actionBID = try XCTUnwrap(archive.workspace.dailyActions.first {
            $0.sourceDocumentIDs.contains(sourceBID)
        }?.metadata.id)
        XCTAssertNotEqual(actionA.metadata.id, actionBID)
        let replan = try makeReplanAcceptance(
            archive: archive,
            operationID: OperationID(fixedUUID(700)),
            trigger: .actionDeferred,
            reasonCode: .userRequestedDeferral,
            remainingMinutes: nil,
            occurredAt: replanAt,
            actionID: actionA.metadata.id
        )
        let actionBAfterReplan = try XCTUnwrap(
            replan.archive.workspace.dailyActions.first {
                $0.metadata.id == actionBID
            }
        )
        let packageB = try XCTUnwrap(
            replan.archive.workspace.guidedPackages.first {
                $0.metadata.id == actionBAfterReplan.packageID
            }
        )
        XCTAssertNil(packageB.quiz)
        let completionOperation = try makeCompletionOperation(
            action: actionBAfterReplan,
            package: packageB,
            archive: replan.archive,
            operationID: OperationID(fixedUUID(701)),
            attestationID: CompletionEvidenceID(fixedUUID(702)),
            completedAt: completedAt
        )
        let completedArchive = try NextStepBetaCompletionOperationReducer().replay(
            completionOperation,
            in: replan.archive
        ).archive
        try completedArchive.validate()
        return CrossTypeFixture(
            baseArchive: archive,
            replan: replan,
            completion: CompletionFixture(
                operation: completionOperation,
                archive: completedArchive
            ),
            finalArchive: completedArchive,
            sourceBytes: sourceBytes,
            completedAt: completedAt,
            sourceRecordBytes: canonicalSourceBytes(archive),
            deadlineBytes: canonicalDeadlineBytes(archive)
        )
    }

    private func makeReplanAcceptance(
        archive: NextStepBetaArchive,
        operationID: OperationID,
        trigger: ReplanTrigger,
        reasonCode: NextStepBetaActionReplanReasonCode,
        remainingMinutes: Int?,
        occurredAt: Date,
        actionID requestedActionID: DailyActionID? = nil
    ) throws -> NextStepBetaActionReplanAcceptance {
        let actionID: DailyActionID
        if let requestedActionID {
            actionID = requestedActionID
        } else {
            actionID = try XCTUnwrap(
                archive.workspace.dailyActions.first?.metadata.id
            )
        }
        let today = try LocalDay(
            date: occurredAt,
            timeZoneIdentifier: archive.workspace.userProfile.timeZoneIdentifier
        )
        let preview = try NextStepBetaActionReplanCoordinator().prepare(
            operationID: operationID,
            actionID: actionID,
            trigger: trigger,
            reasonCode: reasonCode,
            requestedEarliestDay: try today.adding(days: 1),
            remainingMinutes: remainingMinutes,
            in: archive,
            occurredAt: occurredAt
        )
        return try NextStepBetaActionReplanCoordinator().accept(
            preview,
            in: archive
        )
    }

    private func makeCompletionOperation(
        _ fixture: Fixture
    ) throws -> NextStepBetaGuidedActionCompletionOperation {
        try makeCompletionOperation(
            action: fixture.action,
            package: fixture.package,
            archive: fixture.baseArchive,
            operationID: OperationID(fixedUUID(600)),
            attestationID: CompletionEvidenceID(fixedUUID(601)),
            completedAt: fixture.occurredAt.addingTimeInterval(5)
        )
    }

    private func makeCompletionOperation(
        action: DailyAction,
        package: GuidedLearningPackage,
        archive: NextStepBetaArchive,
        operationID: OperationID,
        attestationID: CompletionEvidenceID,
        completedAt: Date
    ) throws -> NextStepBetaGuidedActionCompletionOperation {
        let criterionIDs = action.completionCriteria
            .map(\.id)
            .sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
        let attestation = try CompletionEvidence(
            metadata: RecordMetadata(
                id: attestationID,
                createdAt: completedAt,
                originDeviceID: archive.deviceID,
                lastOperationID: operationID,
                provenance: .user
            ),
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            kind: .userAttestation,
            value: "Verified point one\nVerified point two\nVerified point three",
            capturedAt: completedAt,
            criterionIDs: criterionIDs
        )
        return try NextStepBetaGuidedActionCompletionOperation(
            operationID: operationID,
            action: action,
            package: package,
            completedAt: completedAt,
            originDeviceID: archive.deviceID,
            userAttestation: attestation
        )
    }

    private func installFixtureSource(
        _ fixture: Fixture,
        in store: NextStepBetaStore
    ) async throws {
        try await installFixtureSources(
            archive: fixture.baseArchive,
            sourceBytes: fixture.sourceBytes,
            in: store
        )
    }

    private func installFixtureSources(
        archive: NextStepBetaArchive,
        sourceBytes: Data,
        in store: NextStepBetaStore
    ) async throws {
        for document in archive.workspace.sourceDocuments {
            let relativePath = try XCTUnwrap(document.localRelativePath)
            let expectedSHA256 = try XCTUnwrap(document.contentSHA256)
            try await store.installSyncedSource(
                sourceBytes,
                relativePath: relativePath,
                expectedSHA256: expectedSHA256
            )
        }
    }

    private func assertStoredSourceBytes(
        _ fixture: Fixture,
        in store: NextStepBetaStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await assertStoredSourceBytes(
            archive: fixture.baseArchive,
            expectedBytes: fixture.sourceBytes,
            in: store,
            file: file,
            line: line
        )
    }

    private func assertStoredSourceBytes(
        archive: NextStepBetaArchive,
        expectedBytes: Data,
        in store: NextStepBetaStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for document in archive.workspace.sourceDocuments {
            let relativePath = try XCTUnwrap(
                document.localRelativePath,
                file: file,
                line: line
            )
            let storedBytes = try await store.storedSourceData(
                relativePath: relativePath
            )
            XCTAssertEqual(storedBytes, expectedBytes, file: file, line: line)
        }
    }

    private func assertReplan(
        _ archive: NextStepBetaArchive,
        operation: NextStepBetaActionReplanOperationV1,
        expectedSourceBytes: Data,
        expectedDeadlineBytes: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let action = try XCTUnwrap(
            archive.workspace.dailyActions.first {
                $0.metadata.id == operation.actionID
            },
            file: file,
            line: line
        )
        XCTAssertEqual(
            action.earliestDay,
            operation.requestedEarliestDay,
            file: file,
            line: line
        )
        XCTAssertNotEqual(action.status, .deferred, file: file, line: line)
        XCTAssertTrue(
            archive.workspace.planningDecisions.contains {
                $0.metadata.id == operation.decisionID
            },
            file: file,
            line: line
        )
        XCTAssertTrue(
            archive.workspace.replanEvents.contains {
                $0.metadata.id == operation.replanEventID
            },
            file: file,
            line: line
        )
        let receipts = archive.actionReplanApplicationReceipts.filter {
            $0.operationID == operation.operationID
        }
        XCTAssertEqual(receipts.count, 1, file: file, line: line)
        XCTAssertTrue(
            receipts.first?.matches(operation) == true,
            file: file,
            line: line
        )
        XCTAssertEqual(
            canonicalSourceBytes(archive),
            expectedSourceBytes,
            file: file,
            line: line
        )
        XCTAssertEqual(
            canonicalDeadlineBytes(archive),
            expectedDeadlineBytes,
            file: file,
            line: line
        )
        try archive.validate()
    }

    private func assertActionReplanReview(
        _ operation: () async throws -> NextStepBetaSyncAdapterResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            let result = try await operation()
            XCTAssertEqual(
                result.pendingReview?.summary.kind,
                .actionReplan,
                file: file,
                line: line
            )
        } catch let error as NextStepBetaActionReplanOperationError {
            switch error {
            case .contextRequiresReview, .derivedRecordConflict:
                break
            default:
                XCTFail("Unexpected replan failure: \(error)", file: file, line: line)
            }
            guard case .reviewRequired(let review) =
                NextStepBetaSyncFailureClassifier.state(
                    for: error,
                    lastSyncedAt: nil
                ) else {
                return XCTFail(
                    "The sync classifier must surface a review state.",
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(review.kind, .actionReplan, file: file, line: line)
        }
    }

    private func projectionFingerprint(
        _ archive: NextStepBetaArchive
    ) -> ProjectionFingerprint {
        let action = archive.workspace.dailyActions.first
        return ProjectionFingerprint(
            revision: archive.workspace.revision,
            savedAt: archive.workspace.savedAt,
            currentDecisionID: archive.currentDecisionID,
            decisionCount: archive.workspace.planningDecisions.count,
            eventCount: archive.workspace.replanEvents.count,
            receiptCount: archive.actionReplanApplicationReceipts.count,
            actionStatus: action?.status,
            actionEarliestDay: action?.earliestDay,
            actionScheduledDay: action?.scheduledDay,
            sourceBytes: canonicalSourceBytes(archive),
            deadlineBytes: canonicalDeadlineBytes(archive)
        )
    }

    private func canonicalSourceBytes(_ archive: NextStepBetaArchive) -> Data {
        let sources = archive.workspace.sourceDocuments.sorted {
            $0.metadata.id < $1.metadata.id
        }
        return (try? canonicalData(sources)) ?? Data()
    }

    private func canonicalDeadlineBytes(_ archive: NextStepBetaArchive) -> Data {
        let envelope = DeadlineEnvelope(
            ultimate: archive.workspace.ultimateGoals
                .sorted { $0.metadata.id < $1.metadata.id }
                .map(\.targetDay),
            goals: archive.workspace.goals
                .sorted { $0.metadata.id < $1.metadata.id }
                .map(\.targetDay),
            milestones: archive.workspace.milestones
                .sorted { $0.metadata.id < $1.metadata.id }
                .map(\.targetDay),
            actions: archive.workspace.dailyActions
                .sorted { $0.metadata.id < $1.metadata.id }
                .map(\.deadline)
        )
        return (try? canonicalData(envelope)) ?? Data()
    }

    private func canonicalData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func encodeSyncSeedPayload(
        _ archive: NextStepBetaArchive
    ) throws -> Data {
        try archive.validate()
        let payload = SyncSeedPayload(
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

    private func assertRemoteBlob(
        _ expected: Data,
        entity: SyncEntityReference,
        field: SyncKey,
        snapshot: SyncSnapshot,
        engine: NextStepSyncEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        guard case .blob(let reference)? = snapshot.entity(entity)?.field(field)?.value else {
            XCTFail(
                "Expected a remote blob for \(entity) / \(field).",
                file: file,
                line: line
            )
            return
        }
        let remoteData = try await engine.blobData(for: reference)
        let actual = try XCTUnwrap(remoteData, file: file, line: line)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func makeEngine(
        localRoot: URL,
        remoteRoot: URL,
        deviceID: NextStepSync.DeviceID,
        now: Date,
        libraryID: SyncLibraryID
    ) throws -> NextStepSyncEngine {
        let transport = try FileFolderSyncTransport(
            rootURL: remoteRoot,
            requiresSecurityScopedAccess: false
        )
        return try NextStepSyncEngine(
            libraryID: libraryID,
            deviceID: deviceID,
            localRootURL: localRoot,
            transport: transport,
            now: { now }
        )
    }

    private func temporaryRoot(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func fixedUUID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
