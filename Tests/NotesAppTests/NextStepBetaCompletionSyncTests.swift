import Foundation
import NextStepDomain
import NextStepPlanning
@testable import NotesApp
import XCTest

final class NextStepBetaCompletionSyncTests: XCTestCase {
    func testCanonicalPayloadRoundTripsAndLocksDerivedIdentifiers() throws {
        let fixture = try makeFixture()
        let operation = fixture.operation

        XCTAssertEqual(
            operation.kind,
            NextStepBetaGuidedActionCompletionOperation.payloadKind
        )
        XCTAssertEqual(operation.schemaVersion, 1)
        XCTAssertEqual(
            operation.planningEngineVersion,
            NextStepBetaGuidedActionCompletionOperation.supportedPlanningEngineVersion
        )
        XCTAssertEqual(operation.planningEngineVersion, PlanningEngine.version)
        XCTAssertNotEqual(
            operation.derivedRecordContractSHA256,
            String(repeating: "0", count: 64)
        )
        XCTAssertEqual(
            operation.progressSnapshotID.rawValue,
            UUID(uuidString: "bcdead7f-e3df-575c-9d3f-04cfaaa1f4b7")!
        )
        XCTAssertEqual(
            operation.planningDecisionID.rawValue,
            UUID(uuidString: "7c9f2630-c961-5c53-bd18-52e93635bd90")!
        )
        XCTAssertEqual(
            operation.replanEventID.rawValue,
            UUID(uuidString: "c98c8544-3735-56b1-ba5a-92752a93e3b1")!
        )

        let canonical = try operation.canonicalData()
        XCTAssertEqual(
            try NextStepBetaGuidedActionCompletionOperation.decodeCanonical(from: canonical),
            operation
        )
        XCTAssertEqual(try operation.canonicalData(), canonical)

        var whitespacePrefixed = Data([0x20])
        whitespacePrefixed.append(canonical)
        XCTAssertThrowsError(
            try NextStepBetaGuidedActionCompletionOperation.decodeCanonical(
                from: whitespacePrefixed
            )
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaCompletionOperationError,
                .nonCanonicalPayload
            )
        }

        var reversedAction = fixture.action
        var reversedPackage = fixture.package
        reversedAction.completionCriteria.reverse()
        reversedPackage.completionCriteria.reverse()
        XCTAssertEqual(
            try NextStepBetaGuidedActionCompletionOperation.contractSHA256(
                action: reversedAction,
                package: reversedPackage
            ),
            operation.completionContractSHA256
        )
    }

    func testCanonicalDecodeRejectsTamperedDerivedIdentifier() throws {
        let canonical = try makeFixture().operation.canonicalData()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        object["progressSnapshotID"] = fixedUUID(999).uuidString.lowercased()
        let tampered = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        XCTAssertThrowsError(
            try NextStepBetaGuidedActionCompletionOperation.decodeCanonical(from: tampered)
        ) { error in
            guard let operationError = error as? NextStepBetaCompletionOperationError,
                  case let .invalidOperation(reason) = operationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("derived record identifiers"))
        }
    }

    func testReducerAppliesCompletionThenReplaysIdempotently() throws {
        let fixture = try makeFixture()
        let reducer = NextStepBetaCompletionOperationReducer()

        let first = try reducer.replay(fixture.operation, in: fixture.archive)
        XCTAssertEqual(first.outcome, .applied)
        let completedAction = try XCTUnwrap(first.archive.workspace.dailyActions.first {
            $0.metadata.id == fixture.action.metadata.id
        })
        XCTAssertEqual(completedAction.status, .completed)
        XCTAssertEqual(completedAction.completedAt, fixture.completedAt)
        let persistedEvidenceIDs = Set(
            first.archive.workspace.completionEvidence.map(\.metadata.id)
        )
        XCTAssertTrue(persistedEvidenceIDs.contains(fixture.quizEvidence.metadata.id))
        XCTAssertTrue(
            persistedEvidenceIDs.contains(fixture.operation.userAttestation.metadata.id)
        )
        XCTAssertEqual(persistedEvidenceIDs.count, 3)
        XCTAssertEqual(
            first.archive.workspace.progressSnapshots.last?.metadata.id,
            fixture.operation.progressSnapshotID
        )
        XCTAssertEqual(
            first.archive.workspace.planningDecisions.last?.metadata.id,
            fixture.operation.planningDecisionID
        )
        XCTAssertEqual(
            first.archive.workspace.replanEvents.last?.metadata.id,
            fixture.operation.replanEventID
        )
        XCTAssertEqual(
            first.archive.currentDecisionID,
            fixture.operation.planningDecisionID
        )
        let receipt = try XCTUnwrap(first.archive.completionApplicationReceipts.first)
        XCTAssertEqual(first.archive.completionApplicationReceipts.count, 1)
        XCTAssertTrue(receipt.matches(fixture.operation))
        XCTAssertEqual(receipt.derivedRecordsSHA256.count, 64)
        XCTAssertEqual(receipt.baseContextSHA256.count, 64)

        let independent = try reducer.replay(fixture.operation, in: fixture.archive)
        XCTAssertEqual(independent.outcome, .applied)
        XCTAssertEqual(independent.archive.workspace, first.archive.workspace)
        XCTAssertEqual(independent.archive.currentDecisionID, first.archive.currentDecisionID)
        XCTAssertEqual(
            independent.archive.completionApplicationReceipts,
            first.archive.completionApplicationReceipts
        )

        let second = try reducer.replay(fixture.operation, in: first.archive)
        XCTAssertEqual(second.outcome, .alreadyApplied)
        XCTAssertEqual(second.archive.workspace, first.archive.workspace)
        XCTAssertEqual(second.archive.currentDecisionID, first.archive.currentDecisionID)
        XCTAssertEqual(second.archive.grounding, first.archive.grounding)
    }

    func testReceiptBaseContextCanonicalizesCollectionAndProgressMapOrder() throws {
        let fixture = try makeFixture()
        let capturedAt = fixture.completedAt.addingTimeInterval(-5)
        let actualUltimateID = try XCTUnwrap(
            fixture.archive.workspace.ultimateGoals.first?.metadata.id
        )
        let actualGoalID = try XCTUnwrap(
            fixture.archive.workspace.goals.first?.metadata.id
        )
        let actualMilestoneID = try XCTUnwrap(
            fixture.archive.workspace.milestones.first?.metadata.id
        )
        let otherUltimateID = UltimateGoalID(fixedUUID(610))
        let otherGoalID = GoalID(fixedUUID(611))
        let otherMilestoneID = MilestoneID(fixedUUID(612))

        var ultimateProgressA: [UltimateGoalID: Double] = [:]
        ultimateProgressA[actualUltimateID] = 0.25
        ultimateProgressA[otherUltimateID] = 0.75
        var ultimateProgressB: [UltimateGoalID: Double] = [:]
        ultimateProgressB[otherUltimateID] = 0.75
        ultimateProgressB[actualUltimateID] = 0.25
        var goalProgressA: [GoalID: Double] = [:]
        goalProgressA[actualGoalID] = 0.2
        goalProgressA[otherGoalID] = 0.8
        var goalProgressB: [GoalID: Double] = [:]
        goalProgressB[otherGoalID] = 0.8
        goalProgressB[actualGoalID] = 0.2
        var milestoneProgressA: [MilestoneID: Double] = [:]
        milestoneProgressA[actualMilestoneID] = 0.1
        milestoneProgressA[otherMilestoneID] = 0.9
        var milestoneProgressB: [MilestoneID: Double] = [:]
        milestoneProgressB[otherMilestoneID] = 0.9
        milestoneProgressB[actualMilestoneID] = 0.1

        let progressMetadata = try RecordMetadata(
            id: ProgressSnapshotID(fixedUUID(613)),
            createdAt: capturedAt,
            originDeviceID: fixture.archive.deviceID,
            provenance: .deterministicEngine
        )
        let progressA = try ProgressSnapshot(
            metadata: progressMetadata,
            capturedAt: capturedAt,
            planRevision: fixture.archive.workspace.revision,
            ultimateGoalProgress: ultimateProgressA,
            goalProgress: goalProgressA,
            milestoneProgress: milestoneProgressA,
            completedActionCount: 0,
            totalActionCount: 1,
            atRiskMilestoneIDs: [actualMilestoneID, otherMilestoneID]
        )
        let progressB = try ProgressSnapshot(
            metadata: progressMetadata,
            capturedAt: capturedAt,
            planRevision: fixture.archive.workspace.revision,
            ultimateGoalProgress: ultimateProgressB,
            goalProgress: goalProgressB,
            milestoneProgress: milestoneProgressB,
            completedActionCount: 0,
            totalActionCount: 1,
            atRiskMilestoneIDs: [actualMilestoneID, otherMilestoneID]
        )

        var archiveA = fixture.archive
        archiveA.workspace.progressSnapshots.append(progressA)
        var archiveB = fixture.archive
        archiveB.workspace.userResponses.reverse()
        archiveB.workspace.completionEvidence.reverse()
        archiveB.workspace.evidenceLinks.reverse()
        archiveB.workspace.progressSnapshots.append(progressB)
        try archiveA.validate()
        try archiveB.validate()
        XCTAssertEqual(
            try PlanningWorkspaceCanonicalizer.canonicalData(archiveA.workspace),
            try PlanningWorkspaceCanonicalizer.canonicalData(archiveB.workspace)
        )

        let reducer = NextStepBetaCompletionOperationReducer()
        let resultA = try reducer.replay(fixture.operation, in: archiveA)
        let resultB = try reducer.replay(fixture.operation, in: archiveB)
        let receiptA = try XCTUnwrap(
            resultA.archive.completionApplicationReceipts.first
        )
        let receiptB = try XCTUnwrap(
            resultB.archive.completionApplicationReceipts.first
        )
        XCTAssertEqual(receiptA.baseContextSHA256, receiptB.baseContextSHA256)
        XCTAssertEqual(receiptA.derivedRecordsSHA256, receiptB.derivedRecordsSHA256)
        XCTAssertEqual(
            resultA.archive.workspace.planningDecisions.last?.inputSnapshotSHA256,
            resultB.archive.workspace.planningDecisions.last?.inputSnapshotSHA256
        )
    }

    func testReducerReplansAgainstReceivingArchiveWithoutChangingCausalIdentifiers() throws {
        let fixture = try makeFixture()
        let reducer = NextStepBetaCompletionOperationReducer()
        let originResult = try reducer.replay(fixture.operation, in: fixture.archive)
        var receivingArchive = fixture.archive
        receivingArchive.workspace.revision += 1
        receivingArchive.workspace.savedAt = fixture.completedAt.addingTimeInterval(-1)
        try receivingArchive.validate()

        let receivingResult = try reducer.replay(
            fixture.operation,
            in: receivingArchive
        )
        XCTAssertEqual(receivingResult.outcome, .applied)
        XCTAssertEqual(
            receivingResult.archive.workspace.progressSnapshots.last?.metadata.id,
            fixture.operation.progressSnapshotID
        )
        XCTAssertEqual(
            receivingResult.archive.workspace.planningDecisions.last?.metadata.id,
            fixture.operation.planningDecisionID
        )
        XCTAssertEqual(
            receivingResult.archive.workspace.replanEvents.last?.metadata.id,
            fixture.operation.replanEventID
        )
        XCTAssertNotEqual(
            receivingResult.archive.workspace.progressSnapshots.last?.planRevision,
            originResult.archive.workspace.progressSnapshots.last?.planRevision
        )
        XCTAssertNotEqual(
            receivingResult.archive.workspace.planningDecisions.last?.inputSnapshotSHA256,
            originResult.archive.workspace.planningDecisions.last?.inputSnapshotSHA256
        )
        let originReceipt = try XCTUnwrap(
            originResult.archive.completionApplicationReceipts.first
        )
        let receivingReceipt = try XCTUnwrap(
            receivingResult.archive.completionApplicationReceipts.first
        )
        XCTAssertNotEqual(
            receivingReceipt.baseContextSHA256,
            originReceipt.baseContextSHA256
        )
        XCTAssertNotEqual(
            receivingReceipt.derivedRecordsSHA256,
            originReceipt.derivedRecordsSHA256
        )

        let replay = try reducer.replay(fixture.operation, in: receivingResult.archive)
        XCTAssertEqual(replay.outcome, .alreadyApplied)
    }

    func testReducerRejectsTamperedDerivedRecordContentUsingApplicationReceipt() throws {
        let fixture = try makeFixture()
        let reducer = NextStepBetaCompletionOperationReducer()
        let first = try reducer.replay(fixture.operation, in: fixture.archive)
        var tampered = first.archive
        let decisionIndex = try XCTUnwrap(tampered.workspace.planningDecisions.firstIndex {
            $0.metadata.id == fixture.operation.planningDecisionID
        })
        let decision = tampered.workspace.planningDecisions[decisionIndex]
        let replacementDigest = decision.inputSnapshotSHA256 == String(repeating: "f", count: 64)
            ? String(repeating: "e", count: 64)
            : String(repeating: "f", count: 64)
        tampered.workspace.planningDecisions[decisionIndex] = try PlanningDecision(
            metadata: decision.metadata,
            engineVersion: decision.engineVersion,
            inputSnapshotSHA256: replacementDigest,
            horizonStart: decision.horizonStart,
            horizonEnd: decision.horizonEnd,
            assignments: decision.assignments,
            rejectedActions: decision.rejectedActions,
            risks: decision.risks,
            createdAt: decision.createdAt
        )

        XCTAssertThrowsError(
            try reducer.replay(fixture.operation, in: tampered)
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaCompletionOperationError,
                .derivedRecordsMismatch
            )
        }
    }

    func testReducerFailsClosedOnSecondCompletionPayloadAndKeepsCompletedState() throws {
        let fixture = try makeFixture()
        let reducer = NextStepBetaCompletionOperationReducer()
        let first = try reducer.replay(fixture.operation, in: fixture.archive)
        let conflictingAttestation = try makeAttestation(
            fixture: fixture,
            evidenceID: CompletionEvidenceID(fixedUUID(403)),
            value: "Different point one\nDifferent point two\nDifferent point three"
        )
        let conflicting = try NextStepBetaGuidedActionCompletionOperation(
            operationID: OperationID(fixedUUID(501)),
            action: fixture.action,
            package: fixture.package,
            completedAt: fixture.completedAt,
            originDeviceID: fixture.archive.deviceID,
            referencedUserResponses: fixture.responses,
            quizEvidence: fixture.quizEvidence,
            userAttestation: conflictingAttestation
        )

        XCTAssertThrowsError(try reducer.replay(conflicting, in: first.archive)) { error in
            XCTAssertEqual(
                error as? NextStepBetaCompletionOperationError,
                .conflictingActionCompletion(fixture.action.metadata.id)
            )
        }
        XCTAssertEqual(
            first.archive.workspace.dailyActions.first {
                $0.metadata.id == fixture.action.metadata.id
            }?.status,
            .completed
        )
        XCTAssertEqual(
            first.archive.workspace.dailyActions.first {
                $0.metadata.id == fixture.action.metadata.id
            }?.completedAt,
            fixture.completedAt
        )
    }

    func testReducerRejectsChangedCompletionContract() throws {
        let fixture = try makeFixture()
        var changed = fixture.archive
        let original = try XCTUnwrap(fixture.action.completionCriteria.first {
            $0.kind == .userAttestation
        })
        let replacement = try CompletionCriterion(
            id: original.id,
            kind: original.kind,
            title: "Changed attestation contract",
            threshold: original.threshold,
            requiresEvidence: original.requiresEvidence,
            requiresUserConfirmation: original.requiresUserConfirmation
        )
        let actionIndex = try XCTUnwrap(changed.workspace.dailyActions.firstIndex {
            $0.metadata.id == fixture.action.metadata.id
        })
        let packageIndex = try XCTUnwrap(changed.workspace.guidedPackages.firstIndex {
            $0.metadata.id == fixture.package.metadata.id
        })
        changed.workspace.dailyActions[actionIndex].completionCriteria =
            changed.workspace.dailyActions[actionIndex].completionCriteria.map {
                $0.id == replacement.id ? replacement : $0
            }
        changed.workspace.guidedPackages[packageIndex].completionCriteria =
            changed.workspace.guidedPackages[packageIndex].completionCriteria.map {
                $0.id == replacement.id ? replacement : $0
            }
        try changed.validate()

        XCTAssertThrowsError(
            try NextStepBetaCompletionOperationReducer().replay(
                fixture.operation,
                in: changed
            )
        ) { error in
            guard let operationError = error as? NextStepBetaCompletionOperationError,
                  case .completionContractMismatch = operationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testOperationFailsClosedForPackageWithoutDeterministicQuiz() throws {
        let fixture = try makeFixture()
        var packageWithoutQuiz = fixture.package
        packageWithoutQuiz.quiz = nil

        XCTAssertThrowsError(
            try NextStepBetaGuidedActionCompletionOperation.contractSHA256(
                action: fixture.action,
                package: packageWithoutQuiz
            )
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaCompletionOperationError,
                .quizBackedPackageRequired(fixture.package.metadata.id)
            )
        }
    }

    func testOperationRejectsCompletionTimeOutsidePersistableMilliseconds() throws {
        let fixture = try makeFixture()
        let invalidTime = Date(timeIntervalSince1970: -0.001)
        let attestation = try makeAttestation(
            action: fixture.action,
            package: fixture.package,
            completedAt: invalidTime,
            deviceID: fixture.archive.deviceID,
            evidenceID: CompletionEvidenceID(fixedUUID(404)),
            value: "Point one\nPoint two\nPoint three"
        )

        XCTAssertThrowsError(try NextStepBetaGuidedActionCompletionOperation(
            operationID: OperationID(fixedUUID(502)),
            action: fixture.action,
            package: fixture.package,
            completedAt: invalidTime,
            originDeviceID: fixture.archive.deviceID,
            referencedUserResponses: fixture.responses,
            quizEvidence: fixture.quizEvidence,
            userAttestation: attestation
        )) { error in
            guard let operationError = error as? NextStepBetaCompletionOperationError,
                  case let .invalidOperation(reason) = operationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("persistable millisecond range"))
        }
    }

    func testReducerRejectsSameResponseIdentifierWithDifferentAnswer() throws {
        let fixture = try makeFixture()
        var changed = fixture.archive
        changed.workspace.completionEvidence.removeAll()

        let original = try XCTUnwrap(fixture.responses.first)
        let quiz = try XCTUnwrap(fixture.package.quiz)
        let item = try XCTUnwrap(quiz.items.first { $0.id == original.quizItemID })
        let wrongOptionID = try XCTUnwrap(item.options.first {
            item.correctOptionIDs.contains($0.id) == false
        }?.id)
        let conflicting = try QuizEvaluator().makeResponse(
            metadata: original.metadata,
            attemptID: original.attemptID,
            quiz: quiz,
            quizItemID: item.id,
            packageVersion: fixture.package.version,
            selectedOptionID: wrongOptionID,
            attemptedAt: original.attemptedAt
        )
        let responseIndex = try XCTUnwrap(changed.workspace.userResponses.firstIndex {
            $0.metadata.id == original.metadata.id
        })
        changed.workspace.userResponses[responseIndex] = conflicting
        try changed.validate()

        XCTAssertThrowsError(
            try NextStepBetaCompletionOperationReducer().replay(
                fixture.operation,
                in: changed
            )
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaCompletionOperationError,
                .conflictingUserResponse(original.metadata.id)
            )
        }
    }

    private struct Fixture {
        let archive: NextStepBetaArchive
        let action: DailyAction
        let package: GuidedLearningPackage
        let responses: [UserResponse]
        let quizEvidence: CompletionEvidence
        let completedAt: Date
        let operation: NextStepBetaGuidedActionCompletionOperation
    }

    private func makeFixture() throws -> Fixture {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let quizAt = createdAt.addingTimeInterval(20)
        let completedAt = createdAt.addingTimeInterval(60)
        let deviceID = DeviceID(fixedUUID(1))
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
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceID,
            displayTitle: "Verified finance notes",
            fileExtension: "pdf",
            relativePath: "Sources/verified-finance.pdf",
            contentSHA256: String(repeating: "a", count: 64),
            now: createdAt,
            deviceID: deviceID,
            parserVersion: "completion-sync-tests-v1"
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
        let correctSelections = Dictionary(uniqueKeysWithValues: quiz.items.map {
            ($0.id, Set($0.correctOptionIDs))
        })
        let olderQuizAt = createdAt.addingTimeInterval(15)
        let olderAttempt = try NextStepBetaQuizGrader().grade(
            package: package,
            selections: correctSelections,
            attemptID: fixedUUID(299),
            now: olderQuizAt,
            deviceID: deviceID
        )
        let attempt = try NextStepBetaQuizGrader().grade(
            package: package,
            selections: correctSelections,
            attemptID: fixedUUID(300),
            now: quizAt,
            deviceID: deviceID
        )
        XCTAssertTrue(olderAttempt.passed)
        XCTAssertTrue(attempt.passed)
        let olderQuizResult = try QuizEvaluator().evaluate(
            quiz: quiz,
            packageID: package.metadata.id,
            packageVersion: package.version,
            responses: olderAttempt.responses,
            scoredAt: olderQuizAt
        )
        let quizResult = try QuizEvaluator().evaluate(
            quiz: quiz,
            packageID: package.metadata.id,
            packageVersion: package.version,
            responses: attempt.responses,
            scoredAt: quizAt
        )
        let quizCriterionIDs = action.completionCriteria.filter {
            $0.kind == .quizScore && $0.requiresEvidence
        }.map(\.id)
        let olderQuizEvidence = try CompletionEvidence(
            metadata: RecordMetadata(
                id: CompletionEvidenceID(fixedUUID(400)),
                createdAt: olderQuizAt,
                originDeviceID: deviceID,
                provenance: .deterministicEngine
            ),
            actionID: actionID,
            packageID: package.metadata.id,
            packageVersion: package.version,
            quizResult: olderQuizResult,
            capturedAt: olderQuizAt,
            criterionIDs: quizCriterionIDs
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
            criterionIDs: quizCriterionIDs
        )
        archive.workspace.userResponses.append(contentsOf: olderAttempt.responses)
        archive.workspace.userResponses.append(contentsOf: attempt.responses)
        archive.workspace.completionEvidence.append(olderQuizEvidence)
        archive.workspace.completionEvidence.append(quizEvidence)
        archive.workspace.revision += 1
        archive.workspace.savedAt = quizAt
        try archive.validate()

        let attestation = try makeAttestation(
            action: action,
            package: package,
            completedAt: completedAt,
            deviceID: deviceID,
            evidenceID: CompletionEvidenceID(fixedUUID(402)),
            value: "Point one\nPoint two\nPoint three"
        )
        let operation = try NextStepBetaGuidedActionCompletionOperation(
            operationID: OperationID(fixedUUID(500)),
            action: action,
            package: package,
            completedAt: completedAt,
            originDeviceID: deviceID,
            referencedUserResponses: attempt.responses,
            quizEvidence: quizEvidence,
            userAttestation: attestation
        )
        return Fixture(
            archive: archive,
            action: action,
            package: package,
            responses: attempt.responses,
            quizEvidence: quizEvidence,
            completedAt: completedAt,
            operation: operation
        )
    }

    private func makeAttestation(
        fixture: Fixture,
        evidenceID: CompletionEvidenceID,
        value: String
    ) throws -> CompletionEvidence {
        try makeAttestation(
            action: fixture.action,
            package: fixture.package,
            completedAt: fixture.completedAt,
            deviceID: fixture.archive.deviceID,
            evidenceID: evidenceID,
            value: value
        )
    }

    private func makeAttestation(
        action: DailyAction,
        package: GuidedLearningPackage,
        completedAt: Date,
        deviceID: DeviceID,
        evidenceID: CompletionEvidenceID,
        value: String
    ) throws -> CompletionEvidence {
        let criterionIDs = action.completionCriteria.filter {
            $0.kind == .userAttestation && $0.requiresEvidence
        }.map(\.id)
        return try CompletionEvidence(
            metadata: RecordMetadata(
                id: evidenceID,
                createdAt: completedAt,
                originDeviceID: deviceID,
                provenance: .user
            ),
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            kind: .userAttestation,
            value: value,
            capturedAt: completedAt,
            criterionIDs: criterionIDs
        )
    }

    private func fixedUUID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }
}
