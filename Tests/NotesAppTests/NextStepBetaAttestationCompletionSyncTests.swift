import CryptoKit
import Foundation
import NextStepDomain
import NextStepPlanning
@testable import NotesApp
import XCTest

final class NextStepBetaAttestationCompletionSyncTests: XCTestCase {
    func testSchemaV1GoldenPayloadRemainsByteIdenticalThroughVersionedRoot() throws {
        let golden = Data(Self.v1CanonicalJSON.utf8)
        XCTAssertEqual(Self.sha256(golden), Self.v1CanonicalSHA256)

        let decoded = try NextStepBetaGuidedActionCompletionOperation.decodeCanonical(
            from: golden
        )

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.kind, NextStepBetaGuidedActionCompletionOperation.payloadKind)
        XCTAssertNotNil(decoded.quizEvidence)
        XCTAssertEqual(try decoded.canonicalData(), golden)
        XCTAssertEqual(Self.sha256(try decoded.canonicalData()), Self.v1CanonicalSHA256)
    }

    func testAttestationOnlyPayloadHasCanonicalSchemaV2RootAndNoQuizRecords() throws {
        let fixture = try makeFixture()
        let canonical = try fixture.operation.canonicalData()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )

        XCTAssertEqual(fixture.operation.schemaVersion, 2)
        XCTAssertEqual(root["schemaVersion"] as? Int, 2)
        XCTAssertEqual(
            root["kind"] as? String,
            NextStepBetaGuidedActionCompletionOperation.payloadKind
        )
        XCTAssertNil(root["quizEvidence"])
        XCTAssertNil(root["referencedUserResponses"])
        XCTAssertNotNil(root["userAttestation"])
        XCTAssertNil(fixture.operation.quizEvidence)
        XCTAssertTrue(fixture.operation.referencedUserResponses.isEmpty)
        XCTAssertEqual(fixture.operation.completionEvidence, [fixture.attestation])
        XCTAssertEqual(
            fixture.operation.progressSnapshotID.rawValue.uuidString.lowercased(),
            "44e8a35c-0461-5fe5-9e69-c4b69b0ad679"
        )
        XCTAssertEqual(
            fixture.operation.planningDecisionID.rawValue.uuidString.lowercased(),
            "e990b2d7-3bac-5564-92df-67e3bd4f3bcc"
        )
        XCTAssertEqual(
            fixture.operation.replanEventID.rawValue.uuidString.lowercased(),
            "f7622601-633a-5f2a-98ac-3f0a0ce479c5"
        )
        XCTAssertEqual(
            try NextStepBetaGuidedActionCompletionOperation.decodeCanonical(from: canonical),
            fixture.operation
        )

        var withUnknownV1Field = root
        withUnknownV1Field["referencedUserResponses"] = []
        let nonCanonical = try JSONSerialization.data(
            withJSONObject: withUnknownV1Field,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(
            try NextStepBetaGuidedActionCompletionOperation.decodeCanonical(
                from: nonCanonical
            )
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaCompletionOperationError,
                .nonCanonicalPayload
            )
        }
    }

    func testAttestationOnlyReducerAppliesAndReplaysIdempotently() throws {
        let fixture = try makeFixture()
        let reducer = NextStepBetaCompletionOperationReducer()

        let first = try reducer.replay(fixture.operation, in: fixture.archive)
        XCTAssertEqual(first.outcome, .applied)
        let completed = try XCTUnwrap(first.archive.workspace.dailyActions.first {
            $0.metadata.id == fixture.action.metadata.id
        })
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.completedAt, fixture.completedAt)
        XCTAssertEqual(
            first.archive.workspace.completionEvidence.filter {
                $0.actionID == fixture.action.metadata.id
            },
            [fixture.attestation]
        )
        XCTAssertTrue(first.archive.workspace.userResponses.isEmpty)
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
        let receipt = try XCTUnwrap(first.archive.completionApplicationReceipts.first)
        XCTAssertEqual(first.archive.completionApplicationReceipts.count, 1)
        XCTAssertTrue(receipt.matches(fixture.operation))

        let second = try reducer.replay(fixture.operation, in: first.archive)
        XCTAssertEqual(second.outcome, .alreadyApplied)
        XCTAssertEqual(second.archive.workspace, first.archive.workspace)
        XCTAssertEqual(
            second.archive.completionApplicationReceipts,
            first.archive.completionApplicationReceipts
        )
    }

    func testAttestationOnlyContractRejectsQuizAndEveryNonAttestationGate() throws {
        let fixture = try makeFixture()

        var packageWithQuiz = fixture.package
        packageWithQuiz.quiz = try makeGenericQuiz(
            objectiveID: fixture.package.learningObjectives[0].id,
            deviceID: fixture.archive.deviceID,
            now: fixture.createdAt
        )
        assertOperationRejected(
            action: fixture.action,
            package: packageWithQuiz,
            fixture: fixture
        )

        let existsOutput = try RequiredOutput(
            kind: fixture.action.requiredOutput.kind,
            title: fixture.action.requiredOutput.title,
            destinationHint: fixture.action.requiredOutput.destinationHint,
            validationKind: .exists
        )
        var actionWithExistsOutput = fixture.action
        var packageWithExistsOutput = fixture.package
        actionWithExistsOutput.requiredOutput = existsOutput
        packageWithExistsOutput.requiredOutput = existsOutput
        assertOperationRejected(
            action: actionWithExistsOutput,
            package: packageWithExistsOutput,
            fixture: fixture
        )

        let originalCriterion = try XCTUnwrap(fixture.action.completionCriteria.first)
        for forbiddenKind in CompletionCriterionKind.allCases
            where forbiddenKind != .userAttestation {
            let threshold: Double? = switch forbiddenKind {
            case .quizScore: 1
            case .minimumWordCount: 3
            default: nil
            }
            let forbidden = try CompletionCriterion(
                id: originalCriterion.id,
                kind: forbiddenKind,
                title: "Forbidden completion gate",
                threshold: threshold,
                requiresEvidence: true,
                requiresUserConfirmation: true
            )
            var action = fixture.action
            var package = fixture.package
            action.completionCriteria = [forbidden]
            package.completionCriteria = [forbidden]
            assertOperationRejected(action: action, package: package, fixture: fixture)
        }

        for flags in [(false, true), (true, false), (false, false)] {
            let bypass = try CompletionCriterion(
                id: originalCriterion.id,
                kind: .userAttestation,
                title: originalCriterion.title,
                requiresEvidence: flags.0,
                requiresUserConfirmation: flags.1
            )
            var action = fixture.action
            var package = fixture.package
            action.completionCriteria = [bypass]
            package.completionCriteria = [bypass]
            assertOperationRejected(action: action, package: package, fixture: fixture)
        }
    }

    func testAttestationMustCoverExactCanonicalCriterionSetAndBindOperationMetadata() throws {
        let fixture = try makeFixture()
        let second = try CompletionCriterion(
            id: fixedUUID(902),
            kind: .userAttestation,
            title: "Confirm the second explicit statement",
            requiresEvidence: true,
            requiresUserConfirmation: true
        )
        var action = fixture.action
        var package = fixture.package
        action.completionCriteria.append(second)
        package.completionCriteria.append(second)

        let incomplete = try makeAttestation(
            operationID: fixture.operationID,
            action: action,
            package: package,
            completedAt: fixture.completedAt,
            deviceID: fixture.archive.deviceID,
            evidenceID: CompletionEvidenceID(fixedUUID(903)),
            criterionIDs: [fixture.attestation.criterionIDs[0]]
        )
        XCTAssertThrowsError(try NextStepBetaGuidedActionCompletionOperation(
            operationID: fixture.operationID,
            action: action,
            package: package,
            completedAt: fixture.completedAt,
            originDeviceID: fixture.archive.deviceID,
            userAttestation: incomplete
        )) { error in
            guard let operationError = error as? NextStepBetaCompletionOperationError,
                  case let .invalidOperation(reason) = operationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("complete canonical criterion set"))
        }

        let sortedIDs = action.completionCriteria.map(\.id).sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let exact = try makeAttestation(
            operationID: fixture.operationID,
            action: action,
            package: package,
            completedAt: fixture.completedAt,
            deviceID: fixture.archive.deviceID,
            evidenceID: CompletionEvidenceID(fixedUUID(904)),
            criterionIDs: sortedIDs
        )
        XCTAssertNoThrow(try NextStepBetaGuidedActionCompletionOperation(
            operationID: fixture.operationID,
            action: action,
            package: package,
            completedAt: fixture.completedAt,
            originDeviceID: fixture.archive.deviceID,
            userAttestation: exact
        ))

        let unbound = try CompletionEvidence(
            metadata: RecordMetadata(
                id: CompletionEvidenceID(fixedUUID(905)),
                createdAt: fixture.completedAt,
                originDeviceID: fixture.archive.deviceID,
                provenance: .user
            ),
            actionID: fixture.action.metadata.id,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            kind: .userAttestation,
            value: "Point one\nPoint two\nPoint three",
            capturedAt: fixture.completedAt,
            criterionIDs: fixture.attestation.criterionIDs
        )
        XCTAssertThrowsError(try NextStepBetaGuidedActionCompletionOperation(
            operationID: fixture.operationID,
            action: fixture.action,
            package: fixture.package,
            completedAt: fixture.completedAt,
            originDeviceID: fixture.archive.deviceID,
            userAttestation: unbound
        ))
    }

    func testAttestationRejectsFewerThanThreeCanonicalLines() throws {
        let fixture = try makeFixture()
        let insufficient = try makeAttestation(
            operationID: fixture.operationID,
            action: fixture.action,
            package: fixture.package,
            completedAt: fixture.completedAt,
            deviceID: fixture.archive.deviceID,
            evidenceID: CompletionEvidenceID(fixedUUID(906)),
            value: "Only one attested point"
        )

        XCTAssertThrowsError(try NextStepBetaGuidedActionCompletionOperation(
            operationID: fixture.operationID,
            action: fixture.action,
            package: fixture.package,
            completedAt: fixture.completedAt,
            originDeviceID: fixture.archive.deviceID,
            userAttestation: insufficient
        )) { error in
            guard let operationError = error as? NextStepBetaCompletionOperationError,
                  case let .invalidOperation(reason) = operationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("canonical explicit user evidence"))
        }
    }

    func testAttestationOnlyReducerRejectsOtherSameActionEvidenceAndSecondPayload() throws {
        let fixture = try makeFixture()
        var archiveWithOtherEvidence = fixture.archive
        let otherEvidence = try makeAttestation(
            operationID: OperationID(fixedUUID(910)),
            action: fixture.action,
            package: fixture.package,
            completedAt: fixture.completedAt.addingTimeInterval(-1),
            deviceID: fixture.archive.deviceID,
            evidenceID: CompletionEvidenceID(fixedUUID(911))
        )
        archiveWithOtherEvidence.workspace.completionEvidence.append(otherEvidence)
        try archiveWithOtherEvidence.validate()

        XCTAssertThrowsError(
            try NextStepBetaCompletionOperationReducer().replay(
                fixture.operation,
                in: archiveWithOtherEvidence
            )
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaCompletionOperationError,
                .conflictingActionCompletion(fixture.action.metadata.id)
            )
        }

        let first = try NextStepBetaCompletionOperationReducer().replay(
            fixture.operation,
            in: fixture.archive
        )
        let secondOperationID = OperationID(fixedUUID(912))
        let secondAttestation = try makeAttestation(
            operationID: secondOperationID,
            action: fixture.action,
            package: fixture.package,
            completedAt: fixture.completedAt,
            deviceID: fixture.archive.deviceID,
            evidenceID: CompletionEvidenceID(fixedUUID(913)),
            value: "Different point one\nDifferent point two\nDifferent point three"
        )
        let secondOperation = try NextStepBetaGuidedActionCompletionOperation(
            operationID: secondOperationID,
            action: fixture.action,
            package: fixture.package,
            completedAt: fixture.completedAt,
            originDeviceID: fixture.archive.deviceID,
            userAttestation: secondAttestation
        )

        XCTAssertThrowsError(
            try NextStepBetaCompletionOperationReducer().replay(
                secondOperation,
                in: first.archive
            )
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaCompletionOperationError,
                .conflictingActionCompletion(fixture.action.metadata.id)
            )
        }
    }

    func testAttestationOnlyReducerRejectsChangedCompletionContract() throws {
        let fixture = try makeFixture()
        var changed = fixture.archive
        let actionIndex = try XCTUnwrap(changed.workspace.dailyActions.firstIndex {
            $0.metadata.id == fixture.action.metadata.id
        })
        let packageIndex = try XCTUnwrap(changed.workspace.guidedPackages.firstIndex {
            $0.metadata.id == fixture.package.metadata.id
        })
        let criterion = try XCTUnwrap(fixture.action.completionCriteria.first)
        let renamed = try CompletionCriterion(
            id: criterion.id,
            kind: criterion.kind,
            title: "Changed attestation contract",
            requiresEvidence: true,
            requiresUserConfirmation: true
        )
        changed.workspace.dailyActions[actionIndex].completionCriteria = [renamed]
        changed.workspace.guidedPackages[packageIndex].completionCriteria = [renamed]
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

    private struct Fixture {
        let archive: NextStepBetaArchive
        let action: DailyAction
        let package: GuidedLearningPackage
        let createdAt: Date
        let completedAt: Date
        let operationID: OperationID
        let attestation: CompletionEvidence
        let operation: NextStepBetaGuidedActionCompletionOperation
    }

    private func makeFixture() throws -> Fixture {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let completedAt = createdAt.addingTimeInterval(60)
        let deviceID = DeviceID(fixedUUID(1))
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: createdAt,
            deviceID: deviceID,
            timeZoneIdentifier: "UTC"
        )
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "Complete the OCR-guided review",
            deadline: try LocalDay(year: 2028, month: 12, day: 31),
            dailyMinutes: 35,
            to: archive,
            now: createdAt
        )
        let sourceID = SourceDocumentID(fixedUUID(100))
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceID,
            displayTitle: "OCR review.png",
            fileExtension: "png",
            relativePath: "Sources/ocr-review.png",
            contentSHA256: String(repeating: "b", count: 64),
            now: createdAt,
            deviceID: deviceID,
            parserVersion: "vision-ocr-first-page-v1"
        )
        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: document,
                exactExtract: "OCR point one.\nOCR point two.\nOCR point three.",
                pageIndex: 0,
                usedVisionOCR: true,
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
        XCTAssertNil(package.quiz)
        let operationID = OperationID(fixedUUID(900))
        let attestation = try makeAttestation(
            operationID: operationID,
            action: action,
            package: package,
            completedAt: completedAt,
            deviceID: deviceID,
            evidenceID: CompletionEvidenceID(fixedUUID(901))
        )
        let operation = try NextStepBetaGuidedActionCompletionOperation(
            operationID: operationID,
            action: action,
            package: package,
            completedAt: completedAt,
            originDeviceID: deviceID,
            userAttestation: attestation
        )
        try archive.validate()
        return Fixture(
            archive: archive,
            action: action,
            package: package,
            createdAt: createdAt,
            completedAt: completedAt,
            operationID: operationID,
            attestation: attestation,
            operation: operation
        )
    }

    private func makeAttestation(
        operationID: OperationID,
        action: DailyAction,
        package: GuidedLearningPackage,
        completedAt: Date,
        deviceID: DeviceID,
        evidenceID: CompletionEvidenceID,
        criterionIDs: [UUID]? = nil,
        value: String = "Point one\nPoint two\nPoint three"
    ) throws -> CompletionEvidence {
        let effectiveCriterionIDs = criterionIDs ?? action.completionCriteria
            .map(\.id)
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        return try CompletionEvidence(
            metadata: RecordMetadata(
                id: evidenceID,
                createdAt: completedAt,
                originDeviceID: deviceID,
                lastOperationID: operationID,
                provenance: .user
            ),
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            kind: .userAttestation,
            value: value,
            capturedAt: completedAt,
            criterionIDs: effectiveCriterionIDs
        )
    }

    private func makeGenericQuiz(
        objectiveID: UUID,
        deviceID: DeviceID,
        now: Date
    ) throws -> Quiz {
        let item = try QuizItem(
            id: QuizItemID(fixedUUID(920)),
            kind: .shortAnswer,
            prompt: "This quiz must make the v2 profile fail.",
            answerExplanation: "Attestation-only schema v2 cannot carry a quiz.",
            objectiveID: objectiveID,
            evidenceLinkIDs: [EvidenceLinkID(fixedUUID(921))]
        )
        return try Quiz(
            metadata: RecordMetadata(
                id: QuizID(fixedUUID(922)),
                createdAt: now,
                originDeviceID: deviceID,
                provenance: .deterministicEngine
            ),
            learningObjectiveIDs: [objectiveID],
            items: [item],
            passingFraction: 1
        )
    }

    private func assertOperationRejected(
        action: DailyAction,
        package: GuidedLearningPackage,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try NextStepBetaGuidedActionCompletionOperation(
            operationID: fixture.operationID,
            action: action,
            package: package,
            completedAt: fixture.completedAt,
            originDeviceID: fixture.archive.deviceID,
            userAttestation: fixture.attestation
        ), file: file, line: line) { error in
            guard let operationError = error as? NextStepBetaCompletionOperationError else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertEqual(
                operationError,
                .attestationOnlyPackageRequired(package.metadata.id),
                file: file,
                line: line
            )
        }
    }

    private func fixedUUID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let v1CanonicalSHA256 =
        "f663dd1cfd25ab0539ca547dd50b87f839a061233289501ed53246f47c459a19"

    private static let v1CanonicalJSON = #"{"actionID":"00000000-0000-0000-0000-000000000013","completedAt":1800000060000,"completionContractSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","derivedRecordContractSHA256":"9970f448fe36e1cfb37c0c819fae0dca135dc39fdefda3498a6957aafee3d57b","kind":"nextstep.beta.guided-action-completion","operationID":"00000000-0000-0000-0000-000000000500","originDeviceID":"00000000-0000-0000-0000-000000000001","packageID":"00000000-0000-0000-0000-000000000014","packageVersion":1,"planningDecisionID":"7C9F2630-C961-5C53-BD18-52E93635BD90","planningEngineVersion":"nextstep-deterministic-v1","progressSnapshotID":"BCDEAD7F-E3DF-575C-9D3F-04CFAAA1F4B7","quizEvidence":{"actionID":"00000000-0000-0000-0000-000000000013","capturedAt":1800000020000,"criterionIDs":["00000000-0000-0000-0000-000000000022"],"kind":"quizResult","measuredValue":1,"metadata":{"createdAt":1800000020000,"id":"00000000-0000-0000-0000-000000000401","originDeviceID":"00000000-0000-0000-0000-000000000001","provenance":{"kind":"deterministicEngine","sourceDocumentIDs":[]},"revision":0,"schemaVersion":1,"updatedAt":1800000020000},"packageID":"00000000-0000-0000-0000-000000000014","packageVersion":1,"quizResult":{"attemptID":"00000000-0000-0000-0000-000000000300","evidenceLinkIDs":["00000000-0000-0000-0000-000000000201"],"packageID":"00000000-0000-0000-0000-000000000014","packageVersion":1,"quizID":"00000000-0000-0000-0000-000000000200","responseIDs":["00000000-0000-0000-0000-000000000301"],"scoreFraction":1,"scoredAt":1800000020000,"scorerVersion":1},"value":"quiz:00000000-0000-0000-0000-000000000200:1.0"},"referencedUserResponses":[{"answer":"Canonical answer","attemptID":"00000000-0000-0000-0000-000000000300","attemptedAt":1800000020000,"feedback":"Canonical feedback","metadata":{"createdAt":1800000020000,"id":"00000000-0000-0000-0000-000000000301","originDeviceID":"00000000-0000-0000-0000-000000000001","provenance":{"kind":"user","sourceDocumentIDs":[]},"revision":0,"schemaVersion":1,"updatedAt":1800000020000},"packageVersion":1,"quizID":"00000000-0000-0000-0000-000000000200","quizItemID":"00000000-0000-0000-0000-000000000202","scoreFraction":1,"selectedOptionIDs":["00000000-0000-0000-0000-000000000203"]}],"replanEventID":"C98C8544-3735-56B1-BA5A-92752A93E3B1","schemaVersion":1,"userAttestation":{"actionID":"00000000-0000-0000-0000-000000000013","capturedAt":1800000060000,"criterionIDs":["00000000-0000-0000-0000-000000000023"],"kind":"userAttestation","metadata":{"createdAt":1800000060000,"id":"00000000-0000-0000-0000-000000000402","originDeviceID":"00000000-0000-0000-0000-000000000001","provenance":{"kind":"user","sourceDocumentIDs":[]},"revision":0,"schemaVersion":1,"updatedAt":1800000060000},"packageID":"00000000-0000-0000-0000-000000000014","packageVersion":1,"value":"Point one\nPoint two\nPoint three"}}"#
}
