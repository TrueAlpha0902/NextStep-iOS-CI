import CryptoKit
import Foundation
import NextStepDomain
import NextStepPlanning
import NextStepSync
@testable import NotesApp
import XCTest

final class NextStepBetaAttestationCompletionIntegrationTests: XCTestCase {
    func testSchemaTwoCommitSurvivesReopenAndExactReplayIsNoOp() async throws {
        let root = temporaryRoot(named: "attestation-reopen")
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
        try assertAttestationCompletion(
            loaded,
            operation: fixture.primaryOperation
        )
        let loadedBytes = try await reopened.encodeArchiveForSync(loaded)
        let completedBytes = try await reopened.encodeArchiveForSync(completed)
        XCTAssertEqual(loadedBytes, completedBytes)

        let pending = try await reopened.pendingCompletionOperations()
        let stored = try await reopened.storedCompletionOperations()
        XCTAssertEqual(pending.map(\.operation), [fixture.primaryOperation])
        XCTAssertEqual(stored.map(\.operation), [fixture.primaryOperation])
        XCTAssertEqual(pending.first?.operation.schemaVersion, 2)
        XCTAssertEqual(
            pending.first?.canonicalData,
            try fixture.primaryOperation.canonicalData()
        )

        try await reopened.markCompletionOperationPublished(
            fixture.primaryOperation,
            publishedAt: fixture.completedAt.addingTimeInterval(1)
        )
        let pendingAfterPublish = try await reopened.pendingCompletionOperations()
        let storedAfterPublish = try await reopened.storedCompletionOperations()
        XCTAssertTrue(pendingAfterPublish.isEmpty)
        XCTAssertEqual(
            storedAfterPublish.map(\.operation),
            [fixture.primaryOperation]
        )
        let bytesBeforeReplay = try await reopened.encodeArchiveForSync(loaded)

        try await reopened.saveCompletionOperation(
            completed,
            replacing: fixture.baseArchive,
            operation: fixture.primaryOperation
        )

        let afterReplayValue = try await reopened.load()
        let afterReplay = try XCTUnwrap(afterReplayValue)
        let bytesAfterReplay = try await reopened.encodeArchiveForSync(afterReplay)
        let pendingAfterReplay = try await reopened.pendingCompletionOperations()
        let storedAfterReplay = try await reopened.storedCompletionOperations()
        XCTAssertEqual(bytesAfterReplay, bytesBeforeReplay)
        XCTAssertTrue(pendingAfterReplay.isEmpty)
        XCTAssertEqual(
            storedAfterReplay.map(\.operation),
            [fixture.primaryOperation]
        )
        try assertAttestationCompletion(
            afterReplay,
            operation: fixture.primaryOperation
        )
    }

    func testStaleUncompletedSnapshotCannotRegressSchemaTwoCompletion() async throws {
        let root = temporaryRoot(named: "attestation-stale-cas")
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
        try assertAttestationCompletion(
            loaded,
            operation: fixture.primaryOperation
        )
        let pending = try await store.pendingCompletionOperations()
        let stored = try await store.storedCompletionOperations()
        XCTAssertEqual(pending.map(\.operation), [fixture.primaryOperation])
        XCTAssertEqual(stored.map(\.operation), [fixture.primaryOperation])
    }

    func testTwoFileFolderDevicesConvergeSchemaTwoCompletionOverStaleHead() async throws {
        let root = temporaryRoot(named: "attestation-folder-convergence")
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
        try assertAttestationCompletion(
            receivedB.archive,
            operation: fixture.primaryOperation
        )

        let convergedA = try await adapterA.publishLocalAndSynchronize(
            firstA.archive,
            now: fixture.completedAt.addingTimeInterval(30)
        )
        XCTAssertNil(convergedA.pendingReview)
        try assertAttestationCompletion(
            convergedA.archive,
            operation: fixture.primaryOperation
        )

        let persistedAValue = try await storeA.load()
        let persistedBValue = try await storeB.load()
        let persistedA = try XCTUnwrap(persistedAValue)
        let persistedB = try XCTUnwrap(persistedBValue)
        XCTAssertEqual(persistedA.workspace, persistedB.workspace)
        XCTAssertEqual(persistedA.currentDecisionID, persistedB.currentDecisionID)
        let storedA = try await storeA.storedCompletionOperations()
        let storedB = try await storeB.storedCompletionOperations()
        XCTAssertEqual(storedA.map(\.operation), [fixture.primaryOperation])
        XCTAssertEqual(storedB.map(\.operation), [fixture.primaryOperation])
    }

    func testCompetingSchemaTwoAttestationRequiresImmutableCompletionReview() async throws {
        let root = temporaryRoot(named: "attestation-immutable-review")
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
            action: fixture.action,
            package: fixture.package,
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
        XCTAssertEqual(
            conflictedB.pendingReview?.summary.kind,
            .immutableCompletion
        )
        XCTAssertFalse(conflictedB.didReplaceLocalArchive)
        try assertAttestationCompletion(
            conflictedB.archive,
            operation: competingOperation
        )

        let persistedBValue = try await storeB.load()
        let persistedB = try XCTUnwrap(persistedBValue)
        try assertAttestationCompletion(
            persistedB,
            operation: competingOperation
        )
        let primaryEvidence = try XCTUnwrap(
            fixture.primaryOperation.completionEvidence.first
        )
        XCTAssertFalse(persistedB.workspace.completionEvidence.contains {
            $0.metadata.id == primaryEvidence.metadata.id
        })

        let conflictedA = try await adapterA.publishLocalAndSynchronize(
            firstA.archive,
            now: fixture.completedAt.addingTimeInterval(30)
        )
        XCTAssertEqual(
            conflictedA.pendingReview?.summary.kind,
            .immutableCompletion
        )
        XCTAssertFalse(conflictedA.didReplaceLocalArchive)
        try assertAttestationCompletion(
            conflictedA.archive,
            operation: fixture.primaryOperation
        )
        let competingEvidence = try XCTUnwrap(
            competingOperation.completionEvidence.first
        )
        XCTAssertFalse(conflictedA.archive.workspace.completionEvidence.contains {
            $0.metadata.id == competingEvidence.metadata.id
        })
    }

    func testMissingDependenciesPreserveMeaningfulLocalWorkspace() async throws {
        let root = temporaryRoot(named: "attestation-missing-dependencies")
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
        try assertAttestationCompletion(
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

        let persistedBValue = try await storeB.load()
        let persistedB = try XCTUnwrap(persistedBValue)
        XCTAssertEqual(persistedB.workspace, localB.workspace)
        XCTAssertTrue(persistedB.workspace.dailyActions.isEmpty)
        XCTAssertTrue(persistedB.completionApplicationReceipts.isEmpty)
        let storedB = try await storeB.storedCompletionOperations()
        XCTAssertTrue(storedB.isEmpty)
    }

    private struct Fixture {
        let baseArchive: NextStepBetaArchive
        let action: DailyAction
        let package: GuidedLearningPackage
        let sourceBytes: Data
        let completedAt: Date
        let primaryOperation: NextStepBetaGuidedActionCompletionOperation
    }

    private func makeFixture() throws -> Fixture {
        let createdAt = Date(timeIntervalSince1970: 1_810_000_000)
        let completedAt = createdAt.addingTimeInterval(60)
        let deviceID = NextStepDomain.DeviceID(fixedUUID(1))
        let sourceBytes = Data(
            "OCR evidence remains source linked and requires explicit user attestation."
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
            title: "Complete the OCR-grounded guided lesson",
            deadline: try LocalDay(year: 2029, month: 12, day: 31),
            dailyMinutes: 35,
            to: archive,
            now: createdAt
        )

        let sourceID = SourceDocumentID(fixedUUID(100))
        let relativePath = "Sources/\(sourceID.description)/original.pdf"
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceID,
            displayTitle: "Verified OCR finance notes",
            fileExtension: "pdf",
            relativePath: relativePath,
            contentSHA256: sourceDigest,
            now: createdAt,
            deviceID: deviceID,
            parserVersion: "attestation-integration-tests-v1"
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
                usedVisionOCR: true,
                extractionNotice: "OCR text requires user confirmation."
            ),
            to: archive,
            now: createdAt
        )
        let actionID = try XCTUnwrap(
            archive.workspace.dailyActions.first?.metadata.id
        )
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
        XCTAssertNil(package.quiz)
        XCTAssertEqual(package.requiredOutput.validationKind, .userConfirmation)
        XCTAssertTrue(archive.workspace.userResponses.isEmpty)
        try archive.validate()

        let operation = try makeOperation(
            action: action,
            package: package,
            operationID: OperationID(fixedUUID(500)),
            completedAt: completedAt,
            deviceID: deviceID,
            attestationID: CompletionEvidenceID(fixedUUID(402)),
            attestation: "Point one\nPoint two\nPoint three"
        )
        return Fixture(
            baseArchive: archive,
            action: action,
            package: package,
            sourceBytes: sourceBytes,
            completedAt: completedAt,
            primaryOperation: operation
        )
    }

    private func makeOperation(
        action: DailyAction,
        package: GuidedLearningPackage,
        operationID: OperationID,
        completedAt: Date,
        deviceID: NextStepDomain.DeviceID,
        attestationID: CompletionEvidenceID,
        attestation: String
    ) throws -> NextStepBetaGuidedActionCompletionOperation {
        let criterionIDs = action.completionCriteria
            .map(\.id)
            .sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
        let evidence = try CompletionEvidence(
            metadata: RecordMetadata(
                id: attestationID,
                createdAt: completedAt,
                originDeviceID: deviceID,
                lastOperationID: operationID,
                provenance: .user
            ),
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            kind: .userAttestation,
            value: attestation,
            capturedAt: completedAt,
            criterionIDs: criterionIDs
        )
        return try NextStepBetaGuidedActionCompletionOperation(
            operationID: operationID,
            action: action,
            package: package,
            completedAt: completedAt,
            originDeviceID: deviceID,
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

    private func meaningfulArchiveWithoutCompletionDependencies(
        from source: NextStepBetaArchive,
        deviceID: NextStepDomain.DeviceID,
        now: Date
    ) throws -> NextStepBetaArchive {
        var result = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: deviceID,
            timeZoneIdentifier: source.workspace.userProfile.timeZoneIdentifier
        )
        result.workspace.ultimateGoals = source.workspace.ultimateGoals
        result.workspace.goals = source.workspace.goals
        result.workspace.milestones = source.workspace.milestones
        result.workspace.revision = 1
        result.workspace.savedAt = now
        try result.validate()
        return result
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

    private func assertAttestationCompletion(
        _ archive: NextStepBetaArchive,
        operation: NextStepBetaGuidedActionCompletionOperation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(operation.schemaVersion, 2, file: file, line: line)
        XCTAssertTrue(
            operation.referencedUserResponses.isEmpty,
            file: file,
            line: line
        )
        XCTAssertEqual(operation.completionEvidence.count, 1, file: file, line: line)
        let attestation = try XCTUnwrap(
            operation.completionEvidence.first,
            file: file,
            line: line
        )
        let action = try XCTUnwrap(
            archive.workspace.dailyActions.first {
                $0.metadata.id == operation.actionID
            },
            file: file,
            line: line
        )
        XCTAssertEqual(action.status, .completed, file: file, line: line)
        XCTAssertEqual(action.completedAt, operation.completedAt, file: file, line: line)
        XCTAssertTrue(archive.workspace.userResponses.isEmpty, file: file, line: line)
        let evidenceByID = Dictionary(
            uniqueKeysWithValues: archive.workspace.completionEvidence.map {
                ($0.metadata.id, $0)
            }
        )
        for evidence in operation.completionEvidence {
            XCTAssertEqual(
                evidenceByID[evidence.metadata.id],
                evidence,
                file: file,
                line: line
            )
        }
        let lastOperationID = try XCTUnwrap(
            attestation.metadata.lastOperationID,
            file: file,
            line: line
        )
        XCTAssertEqual(lastOperationID, operation.operationID, file: file, line: line)
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
