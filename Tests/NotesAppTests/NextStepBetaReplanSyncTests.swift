import CryptoKit
import Foundation
import NextStepDomain
import NextStepPlanning
@testable import NotesApp
import XCTest

final class NextStepBetaReplanSyncTests: XCTestCase {
    func testCanonicalGoldenPayloadRoundTripsAndLocksStableDerivedIDs() throws {
        let golden = Data(Self.canonicalGoldenJSON.utf8)
        XCTAssertEqual(Self.sha256(golden), Self.canonicalGoldenSHA256)

        let operation = try NextStepBetaActionReplanOperationV1.decodeCanonical(
            from: golden
        )

        XCTAssertEqual(
            NextStepBetaActionReplanOperationV1.payloadKind,
            "nextstep.beta.action-replan"
        )
        XCTAssertEqual(operation.schemaVersion, 1)
        XCTAssertEqual(operation.trigger, .actionDeferred)
        XCTAssertEqual(operation.reasonCode, .userRequestedDeferral)
        XCTAssertNil(operation.remainingMinutes)
        XCTAssertEqual(
            operation.decisionID.rawValue.uuidString.lowercased(),
            "83ee64b7-ce79-59be-9d7f-169f1386975b"
        )
        XCTAssertEqual(
            operation.replanEventID.rawValue.uuidString.lowercased(),
            "7808952c-cc56-5904-bbe6-80aa1d8b5700"
        )
        XCTAssertEqual(try operation.canonicalData(), golden)

        var whitespacePrefixed = Data([0x20])
        whitespacePrefixed.append(golden)
        XCTAssertThrowsError(
            try NextStepBetaActionReplanOperationV1.decodeCanonical(
                from: whitespacePrefixed
            )
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaActionReplanOperationError,
                .nonCanonicalPayload
            )
        }
    }

    func testCanonicalDecoderRejectsUnknownFieldsAndOversizedPayloads() throws {
        let golden = Data(Self.canonicalGoldenJSON.utf8)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: golden) as? [String: Any]
        )
        root["unexpected"] = true
        let withUnknownField = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        XCTAssertThrowsError(
            try NextStepBetaActionReplanOperationV1.decodeCanonical(
                from: withUnknownField
            )
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaActionReplanOperationError,
                .nonCanonicalPayload
            )
        }

        let oversized = Data(
            repeating: 0x7b,
            count: NextStepBetaActionReplanOperationV1.maximumCanonicalByteCount + 1
        )
        XCTAssertThrowsError(
            try NextStepBetaActionReplanOperationV1.decodeCanonical(from: oversized)
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaActionReplanOperationError,
                .payloadTooLarge(oversized.count)
            )
        }
    }

    func testPrepareAndCancelArePureAndDoNotCreateAnOperation() throws {
        let fixture = try makeFixture()
        let originalWorkspace = fixture.archive.workspace
        let originalDecisionID = fixture.archive.currentDecisionID
        let coordinator = NextStepBetaActionReplanCoordinator()

        let preview = try coordinator.prepare(
            operationID: fixture.operationID,
            actionID: fixture.action.metadata.id,
            trigger: .actionDeferred,
            reasonCode: .userRequestedDeferral,
            requestedEarliestDay: fixture.requestedDay,
            in: fixture.archive,
            occurredAt: fixture.occurredAt
        )

        XCTAssertEqual(fixture.archive.workspace, originalWorkspace)
        XCTAssertEqual(fixture.archive.currentDecisionID, originalDecisionID)
        XCTAssertEqual(preview.proposal.trigger, .actionDeferred)
        XCTAssertEqual(preview.proposal.previousDecisionID, originalDecisionID)
        XCTAssertEqual(preview.proposal.proposedDecision.metadata.id, preview.decisionID)
        XCTAssertFalse(preview.proposal.changes.isEmpty)

        let cancelled = coordinator.cancel(preview, in: fixture.archive)
        XCTAssertEqual(cancelled.workspace, originalWorkspace)
        XCTAssertEqual(cancelled.currentDecisionID, originalDecisionID)
        XCTAssertEqual(cancelled.grounding, fixture.archive.grounding)
        XCTAssertEqual(
            cancelled.completionApplicationReceipts,
            fixture.archive.completionApplicationReceipts
        )
    }

    func testAcceptAndReplayApplyExactlyOnceWithAValidReceipt() throws {
        let fixture = try makeFixture()
        let coordinator = NextStepBetaActionReplanCoordinator()
        let preview = try makePreview(fixture)

        let accepted = try coordinator.accept(preview, in: fixture.archive)
        let acceptedAction = try XCTUnwrap(
            accepted.archive.workspace.dailyActions.first {
                $0.metadata.id == fixture.action.metadata.id
            }
        )
        XCTAssertEqual(acceptedAction.earliestDay, fixture.requestedDay)
        XCTAssertNotEqual(acceptedAction.status, .deferred)
        XCTAssertNil(acceptedAction.completedAt)
        XCTAssertEqual(accepted.archive.currentDecisionID, accepted.operation.decisionID)
        XCTAssertEqual(
            accepted.archive.workspace.planningDecisions.last?.metadata.id,
            accepted.operation.decisionID
        )
        XCTAssertEqual(
            accepted.archive.workspace.replanEvents.last?.metadata.id,
            accepted.operation.replanEventID
        )
        XCTAssertEqual(
            accepted.archive.workspace.replanEvents.last?.trigger,
            .actionDeferred
        )
        XCTAssertEqual(
            accepted.archive.actionReplanApplicationReceipts,
            [accepted.receipt]
        )
        XCTAssertNoThrow(
            try accepted.receipt.validate(
                operation: accepted.operation,
                in: accepted.archive
            )
        )
        XCTAssertNoThrow(try accepted.receipt.validate(in: accepted.archive))

        let independent = try NextStepBetaActionReplanOperationReducer().replay(
            accepted.operation,
            in: fixture.archive
        )
        XCTAssertEqual(independent.outcome, .applied)
        XCTAssertEqual(independent.archive.workspace, accepted.archive.workspace)
        XCTAssertEqual(independent.receipt, accepted.receipt)

        let replay = try NextStepBetaActionReplanOperationReducer().replay(
            accepted.operation,
            in: accepted.archive
        )
        XCTAssertEqual(replay.outcome, .alreadyApplied)
        XCTAssertEqual(replay.archive.workspace, accepted.archive.workspace)
        XCTAssertEqual(replay.receipt, accepted.receipt)
    }

    func testHistoricalReceiptRemainsValidAfterANewerAcceptedReplan() throws {
        let fixture = try makeFixture()
        let coordinator = NextStepBetaActionReplanCoordinator()
        let first = try coordinator.accept(
            makePreview(fixture),
            in: fixture.archive
        )
        let secondOccurredAt = fixture.occurredAt.addingTimeInterval(86_400)
        let secondToday = try LocalDay(
            date: secondOccurredAt,
            timeZoneIdentifier: first.archive.workspace.userProfile.timeZoneIdentifier
        )
        let secondPreview = try coordinator.prepare(
            operationID: OperationID(fixedUUID(501)),
            actionID: fixture.action.metadata.id,
            trigger: .actionDeferred,
            reasonCode: .userRequestedDeferral,
            requestedEarliestDay: try secondToday.adding(days: 1),
            in: first.archive,
            occurredAt: secondOccurredAt
        )
        let second = try coordinator.accept(secondPreview, in: first.archive)

        XCTAssertEqual(second.archive.actionReplanApplicationReceipts.count, 2)
        XCTAssertNoThrow(try first.receipt.validate(in: second.archive))
        let historicalReplay = try NextStepBetaActionReplanOperationReducer().replay(
            first.operation,
            in: second.archive
        )
        XCTAssertEqual(historicalReplay.outcome, .alreadyApplied)
        XCTAssertEqual(historicalReplay.receipt, first.receipt)
    }

    func testInsufficientTimeIntentDoesNotRewriteTheActionEstimate() throws {
        let fixture = try makeFixture()
        let remaining = max(1, fixture.action.estimatedMinutes - 10)
        let coordinator = NextStepBetaActionReplanCoordinator()
        let preview = try coordinator.prepare(
            operationID: fixture.operationID,
            actionID: fixture.action.metadata.id,
            trigger: .insufficientTime,
            reasonCode: .insufficientTime,
            requestedEarliestDay: fixture.requestedDay,
            remainingMinutes: remaining,
            in: fixture.archive,
            occurredAt: fixture.occurredAt
        )
        let accepted = try coordinator.accept(preview, in: fixture.archive)
        let action = try XCTUnwrap(accepted.archive.workspace.dailyActions.first {
            $0.metadata.id == fixture.action.metadata.id
        })

        XCTAssertEqual(accepted.operation.remainingMinutes, remaining)
        XCTAssertEqual(action.estimatedMinutes, fixture.action.estimatedMinutes)
        XCTAssertEqual(action.earliestDay, fixture.requestedDay)
        XCTAssertEqual(
            accepted.archive.workspace.replanEvents.last?.trigger,
            .insufficientTime
        )
    }

    func testV1RejectsUnsupportedTriggerReasonAndRemainingMinuteCombinations() throws {
        let fixture = try makeFixture()
        let coordinator = NextStepBetaActionReplanCoordinator()

        XCTAssertThrowsError(try coordinator.prepare(
            operationID: fixture.operationID,
            actionID: fixture.action.metadata.id,
            trigger: .manualRequest,
            reasonCode: .userRequestedDeferral,
            requestedEarliestDay: fixture.requestedDay,
            in: fixture.archive,
            occurredAt: fixture.occurredAt
        )) { error in
            guard let operationError = error as? NextStepBetaActionReplanOperationError,
                  case .invalidOperation = operationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try coordinator.prepare(
            operationID: fixture.operationID,
            actionID: fixture.action.metadata.id,
            trigger: .actionDeferred,
            reasonCode: .userRequestedDeferral,
            requestedEarliestDay: fixture.requestedDay,
            remainingMinutes: 5,
            in: fixture.archive,
            occurredAt: fixture.occurredAt
        ))

        XCTAssertThrowsError(try coordinator.prepare(
            operationID: fixture.operationID,
            actionID: fixture.action.metadata.id,
            trigger: .insufficientTime,
            reasonCode: .insufficientTime,
            requestedEarliestDay: fixture.requestedDay,
            remainingMinutes: 1_441,
            in: fixture.archive,
            occurredAt: fixture.occurredAt
        ))

        XCTAssertThrowsError(try coordinator.prepare(
            operationID: fixture.operationID,
            actionID: fixture.action.metadata.id,
            trigger: .actionDeferred,
            reasonCode: .userRequestedDeferral,
            requestedEarliestDay: try fixture.requestedDay.adding(days: 1),
            in: fixture.archive,
            occurredAt: fixture.occurredAt
        ))
    }

    func testReplayFailsClosedWhenTheActionWasCompetitivelyChanged() throws {
        let fixture = try makeFixture()
        let operation = try acceptedOperation(fixture)
        var changed = fixture.archive
        let index = try XCTUnwrap(changed.workspace.dailyActions.firstIndex {
            $0.metadata.id == fixture.action.metadata.id
        })
        changed.workspace.dailyActions[index].whyToday += " Competing edit."
        try changed.validate()

        assertReviewReason(
            .actionChanged,
            operation: operation,
            archive: changed
        )
    }

    func testReplayFailsClosedWhenProtectedDeadlineChanges() throws {
        let fixture = try makeFixture()
        let operation = try acceptedOperation(fixture)
        var changed = fixture.archive
        let index = try XCTUnwrap(changed.workspace.dailyActions.firstIndex {
            $0.metadata.id == fixture.action.metadata.id
        })
        changed.workspace.dailyActions[index].deadline = try FactValue(
            value: try fixture.requestedDay.adding(days: 20),
            authority: .userConfirmed,
            mutability: .immutable,
            confirmedAt: fixture.occurredAt
        )
        try changed.validate()

        assertReviewReason(
            .protectedDeadlineChanged,
            operation: operation,
            archive: changed
        )
    }

    func testReplayFailsClosedWhenAnotherProtectedGoalDeadlineChanges() throws {
        let fixture = try makeFixture()
        let operation = try acceptedOperation(fixture)
        var changed = fixture.archive
        let index = try XCTUnwrap(changed.workspace.ultimateGoals.indices.first)
        changed.workspace.ultimateGoals[index].targetDay = try FactValue(
            value: try fixture.requestedDay.adding(days: 40),
            authority: .userConfirmed,
            mutability: .immutable,
            confirmedAt: fixture.occurredAt
        )
        try changed.validate()

        assertReviewReason(
            .protectedDeadlineChanged,
            operation: operation,
            archive: changed
        )
    }

    func testReplayFailsClosedWhenSourceDependencyChanges() throws {
        let fixture = try makeFixture()
        let operation = try acceptedOperation(fixture)
        var changed = fixture.archive
        let sourceID = try XCTUnwrap(fixture.action.sourceDocumentIDs.first)
        let index = try XCTUnwrap(changed.workspace.sourceDocuments.firstIndex {
            $0.metadata.id == sourceID
        })
        changed.workspace.sourceDocuments[index].parserVersion =
            "replan-sync-tests-v2"
        try changed.validate()

        assertReviewReason(
            .sourceDependencyChanged,
            operation: operation,
            archive: changed
        )
    }

    func testReplayRequiresReviewWhenPlanningContextOrProposalChanges() throws {
        let fixture = try makeFixture()
        let operation = try acceptedOperation(fixture)

        let newerPlan = try NextStepBetaPlanningBridge().replan(
            archive: fixture.archive,
            trigger: .availabilityChanged,
            now: fixture.occurredAt.addingTimeInterval(-1)
        )
        assertReviewReason(
            .planningContextChanged,
            operation: operation,
            archive: newerPlan
        )

        var changedCapacity = fixture.archive
        changedCapacity.workspace.userProfile.weeklyAvailability = try (1...7).map {
            try WeeklyAvailability(isoWeekday: $0, availableMinutes: 0)
        }
        changedCapacity.workspace.userProfile.maximumDailyMinutes = 0
        changedCapacity.workspace.revision += 1
        changedCapacity.workspace.savedAt = fixture.occurredAt.addingTimeInterval(-1)
        try changedCapacity.validate()
        assertReviewReason(
            .proposalChanged,
            operation: operation,
            archive: changedCapacity
        )
    }

    func testReplayRecomputesAgainstAnUnrelatedWorkspaceRevision() throws {
        let fixture = try makeFixture()
        let accepted = try NextStepBetaActionReplanCoordinator().accept(
            makePreview(fixture),
            in: fixture.archive
        )
        var receiving = fixture.archive
        receiving.workspace.revision += 1
        receiving.workspace.savedAt = fixture.occurredAt.addingTimeInterval(-1)
        try receiving.validate()

        let replay = try NextStepBetaActionReplanOperationReducer().replay(
            accepted.operation,
            in: receiving
        )

        XCTAssertEqual(replay.outcome, .applied)
        XCTAssertEqual(
            replay.archive.workspace.planningDecisions.last?.metadata.id,
            accepted.operation.decisionID
        )
        XCTAssertNotEqual(
            replay.archive.workspace.planningDecisions.last?.inputSnapshotSHA256,
            accepted.archive.workspace.planningDecisions.last?.inputSnapshotSHA256
        )
        XCTAssertEqual(
            replay.receipt.confirmedProposalDigest,
            accepted.operation.confirmedProposalDigest
        )
    }

    func testAcceptedReplanCannotMutateProtectedDeadlineOrSourceRecords() throws {
        let fixture = try makeFixture()
        let originalDeadline = fixture.action.deadline
        let originalSources = fixture.archive.workspace.sourceDocuments
        let accepted = try NextStepBetaActionReplanCoordinator().accept(
            makePreview(fixture),
            in: fixture.archive
        )
        let action = try XCTUnwrap(accepted.archive.workspace.dailyActions.first {
            $0.metadata.id == fixture.action.metadata.id
        })

        XCTAssertEqual(action.deadline, originalDeadline)
        XCTAssertEqual(accepted.archive.workspace.sourceDocuments, originalSources)
        XCTAssertEqual(
            accepted.receipt.protectedDeadlineDigest,
            accepted.operation.protectedDeadlineDigest
        )
        XCTAssertEqual(
            accepted.receipt.sourceDependencyDigest,
            accepted.operation.sourceDependencyDigest
        )
    }

    func testReplayRejectsDerivedIdentifierCollisionAndTamperedReceiptProjection() throws {
        let fixture = try makeFixture()
        let accepted = try NextStepBetaActionReplanCoordinator().accept(
            makePreview(fixture),
            in: fixture.archive
        )
        var tampered = accepted.archive
        let eventIndex = try XCTUnwrap(tampered.workspace.replanEvents.firstIndex {
            $0.metadata.id == accepted.operation.replanEventID
        })
        let event = tampered.workspace.replanEvents[eventIndex]
        tampered.workspace.replanEvents[eventIndex] = ReplanEvent(
            metadata: event.metadata,
            trigger: .manualRequest,
            beforeDecisionID: event.beforeDecisionID,
            afterDecisionID: event.afterDecisionID,
            protectedFactDescriptions: event.protectedFactDescriptions,
            resolution: event.resolution,
            occurredAt: event.occurredAt
        )
        tampered.actionReplanApplicationReceipts.removeAll()
        try tampered.validate()

        XCTAssertThrowsError(
            try NextStepBetaActionReplanOperationReducer().replay(
                accepted.operation,
                in: tampered
            )
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaActionReplanOperationError,
                .derivedRecordConflict(
                    kind: .replanEvent,
                    id: accepted.operation.replanEventID.rawValue
                )
            )
        }
        XCTAssertThrowsError(try accepted.receipt.validate(in: tampered)) { error in
            XCTAssertEqual(
                error as? NextStepBetaActionReplanOperationError,
                .receiptMismatch
            )
        }
    }

    private struct Fixture {
        let archive: NextStepBetaArchive
        let action: DailyAction
        let operationID: OperationID
        let occurredAt: Date
        let requestedDay: LocalDay
    }

    private func makeFixture() throws -> Fixture {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let occurredAt = createdAt.addingTimeInterval(60)
        let deviceID = DeviceID(fixedUUID(1))
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: createdAt,
            deviceID: deviceID,
            timeZoneIdentifier: "UTC"
        )
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "Finish the grounded finance milestone",
            deadline: try LocalDay(year: 2028, month: 12, day: 31),
            dailyMinutes: 35,
            to: archive,
            now: createdAt
        )
        let sourceID = SourceDocumentID(fixedUUID(100))
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceID,
            displayTitle: "Verified finance source",
            fileExtension: "pdf",
            relativePath: "Sources/verified-finance.pdf",
            contentSHA256: String(repeating: "a", count: 64),
            now: createdAt,
            deviceID: deviceID,
            parserVersion: "replan-sync-tests-v1"
        )
        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: document,
                exactExtract: [
                    "Debt creates contractual interest obligations.",
                    "Cash flow supports debt service capacity.",
                    "Every grounded claim remains traceable."
                ].joined(separator: "\n"),
                pageIndex: 0,
                usedVisionOCR: true,
                extractionNotice: nil
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
        let today = try LocalDay(
            date: occurredAt,
            timeZoneIdentifier: archive.workspace.userProfile.timeZoneIdentifier
        )
        return Fixture(
            archive: archive,
            action: action,
            operationID: OperationID(fixedUUID(500)),
            occurredAt: occurredAt,
            requestedDay: try today.adding(days: 1)
        )
    }

    private func makePreview(
        _ fixture: Fixture
    ) throws -> NextStepBetaActionReplanPreview {
        try NextStepBetaActionReplanCoordinator().prepare(
            operationID: fixture.operationID,
            actionID: fixture.action.metadata.id,
            trigger: .actionDeferred,
            reasonCode: .userRequestedDeferral,
            requestedEarliestDay: fixture.requestedDay,
            in: fixture.archive,
            occurredAt: fixture.occurredAt
        )
    }

    private func acceptedOperation(
        _ fixture: Fixture
    ) throws -> NextStepBetaActionReplanOperationV1 {
        try NextStepBetaActionReplanCoordinator().accept(
            makePreview(fixture),
            in: fixture.archive
        ).operation
    }

    private func assertReviewReason(
        _ expected: NextStepBetaActionReplanReviewReason,
        operation: NextStepBetaActionReplanOperationV1,
        archive: NextStepBetaArchive,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NextStepBetaActionReplanOperationReducer().replay(
                operation,
                in: archive
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? NextStepBetaActionReplanOperationError,
                .contextRequiresReview(expected),
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

    private static let canonicalGoldenSHA256 =
        "fdb72df6aa8fe8b9aff5dd411dd47913958197cbd71e6b92beb89034fd5fd2ac"

    private static let canonicalGoldenJSON = #"{"actionID":"00000000-0000-0000-0000-000000000100","baseActionDigest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","confirmedProposalDigest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","decisionID":"83EE64B7-CE79-59BE-9D7F-169F1386975B","occurredAt":1800000060000,"operationID":"00000000-0000-0000-0000-000000000500","originDeviceID":"00000000-0000-0000-0000-000000000001","planningEngineVersion":"nextstep-deterministic-v1","protectedDeadlineDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","reasonCode":"userRequestedDeferral","replanEventID":"7808952C-CC56-5904-BBE6-80AA1D8B5700","requestedEarliestDay":{"day":2,"month":1,"year":2027},"schemaVersion":1,"sourceDependencyDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","trigger":"actionDeferred"}"#
}
