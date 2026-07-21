import CryptoKit
import Foundation
import NextStepDomain
import NextStepPlanning

enum NextStepBetaActionReplanReasonCode: String, Codable, CaseIterable, Hashable, Sendable {
    case userRequestedDeferral
    case insufficientTime
}

enum NextStepBetaActionReplanReviewReason: String, Codable, Hashable, Sendable {
    case actionChanged
    case actionNoLongerEligible
    case protectedDeadlineChanged
    case sourceDependencyChanged
    case planningContextChanged
    case proposalChanged
}

enum NextStepBetaActionReplanDerivedRecordKind: String, Codable, Hashable, Sendable {
    case planningDecision
    case replanEvent
}

enum NextStepBetaActionReplanOperationError:
    Error,
    Equatable,
    LocalizedError,
    Sendable {
    case unsupportedSchema(Int)
    case unsupportedPlanningEngineVersion(String)
    case payloadTooLarge(Int)
    case nonCanonicalPayload
    case invalidOperation(String)
    case actionNotFound(DailyActionID)
    case actionNotEligible(DailyActionID)
    case previewContextChanged
    case contextRequiresReview(NextStepBetaActionReplanReviewReason)
    case derivedRecordConflict(kind: NextStepBetaActionReplanDerivedRecordKind, id: UUID)
    case proposalRejected(String)
    case receiptMismatch

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported action-replan schema \(version)."
        case let .unsupportedPlanningEngineVersion(version):
            "Unsupported action-replan planning engine \(version)."
        case let .payloadTooLarge(byteCount):
            "The action-replan payload is too large (\(byteCount) bytes)."
        case .nonCanonicalPayload:
            "The action-replan payload is not canonical."
        case let .invalidOperation(reason):
            "The action-replan operation is invalid: \(reason)"
        case let .actionNotFound(actionID):
            "The action \(actionID) was not found."
        case let .actionNotEligible(actionID):
            "The action \(actionID) cannot be deferred."
        case .previewContextChanged:
            "The replan preview no longer matches its prepared operation."
        case let .contextRequiresReview(reason):
            "The receiving planning context changed and requires review (\(reason.rawValue))."
        case let .derivedRecordConflict(kind, id):
            "The derived \(kind.rawValue) identifier \(id.uuidString.lowercased()) is already in use."
        case let .proposalRejected(message):
            "The deterministic replan was rejected: \(message)"
        case .receiptMismatch:
            "The action-replan application receipt does not match the saved projection."
        }
    }
}

/// Canonical, immutable intent for one confirmed action deferral. It carries
/// no mutable workspace projection; every receiver replays deterministic
/// mutation and planning, then verifies the user-confirmed proposal digest.
struct NextStepBetaActionReplanOperationV1: Codable, Hashable, Sendable {
    static let payloadKind = "nextstep.beta.action-replan"
    static let currentSchemaVersion = 1
    static let supportedPlanningEngineVersion = "nextstep-deterministic-v1"
    static let maximumCanonicalByteCount = 1_048_576

    let schemaVersion: Int
    let operationID: OperationID
    let actionID: DailyActionID
    let trigger: ReplanTrigger
    let reasonCode: NextStepBetaActionReplanReasonCode
    let requestedEarliestDay: LocalDay
    let remainingMinutes: Int?
    let occurredAt: Date
    let originDeviceID: DeviceID
    let baseActionDigest: String
    let previousDecisionID: PlanningDecisionID?
    let protectedDeadlineDigest: String
    let sourceDependencyDigest: String
    let planningEngineVersion: String
    let confirmedProposalDigest: String
    let decisionID: PlanningDecisionID
    let replanEventID: ReplanEventID

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case operationID
        case actionID
        case trigger
        case reasonCode
        case requestedEarliestDay
        case remainingMinutes
        case occurredAt
        case originDeviceID
        case baseActionDigest
        case previousDecisionID
        case protectedDeadlineDigest
        case sourceDependencyDigest
        case planningEngineVersion
        case confirmedProposalDigest
        case decisionID
        case replanEventID
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        operationID: OperationID,
        actionID: DailyActionID,
        trigger: ReplanTrigger,
        reasonCode: NextStepBetaActionReplanReasonCode,
        requestedEarliestDay: LocalDay,
        remainingMinutes: Int?,
        occurredAt: Date,
        originDeviceID: DeviceID,
        baseActionDigest: String,
        previousDecisionID: PlanningDecisionID?,
        protectedDeadlineDigest: String,
        sourceDependencyDigest: String,
        planningEngineVersion: String = Self.supportedPlanningEngineVersion,
        confirmedProposalDigest: String,
        decisionID: PlanningDecisionID,
        replanEventID: ReplanEventID
    ) throws {
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.actionID = actionID
        self.trigger = trigger
        self.reasonCode = reasonCode
        self.requestedEarliestDay = requestedEarliestDay
        self.remainingMinutes = remainingMinutes
        self.occurredAt = occurredAt
        self.originDeviceID = originDeviceID
        self.baseActionDigest = baseActionDigest
        self.previousDecisionID = previousDecisionID
        self.protectedDeadlineDigest = protectedDeadlineDigest
        self.sourceDependencyDigest = sourceDependencyDigest
        self.planningEngineVersion = planningEngineVersion
        self.confirmedProposalDigest = confirmedProposalDigest
        self.decisionID = decisionID
        self.replanEventID = replanEventID
        try validateIntrinsic()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            operationID: container.decode(OperationID.self, forKey: .operationID),
            actionID: container.decode(DailyActionID.self, forKey: .actionID),
            trigger: container.decode(ReplanTrigger.self, forKey: .trigger),
            reasonCode: container.decode(
                NextStepBetaActionReplanReasonCode.self,
                forKey: .reasonCode
            ),
            requestedEarliestDay: container.decode(
                LocalDay.self,
                forKey: .requestedEarliestDay
            ),
            remainingMinutes: container.decodeIfPresent(
                Int.self,
                forKey: .remainingMinutes
            ),
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            originDeviceID: container.decode(DeviceID.self, forKey: .originDeviceID),
            baseActionDigest: container.decode(String.self, forKey: .baseActionDigest),
            previousDecisionID: container.decodeIfPresent(
                PlanningDecisionID.self,
                forKey: .previousDecisionID
            ),
            protectedDeadlineDigest: container.decode(
                String.self,
                forKey: .protectedDeadlineDigest
            ),
            sourceDependencyDigest: container.decode(
                String.self,
                forKey: .sourceDependencyDigest
            ),
            planningEngineVersion: container.decode(
                String.self,
                forKey: .planningEngineVersion
            ),
            confirmedProposalDigest: container.decode(
                String.self,
                forKey: .confirmedProposalDigest
            ),
            decisionID: container.decode(PlanningDecisionID.self, forKey: .decisionID),
            replanEventID: container.decode(ReplanEventID.self, forKey: .replanEventID)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(reasonCode, forKey: .reasonCode)
        try container.encode(requestedEarliestDay, forKey: .requestedEarliestDay)
        try container.encodeIfPresent(remainingMinutes, forKey: .remainingMinutes)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(originDeviceID, forKey: .originDeviceID)
        try container.encode(baseActionDigest, forKey: .baseActionDigest)
        try container.encodeIfPresent(previousDecisionID, forKey: .previousDecisionID)
        try container.encode(protectedDeadlineDigest, forKey: .protectedDeadlineDigest)
        try container.encode(sourceDependencyDigest, forKey: .sourceDependencyDigest)
        try container.encode(planningEngineVersion, forKey: .planningEngineVersion)
        try container.encode(confirmedProposalDigest, forKey: .confirmedProposalDigest)
        try container.encode(decisionID, forKey: .decisionID)
        try container.encode(replanEventID, forKey: .replanEventID)
    }

    func canonicalData() throws -> Data {
        try validateIntrinsic()
        let data = try NextStepBetaActionReplanCanonicalizer.data(self)
        guard data.count <= Self.maximumCanonicalByteCount else {
            throw NextStepBetaActionReplanOperationError.payloadTooLarge(data.count)
        }
        return data
    }

    static func decodeCanonical(
        from data: Data,
        maximumByteCount: Int = Self.maximumCanonicalByteCount
    ) throws -> Self {
        guard maximumByteCount > 0,
              data.isEmpty == false,
              data.count <= maximumByteCount,
              data.count <= Self.maximumCanonicalByteCount else {
            throw NextStepBetaActionReplanOperationError.payloadTooLarge(data.count)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let operation = try decoder.decode(Self.self, from: data)
        guard try operation.canonicalData() == data else {
            throw NextStepBetaActionReplanOperationError.nonCanonicalPayload
        }
        return operation
    }

    static func decisionID(for operationID: OperationID) -> PlanningDecisionID {
        PlanningDecisionID(derivedUUID(operationID: operationID, purpose: "decision"))
    }

    static func replanEventID(for operationID: OperationID) -> ReplanEventID {
        ReplanEventID(derivedUUID(operationID: operationID, purpose: "replan-event"))
    }

    private func validateIntrinsic() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NextStepBetaActionReplanOperationError.unsupportedSchema(schemaVersion)
        }
        guard planningEngineVersion == Self.supportedPlanningEngineVersion else {
            throw NextStepBetaActionReplanOperationError
                .unsupportedPlanningEngineVersion(planningEngineVersion)
        }
        guard PlanningEngine.version == Self.supportedPlanningEngineVersion else {
            throw NextStepBetaActionReplanOperationError
                .unsupportedPlanningEngineVersion(PlanningEngine.version)
        }
        let milliseconds = occurredAt.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds < Double(Int64.max) else {
            throw NextStepBetaActionReplanOperationError.invalidOperation(
                "occurredAt is outside the persistable millisecond range"
            )
        }
        guard operationID.rawValue != Self.zeroUUID,
              actionID.rawValue != Self.zeroUUID,
              originDeviceID.rawValue != Self.zeroUUID else {
            throw NextStepBetaActionReplanOperationError.invalidOperation(
                "stable identifiers must not use the nil UUID"
            )
        }
        guard decisionID == Self.decisionID(for: operationID),
              replanEventID == Self.replanEventID(for: operationID) else {
            throw NextStepBetaActionReplanOperationError.invalidOperation(
                "derived record identifiers do not match the operation identifier"
            )
        }
        let digests = [
            baseActionDigest,
            protectedDeadlineDigest,
            sourceDependencyDigest,
            confirmedProposalDigest
        ]
        guard digests.allSatisfy(Self.isCanonicalSHA256) else {
            throw NextStepBetaActionReplanOperationError.invalidOperation(
                "operation digests must be lowercase SHA-256"
            )
        }
        switch (trigger, reasonCode, remainingMinutes) {
        case (.actionDeferred, .userRequestedDeferral, nil):
            break
        case (.insufficientTime, .insufficientTime, let remaining?):
            guard (0...1_440).contains(remaining) else {
                throw NextStepBetaActionReplanOperationError.invalidOperation(
                    "remaining minutes must be between 0 and 1440"
                )
            }
        default:
            throw NextStepBetaActionReplanOperationError.invalidOperation(
                "trigger, reason code and remaining minutes do not form a supported v1 intent"
            )
        }
    }

    private static func derivedUUID(operationID: OperationID, purpose: String) -> UUID {
        let input = "nextstep.beta.action-replan.v1|\(operationID)|\(purpose)"
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static let zeroUUID =
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

struct NextStepBetaActionReplanPreview: Hashable, Sendable {
    let operationID: OperationID
    let actionID: DailyActionID
    let trigger: ReplanTrigger
    let reasonCode: NextStepBetaActionReplanReasonCode
    let requestedEarliestDay: LocalDay
    let remainingMinutes: Int?
    let occurredAt: Date
    let originDeviceID: DeviceID
    let baseActionDigest: String
    let previousDecisionID: PlanningDecisionID?
    let protectedDeadlineDigest: String
    let sourceDependencyDigest: String
    let planningEngineVersion: String
    let confirmedProposalDigest: String
    let decisionID: PlanningDecisionID
    let replanEventID: ReplanEventID
    let proposal: ReplanProposal
}

enum NextStepBetaActionReplanReplayOutcome: String, Codable, Hashable, Sendable {
    case applied
    case alreadyApplied
}

struct NextStepBetaActionReplanApplicationReceipt: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let operationID: OperationID
    let actionID: DailyActionID
    let trigger: ReplanTrigger
    let reasonCode: NextStepBetaActionReplanReasonCode
    let requestedEarliestDay: LocalDay
    let remainingMinutes: Int?
    let previousDecisionID: PlanningDecisionID?
    let planningEngineVersion: String
    let appliedAt: Date
    let originDeviceID: DeviceID
    let operationSHA256: String
    let baseActionDigest: String
    let protectedDeadlineDigest: String
    let sourceDependencyDigest: String
    let confirmedProposalDigest: String
    let decisionID: PlanningDecisionID
    let replanEventID: ReplanEventID
    let derivedProjectionSHA256: String

    init(
        operation: NextStepBetaActionReplanOperationV1,
        resultArchive: NextStepBetaArchive
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        operationID = operation.operationID
        actionID = operation.actionID
        trigger = operation.trigger
        reasonCode = operation.reasonCode
        requestedEarliestDay = operation.requestedEarliestDay
        remainingMinutes = operation.remainingMinutes
        previousDecisionID = operation.previousDecisionID
        planningEngineVersion = operation.planningEngineVersion
        appliedAt = operation.occurredAt
        originDeviceID = operation.originDeviceID
        operationSHA256 = NextStepBetaActionReplanCanonicalizer.sha256(
            try operation.canonicalData()
        )
        baseActionDigest = operation.baseActionDigest
        protectedDeadlineDigest = operation.protectedDeadlineDigest
        sourceDependencyDigest = operation.sourceDependencyDigest
        confirmedProposalDigest = operation.confirmedProposalDigest
        decisionID = operation.decisionID
        replanEventID = operation.replanEventID
        derivedProjectionSHA256 =
            try NextStepBetaActionReplanCanonicalizer.derivedProjectionDigest(
                operation: operation,
                archive: resultArchive
            )
        try validateIntrinsic()
    }

    func matches(_ operation: NextStepBetaActionReplanOperationV1) -> Bool {
        operationID == operation.operationID
            && actionID == operation.actionID
            && trigger == operation.trigger
            && reasonCode == operation.reasonCode
            && requestedEarliestDay == operation.requestedEarliestDay
            && remainingMinutes == operation.remainingMinutes
            && previousDecisionID == operation.previousDecisionID
            && planningEngineVersion == operation.planningEngineVersion
            && appliedAt == operation.occurredAt
            && originDeviceID == operation.originDeviceID
            && baseActionDigest == operation.baseActionDigest
            && protectedDeadlineDigest == operation.protectedDeadlineDigest
            && sourceDependencyDigest == operation.sourceDependencyDigest
            && confirmedProposalDigest == operation.confirmedProposalDigest
            && decisionID == operation.decisionID
            && replanEventID == operation.replanEventID
    }

    func validate(
        operation: NextStepBetaActionReplanOperationV1,
        in archive: NextStepBetaArchive
    ) throws {
        try validate(in: archive)
        guard matches(operation),
              operationSHA256 == NextStepBetaActionReplanCanonicalizer.sha256(
                  try operation.canonicalData()
              ) else {
            throw NextStepBetaActionReplanOperationError.receiptMismatch
        }
    }

    func validate(in archive: NextStepBetaArchive) throws {
        try validateIntrinsic()
        let actions = archive.workspace.dailyActions.filter {
            $0.metadata.id == actionID
        }
        let decisions = archive.workspace.planningDecisions.filter {
            $0.metadata.id == decisionID
        }
        let events = archive.workspace.replanEvents.filter {
            $0.metadata.id == replanEventID
        }
        let actual = try NextStepBetaActionReplanCanonicalizer.derivedProjectionDigest(
            decisionID: decisionID,
            replanEventID: replanEventID,
            archive: archive
        )
        guard actual == derivedProjectionSHA256,
              actions.count == 1,
              decisions.count == 1,
              events.count == 1,
              let decision = decisions.first,
              let event = events.first,
              decision.engineVersion == planningEngineVersion,
              decision.createdAt == appliedAt,
              decision.metadata.createdAt == appliedAt,
              decision.metadata.originDeviceID == originDeviceID,
              decision.metadata.provenance.kind == .deterministicEngine,
              event.trigger == trigger,
              event.beforeDecisionID == previousDecisionID,
              event.afterDecisionID == decisionID,
              event.resolution == .accepted,
              event.occurredAt == appliedAt,
              event.metadata.createdAt == appliedAt,
              event.metadata.originDeviceID == originDeviceID,
              event.metadata.provenance.kind == .deterministicEngine else {
            throw NextStepBetaActionReplanOperationError.receiptMismatch
        }
    }

    private func validateIntrinsic() throws {
        let milliseconds = appliedAt.timeIntervalSince1970 * 1_000
        guard schemaVersion == Self.currentSchemaVersion,
              planningEngineVersion
                == NextStepBetaActionReplanOperationV1.supportedPlanningEngineVersion,
              milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds < Double(Int64.max),
              operationID.rawValue != Self.zeroUUID,
              actionID.rawValue != Self.zeroUUID,
              originDeviceID.rawValue != Self.zeroUUID,
              decisionID
                == NextStepBetaActionReplanOperationV1.decisionID(for: operationID),
              replanEventID
                == NextStepBetaActionReplanOperationV1.replanEventID(for: operationID),
              [
                  operationSHA256,
                  baseActionDigest,
                  protectedDeadlineDigest,
                  sourceDependencyDigest,
                  confirmedProposalDigest,
                  derivedProjectionSHA256
              ].allSatisfy(NextStepBetaActionReplanCanonicalizer.isCanonicalSHA256) else {
            throw NextStepBetaActionReplanOperationError.receiptMismatch
        }
        switch (trigger, reasonCode, remainingMinutes) {
        case (.actionDeferred, .userRequestedDeferral, nil):
            break
        case (.insufficientTime, .insufficientTime, let remaining?)
            where (0...1_440).contains(remaining):
            break
        default:
            throw NextStepBetaActionReplanOperationError.receiptMismatch
        }
    }

    private static let zeroUUID =
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

struct NextStepBetaActionReplanReplayResult: Sendable {
    let outcome: NextStepBetaActionReplanReplayOutcome
    let archive: NextStepBetaArchive
    let receipt: NextStepBetaActionReplanApplicationReceipt
}

struct NextStepBetaActionReplanAcceptance: Sendable {
    let operation: NextStepBetaActionReplanOperationV1
    let archive: NextStepBetaArchive
    let receipt: NextStepBetaActionReplanApplicationReceipt
}

/// Model-independent prepare/accept boundary. IDs and time are supplied by
/// the caller so preview tests and synchronized replay never touch a clock or
/// random generator.
struct NextStepBetaActionReplanCoordinator: Sendable {
    func prepare(
        operationID: OperationID,
        actionID: DailyActionID,
        trigger: ReplanTrigger,
        reasonCode: NextStepBetaActionReplanReasonCode,
        requestedEarliestDay: LocalDay,
        remainingMinutes: Int? = nil,
        in archive: NextStepBetaArchive,
        occurredAt: Date
    ) throws -> NextStepBetaActionReplanPreview {
        try archive.validate()
        guard let action = archive.workspace.dailyActions.first(where: {
            $0.metadata.id == actionID
        }) else {
            throw NextStepBetaActionReplanOperationError.actionNotFound(actionID)
        }
        let decisionID = NextStepBetaActionReplanOperationV1.decisionID(for: operationID)
        let eventID = NextStepBetaActionReplanOperationV1.replanEventID(for: operationID)
        let baseActionDigest = try NextStepBetaActionReplanCanonicalizer.actionDigest(action)
        let deadlineDigest =
            try NextStepBetaActionReplanCanonicalizer.protectedDeadlineDigest(
                workspace: archive.workspace
            )
        let sourceDigest = try NextStepBetaActionReplanCanonicalizer.sourceDependencyDigest(
            action: action,
            workspace: archive.workspace
        )
        let proposal = try NextStepBetaActionReplanOperationReducer.makeProposal(
            actionID: actionID,
            trigger: trigger,
            reasonCode: reasonCode,
            requestedEarliestDay: requestedEarliestDay,
            remainingMinutes: remainingMinutes,
            occurredAt: occurredAt,
            originDeviceID: archive.deviceID,
            decisionID: decisionID,
            previousDecision: archive.currentDecision,
            in: archive.workspace
        )
        let proposalDigest =
            try NextStepBetaActionReplanCanonicalizer.confirmedProposalDigest(proposal)
        let preview = NextStepBetaActionReplanPreview(
            operationID: operationID,
            actionID: actionID,
            trigger: trigger,
            reasonCode: reasonCode,
            requestedEarliestDay: requestedEarliestDay,
            remainingMinutes: remainingMinutes,
            occurredAt: occurredAt,
            originDeviceID: archive.deviceID,
            baseActionDigest: baseActionDigest,
            previousDecisionID: archive.currentDecision?.metadata.id,
            protectedDeadlineDigest: deadlineDigest,
            sourceDependencyDigest: sourceDigest,
            planningEngineVersion:
                NextStepBetaActionReplanOperationV1.supportedPlanningEngineVersion,
            confirmedProposalDigest: proposalDigest,
            decisionID: decisionID,
            replanEventID: eventID,
            proposal: proposal
        )
        _ = try operation(from: preview)
        return preview
    }

    func cancel(
        _ preview: NextStepBetaActionReplanPreview,
        in archive: NextStepBetaArchive
    ) -> NextStepBetaArchive {
        _ = preview
        return archive
    }

    func accept(
        _ preview: NextStepBetaActionReplanPreview,
        in archive: NextStepBetaArchive
    ) throws -> NextStepBetaActionReplanAcceptance {
        guard try NextStepBetaActionReplanCanonicalizer
            .confirmedProposalDigest(preview.proposal) == preview.confirmedProposalDigest else {
            throw NextStepBetaActionReplanOperationError.previewContextChanged
        }
        let acceptedOperation = try operation(from: preview)
        let replay = try NextStepBetaActionReplanOperationReducer().replay(
            acceptedOperation,
            in: archive
        )
        return NextStepBetaActionReplanAcceptance(
            operation: acceptedOperation,
            archive: replay.archive,
            receipt: replay.receipt
        )
    }

    private func operation(
        from preview: NextStepBetaActionReplanPreview
    ) throws -> NextStepBetaActionReplanOperationV1 {
        try NextStepBetaActionReplanOperationV1(
            operationID: preview.operationID,
            actionID: preview.actionID,
            trigger: preview.trigger,
            reasonCode: preview.reasonCode,
            requestedEarliestDay: preview.requestedEarliestDay,
            remainingMinutes: preview.remainingMinutes,
            occurredAt: preview.occurredAt,
            originDeviceID: preview.originDeviceID,
            baseActionDigest: preview.baseActionDigest,
            previousDecisionID: preview.previousDecisionID,
            protectedDeadlineDigest: preview.protectedDeadlineDigest,
            sourceDependencyDigest: preview.sourceDependencyDigest,
            planningEngineVersion: preview.planningEngineVersion,
            confirmedProposalDigest: preview.confirmedProposalDigest,
            decisionID: preview.decisionID,
            replanEventID: preview.replanEventID
        )
    }
}

/// Pure reducer: it has no disk, transport, clock or random-ID access.
struct NextStepBetaActionReplanOperationReducer: Sendable {
    func replay(
        _ operation: NextStepBetaActionReplanOperationV1,
        in archive: NextStepBetaArchive
    ) throws -> NextStepBetaActionReplanReplayResult {
        try archive.validate()
        _ = try operation.canonicalData()
        guard PlanningEngine.version == operation.planningEngineVersion else {
            throw NextStepBetaActionReplanOperationError
                .unsupportedPlanningEngineVersion(operation.planningEngineVersion)
        }

        let decisions = archive.workspace.planningDecisions.filter {
            $0.metadata.id == operation.decisionID
        }
        let events = archive.workspace.replanEvents.filter {
            $0.metadata.id == operation.replanEventID
        }
        if decisions.isEmpty == false || events.isEmpty == false {
            guard decisions.count == 1, events.count == 1 else {
                if decisions.count != 1 {
                    throw NextStepBetaActionReplanOperationError.derivedRecordConflict(
                        kind: .planningDecision,
                        id: operation.decisionID.rawValue
                    )
                }
                throw NextStepBetaActionReplanOperationError.derivedRecordConflict(
                    kind: .replanEvent,
                    id: operation.replanEventID.rawValue
                )
            }
            guard try isExactAppliedOperation(operation, in: archive) else {
                throw NextStepBetaActionReplanOperationError.derivedRecordConflict(
                    kind: .replanEvent,
                    id: operation.replanEventID.rawValue
                )
            }
            let receipts = archive.actionReplanApplicationReceipts.filter {
                $0.operationID == operation.operationID
            }
            guard receipts.count == 1, let receipt = receipts.first else {
                throw NextStepBetaActionReplanOperationError.receiptMismatch
            }
            try receipt.validate(operation: operation, in: archive)
            return NextStepBetaActionReplanReplayResult(
                outcome: .alreadyApplied,
                archive: archive,
                receipt: receipt
            )
        }

        guard let action = archive.workspace.dailyActions.first(where: {
            $0.metadata.id == operation.actionID
        }) else {
            throw NextStepBetaActionReplanOperationError.actionNotFound(operation.actionID)
        }
        guard action.metadata.deletedAt == nil,
              action.status != .completed,
              action.status != .cancelled,
              action.flexibility != .locked else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                .actionNoLongerEligible
            )
        }
        let actualDeadline =
            try NextStepBetaActionReplanCanonicalizer.protectedDeadlineDigest(
                workspace: archive.workspace
            )
        guard actualDeadline == operation.protectedDeadlineDigest else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                .protectedDeadlineChanged
            )
        }
        let actualSource =
            try NextStepBetaActionReplanCanonicalizer.sourceDependencyDigest(
                action: action,
                workspace: archive.workspace
            )
        guard actualSource == operation.sourceDependencyDigest else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                .sourceDependencyChanged
            )
        }
        let actualAction = try NextStepBetaActionReplanCanonicalizer.actionDigest(action)
        guard actualAction == operation.baseActionDigest else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(.actionChanged)
        }
        guard archive.currentDecision?.metadata.id == operation.previousDecisionID else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                .planningContextChanged
            )
        }
        let localDay = try LocalDay(
            date: operation.occurredAt,
            timeZoneIdentifier: archive.workspace.userProfile.timeZoneIdentifier
        )
        guard operation.requestedEarliestDay == (try localDay.adding(days: 1)),
              operation.occurredAt >= action.metadata.createdAt else {
            throw NextStepBetaActionReplanOperationError.invalidOperation(
                "a v1 deferral must target the next local day after the action was created"
            )
        }

        let proposal = try Self.makeProposal(
            actionID: operation.actionID,
            trigger: operation.trigger,
            reasonCode: operation.reasonCode,
            requestedEarliestDay: operation.requestedEarliestDay,
            remainingMinutes: operation.remainingMinutes,
            occurredAt: operation.occurredAt,
            originDeviceID: operation.originDeviceID,
            decisionID: operation.decisionID,
            previousDecision: archive.currentDecision,
            in: archive.workspace
        )
        let actualProposal =
            try NextStepBetaActionReplanCanonicalizer.confirmedProposalDigest(proposal)
        guard actualProposal == operation.confirmedProposalDigest else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(.proposalChanged)
        }

        var result = archive
        do {
            var mutated = try Self.mutatedWorkspace(
                actionID: operation.actionID,
                trigger: operation.trigger,
                reasonCode: operation.reasonCode,
                requestedEarliestDay: operation.requestedEarliestDay,
                remainingMinutes: operation.remainingMinutes,
                occurredAt: operation.occurredAt,
                in: result.workspace
            )
            mutated = try ExecutionService().acceptReplan(
                proposal,
                in: mutated,
                eventID: operation.replanEventID,
                originDeviceID: operation.originDeviceID,
                at: operation.occurredAt
            )
            result.workspace = mutated
            result.currentDecisionID = operation.decisionID
            try result.validate()
        } catch let error as NextStepBetaActionReplanOperationError {
            throw error
        } catch {
            throw NextStepBetaActionReplanOperationError.proposalRejected(
                error.localizedDescription
            )
        }

        guard try isExactAppliedOperation(operation, in: result) else {
            throw NextStepBetaActionReplanOperationError.proposalRejected(
                "the accepted projection does not reproduce the immutable operation"
            )
        }
        let receipt = try NextStepBetaActionReplanApplicationReceipt(
            operation: operation,
            resultArchive: result
        )
        result.actionReplanApplicationReceipts.append(receipt)
        result.actionReplanApplicationReceipts.sort {
            $0.operationID < $1.operationID
        }
        try result.validate()
        try receipt.validate(operation: operation, in: result)
        return NextStepBetaActionReplanReplayResult(
            outcome: .applied,
            archive: result,
            receipt: receipt
        )
    }

    static func makeProposal(
        actionID: DailyActionID,
        trigger: ReplanTrigger,
        reasonCode: NextStepBetaActionReplanReasonCode,
        requestedEarliestDay: LocalDay,
        remainingMinutes: Int?,
        occurredAt: Date,
        originDeviceID: DeviceID,
        decisionID: PlanningDecisionID,
        previousDecision: PlanningDecision?,
        in workspace: NextStepWorkspaceSnapshot
    ) throws -> ReplanProposal {
        let mutated = try mutatedWorkspace(
            actionID: actionID,
            trigger: trigger,
            reasonCode: reasonCode,
            requestedEarliestDay: requestedEarliestDay,
            remainingMinutes: remainingMinutes,
            occurredAt: occurredAt,
            in: workspace
        )
        let today = try LocalDay(
            date: occurredAt,
            timeZoneIdentifier: mutated.userProfile.timeZoneIdentifier
        )
        let input = try PlanningInput(
            snapshot: mutated,
            horizonStart: today,
            horizonEnd: try today.adding(days: 30),
            dailyCapacityOverrides: remainingMinutes.map { [today: $0] } ?? [:],
            createdAt: occurredAt
        )
        do {
            return try PlanningEngine().replan(
                input,
                previous: previousDecision,
                trigger: trigger,
                decisionID: decisionID,
                originDeviceID: originDeviceID
            )
        } catch {
            throw NextStepBetaActionReplanOperationError.proposalRejected(
                error.localizedDescription
            )
        }
    }

    static func mutatedWorkspace(
        actionID: DailyActionID,
        trigger: ReplanTrigger,
        reasonCode: NextStepBetaActionReplanReasonCode,
        requestedEarliestDay: LocalDay,
        remainingMinutes: Int?,
        occurredAt: Date,
        in workspace: NextStepWorkspaceSnapshot
    ) throws -> NextStepWorkspaceSnapshot {
        switch (trigger, reasonCode, remainingMinutes) {
        case (.actionDeferred, .userRequestedDeferral, nil):
            break
        case (.insufficientTime, .insufficientTime, let remaining?)
            where (0...1_440).contains(remaining):
            break
        default:
            throw NextStepBetaActionReplanOperationError.invalidOperation(
                "unsupported v1 action mutation intent"
            )
        }
        guard let original = workspace.dailyActions.first(where: {
            $0.metadata.id == actionID
        }) else {
            throw NextStepBetaActionReplanOperationError.actionNotFound(actionID)
        }
        guard original.metadata.deletedAt == nil,
              original.status != .completed,
              original.status != .cancelled,
              original.flexibility != .locked else {
            throw NextStepBetaActionReplanOperationError.actionNotEligible(actionID)
        }
        let localDay = try LocalDay(
            date: occurredAt,
            timeZoneIdentifier: workspace.userProfile.timeZoneIdentifier
        )
        guard requestedEarliestDay == (try localDay.adding(days: 1)),
              occurredAt >= original.metadata.createdAt else {
            throw NextStepBetaActionReplanOperationError.invalidOperation(
                "a v1 deferral must target the next local day after the action was created"
            )
        }

        var result: NextStepWorkspaceSnapshot
        do {
            result = try ExecutionService().deferAction(
                actionID,
                in: workspace,
                at: occurredAt
            )
        } catch {
            throw NextStepBetaActionReplanOperationError.actionNotEligible(actionID)
        }
        guard let index = result.dailyActions.firstIndex(where: {
            $0.metadata.id == actionID
        }) else {
            throw NextStepBetaActionReplanOperationError.actionNotFound(actionID)
        }
        result.dailyActions[index].earliestDay = requestedEarliestDay
        try result.validateRelationships()
        return result
    }

    private func isExactAppliedOperation(
        _ operation: NextStepBetaActionReplanOperationV1,
        in archive: NextStepBetaArchive
    ) throws -> Bool {
        let decisions = archive.workspace.planningDecisions.filter {
            $0.metadata.id == operation.decisionID
        }
        let events = archive.workspace.replanEvents.filter {
            $0.metadata.id == operation.replanEventID
        }
        guard decisions.count == 1,
              events.count == 1,
              let decision = decisions.first,
              let event = events.first,
              decision.engineVersion == operation.planningEngineVersion,
              decision.createdAt == operation.occurredAt,
              decision.metadata.createdAt == operation.occurredAt,
              decision.metadata.originDeviceID == operation.originDeviceID,
              decision.metadata.provenance.kind == .deterministicEngine,
              event.trigger == operation.trigger,
              event.beforeDecisionID == operation.previousDecisionID,
              event.afterDecisionID == operation.decisionID,
              event.resolution == .accepted,
              event.occurredAt == operation.occurredAt,
              event.metadata.createdAt == operation.occurredAt,
              event.metadata.originDeviceID == operation.originDeviceID,
              event.metadata.provenance.kind == .deterministicEngine else {
            return false
        }
        return true
    }
}

private enum NextStepBetaActionReplanCanonicalizer {
    static func data<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func digest<Value: Encodable>(_ value: Value) throws -> String {
        sha256(try data(value))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    static func actionDigest(_ original: DailyAction) throws -> String {
        let provenance = Provenance(
            kind: original.metadata.provenance.kind,
            actorIdentifier: original.metadata.provenance.actorIdentifier,
            sourceDocumentIDs: original.metadata.provenance.sourceDocumentIDs.sorted(),
            softwareVersion: original.metadata.provenance.softwareVersion
        )
        let metadata = try RecordMetadata(
            id: original.metadata.id,
            schemaVersion: original.metadata.schemaVersion,
            revision: original.metadata.revision,
            createdAt: original.metadata.createdAt,
            updatedAt: original.metadata.updatedAt,
            deletedAt: original.metadata.deletedAt,
            originDeviceID: original.metadata.originDeviceID,
            lastOperationID: original.metadata.lastOperationID,
            provenance: provenance
        )
        let deadline = try original.deadline.map { value in
            try canonicalDeadline(value)
        }
        let action = try DailyAction(
            metadata: metadata,
            milestoneID: original.milestoneID,
            relatedGoalIDs: original.relatedGoalIDs.sorted(),
            title: original.title,
            whyToday: original.whyToday,
            estimatedMinutes: original.estimatedMinutes,
            difficulty: original.difficulty,
            priority: original.priority,
            earliestDay: original.earliestDay,
            deadline: deadline,
            scheduledDay: original.scheduledDay,
            flexibility: original.flexibility,
            dependencyActionIDs: original.dependencyActionIDs.sorted(),
            reasonCodes: original.reasonCodes.sorted { $0.rawValue < $1.rawValue },
            requiredOutput: original.requiredOutput,
            completionCriteria: original.completionCriteria.sorted {
                $0.id.uuidString < $1.id.uuidString
            },
            packageID: original.packageID,
            sourceDocumentIDs: original.sourceDocumentIDs.sorted(),
            status: original.status,
            completedAt: original.completedAt
        )
        return try digest(ActionEnvelopeV1(schemaVersion: 1, action: action))
    }

    static func protectedDeadlineDigest(
        workspace: NextStepWorkspaceSnapshot
    ) throws -> String {
        var entries: [ProtectedDeadlineEntryV1] = []
        entries.append(contentsOf: try workspace.ultimateGoals.compactMap { goal in
            guard let deadline = goal.targetDay, deadline.mutability != .flexible else {
                return nil
            }
            return ProtectedDeadlineEntryV1(
                ownerType: "UltimateGoal",
                ownerID: goal.metadata.id.description,
                deadline: try canonicalDeadline(deadline)
            )
        })
        entries.append(contentsOf: try workspace.goals.compactMap { goal in
            guard let deadline = goal.targetDay, deadline.mutability != .flexible else {
                return nil
            }
            return ProtectedDeadlineEntryV1(
                ownerType: "Goal",
                ownerID: goal.metadata.id.description,
                deadline: try canonicalDeadline(deadline)
            )
        })
        entries.append(contentsOf: try workspace.milestones.compactMap { milestone in
            guard let deadline = milestone.targetDay, deadline.mutability != .flexible else {
                return nil
            }
            return ProtectedDeadlineEntryV1(
                ownerType: "Milestone",
                ownerID: milestone.metadata.id.description,
                deadline: try canonicalDeadline(deadline)
            )
        })
        entries.append(contentsOf: try workspace.dailyActions.compactMap { action in
            guard let deadline = action.deadline, deadline.mutability != .flexible else {
                return nil
            }
            return ProtectedDeadlineEntryV1(
                ownerType: "DailyAction",
                ownerID: action.metadata.id.description,
                deadline: try canonicalDeadline(deadline)
            )
        })
        entries.sort {
            if $0.ownerType != $1.ownerType { return $0.ownerType < $1.ownerType }
            return $0.ownerID < $1.ownerID
        }
        return try digest(ProtectedDeadlineEnvelopeV1(
            schemaVersion: 1,
            entries: entries
        ))
    }

    private static func canonicalDeadline(
        _ deadline: FactValue<LocalDay>
    ) throws -> FactValue<LocalDay> {
        try FactValue(
            value: deadline.value,
            authority: deadline.authority,
            mutability: deadline.mutability,
            evidenceLinkIDs: deadline.evidenceLinkIDs.sorted(),
            confidence: deadline.confidence,
            confirmedAt: deadline.confirmedAt
        )
    }

    static func sourceDependencyDigest(
        action: DailyAction,
        workspace: NextStepWorkspaceSnapshot
    ) throws -> String {
        let sourceIDs = action.sourceDocumentIDs.sorted()
        guard Set(sourceIDs).count == sourceIDs.count else {
            throw NextStepBetaActionReplanOperationError.invalidOperation(
                "source dependencies must be unique"
            )
        }
        let matching = workspace.sourceDocuments.filter {
            Set(sourceIDs).contains($0.metadata.id)
        }
        guard matching.count == sourceIDs.count,
              matching.allSatisfy({ $0.metadata.deletedAt == nil }) else {
            throw NextStepBetaActionReplanOperationError.contextRequiresReview(
                .sourceDependencyChanged
            )
        }
        let records = matching.map(ProtectedSourceDocumentV1.init).sorted {
            $0.id < $1.id
        }
        return try digest(SourceDependencyEnvelopeV1(
            schemaVersion: 1,
            actionID: action.metadata.id,
            sourceDocumentIDs: sourceIDs,
            documents: records
        ))
    }

    /// This digest represents what the user reviewed. The planner's complete
    /// input SHA is deliberately omitted: an unrelated workspace revision may
    /// change that audit hash while leaving every visible plan change intact.
    static func confirmedProposalDigest(_ proposal: ReplanProposal) throws -> String {
        try digest(ConfirmedProposalEnvelopeV1(
            schemaVersion: 1,
            trigger: proposal.trigger,
            previousDecisionID: proposal.previousDecisionID,
            decisionID: proposal.proposedDecision.metadata.id,
            engineVersion: proposal.proposedDecision.engineVersion,
            horizonStart: proposal.proposedDecision.horizonStart,
            horizonEnd: proposal.proposedDecision.horizonEnd,
            assignments: proposal.proposedDecision.assignments,
            rejectedActions: proposal.proposedDecision.rejectedActions,
            risks: proposal.proposedDecision.risks,
            changes: proposal.changes,
            protectedFactDescriptions: proposal.protectedFactDescriptions.sorted(),
            createdAt: proposal.createdAt
        ))
    }

    static func derivedProjectionDigest(
        operation: NextStepBetaActionReplanOperationV1,
        archive: NextStepBetaArchive
    ) throws -> String {
        try derivedProjectionDigest(
            decisionID: operation.decisionID,
            replanEventID: operation.replanEventID,
            archive: archive
        )
    }

    static func derivedProjectionDigest(
        decisionID: PlanningDecisionID,
        replanEventID: ReplanEventID,
        archive: NextStepBetaArchive
    ) throws -> String {
        let decisions = archive.workspace.planningDecisions.filter {
            $0.metadata.id == decisionID
        }
        let events = archive.workspace.replanEvents.filter {
            $0.metadata.id == replanEventID
        }
        guard decisions.count == 1,
              events.count == 1,
              let decision = decisions.first,
              let event = events.first else {
            throw NextStepBetaActionReplanOperationError.receiptMismatch
        }
        return try digest(DerivedProjectionEnvelopeV1(
            schemaVersion: 1,
            planningDecision: decision,
            replanEvent: event
        ))
    }

    private struct ActionEnvelopeV1: Encodable {
        let schemaVersion: Int
        let action: DailyAction
    }

    private struct ProtectedDeadlineEnvelopeV1: Encodable {
        let schemaVersion: Int
        let entries: [ProtectedDeadlineEntryV1]
    }

    private struct ProtectedDeadlineEntryV1: Encodable {
        let ownerType: String
        let ownerID: String
        let deadline: FactValue<LocalDay>
    }

    private struct SourceDependencyEnvelopeV1: Encodable {
        let schemaVersion: Int
        let actionID: DailyActionID
        let sourceDocumentIDs: [SourceDocumentID]
        let documents: [ProtectedSourceDocumentV1]
    }

    private struct ProtectedSourceDocumentV1: Encodable {
        let id: SourceDocumentID
        let revision: Int64
        let deletedAt: Date?
        let type: SourceDocumentType
        let contentSHA256: String?
        let rightsState: SourceRightsState
        let accessState: SourceAccessState
        let canonicalURL: URL?
        let parserVersion: String?
        let publishedAt: Date?
        let verificationState: SourceVerificationState

        init(_ document: SourceDocument) {
            id = document.metadata.id
            revision = document.metadata.revision
            deletedAt = document.metadata.deletedAt
            type = document.type
            contentSHA256 = document.contentSHA256
            rightsState = document.rightsState
            accessState = document.accessState
            canonicalURL = document.canonicalURL
            parserVersion = document.parserVersion
            publishedAt = document.publishedAt
            verificationState = document.verificationState
        }
    }

    private struct ConfirmedProposalEnvelopeV1: Encodable {
        let schemaVersion: Int
        let trigger: ReplanTrigger
        let previousDecisionID: PlanningDecisionID?
        let decisionID: PlanningDecisionID
        let engineVersion: String
        let horizonStart: LocalDay
        let horizonEnd: LocalDay
        let assignments: [ScheduledAction]
        let rejectedActions: [RejectedAction]
        let risks: [PlanningRisk]
        let changes: [PlanChange]
        let protectedFactDescriptions: [String]
        let createdAt: Date
    }

    private struct DerivedProjectionEnvelopeV1: Encodable {
        let schemaVersion: Int
        let planningDecision: PlanningDecision
        let replanEvent: ReplanEvent
    }
}
