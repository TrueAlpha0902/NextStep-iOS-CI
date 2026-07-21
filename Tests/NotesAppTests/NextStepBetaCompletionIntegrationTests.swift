import CryptoKit
import Foundation
import NextStepDomain
import NextStepPlanning
import NextStepSync
@testable import NotesApp
import XCTest

final class NextStepBetaCompletionIntegrationTests: XCTestCase {
    func testLocalCompletionCommitSurvivesReopenAndExactReplayIsNoOp() async throws {
        let root = temporaryRoot(named: "completion-reopen")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let store = NextStepBetaStore(rootURL: root)
        try await installFixtureSource(fixture, in: store)
        try await store.save(fixture.baseArchive, replacing: nil)

        let completed = try completedArchive(
            fixture.baseArchive,
            operation: fixture.primaryOperation
        )
        try await store.saveCompletionOperation(
            completed,
            replacing: fixture.baseArchive,
            operation: fixture.primaryOperation
        )

        let reopened = NextStepBetaStore(rootURL: root)
        let loadedValue = try await reopened.load()
        let loaded = try XCTUnwrap(loadedValue)
        try assertFullCompletion(loaded, operation: fixture.primaryOperation)
        let loadedBytes = try await reopened.encodeArchiveForSync(loaded)
        let completedBytes = try await reopened.encodeArchiveForSync(completed)
        XCTAssertEqual(loadedBytes, completedBytes)

        let pending = try await reopened.pendingCompletionOperations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.operation, fixture.primaryOperation)
        XCTAssertEqual(
            pending.first?.canonicalData,
            try fixture.primaryOperation.canonicalData()
        )

        try await reopened.markCompletionOperationPublished(
            fixture.primaryOperation,
            publishedAt: fixture.completedAt.addingTimeInterval(1)
        )
        let pendingAfterPublish = try await reopened.pendingCompletionOperations()
        XCTAssertTrue(pendingAfterPublish.isEmpty)
        let durableForFutureDestinations = try await reopened.storedCompletionOperations()
        XCTAssertEqual(durableForFutureDestinations.count, 1)
        XCTAssertEqual(
            durableForFutureDestinations.first?.operation,
            fixture.primaryOperation
        )
        let bytesBeforeReplay = try await reopened.encodeArchiveForSync(loaded)

        // The projection is already current and the outbox row is published.
        // Success therefore indirectly proves the immutable applied-operation
        // ledger survived reopen; the exact replay must not create new work.
        try await reopened.saveCompletionOperation(
            completed,
            replacing: fixture.baseArchive,
            operation: fixture.primaryOperation
        )

        let afterReplayValue = try await reopened.load()
        let afterReplay = try XCTUnwrap(afterReplayValue)
        let bytesAfterReplay = try await reopened.encodeArchiveForSync(afterReplay)
        XCTAssertEqual(bytesAfterReplay, bytesBeforeReplay)
        let pendingAfterReplay = try await reopened.pendingCompletionOperations()
        XCTAssertTrue(pendingAfterReplay.isEmpty)
        try assertFullCompletion(afterReplay, operation: fixture.primaryOperation)
    }

    func testStaleArchiveSnapshotCannotRegressDurableCompletion() async throws {
        let root = temporaryRoot(named: "completion-stale-cas")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture()
        let store = NextStepBetaStore(rootURL: root)
        try await installFixtureSource(fixture, in: store)
        try await store.save(fixture.baseArchive, replacing: nil)
        let completed = try completedArchive(
            fixture.baseArchive,
            operation: fixture.primaryOperation
        )
        try await store.saveCompletionOperation(
            completed,
            replacing: fixture.baseArchive,
            operation: fixture.primaryOperation
        )

        do {
            try await store.save(
                fixture.baseArchive,
                replacing: fixture.baseArchive
            )
            XCTFail("A stale uncompleted parent must not replace a durable completion.")
        } catch {
            XCTAssertEqual(error as? NextStepBetaStoreError, .localPersistenceFailure)
        }

        let loadedValue = try await store.load()
        let loaded = try XCTUnwrap(loadedValue)
        try assertFullCompletion(loaded, operation: fixture.primaryOperation)
        let pending = try await store.pendingCompletionOperations()
        XCTAssertEqual(
            pending.map(\.operation),
            [fixture.primaryOperation]
        )
    }

    func testTwoFileFolderDevicesConvergeQuizCompletionOverStaleUncompletedHead() async throws {
        let root = temporaryRoot(named: "completion-folder-convergence")
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
        let engineA = try makeEngine(
            localRoot: root.appendingPathComponent("engine-a", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(901)),
            now: fixture.completedAt.addingTimeInterval(10),
            libraryID: libraryID
        )
        let engineB = try makeEngine(
            localRoot: root.appendingPathComponent("engine-b", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(902)),
            // B publishes later so its uncompleted archive is the stale LWW
            // head. The immutable operation must still restore completion.
            now: fixture.completedAt.addingTimeInterval(20),
            libraryID: libraryID
        )
        let adapterA = NextStepBetaSyncArchiveAdapter(engine: engineA, store: storeA)
        let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)

        _ = try await adapterA.reconcileInitial(
            localArchive: baseA,
            now: fixture.completedAt.addingTimeInterval(2)
        )
        _ = try await adapterB.reconcileInitial(
            localArchive: baseB,
            now: fixture.completedAt.addingTimeInterval(3)
        )

        let completedA = try completedArchive(
            baseA,
            operation: fixture.primaryOperation
        )
        try await storeA.saveCompletionOperation(
            completedA,
            replacing: baseA,
            operation: fixture.primaryOperation
        )
        var staleUncompletedB = baseB
        staleUncompletedB.workspace.revision += 1
        staleUncompletedB.workspace.savedAt = fixture.completedAt.addingTimeInterval(-1)
        try staleUncompletedB.validate()
        try await storeB.save(staleUncompletedB, replacing: baseB)

        let firstA = try await adapterA.publishLocalAndSynchronize(
            completedA,
            now: fixture.completedAt.addingTimeInterval(10)
        )
        XCTAssertNil(firstA.pendingReview)

        let receivedB = try await adapterB.publishLocalAndSynchronize(
            staleUncompletedB,
            now: fixture.completedAt.addingTimeInterval(20)
        )
        XCTAssertNil(receivedB.pendingReview)
        try assertFullCompletion(receivedB.archive, operation: fixture.primaryOperation)

        let convergedA = try await adapterA.publishLocalAndSynchronize(
            firstA.archive,
            now: fixture.completedAt.addingTimeInterval(30)
        )
        XCTAssertNil(convergedA.pendingReview)
        try assertFullCompletion(convergedA.archive, operation: fixture.primaryOperation)

        let persistedAValue = try await storeA.load()
        let persistedBValue = try await storeB.load()
        let persistedA = try XCTUnwrap(persistedAValue)
        let persistedB = try XCTUnwrap(persistedBValue)
        XCTAssertEqual(persistedA.workspace, persistedB.workspace)
        XCTAssertEqual(persistedA.currentDecisionID, persistedB.currentDecisionID)
        let persistedABytes = try await storeA.encodeArchiveForSync(persistedA)
        let convergedABytes = try await storeA.encodeArchiveForSync(convergedA.archive)
        XCTAssertEqual(persistedABytes, convergedABytes)
        let persistedBBytes = try await storeB.encodeArchiveForSync(persistedB)
        let receivedBBytes = try await storeB.encodeArchiveForSync(receivedB.archive)
        XCTAssertEqual(persistedBBytes, receivedBBytes)

        // A published outbox row may already be pruned when the user selects a
        // different folder. The applied ledger must still seed that destination.
        let replacementRemote = root.appendingPathComponent(
            "replacement-remote",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementRemote,
            withIntermediateDirectories: true
        )
        let replacementLibraryID = SyncLibraryID(fixedUUID(920))
        let replacementEngineA = try makeEngine(
            localRoot: root.appendingPathComponent("engine-a-replacement", isDirectory: true),
            remoteRoot: replacementRemote,
            deviceID: NextStepSync.DeviceID(fixedUUID(921)),
            now: fixture.completedAt.addingTimeInterval(40),
            libraryID: replacementLibraryID
        )
        let replacementAdapterA = NextStepBetaSyncArchiveAdapter(
            engine: replacementEngineA,
            store: storeA
        )
        let seeded = try await replacementAdapterA.reconcileInitial(
            localArchive: persistedA,
            now: fixture.completedAt.addingTimeInterval(40)
        )
        XCTAssertNil(seeded.pendingReview)

        let storeC = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-c", isDirectory: true)
        )
        let baseC = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: fixture.completedAt.addingTimeInterval(-120),
            deviceID: NextStepDomain.DeviceID(fixedUUID(3)),
            timeZoneIdentifier: "UTC"
        )
        try await storeC.save(baseC, replacing: nil)
        let replacementEngineC = try makeEngine(
            localRoot: root.appendingPathComponent("engine-c", isDirectory: true),
            remoteRoot: replacementRemote,
            deviceID: NextStepSync.DeviceID(fixedUUID(922)),
            now: fixture.completedAt.addingTimeInterval(50),
            libraryID: replacementLibraryID
        )
        let replacementAdapterC = NextStepBetaSyncArchiveAdapter(
            engine: replacementEngineC,
            store: storeC
        )
        let restoredC = try await replacementAdapterC.reconcileInitial(
            localArchive: baseC,
            now: fixture.completedAt.addingTimeInterval(50)
        )
        XCTAssertNil(restoredC.pendingReview)
        try assertFullCompletion(restoredC.archive, operation: fixture.primaryOperation)
        let restoredOperations = try await storeC.storedCompletionOperations()
        XCTAssertEqual(restoredOperations.map(\.operation), [fixture.primaryOperation])
    }

    func testMissingCompletionDependenciesNeverOverwriteMeaningfulLocalWorkspace() async throws {
        let root = temporaryRoot(named: "completion-missing-dependencies")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: remote,
            withIntermediateDirectories: true
        )
        let fixture = try makeFixture()
        let libraryID = SyncLibraryID(fixedUUID(930))
        let storeA = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-a", isDirectory: true)
        )
        try await installFixtureSource(fixture, in: storeA)
        try await storeA.save(fixture.baseArchive, replacing: nil)
        let engineA = try makeEngine(
            localRoot: root.appendingPathComponent("engine-a", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(931)),
            now: fixture.completedAt.addingTimeInterval(10),
            libraryID: libraryID
        )
        let adapterA = NextStepBetaSyncArchiveAdapter(engine: engineA, store: storeA)
        _ = try await adapterA.reconcileInitial(
            localArchive: fixture.baseArchive,
            now: fixture.completedAt.addingTimeInterval(2)
        )
        let completedA = try completedArchive(
            fixture.baseArchive,
            operation: fixture.primaryOperation
        )
        try await storeA.saveCompletionOperation(
            completedA,
            replacing: fixture.baseArchive,
            operation: fixture.primaryOperation
        )
        let publishedA = try await adapterA.publishLocalAndSynchronize(
            completedA,
            now: fixture.completedAt.addingTimeInterval(10)
        )
        try assertFullCompletion(
            publishedA.archive,
            operation: fixture.primaryOperation
        )

        let localB = try meaningfulArchiveWithoutCompletionDependencies(
            from: fixture.baseArchive,
            deviceID: NextStepDomain.DeviceID(fixedUUID(4)),
            now: fixture.completedAt.addingTimeInterval(20)
        )
        let storeB = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-b", isDirectory: true)
        )
        try await storeB.save(localB, replacing: nil)
        let engineB = try makeEngine(
            localRoot: root.appendingPathComponent("engine-b", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(932)),
            now: fixture.completedAt.addingTimeInterval(20),
            libraryID: libraryID
        )
        let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)
        do {
            _ = try await adapterB.reconcileInitial(
                localArchive: localB,
                now: fixture.completedAt.addingTimeInterval(20)
            )
            XCTFail("A meaningful local workspace must not be replaced implicitly.")
        } catch {
            XCTAssertEqual(
                error as? NextStepBetaCompletionDependencySyncError,
                .localWorkspaceRequiresReview
            )
        }
        let loadedBAfterFailure = try await storeB.load()
        let storedBAfterFailure = try XCTUnwrap(loadedBAfterFailure)
        XCTAssertEqual(storedBAfterFailure.workspace, localB.workspace)
        XCTAssertTrue(storedBAfterFailure.workspace.dailyActions.isEmpty)
        let storedBOperations = try await storeB.storedCompletionOperations()
        XCTAssertTrue(storedBOperations.isEmpty)

        let localC = try meaningfulArchiveWithoutCompletionDependencies(
            from: fixture.baseArchive,
            deviceID: NextStepDomain.DeviceID(fixedUUID(5)),
            now: fixture.completedAt.addingTimeInterval(30),
            replacingDeadlineWith: try LocalDay(year: 2029, month: 1, day: 31)
        )
        let storeC = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-c", isDirectory: true)
        )
        try await storeC.save(localC, replacing: nil)
        let engineC = try makeEngine(
            localRoot: root.appendingPathComponent("engine-c", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(933)),
            now: fixture.completedAt.addingTimeInterval(30),
            libraryID: libraryID
        )
        let adapterC = NextStepBetaSyncArchiveAdapter(engine: engineC, store: storeC)
        let reviewResult = try await adapterC.reconcileInitial(
            localArchive: localC,
            now: fixture.completedAt.addingTimeInterval(30)
        )
        let pending = try XCTUnwrap(reviewResult.pendingReview)
        XCTAssertEqual(pending.summary.kind, .protectedDeadline)

        do {
            _ = try await adapterC.resolve(
                pending,
                useSyncedArchive: false,
                now: fixture.completedAt.addingTimeInterval(40)
            )
            XCTFail("Keeping an incompatible local dependency graph must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? NextStepBetaCompletionDependencySyncError,
                .localWorkspaceRequiresReview
            )
        }
        let conflictSnapshot = try await engineC.snapshot()
        XCTAssertTrue(
            conflictSnapshot.conflicts.contains {
                $0.status == .unresolved
            }
        )
        let loadedCAfterFailure = try await storeC.load()
        let storedCAfterFailure = try XCTUnwrap(loadedCAfterFailure)
        XCTAssertEqual(storedCAfterFailure.workspace, localC.workspace)

        let resolvedToSynced = try await adapterC.resolve(
            pending,
            useSyncedArchive: true,
            now: fixture.completedAt.addingTimeInterval(50)
        )
        XCTAssertNil(resolvedToSynced.pendingReview)
        XCTAssertTrue(resolvedToSynced.didReplaceLocalArchive)
        try assertFullCompletion(
            resolvedToSynced.archive,
            operation: fixture.primaryOperation
        )
        let storedCOperations = try await storeC.storedCompletionOperations()
        XCTAssertEqual(storedCOperations.map(\.operation), [fixture.primaryOperation])
    }

    func testLocalDeadlineResolutionPersistsCarryForwardBeforeCompletionLedger() async throws {
        let root = temporaryRoot(named: "completion-deadline-carry-forward")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: remote,
            withIntermediateDirectories: true
        )
        let fixture = try makeFixture()
        let libraryID = SyncLibraryID(fixedUUID(940))
        let storeA = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-a", isDirectory: true)
        )
        try await installFixtureSource(fixture, in: storeA)
        try await storeA.save(fixture.baseArchive, replacing: nil)
        let engineA = try makeEngine(
            localRoot: root.appendingPathComponent("engine-a", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(941)),
            now: fixture.completedAt.addingTimeInterval(10),
            libraryID: libraryID
        )
        let adapterA = NextStepBetaSyncArchiveAdapter(engine: engineA, store: storeA)
        _ = try await adapterA.reconcileInitial(
            localArchive: fixture.baseArchive,
            now: fixture.completedAt.addingTimeInterval(2)
        )
        let completedA = try completedArchive(
            fixture.baseArchive,
            operation: fixture.primaryOperation
        )
        try await storeA.saveCompletionOperation(
            completedA,
            replacing: fixture.baseArchive,
            operation: fixture.primaryOperation
        )
        let extraAttemptID = fixedUUID(350)
        let remoteWithExtraAttempt = try addingPassingQuizAttempt(
            to: completedA,
            attemptID: extraAttemptID,
            now: fixture.completedAt.addingTimeInterval(3)
        )
        try await storeA.save(remoteWithExtraAttempt, replacing: completedA)
        _ = try await adapterA.publishLocalAndSynchronize(
            remoteWithExtraAttempt,
            now: fixture.completedAt.addingTimeInterval(10)
        )

        let localDeadline = try LocalDay(year: 2029, month: 2, day: 28)
        let localB = try replacingProtectedDeadline(
            in: fixture.baseArchive,
            with: localDeadline,
            deviceID: NextStepDomain.DeviceID(fixedUUID(6)),
            now: fixture.completedAt.addingTimeInterval(20)
        )
        let storeB = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-b", isDirectory: true)
        )
        try await installFixtureSource(fixture, in: storeB)
        try await storeB.save(localB, replacing: nil)
        let engineB = try makeEngine(
            localRoot: root.appendingPathComponent("engine-b", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(942)),
            now: fixture.completedAt.addingTimeInterval(20),
            libraryID: libraryID
        )
        let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)
        let reviewResult = try await adapterB.reconcileInitial(
            localArchive: localB,
            now: fixture.completedAt.addingTimeInterval(20)
        )
        let pending = try XCTUnwrap(reviewResult.pendingReview)
        XCTAssertEqual(pending.summary.kind, .protectedDeadline)

        let resolved = try await adapterB.resolve(
            pending,
            useSyncedArchive: false,
            now: fixture.completedAt.addingTimeInterval(30)
        )
        XCTAssertNil(resolved.pendingReview)
        XCTAssertFalse(resolved.didReplaceLocalArchive)
        XCTAssertEqual(
            resolved.archive.workspace.ultimateGoals.first?.targetDay?.value,
            localDeadline
        )
        XCTAssertTrue(
            resolved.archive.workspace.userResponses.contains {
                $0.attemptID == extraAttemptID
            }
        )
        try assertFullCompletion(
            resolved.archive,
            operation: fixture.primaryOperation
        )
        let storedOperations = try await storeB.storedCompletionOperations()
        XCTAssertEqual(storedOperations.map(\.operation), [fixture.primaryOperation])
        let loadedBValue = try await storeB.load()
        let loadedB = try XCTUnwrap(loadedBValue)
        XCTAssertEqual(loadedB.workspace, resolved.archive.workspace)
        XCTAssertEqual(
            loadedB.completionApplicationReceipts,
            resolved.archive.completionApplicationReceipts
        )
    }

    func testDifferentCompletionPayloadForSameActionRequiresImmutableSyncReview() async throws {
        let root = temporaryRoot(named: "completion-immutable-review")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(
            at: remote,
            withIntermediateDirectories: true
        )
        let fixture = try makeFixture()
        let secondDeviceID = NextStepDomain.DeviceID(fixedUUID(2))
        var baseB = fixture.baseArchive
        baseB.deviceID = secondDeviceID
        try baseB.validate()
        let competingOperation = try makeOperation(
            fixture: fixture,
            operationID: OperationID(fixedUUID(501)),
            completedAt: fixture.completedAt.addingTimeInterval(1),
            deviceID: secondDeviceID,
            attestationID: CompletionEvidenceID(fixedUUID(403)),
            attestation: "Alternative point one\nAlternative point two\nAlternative point three"
        )
        let storeA = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-a", isDirectory: true)
        )
        let storeB = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store-b", isDirectory: true)
        )
        let baseA = fixture.baseArchive
        try await installFixtureSource(fixture, in: storeA)
        try await installFixtureSource(fixture, in: storeB)
        try await storeA.save(baseA, replacing: nil)
        try await storeB.save(baseB, replacing: nil)
        let libraryID = SyncLibraryID(fixedUUID(910))
        let engineA = try makeEngine(
            localRoot: root.appendingPathComponent("engine-a", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(911)),
            now: fixture.completedAt.addingTimeInterval(10),
            libraryID: libraryID
        )
        let engineB = try makeEngine(
            localRoot: root.appendingPathComponent("engine-b", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(fixedUUID(912)),
            now: fixture.completedAt.addingTimeInterval(20),
            libraryID: libraryID
        )
        let adapterA = NextStepBetaSyncArchiveAdapter(engine: engineA, store: storeA)
        let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)
        _ = try await adapterA.reconcileInitial(
            localArchive: baseA,
            now: fixture.completedAt.addingTimeInterval(2)
        )
        _ = try await adapterB.reconcileInitial(
            localArchive: baseB,
            now: fixture.completedAt.addingTimeInterval(3)
        )

        let completedA = try completedArchive(
            baseA,
            operation: fixture.primaryOperation
        )
        let completedB = try completedArchive(
            baseB,
            operation: competingOperation
        )
        try await storeA.saveCompletionOperation(
            completedA,
            replacing: baseA,
            operation: fixture.primaryOperation
        )
        try await storeB.saveCompletionOperation(
            completedB,
            replacing: baseB,
            operation: competingOperation
        )

        let firstA = try await adapterA.publishLocalAndSynchronize(
            completedA,
            now: fixture.completedAt.addingTimeInterval(10)
        )
        XCTAssertNil(firstA.pendingReview)

        let conflictedB = try await adapterB.publishLocalAndSynchronize(
            completedB,
            now: fixture.completedAt.addingTimeInterval(20)
        )
        XCTAssertEqual(conflictedB.pendingReview?.summary.kind, .immutableCompletion)
        XCTAssertFalse(conflictedB.didReplaceLocalArchive)
        try assertFullCompletion(conflictedB.archive, operation: competingOperation)

        let persistedBValue = try await storeB.load()
        let persistedB = try XCTUnwrap(persistedBValue)
        try assertFullCompletion(persistedB, operation: competingOperation)
        let persistedBBytes = try await storeB.encodeArchiveForSync(persistedB)
        let completedBBytes = try await storeB.encodeArchiveForSync(completedB)
        XCTAssertEqual(persistedBBytes, completedBBytes)

        let conflictedA = try await adapterA.publishLocalAndSynchronize(
            firstA.archive,
            now: fixture.completedAt.addingTimeInterval(30)
        )
        XCTAssertEqual(conflictedA.pendingReview?.summary.kind, .immutableCompletion)
        XCTAssertFalse(conflictedA.didReplaceLocalArchive)
        try assertFullCompletion(conflictedA.archive, operation: fixture.primaryOperation)
    }

    private struct Fixture {
        let baseArchive: NextStepBetaArchive
        let action: DailyAction
        let package: GuidedLearningPackage
        let responses: [UserResponse]
        let quizEvidence: CompletionEvidence
        let sourceBytes: Data
        let completedAt: Date
        let primaryOperation: NextStepBetaGuidedActionCompletionOperation
    }

    private func meaningfulArchiveWithoutCompletionDependencies(
        from source: NextStepBetaArchive,
        deviceID: NextStepDomain.DeviceID,
        now: Date,
        replacingDeadlineWith replacementDeadline: LocalDay? = nil
    ) throws -> NextStepBetaArchive {
        var result = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: deviceID,
            timeZoneIdentifier: source.workspace.userProfile.timeZoneIdentifier
        )
        result.workspace.ultimateGoals = source.workspace.ultimateGoals
        result.workspace.goals = source.workspace.goals
        result.workspace.milestones = source.workspace.milestones
        if let replacementDeadline {
            let value = try FactValue(
                value: replacementDeadline,
                authority: .userConfirmed,
                mutability: .immutable,
                confirmedAt: now
            )
            for index in result.workspace.ultimateGoals.indices {
                result.workspace.ultimateGoals[index].targetDay = value
            }
            for index in result.workspace.goals.indices {
                result.workspace.goals[index].targetDay = value
            }
            for index in result.workspace.milestones.indices {
                result.workspace.milestones[index].targetDay = value
            }
        }
        result.workspace.revision = 1
        result.workspace.savedAt = now
        try result.validate()
        return result
    }

    private func replacingProtectedDeadline(
        in archive: NextStepBetaArchive,
        with deadline: LocalDay,
        deviceID: NextStepDomain.DeviceID,
        now: Date
    ) throws -> NextStepBetaArchive {
        let value = try FactValue(
            value: deadline,
            authority: .userConfirmed,
            mutability: .immutable,
            confirmedAt: now
        )
        var result = archive
        result.deviceID = deviceID
        for index in result.workspace.ultimateGoals.indices {
            result.workspace.ultimateGoals[index].targetDay = value
        }
        for index in result.workspace.goals.indices {
            result.workspace.goals[index].targetDay = value
        }
        for index in result.workspace.milestones.indices {
            result.workspace.milestones[index].targetDay = value
        }
        for index in result.workspace.dailyActions.indices {
            result.workspace.dailyActions[index].deadline = value
        }
        result.workspace.revision += 1
        result.workspace.savedAt = now
        try result.validate()
        return result
    }

    private func addingPassingQuizAttempt(
        to archive: NextStepBetaArchive,
        attemptID: UUID,
        now: Date
    ) throws -> NextStepBetaArchive {
        var result = archive
        let package = try XCTUnwrap(result.workspace.guidedPackages.first)
        let quiz = try XCTUnwrap(package.quiz)
        let action = try XCTUnwrap(result.workspace.dailyActions.first)
        let responses = try NextStepBetaQuizGrader().grade(
            package: package,
            selections: Dictionary(uniqueKeysWithValues: quiz.items.map {
                ($0.id, Set($0.correctOptionIDs))
            }),
            attemptID: attemptID,
            now: now,
            deviceID: result.deviceID
        ).responses
        let quizResult = try QuizEvaluator().evaluate(
            quiz: quiz,
            packageID: package.metadata.id,
            packageVersion: package.version,
            responses: responses,
            scoredAt: now
        )
        let evidence = try CompletionEvidence(
            metadata: RecordMetadata(
                id: CompletionEvidenceID(fixedUUID(351)),
                createdAt: now,
                originDeviceID: result.deviceID,
                provenance: .deterministicEngine
            ),
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            quizResult: quizResult,
            capturedAt: now,
            criterionIDs: action.completionCriteria.filter {
                $0.kind == .quizScore
            }.map(\.id)
        )
        result.workspace.userResponses.append(contentsOf: responses)
        result.workspace.completionEvidence.append(evidence)
        result.workspace.revision += 1
        result.workspace.savedAt = now
        try result.validate()
        return result
    }

    private func makeFixture() throws -> Fixture {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let quizAt = createdAt.addingTimeInterval(20)
        let completedAt = createdAt.addingTimeInterval(60)
        let deviceID = NextStepDomain.DeviceID(fixedUUID(1))
        let sourceBytes = Data(
            "Equity finances assets. Debt creates obligations. Cash flow supports repayment."
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
            title: "Complete the guided finance lesson",
            deadline: try LocalDay(year: 2028, month: 12, day: 31),
            dailyMinutes: 35,
            to: archive,
            now: createdAt
        )

        let sourceID = SourceDocumentID(fixedUUID(100))
        let relativePath = "Sources/\(sourceID.description)/original.pdf"
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceID,
            displayTitle: "Verified finance notes",
            fileExtension: "pdf",
            relativePath: relativePath,
            contentSHA256: sourceDigest,
            now: createdAt,
            deviceID: deviceID,
            parserVersion: "completion-integration-tests-v1"
        )
        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: document,
                exactExtract: [
                    "Equity finances long-term assets.",
                    "Debt creates contractual interest obligations.",
                    "Cash flow supports debt service capacity."
                ].joined(separator: "\n"),
                pageIndex: 0,
                usedVisionOCR: false,
                extractionNotice: nil
            ),
            to: archive,
            now: createdAt
        )
        let actionID = try XCTUnwrap(archive.workspace.dailyActions.first?.metadata.id)
        archive.workspace = try ExecutionService().startAction(
            actionID,
            in: archive.workspace,
            at: createdAt.addingTimeInterval(10)
        )
        let action = try XCTUnwrap(archive.workspace.dailyActions.first {
            $0.metadata.id == actionID
        })
        let package = try XCTUnwrap(archive.workspace.guidedPackages.first {
            $0.metadata.id == action.packageID
        })
        let quiz = try XCTUnwrap(package.quiz)
        let attempt = try NextStepBetaQuizGrader().grade(
            package: package,
            selections: Dictionary(uniqueKeysWithValues: quiz.items.map {
                ($0.id, Set($0.correctOptionIDs))
            }),
            attemptID: fixedUUID(300),
            now: quizAt,
            deviceID: deviceID
        )
        XCTAssertTrue(attempt.passed)
        let quizResult = try QuizEvaluator().evaluate(
            quiz: quiz,
            packageID: package.metadata.id,
            packageVersion: package.version,
            responses: attempt.responses,
            scoredAt: quizAt
        )
        let quizEvidence = try CompletionEvidence(
            metadata: RecordMetadata(
                id: CompletionEvidenceID(fixedUUID(401)),
                createdAt: quizAt,
                originDeviceID: deviceID,
                provenance: .deterministicEngine
            ),
            actionID: actionID,
            packageID: package.metadata.id,
            packageVersion: package.version,
            quizResult: quizResult,
            capturedAt: quizAt,
            criterionIDs: action.completionCriteria.filter {
                $0.kind == .quizScore && $0.requiresEvidence
            }.map(\.id)
        )
        archive.workspace.userResponses.append(contentsOf: attempt.responses)
        archive.workspace.completionEvidence.append(quizEvidence)
        archive.workspace.revision += 1
        archive.workspace.savedAt = quizAt
        try archive.validate()

        let partialFixture = Fixture(
            baseArchive: archive,
            action: action,
            package: package,
            responses: attempt.responses,
            quizEvidence: quizEvidence,
            sourceBytes: sourceBytes,
            completedAt: completedAt,
            primaryOperation: try makeOperation(
                action: action,
                package: package,
                responses: attempt.responses,
                quizEvidence: quizEvidence,
                operationID: OperationID(fixedUUID(500)),
                completedAt: completedAt,
                deviceID: deviceID,
                attestationID: CompletionEvidenceID(fixedUUID(402)),
                attestation: "Point one\nPoint two\nPoint three"
            )
        )
        return partialFixture
    }

    private func makeOperation(
        fixture: Fixture,
        operationID: OperationID,
        completedAt: Date,
        deviceID: NextStepDomain.DeviceID,
        attestationID: CompletionEvidenceID,
        attestation: String
    ) throws -> NextStepBetaGuidedActionCompletionOperation {
        try makeOperation(
            action: fixture.action,
            package: fixture.package,
            responses: fixture.responses,
            quizEvidence: fixture.quizEvidence,
            operationID: operationID,
            completedAt: completedAt,
            deviceID: deviceID,
            attestationID: attestationID,
            attestation: attestation
        )
    }

    private func makeOperation(
        action: DailyAction,
        package: GuidedLearningPackage,
        responses: [UserResponse],
        quizEvidence: CompletionEvidence,
        operationID: OperationID,
        completedAt: Date,
        deviceID: NextStepDomain.DeviceID,
        attestationID: CompletionEvidenceID,
        attestation: String
    ) throws -> NextStepBetaGuidedActionCompletionOperation {
        let evidence = try CompletionEvidence(
            metadata: RecordMetadata(
                id: attestationID,
                createdAt: completedAt,
                originDeviceID: deviceID,
                provenance: .user
            ),
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            kind: .userAttestation,
            value: attestation,
            capturedAt: completedAt,
            criterionIDs: action.completionCriteria.filter {
                $0.kind == .userAttestation && $0.requiresEvidence
            }.map(\.id)
        )
        return try NextStepBetaGuidedActionCompletionOperation(
            operationID: operationID,
            action: action,
            package: package,
            completedAt: completedAt,
            originDeviceID: deviceID,
            referencedUserResponses: responses,
            quizEvidence: quizEvidence,
            userAttestation: evidence
        )
    }

    private func completedArchive(
        _ archive: NextStepBetaArchive,
        operation: NextStepBetaGuidedActionCompletionOperation
    ) throws -> NextStepBetaArchive {
        let replay = try NextStepBetaCompletionOperationReducer().replay(
            operation,
            in: archive
        )
        XCTAssertEqual(replay.outcome, .applied)
        return replay.archive
    }

    private func installFixtureSource(
        _ fixture: Fixture,
        in store: NextStepBetaStore
    ) async throws {
        let relativePath = try XCTUnwrap(
            fixture.baseArchive.workspace.sourceDocuments.first?.localRelativePath
        )
        let expectedSHA256 = try XCTUnwrap(
            fixture.baseArchive.workspace.sourceDocuments.first?.contentSHA256
        )
        try await store.installSyncedSource(
            fixture.sourceBytes,
            relativePath: relativePath,
            expectedSHA256: expectedSHA256
        )
    }

    private func assertFullCompletion(
        _ archive: NextStepBetaArchive,
        operation: NextStepBetaGuidedActionCompletionOperation,
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
        XCTAssertEqual(action.status, .completed, file: file, line: line)
        XCTAssertEqual(action.completedAt, operation.completedAt, file: file, line: line)
        let quizEvidence = try XCTUnwrap(operation.quizEvidence, file: file, line: line)
        XCTAssertNotNil(quizEvidence.quizResult, file: file, line: line)
        let responseByID = Dictionary(uniqueKeysWithValues: archive.workspace.userResponses.map {
            ($0.metadata.id, $0)
        })
        for response in operation.referencedUserResponses {
            XCTAssertEqual(responseByID[response.metadata.id], response, file: file, line: line)
        }
        let evidenceByID = Dictionary(
            uniqueKeysWithValues: archive.workspace.completionEvidence.map {
                ($0.metadata.id, $0)
            }
        )
        XCTAssertEqual(
            evidenceByID[quizEvidence.metadata.id],
            quizEvidence,
            file: file,
            line: line
        )
        XCTAssertEqual(
            evidenceByID[operation.userAttestation.metadata.id],
            operation.userAttestation,
            file: file,
            line: line
        )
        XCTAssertTrue(
            archive.workspace.progressSnapshots.contains {
                $0.metadata.id == operation.progressSnapshotID
            },
            file: file,
            line: line
        )
        XCTAssertTrue(
            archive.workspace.planningDecisions.contains {
                $0.metadata.id == operation.planningDecisionID
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
        XCTAssertEqual(
            archive.currentDecisionID,
            operation.planningDecisionID,
            file: file,
            line: line
        )
        let receipts = archive.completionApplicationReceipts.filter {
            $0.operationID == operation.operationID
        }
        XCTAssertEqual(receipts.count, 1, file: file, line: line)
        XCTAssertTrue(
            receipts.first?.matches(operation) == true,
            file: file,
            line: line
        )
        try archive.validate()
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
