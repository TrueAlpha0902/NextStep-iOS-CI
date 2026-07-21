import CryptoKit
import Foundation
import NextStepDomain
import NextStepPlanning

enum NextStepBetaCompletionOperationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema(Int)
    case unsupportedPlanningEngineVersion(String)
    case unexpectedPayloadKind(String)
    case payloadTooLarge(Int)
    case nonCanonicalPayload
    case invalidOperation(String)
    case actionNotFound(DailyActionID)
    case packageNotFound(GuidedLearningPackageID)
    case quizBackedPackageRequired(GuidedLearningPackageID)
    case attestationOnlyPackageRequired(GuidedLearningPackageID)
    case actionPackageMismatch
    case completionContractMismatch(expected: String, actual: String)
    case conflictingActionCompletion(DailyActionID)
    case conflictingUserResponse(UserResponseID)
    case conflictingCompletionEvidence(CompletionEvidenceID)
    case derivedRecordConflict(kind: NextStepBetaCompletionDerivedRecordKind, id: UUID)
    case derivedRecordContractMismatch
    case missingApplicationReceipt(OperationID)
    case conflictingApplicationReceipt(OperationID)
    case derivedRecordsMismatch
    case completionRejected(String)
    case replanningRejected(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported guided-action completion schema \(version)."
        case let .unsupportedPlanningEngineVersion(version):
            "Unsupported guided-action completion planning engine \(version)."
        case let .unexpectedPayloadKind(kind):
            "Unexpected guided-action completion payload kind \(kind)."
        case let .payloadTooLarge(byteCount):
            "The guided-action completion payload is too large (\(byteCount) bytes)."
        case .nonCanonicalPayload:
            "The guided-action completion payload is not canonical."
        case let .invalidOperation(reason):
            "The guided-action completion operation is invalid: \(reason)"
        case let .actionNotFound(id):
            "The guided action \(id) was not found."
        case let .packageNotFound(id):
            "The guided package \(id) was not found."
        case let .quizBackedPackageRequired(id):
            "Guided package \(id) is not backed by the deterministic grounded quiz required by this operation version."
        case let .attestationOnlyPackageRequired(id):
            "Guided package \(id) does not use the explicit user-attestation-only completion contract required by this operation version."
        case .actionPackageMismatch:
            "The guided action and package do not describe the same completion contract."
        case let .completionContractMismatch(expected, actual):
            "The completion contract digest differs (expected \(expected), received \(actual))."
        case let .conflictingActionCompletion(id):
            "The guided action \(id) was completed by a different payload or evidence set."
        case let .conflictingUserResponse(id):
            "User response \(id) already exists with different content."
        case let .conflictingCompletionEvidence(id):
            "Completion evidence \(id) already exists with different content."
        case let .derivedRecordConflict(kind, id):
            "The derived \(kind.rawValue) identifier \(id.uuidString.lowercased()) is already in use."
        case .derivedRecordContractMismatch:
            "The deterministic projection identifiers or causal metadata differ from the immutable operation."
        case let .missingApplicationReceipt(id):
            "The completed operation \(id) has no context-specific application receipt."
        case let .conflictingApplicationReceipt(id):
            "The completed operation \(id) has conflicting application receipts."
        case .derivedRecordsMismatch:
            "The saved progress, planning decision or replan event differs from its application receipt."
        case let .completionRejected(message):
            "The completion contract rejected the operation: \(message)"
        case let .replanningRejected(message):
            "Deterministic replanning rejected the operation: \(message)"
        }
    }
}

enum NextStepBetaCompletionDerivedRecordKind: String, Codable, Hashable, Sendable {
    case progressSnapshot
    case planningDecision
    case replanEvent
}

enum NextStepBetaCompletionReplayOutcome: String, Codable, Hashable, Sendable {
    case applied
    case alreadyApplied
}

struct NextStepBetaCompletionReplayResult: Sendable {
    let outcome: NextStepBetaCompletionReplayOutcome
    let archive: NextStepBetaArchive
}

/// Immutable operation payload for the first Guided Action completion sync
/// slice. The payload carries the user records needed to replay strict quiz
/// evidence instead of trusting a free-text score or a remote completed flag.
private struct NextStepBetaGuidedActionQuizCompletionOperationV1: Codable, Hashable, Sendable {
    static let payloadKind = "nextstep.beta.guided-action-completion"
    static let currentSchemaVersion = 1
    static let supportedPlanningEngineVersion = "nextstep-deterministic-v1"
    static let maximumCanonicalByteCount = 1_048_576

    let kind: String
    let schemaVersion: Int
    let planningEngineVersion: String
    let operationID: OperationID
    let actionID: DailyActionID
    let packageID: GuidedLearningPackageID
    let packageVersion: Int
    let completionContractSHA256: String
    let completedAt: Date
    let originDeviceID: DeviceID
    let referencedUserResponses: [UserResponse]
    let quizEvidence: CompletionEvidence
    let userAttestation: CompletionEvidence
    let progressSnapshotID: ProgressSnapshotID
    let planningDecisionID: PlanningDecisionID
    let replanEventID: ReplanEventID
    /// Binds only base-invariant projection identity and causality. Progress
    /// fractions and planning output are intentionally excluded because they
    /// are recalculated against each receiving device's current archive.
    let derivedRecordContractSHA256: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion
        case planningEngineVersion
        case operationID
        case actionID
        case packageID
        case packageVersion
        case completionContractSHA256
        case completedAt
        case originDeviceID
        case referencedUserResponses
        case quizEvidence
        case userAttestation
        case progressSnapshotID
        case planningDecisionID
        case replanEventID
        case derivedRecordContractSHA256
    }

    init(
        operationID: OperationID,
        action: DailyAction,
        package: GuidedLearningPackage,
        completedAt: Date,
        originDeviceID: DeviceID,
        referencedUserResponses: [UserResponse],
        quizEvidence: CompletionEvidence,
        userAttestation: CompletionEvidence
    ) throws {
        let contractDigest = try Self.contractSHA256(action: action, package: package)
        guard PlanningEngine.version == Self.supportedPlanningEngineVersion else {
            throw NextStepBetaCompletionOperationError.unsupportedPlanningEngineVersion(
                PlanningEngine.version
            )
        }
        let progressSnapshotID = Self.progressSnapshotID(for: operationID)
        let planningDecisionID = Self.planningDecisionID(for: operationID)
        let replanEventID = Self.replanEventID(for: operationID)
        let derivedContractDigest = try Self.derivedRecordContractSHA256(
            planningEngineVersion: Self.supportedPlanningEngineVersion,
            operationID: operationID,
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            completedAt: completedAt,
            originDeviceID: originDeviceID,
            progressSnapshotID: progressSnapshotID,
            planningDecisionID: planningDecisionID,
            replanEventID: replanEventID
        )
        try self.init(
            kind: Self.payloadKind,
            schemaVersion: Self.currentSchemaVersion,
            planningEngineVersion: Self.supportedPlanningEngineVersion,
            operationID: operationID,
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            completionContractSHA256: contractDigest,
            completedAt: completedAt,
            originDeviceID: originDeviceID,
            referencedUserResponses: referencedUserResponses.sorted {
                $0.metadata.id < $1.metadata.id
            },
            quizEvidence: quizEvidence,
            userAttestation: userAttestation,
            progressSnapshotID: progressSnapshotID,
            planningDecisionID: planningDecisionID,
            replanEventID: replanEventID,
            derivedRecordContractSHA256: derivedContractDigest,
            requireCanonicalResponseOrder: true
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(String.self, forKey: .kind),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            planningEngineVersion: container.decode(
                String.self,
                forKey: .planningEngineVersion
            ),
            operationID: container.decode(OperationID.self, forKey: .operationID),
            actionID: container.decode(DailyActionID.self, forKey: .actionID),
            packageID: container.decode(GuidedLearningPackageID.self, forKey: .packageID),
            packageVersion: container.decode(Int.self, forKey: .packageVersion),
            completionContractSHA256: container.decode(
                String.self,
                forKey: .completionContractSHA256
            ),
            completedAt: container.decode(Date.self, forKey: .completedAt),
            originDeviceID: container.decode(DeviceID.self, forKey: .originDeviceID),
            referencedUserResponses: container.decode(
                [UserResponse].self,
                forKey: .referencedUserResponses
            ),
            quizEvidence: container.decode(CompletionEvidence.self, forKey: .quizEvidence),
            userAttestation: container.decode(
                CompletionEvidence.self,
                forKey: .userAttestation
            ),
            progressSnapshotID: container.decode(
                ProgressSnapshotID.self,
                forKey: .progressSnapshotID
            ),
            planningDecisionID: container.decode(
                PlanningDecisionID.self,
                forKey: .planningDecisionID
            ),
            replanEventID: container.decode(ReplanEventID.self, forKey: .replanEventID),
            derivedRecordContractSHA256: container.decode(
                String.self,
                forKey: .derivedRecordContractSHA256
            ),
            requireCanonicalResponseOrder: true
        )
    }

    func encode(to encoder: Encoder) throws {
        try validateIntrinsic()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(planningEngineVersion, forKey: .planningEngineVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(packageVersion, forKey: .packageVersion)
        try container.encode(completionContractSHA256, forKey: .completionContractSHA256)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(originDeviceID, forKey: .originDeviceID)
        try container.encode(referencedUserResponses, forKey: .referencedUserResponses)
        try container.encode(quizEvidence, forKey: .quizEvidence)
        try container.encode(userAttestation, forKey: .userAttestation)
        try container.encode(progressSnapshotID, forKey: .progressSnapshotID)
        try container.encode(planningDecisionID, forKey: .planningDecisionID)
        try container.encode(replanEventID, forKey: .replanEventID)
        try container.encode(
            derivedRecordContractSHA256,
            forKey: .derivedRecordContractSHA256
        )
    }

    func canonicalData() throws -> Data {
        try validateIntrinsic()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumCanonicalByteCount else {
            throw NextStepBetaCompletionOperationError.payloadTooLarge(data.count)
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
            throw NextStepBetaCompletionOperationError.payloadTooLarge(data.count)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let operation = try decoder.decode(Self.self, from: data)
        guard try operation.canonicalData() == data else {
            throw NextStepBetaCompletionOperationError.nonCanonicalPayload
        }
        return operation
    }

    static func contractSHA256(
        action: DailyAction,
        package: GuidedLearningPackage
    ) throws -> String {
        guard action.packageID == package.metadata.id,
              package.dailyActionID == action.metadata.id,
              package.version >= 1,
              action.requiredOutput == package.requiredOutput,
              action.completionCriteria == package.completionCriteria else {
            throw NextStepBetaCompletionOperationError.actionPackageMismatch
        }
        guard let quiz = package.quiz,
              quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1 else {
            throw NextStepBetaCompletionOperationError.quizBackedPackageRequired(
                package.metadata.id
            )
        }
        let contract = CompletionContractV1(
            schemaVersion: 1,
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            requiredOutput: action.requiredOutput,
            completionCriteria: action.completionCriteria.sorted {
                $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            },
            quiz: quiz
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(contract)
        return Self.sha256(data)
    }

    private init(
        kind: String,
        schemaVersion: Int,
        planningEngineVersion: String,
        operationID: OperationID,
        actionID: DailyActionID,
        packageID: GuidedLearningPackageID,
        packageVersion: Int,
        completionContractSHA256: String,
        completedAt: Date,
        originDeviceID: DeviceID,
        referencedUserResponses: [UserResponse],
        quizEvidence: CompletionEvidence,
        userAttestation: CompletionEvidence,
        progressSnapshotID: ProgressSnapshotID,
        planningDecisionID: PlanningDecisionID,
        replanEventID: ReplanEventID,
        derivedRecordContractSHA256: String,
        requireCanonicalResponseOrder: Bool
    ) throws {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.planningEngineVersion = planningEngineVersion
        self.operationID = operationID
        self.actionID = actionID
        self.packageID = packageID
        self.packageVersion = packageVersion
        self.completionContractSHA256 = completionContractSHA256
        self.completedAt = completedAt
        self.originDeviceID = originDeviceID
        self.referencedUserResponses = referencedUserResponses
        self.quizEvidence = quizEvidence
        self.userAttestation = userAttestation
        self.progressSnapshotID = progressSnapshotID
        self.planningDecisionID = planningDecisionID
        self.replanEventID = replanEventID
        self.derivedRecordContractSHA256 = derivedRecordContractSHA256

        if requireCanonicalResponseOrder {
            let sorted = referencedUserResponses.sorted { $0.metadata.id < $1.metadata.id }
            guard sorted == referencedUserResponses else {
                throw NextStepBetaCompletionOperationError.invalidOperation(
                    "referenced user responses are not in canonical identifier order"
                )
            }
        }
        try validateIntrinsic()
    }

    private func validateIntrinsic() throws {
        guard kind == Self.payloadKind else {
            throw NextStepBetaCompletionOperationError.unexpectedPayloadKind(kind)
        }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NextStepBetaCompletionOperationError.unsupportedSchema(schemaVersion)
        }
        guard planningEngineVersion == Self.supportedPlanningEngineVersion else {
            throw NextStepBetaCompletionOperationError.unsupportedPlanningEngineVersion(
                planningEngineVersion
            )
        }
        guard packageVersion >= 1 else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "package version must be positive"
            )
        }
        let completedMilliseconds = completedAt.timeIntervalSince1970 * 1_000
        guard completedMilliseconds.isFinite,
              completedMilliseconds >= 0,
              completedMilliseconds < Double(Int64.max) else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "completion time is outside the persistable millisecond range"
            )
        }
        guard Self.isCanonicalSHA256(completionContractSHA256),
              Self.isCanonicalSHA256(derivedRecordContractSHA256) else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "completion contract and derived record digests must be lowercase SHA-256"
            )
        }
        guard operationID.rawValue != Self.zeroUUID,
              actionID.rawValue != Self.zeroUUID,
              packageID.rawValue != Self.zeroUUID,
              originDeviceID.rawValue != Self.zeroUUID else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "stable identifiers must not use the nil UUID"
            )
        }
        guard progressSnapshotID == Self.progressSnapshotID(for: operationID),
              planningDecisionID == Self.planningDecisionID(for: operationID),
              replanEventID == Self.replanEventID(for: operationID) else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "derived record identifiers do not match the operation identifier"
            )
        }
        let expectedDerivedContract = try Self.derivedRecordContractSHA256(
            planningEngineVersion: planningEngineVersion,
            operationID: operationID,
            actionID: actionID,
            packageID: packageID,
            completedAt: completedAt,
            originDeviceID: originDeviceID,
            progressSnapshotID: progressSnapshotID,
            planningDecisionID: planningDecisionID,
            replanEventID: replanEventID
        )
        guard expectedDerivedContract == derivedRecordContractSHA256 else {
            throw NextStepBetaCompletionOperationError.derivedRecordContractMismatch
        }
        guard quizEvidence.metadata.id != userAttestation.metadata.id else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "quiz evidence and user attestation must have distinct identifiers"
            )
        }
        guard quizEvidence.metadata.id.rawValue != Self.zeroUUID,
              userAttestation.metadata.id.rawValue != Self.zeroUUID else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "completion evidence identifiers must not use the nil UUID"
            )
        }
        guard quizEvidence.actionID == actionID,
              quizEvidence.packageID == packageID,
              quizEvidence.packageVersion == packageVersion,
              quizEvidence.kind == .quizResult,
              quizEvidence.metadata.provenance.kind == .deterministicEngine,
              quizEvidence.metadata.deletedAt == nil,
              quizEvidence.hasReplayableQuizResult,
              let quizResult = quizEvidence.quizResult else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "quiz evidence is not replayable for this action and package"
            )
        }
        guard userAttestation.actionID == actionID,
              userAttestation.packageID == packageID,
              userAttestation.packageVersion == packageVersion,
              userAttestation.kind == .userAttestation,
              userAttestation.metadata.provenance.kind == .user,
              userAttestation.metadata.originDeviceID == originDeviceID,
              userAttestation.metadata.deletedAt == nil,
              userAttestation.measuredValue == nil,
              userAttestation.quizResult == nil else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "user attestation is not explicit user evidence for this operation"
            )
        }
        guard quizResult.packageID == packageID,
              quizResult.packageVersion == packageVersion,
              quizResult.scoredAt == quizEvidence.capturedAt,
              quizEvidence.capturedAt <= completedAt,
              userAttestation.capturedAt == completedAt,
              userAttestation.metadata.createdAt == completedAt else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "completion evidence chronology or package identity is inconsistent"
            )
        }
        let responseIDs = referencedUserResponses.map(\.metadata.id)
        guard responseIDs.isEmpty == false,
              Set(responseIDs).count == responseIDs.count,
              responseIDs.allSatisfy({ $0.rawValue != Self.zeroUUID }),
              quizResult.attemptID != Self.zeroUUID,
              quizResult.quizID.rawValue != Self.zeroUUID,
              Set(responseIDs) == Set(quizResult.responseIDs),
              referencedUserResponses.allSatisfy({ response in
                  response.metadata.provenance.kind == .user
                      && response.metadata.deletedAt == nil
                      && response.attemptID == quizResult.attemptID
                      && response.quizID == quizResult.quizID
                      && response.packageVersion == packageVersion
                      && response.attemptedAt <= quizResult.scoredAt
              }) else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "referenced responses do not exactly support the quiz result"
            )
        }
        guard Set(quizEvidence.criterionIDs).isDisjoint(
            with: Set(userAttestation.criterionIDs)
        ) else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "quiz and attestation evidence claim the same criterion"
            )
        }
    }

    private static func progressSnapshotID(for operationID: OperationID) -> ProgressSnapshotID {
        ProgressSnapshotID(derivedUUID(operationID: operationID, purpose: "progress"))
    }

    private static func planningDecisionID(for operationID: OperationID) -> PlanningDecisionID {
        PlanningDecisionID(derivedUUID(operationID: operationID, purpose: "decision"))
    }

    private static func replanEventID(for operationID: OperationID) -> ReplanEventID {
        ReplanEventID(derivedUUID(operationID: operationID, purpose: "replan"))
    }

    private static func derivedUUID(operationID: OperationID, purpose: String) -> UUID {
        let input = "nextstep.beta.guided-action-completion.v1|\(operationID)|\(purpose)"
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

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func derivedRecordContractSHA256(
        planningEngineVersion: String,
        operationID: OperationID,
        actionID: DailyActionID,
        packageID: GuidedLearningPackageID,
        completedAt: Date,
        originDeviceID: DeviceID,
        progressSnapshotID: ProgressSnapshotID,
        planningDecisionID: PlanningDecisionID,
        replanEventID: ReplanEventID
    ) throws -> String {
        let envelope = DerivedRecordContractV1(
            schemaVersion: 1,
            planningEngineVersion: planningEngineVersion,
            operationID: operationID,
            actionID: actionID,
            packageID: packageID,
            completedAt: completedAt,
            originDeviceID: originDeviceID,
            progressSnapshotID: progressSnapshotID,
            planningDecisionID: planningDecisionID,
            replanEventID: replanEventID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(envelope))
    }

    private static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private struct CompletionContractV1: Encodable {
        let schemaVersion: Int
        let actionID: DailyActionID
        let packageID: GuidedLearningPackageID
        let packageVersion: Int
        let requiredOutput: RequiredOutput
        let completionCriteria: [CompletionCriterion]
        let quiz: Quiz
    }

    private struct DerivedRecordContractV1: Encodable {
        let schemaVersion: Int
        let planningEngineVersion: String
        let operationID: OperationID
        let actionID: DailyActionID
        let packageID: GuidedLearningPackageID
        let completedAt: Date
        let originDeviceID: DeviceID
        let progressSnapshotID: ProgressSnapshotID
        let planningDecisionID: PlanningDecisionID
        let replanEventID: ReplanEventID
    }
}

private struct NextStepBetaGuidedActionAttestationCompletionOperationV2:
    Codable,
    Hashable,
    Sendable {
    static let currentSchemaVersion = 2
    static let completionMode = "userAttestationOnly"
    static let minimumAttestationLineCount = 3

    let kind: String
    let schemaVersion: Int
    let planningEngineVersion: String
    let operationID: OperationID
    let actionID: DailyActionID
    let packageID: GuidedLearningPackageID
    let packageVersion: Int
    let completionContractSHA256: String
    let completedAt: Date
    let originDeviceID: DeviceID
    let userAttestation: CompletionEvidence
    let progressSnapshotID: ProgressSnapshotID
    let planningDecisionID: PlanningDecisionID
    let replanEventID: ReplanEventID
    let derivedRecordContractSHA256: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion
        case planningEngineVersion
        case operationID
        case actionID
        case packageID
        case packageVersion
        case completionContractSHA256
        case completedAt
        case originDeviceID
        case userAttestation
        case progressSnapshotID
        case planningDecisionID
        case replanEventID
        case derivedRecordContractSHA256
    }

    init(
        operationID: OperationID,
        action: DailyAction,
        package: GuidedLearningPackage,
        completedAt: Date,
        originDeviceID: DeviceID,
        userAttestation: CompletionEvidence
    ) throws {
        let contractDigest = try Self.contractSHA256(action: action, package: package)
        guard PlanningEngine.version
            == NextStepBetaGuidedActionCompletionOperation.supportedPlanningEngineVersion else {
            throw NextStepBetaCompletionOperationError.unsupportedPlanningEngineVersion(
                PlanningEngine.version
            )
        }
        let progressSnapshotID = Self.progressSnapshotID(for: operationID)
        let planningDecisionID = Self.planningDecisionID(for: operationID)
        let replanEventID = Self.replanEventID(for: operationID)
        let derivedContractDigest = try Self.derivedRecordContractSHA256(
            planningEngineVersion:
                NextStepBetaGuidedActionCompletionOperation.supportedPlanningEngineVersion,
            operationID: operationID,
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            completedAt: completedAt,
            originDeviceID: originDeviceID,
            progressSnapshotID: progressSnapshotID,
            planningDecisionID: planningDecisionID,
            replanEventID: replanEventID
        )
        try self.init(
            kind: NextStepBetaGuidedActionCompletionOperation.payloadKind,
            schemaVersion: Self.currentSchemaVersion,
            planningEngineVersion:
                NextStepBetaGuidedActionCompletionOperation.supportedPlanningEngineVersion,
            operationID: operationID,
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            completionContractSHA256: contractDigest,
            completedAt: completedAt,
            originDeviceID: originDeviceID,
            userAttestation: userAttestation,
            progressSnapshotID: progressSnapshotID,
            planningDecisionID: planningDecisionID,
            replanEventID: replanEventID,
            derivedRecordContractSHA256: derivedContractDigest
        )
        try validateEvidenceContract(action: action, package: package)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(String.self, forKey: .kind),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            planningEngineVersion: container.decode(
                String.self,
                forKey: .planningEngineVersion
            ),
            operationID: container.decode(OperationID.self, forKey: .operationID),
            actionID: container.decode(DailyActionID.self, forKey: .actionID),
            packageID: container.decode(GuidedLearningPackageID.self, forKey: .packageID),
            packageVersion: container.decode(Int.self, forKey: .packageVersion),
            completionContractSHA256: container.decode(
                String.self,
                forKey: .completionContractSHA256
            ),
            completedAt: container.decode(Date.self, forKey: .completedAt),
            originDeviceID: container.decode(DeviceID.self, forKey: .originDeviceID),
            userAttestation: container.decode(
                CompletionEvidence.self,
                forKey: .userAttestation
            ),
            progressSnapshotID: container.decode(
                ProgressSnapshotID.self,
                forKey: .progressSnapshotID
            ),
            planningDecisionID: container.decode(
                PlanningDecisionID.self,
                forKey: .planningDecisionID
            ),
            replanEventID: container.decode(ReplanEventID.self, forKey: .replanEventID),
            derivedRecordContractSHA256: container.decode(
                String.self,
                forKey: .derivedRecordContractSHA256
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        try validateIntrinsic()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(planningEngineVersion, forKey: .planningEngineVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(packageVersion, forKey: .packageVersion)
        try container.encode(completionContractSHA256, forKey: .completionContractSHA256)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(originDeviceID, forKey: .originDeviceID)
        try container.encode(userAttestation, forKey: .userAttestation)
        try container.encode(progressSnapshotID, forKey: .progressSnapshotID)
        try container.encode(planningDecisionID, forKey: .planningDecisionID)
        try container.encode(replanEventID, forKey: .replanEventID)
        try container.encode(
            derivedRecordContractSHA256,
            forKey: .derivedRecordContractSHA256
        )
    }

    func canonicalData() throws -> Data {
        try validateIntrinsic()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count
            <= NextStepBetaGuidedActionCompletionOperation.maximumCanonicalByteCount else {
            throw NextStepBetaCompletionOperationError.payloadTooLarge(data.count)
        }
        return data
    }

    static func contractSHA256(
        action: DailyAction,
        package: GuidedLearningPackage
    ) throws -> String {
        guard action.packageID == package.metadata.id,
              package.dailyActionID == action.metadata.id,
              package.version >= 1,
              action.requiredOutput == package.requiredOutput,
              action.completionCriteria == package.completionCriteria else {
            throw NextStepBetaCompletionOperationError.actionPackageMismatch
        }
        guard package.quiz == nil,
              action.requiredOutput.validationKind == .userConfirmation,
              action.requiredOutput.minimumWordCount == nil,
              action.completionCriteria.isEmpty == false else {
            throw NextStepBetaCompletionOperationError.attestationOnlyPackageRequired(
                package.metadata.id
            )
        }
        let criterionIDs = action.completionCriteria.map(\.id)
        guard Set(criterionIDs).count == criterionIDs.count,
              criterionIDs.allSatisfy({ $0 != zeroUUID }),
              action.completionCriteria.allSatisfy({
                  $0.kind == .userAttestation
                      && $0.threshold == nil
                      && $0.requiresEvidence
                      && $0.requiresUserConfirmation
              }) else {
            throw NextStepBetaCompletionOperationError.attestationOnlyPackageRequired(
                package.metadata.id
            )
        }
        let contract = CompletionContractV2(
            schemaVersion: Self.currentSchemaVersion,
            completionMode: Self.completionMode,
            minimumAttestationLineCount: Self.minimumAttestationLineCount,
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            requiredOutput: action.requiredOutput,
            completionCriteria: action.completionCriteria.sorted {
                $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
            }
        )
        return try digest(contract)
    }

    func validateEvidenceContract(
        action: DailyAction,
        package: GuidedLearningPackage
    ) throws {
        _ = try Self.contractSHA256(action: action, package: package)
        let expectedCriterionIDs = action.completionCriteria
            .map(\.id)
            .sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard userAttestation.criterionIDs == expectedCriterionIDs else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "user attestation must cover the complete canonical criterion set"
            )
        }
    }

    private init(
        kind: String,
        schemaVersion: Int,
        planningEngineVersion: String,
        operationID: OperationID,
        actionID: DailyActionID,
        packageID: GuidedLearningPackageID,
        packageVersion: Int,
        completionContractSHA256: String,
        completedAt: Date,
        originDeviceID: DeviceID,
        userAttestation: CompletionEvidence,
        progressSnapshotID: ProgressSnapshotID,
        planningDecisionID: PlanningDecisionID,
        replanEventID: ReplanEventID,
        derivedRecordContractSHA256: String
    ) throws {
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.planningEngineVersion = planningEngineVersion
        self.operationID = operationID
        self.actionID = actionID
        self.packageID = packageID
        self.packageVersion = packageVersion
        self.completionContractSHA256 = completionContractSHA256
        self.completedAt = completedAt
        self.originDeviceID = originDeviceID
        self.userAttestation = userAttestation
        self.progressSnapshotID = progressSnapshotID
        self.planningDecisionID = planningDecisionID
        self.replanEventID = replanEventID
        self.derivedRecordContractSHA256 = derivedRecordContractSHA256
        try validateIntrinsic()
    }

    private func validateIntrinsic() throws {
        guard kind == NextStepBetaGuidedActionCompletionOperation.payloadKind else {
            throw NextStepBetaCompletionOperationError.unexpectedPayloadKind(kind)
        }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NextStepBetaCompletionOperationError.unsupportedSchema(schemaVersion)
        }
        guard planningEngineVersion
            == NextStepBetaGuidedActionCompletionOperation.supportedPlanningEngineVersion else {
            throw NextStepBetaCompletionOperationError.unsupportedPlanningEngineVersion(
                planningEngineVersion
            )
        }
        guard packageVersion >= 1 else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "package version must be positive"
            )
        }
        let completedMilliseconds = completedAt.timeIntervalSince1970 * 1_000
        guard completedMilliseconds.isFinite,
              completedMilliseconds >= 0,
              completedMilliseconds < Double(Int64.max) else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "completion time is outside the persistable millisecond range"
            )
        }
        guard Self.isCanonicalSHA256(completionContractSHA256),
              Self.isCanonicalSHA256(derivedRecordContractSHA256) else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "completion contract and derived record digests must be lowercase SHA-256"
            )
        }
        guard operationID.rawValue != Self.zeroUUID,
              actionID.rawValue != Self.zeroUUID,
              packageID.rawValue != Self.zeroUUID,
              originDeviceID.rawValue != Self.zeroUUID,
              userAttestation.metadata.id.rawValue != Self.zeroUUID else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "stable identifiers must not use the nil UUID"
            )
        }
        guard progressSnapshotID == Self.progressSnapshotID(for: operationID),
              planningDecisionID == Self.planningDecisionID(for: operationID),
              replanEventID == Self.replanEventID(for: operationID) else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "derived record identifiers do not match the operation identifier"
            )
        }
        let expectedDerivedContract = try Self.derivedRecordContractSHA256(
            planningEngineVersion: planningEngineVersion,
            operationID: operationID,
            actionID: actionID,
            packageID: packageID,
            completedAt: completedAt,
            originDeviceID: originDeviceID,
            progressSnapshotID: progressSnapshotID,
            planningDecisionID: planningDecisionID,
            replanEventID: replanEventID
        )
        guard expectedDerivedContract == derivedRecordContractSHA256 else {
            throw NextStepBetaCompletionOperationError.derivedRecordContractMismatch
        }
        let canonicalCriterionIDs = userAttestation.criterionIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }
        let canonicalAttestationLines = Self.canonicalAttestationLines(
            userAttestation.value
        )
        guard userAttestation.actionID == actionID,
              userAttestation.packageID == packageID,
              userAttestation.packageVersion == packageVersion,
              userAttestation.kind == .userAttestation,
              userAttestation.metadata.provenance.kind == .user,
              userAttestation.metadata.originDeviceID == originDeviceID,
              userAttestation.metadata.revision == 0,
              userAttestation.metadata.createdAt == completedAt,
              userAttestation.metadata.updatedAt == completedAt,
              userAttestation.metadata.deletedAt == nil,
              userAttestation.metadata.lastOperationID == operationID,
              userAttestation.measuredValue == nil,
              userAttestation.quizResult == nil,
              userAttestation.capturedAt == completedAt,
              userAttestation.criterionIDs == canonicalCriterionIDs,
              canonicalCriterionIDs.allSatisfy({ $0 != Self.zeroUUID }),
              canonicalAttestationLines.count >= Self.minimumAttestationLineCount,
              userAttestation.value == canonicalAttestationLines.joined(separator: "\n") else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "user attestation is not canonical explicit user evidence for this operation"
            )
        }
    }

    private static func canonicalAttestationLines(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func progressSnapshotID(for operationID: OperationID) -> ProgressSnapshotID {
        ProgressSnapshotID(derivedUUID(operationID: operationID, purpose: "progress"))
    }

    private static func planningDecisionID(for operationID: OperationID) -> PlanningDecisionID {
        PlanningDecisionID(derivedUUID(operationID: operationID, purpose: "decision"))
    }

    private static func replanEventID(for operationID: OperationID) -> ReplanEventID {
        ReplanEventID(derivedUUID(operationID: operationID, purpose: "replan"))
    }

    private static func derivedUUID(operationID: OperationID, purpose: String) -> UUID {
        let input = "nextstep.beta.guided-action-completion.v2|\(operationID)|\(purpose)"
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

    private static func derivedRecordContractSHA256(
        planningEngineVersion: String,
        operationID: OperationID,
        actionID: DailyActionID,
        packageID: GuidedLearningPackageID,
        completedAt: Date,
        originDeviceID: DeviceID,
        progressSnapshotID: ProgressSnapshotID,
        planningDecisionID: PlanningDecisionID,
        replanEventID: ReplanEventID
    ) throws -> String {
        try digest(DerivedRecordContractV2(
            schemaVersion: Self.currentSchemaVersion,
            planningEngineVersion: planningEngineVersion,
            operationID: operationID,
            actionID: actionID,
            packageID: packageID,
            completedAt: completedAt,
            originDeviceID: originDeviceID,
            progressSnapshotID: progressSnapshotID,
            planningDecisionID: planningDecisionID,
            replanEventID: replanEventID
        ))
    }

    private static func digest<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(value))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    private struct CompletionContractV2: Encodable {
        let schemaVersion: Int
        let completionMode: String
        let minimumAttestationLineCount: Int
        let actionID: DailyActionID
        let packageID: GuidedLearningPackageID
        let packageVersion: Int
        let requiredOutput: RequiredOutput
        let completionCriteria: [CompletionCriterion]
    }

    private struct DerivedRecordContractV2: Encodable {
        let schemaVersion: Int
        let planningEngineVersion: String
        let operationID: OperationID
        let actionID: DailyActionID
        let packageID: GuidedLearningPackageID
        let completedAt: Date
        let originDeviceID: DeviceID
        let progressSnapshotID: ProgressSnapshotID
        let planningDecisionID: PlanningDecisionID
        let replanEventID: ReplanEventID
    }
}

/// Version-dispatching root for immutable Guided Action completion payloads.
/// The v1 concrete encoder remains untouched and is delegated to directly, so
/// existing canonical root JSON bytes keep their exact historical shape.
struct NextStepBetaGuidedActionCompletionOperation: Codable, Hashable, Sendable {
    static let payloadKind = NextStepBetaGuidedActionQuizCompletionOperationV1.payloadKind
    static let currentSchemaVersion =
        NextStepBetaGuidedActionAttestationCompletionOperationV2.currentSchemaVersion
    static let supportedPlanningEngineVersion =
        NextStepBetaGuidedActionQuizCompletionOperationV1.supportedPlanningEngineVersion
    static let maximumCanonicalByteCount =
        NextStepBetaGuidedActionQuizCompletionOperationV1.maximumCanonicalByteCount

    private enum Storage: Hashable, Sendable {
        case quizV1(NextStepBetaGuidedActionQuizCompletionOperationV1)
        case attestationV2(NextStepBetaGuidedActionAttestationCompletionOperationV2)
    }

    private enum HeaderKeys: String, CodingKey {
        case kind
        case schemaVersion
    }

    private let storage: Storage

    var kind: String {
        switch storage {
        case let .quizV1(value): value.kind
        case let .attestationV2(value): value.kind
        }
    }

    var schemaVersion: Int {
        switch storage {
        case let .quizV1(value): value.schemaVersion
        case let .attestationV2(value): value.schemaVersion
        }
    }

    var planningEngineVersion: String {
        switch storage {
        case let .quizV1(value): value.planningEngineVersion
        case let .attestationV2(value): value.planningEngineVersion
        }
    }

    var operationID: OperationID {
        switch storage {
        case let .quizV1(value): value.operationID
        case let .attestationV2(value): value.operationID
        }
    }

    var actionID: DailyActionID {
        switch storage {
        case let .quizV1(value): value.actionID
        case let .attestationV2(value): value.actionID
        }
    }

    var packageID: GuidedLearningPackageID {
        switch storage {
        case let .quizV1(value): value.packageID
        case let .attestationV2(value): value.packageID
        }
    }

    var packageVersion: Int {
        switch storage {
        case let .quizV1(value): value.packageVersion
        case let .attestationV2(value): value.packageVersion
        }
    }

    var completionContractSHA256: String {
        switch storage {
        case let .quizV1(value): value.completionContractSHA256
        case let .attestationV2(value): value.completionContractSHA256
        }
    }

    var completedAt: Date {
        switch storage {
        case let .quizV1(value): value.completedAt
        case let .attestationV2(value): value.completedAt
        }
    }

    var originDeviceID: DeviceID {
        switch storage {
        case let .quizV1(value): value.originDeviceID
        case let .attestationV2(value): value.originDeviceID
        }
    }

    var referencedUserResponses: [UserResponse] {
        switch storage {
        case let .quizV1(value): value.referencedUserResponses
        case .attestationV2: []
        }
    }

    var quizEvidence: CompletionEvidence? {
        guard case let .quizV1(value) = storage else { return nil }
        return value.quizEvidence
    }

    var userAttestation: CompletionEvidence {
        switch storage {
        case let .quizV1(value): value.userAttestation
        case let .attestationV2(value): value.userAttestation
        }
    }

    var completionEvidence: [CompletionEvidence] {
        switch storage {
        case let .quizV1(value): [value.quizEvidence, value.userAttestation]
        case let .attestationV2(value): [value.userAttestation]
        }
    }

    var progressSnapshotID: ProgressSnapshotID {
        switch storage {
        case let .quizV1(value): value.progressSnapshotID
        case let .attestationV2(value): value.progressSnapshotID
        }
    }

    var planningDecisionID: PlanningDecisionID {
        switch storage {
        case let .quizV1(value): value.planningDecisionID
        case let .attestationV2(value): value.planningDecisionID
        }
    }

    var replanEventID: ReplanEventID {
        switch storage {
        case let .quizV1(value): value.replanEventID
        case let .attestationV2(value): value.replanEventID
        }
    }

    var derivedRecordContractSHA256: String {
        switch storage {
        case let .quizV1(value): value.derivedRecordContractSHA256
        case let .attestationV2(value): value.derivedRecordContractSHA256
        }
    }

    var isQuizBackedV1: Bool {
        if case .quizV1 = storage { return true }
        return false
    }

    init(
        operationID: OperationID,
        action: DailyAction,
        package: GuidedLearningPackage,
        completedAt: Date,
        originDeviceID: DeviceID,
        referencedUserResponses: [UserResponse],
        quizEvidence: CompletionEvidence,
        userAttestation: CompletionEvidence
    ) throws {
        storage = .quizV1(try NextStepBetaGuidedActionQuizCompletionOperationV1(
            operationID: operationID,
            action: action,
            package: package,
            completedAt: completedAt,
            originDeviceID: originDeviceID,
            referencedUserResponses: referencedUserResponses,
            quizEvidence: quizEvidence,
            userAttestation: userAttestation
        ))
    }

    init(
        operationID: OperationID,
        action: DailyAction,
        package: GuidedLearningPackage,
        completedAt: Date,
        originDeviceID: DeviceID,
        userAttestation: CompletionEvidence
    ) throws {
        storage = .attestationV2(
            try NextStepBetaGuidedActionAttestationCompletionOperationV2(
                operationID: operationID,
                action: action,
                package: package,
                completedAt: completedAt,
                originDeviceID: originDeviceID,
                userAttestation: userAttestation
            )
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: HeaderKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == Self.payloadKind else {
            throw NextStepBetaCompletionOperationError.unexpectedPayloadKind(kind)
        }
        switch try container.decode(Int.self, forKey: .schemaVersion) {
        case NextStepBetaGuidedActionQuizCompletionOperationV1.currentSchemaVersion:
            storage = .quizV1(
                try NextStepBetaGuidedActionQuizCompletionOperationV1(from: decoder)
            )
        case NextStepBetaGuidedActionAttestationCompletionOperationV2.currentSchemaVersion:
            storage = .attestationV2(
                try NextStepBetaGuidedActionAttestationCompletionOperationV2(from: decoder)
            )
        case let version:
            throw NextStepBetaCompletionOperationError.unsupportedSchema(version)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch storage {
        case let .quizV1(value):
            try value.encode(to: encoder)
        case let .attestationV2(value):
            try value.encode(to: encoder)
        }
    }

    func canonicalData() throws -> Data {
        switch storage {
        case let .quizV1(value): try value.canonicalData()
        case let .attestationV2(value): try value.canonicalData()
        }
    }

    static func decodeCanonical(
        from data: Data,
        maximumByteCount: Int = Self.maximumCanonicalByteCount
    ) throws -> Self {
        guard maximumByteCount > 0,
              data.isEmpty == false,
              data.count <= maximumByteCount,
              data.count <= Self.maximumCanonicalByteCount else {
            throw NextStepBetaCompletionOperationError.payloadTooLarge(data.count)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let operation = try decoder.decode(Self.self, from: data)
        guard try operation.canonicalData() == data else {
            throw NextStepBetaCompletionOperationError.nonCanonicalPayload
        }
        return operation
    }

    /// Historical v1 contract helper retained for existing quiz fixtures.
    static func contractSHA256(
        action: DailyAction,
        package: GuidedLearningPackage
    ) throws -> String {
        try NextStepBetaGuidedActionQuizCompletionOperationV1.contractSHA256(
            action: action,
            package: package
        )
    }

    func expectedContractSHA256(
        action: DailyAction,
        package: GuidedLearningPackage
    ) throws -> String {
        switch storage {
        case .quizV1:
            try Self.contractSHA256(action: action, package: package)
        case .attestationV2:
            try NextStepBetaGuidedActionAttestationCompletionOperationV2.contractSHA256(
                action: action,
                package: package
            )
        }
    }

    func validateEvidenceContract(
        action: DailyAction,
        package: GuidedLearningPackage
    ) throws {
        switch storage {
        case .quizV1:
            break
        case let .attestationV2(value):
            try value.validateEvidenceContract(action: action, package: package)
        }
    }
}

/// Context-specific proof for one deterministic application of an immutable
/// completion operation. Unlike the operation contract, this receipt binds the
/// exact planning input and derived output bytes produced on the receiving
/// archive, so legitimate cross-device context differences remain possible
/// while later projection corruption is detected.
struct NextStepBetaCompletionApplicationReceipt: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let operationID: OperationID
    let actionID: DailyActionID
    let planningEngineVersion: String
    let appliedAt: Date
    let originDeviceID: DeviceID
    let baseContextSHA256: String
    let progressSnapshotID: ProgressSnapshotID
    let planningDecisionID: PlanningDecisionID
    let replanEventID: ReplanEventID
    let derivedRecordsSHA256: String

    init(
        operation: NextStepBetaGuidedActionCompletionOperation,
        baseArchive: NextStepBetaArchive,
        resultArchive: NextStepBetaArchive
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.operationID = operation.operationID
        self.actionID = operation.actionID
        self.planningEngineVersion = operation.planningEngineVersion
        self.appliedAt = operation.completedAt
        self.originDeviceID = operation.originDeviceID
        self.baseContextSHA256 = try Self.replayContextSHA256(in: baseArchive)
        self.progressSnapshotID = operation.progressSnapshotID
        self.planningDecisionID = operation.planningDecisionID
        self.replanEventID = operation.replanEventID
        self.derivedRecordsSHA256 = try Self.derivedRecordsSHA256(
            in: resultArchive,
            progressSnapshotID: operation.progressSnapshotID,
            planningDecisionID: operation.planningDecisionID,
            replanEventID: operation.replanEventID
        )
        try validateIntrinsic()
    }

    func matches(_ operation: NextStepBetaGuidedActionCompletionOperation) -> Bool {
        operationID == operation.operationID
            && actionID == operation.actionID
            && planningEngineVersion == operation.planningEngineVersion
            && appliedAt == operation.completedAt
            && originDeviceID == operation.originDeviceID
            && progressSnapshotID == operation.progressSnapshotID
            && planningDecisionID == operation.planningDecisionID
            && replanEventID == operation.replanEventID
    }

    func validate(in archive: NextStepBetaArchive) throws {
        try validateIntrinsic()
        let actions = archive.workspace.dailyActions.filter {
            $0.metadata.id == actionID
        }
        let progress = archive.workspace.progressSnapshots.filter {
            $0.metadata.id == progressSnapshotID
        }
        let decisions = archive.workspace.planningDecisions.filter {
            $0.metadata.id == planningDecisionID
        }
        let events = archive.workspace.replanEvents.filter {
            $0.metadata.id == replanEventID
        }
        guard actions.count == 1,
              let action = actions.first,
              action.status == .completed,
              action.completedAt == appliedAt,
              progress.count == 1,
              let progressRecord = progress.first,
              decisions.count == 1,
              let decision = decisions.first,
              events.count == 1,
              let event = events.first,
              progressRecord.capturedAt == appliedAt,
              progressRecord.metadata.createdAt == appliedAt,
              progressRecord.metadata.originDeviceID == originDeviceID,
              progressRecord.metadata.provenance.kind == .deterministicEngine,
              decision.createdAt == appliedAt,
              decision.metadata.createdAt == appliedAt,
              decision.metadata.originDeviceID == originDeviceID,
              decision.metadata.provenance.kind == .deterministicEngine,
              decision.engineVersion == planningEngineVersion,
              event.trigger == .actionCompleted,
              event.afterDecisionID == planningDecisionID,
              event.resolution == .accepted,
              event.occurredAt == appliedAt,
              event.metadata.createdAt == appliedAt,
              event.metadata.originDeviceID == originDeviceID,
              event.metadata.provenance.kind == .deterministicEngine else {
            throw NextStepBetaCompletionOperationError.derivedRecordsMismatch
        }
        let actual = try Self.derivedRecordsSHA256(
            in: archive,
            progressSnapshotID: progressSnapshotID,
            planningDecisionID: planningDecisionID,
            replanEventID: replanEventID
        )
        guard actual == derivedRecordsSHA256 else {
            throw NextStepBetaCompletionOperationError.derivedRecordsMismatch
        }
    }

    private func validateIntrinsic() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NextStepBetaCompletionOperationError.unsupportedSchema(schemaVersion)
        }
        guard planningEngineVersion
            == NextStepBetaGuidedActionCompletionOperation.supportedPlanningEngineVersion else {
            throw NextStepBetaCompletionOperationError.unsupportedPlanningEngineVersion(
                planningEngineVersion
            )
        }
        guard Self.isCanonicalSHA256(baseContextSHA256),
              Self.isCanonicalSHA256(derivedRecordsSHA256) else {
            throw NextStepBetaCompletionOperationError.invalidOperation(
                "application receipt digests must be lowercase SHA-256"
            )
        }
    }

    private static func replayContextSHA256(
        in archive: NextStepBetaArchive
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metadata = ReplayContextV1(
            schemaVersion: 1,
            currentDecisionID: archive.currentDecisionID
        )
        guard var contextObject = try JSONSerialization.jsonObject(
            with: encoder.encode(metadata)
        ) as? [String: Any],
        let workspaceObject = try JSONSerialization.jsonObject(
            with: PlanningWorkspaceCanonicalizer.canonicalData(archive.workspace)
        ) as? [String: Any] else {
            throw EncodingError.invalidValue(
                metadata,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "The completion replay context is not a JSON object."
                )
            )
        }
        contextObject["workspace"] = workspaceObject
        let data = try JSONSerialization.data(
            withJSONObject: contextObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return sha256(data)
    }

    private static func derivedRecordsSHA256(
        in archive: NextStepBetaArchive,
        progressSnapshotID: ProgressSnapshotID,
        planningDecisionID: PlanningDecisionID,
        replanEventID: ReplanEventID
    ) throws -> String {
        guard let progress = archive.workspace.progressSnapshots.first(where: {
            $0.metadata.id == progressSnapshotID
        }), let decision = archive.workspace.planningDecisions.first(where: {
            $0.metadata.id == planningDecisionID
        }), let event = archive.workspace.replanEvents.first(where: {
            $0.metadata.id == replanEventID
        }) else {
            throw NextStepBetaCompletionOperationError.derivedRecordsMismatch
        }
        return try digest(DerivedRecordsEnvelopeV1(
            schemaVersion: 1,
            progressSnapshot: CanonicalProgressSnapshotV1(progress),
            planningDecision: decision,
            replanEvent: event
        ))
    }

    private static func digest<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(value))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private struct ReplayContextV1: Encodable {
        let schemaVersion: Int
        let currentDecisionID: PlanningDecisionID?
    }

    private struct DerivedRecordsEnvelopeV1: Encodable {
        let schemaVersion: Int
        let progressSnapshot: CanonicalProgressSnapshotV1
        let planningDecision: PlanningDecision
        let replanEvent: ReplanEvent
    }

    private struct ProgressFractionEntry<ID: Encodable & Comparable>: Encodable {
        let id: ID
        let fraction: Double
    }

    private struct CanonicalProgressSnapshotV1: Encodable {
        let metadata: RecordMetadata<ProgressSnapshotID>
        let capturedAt: Date
        let planRevision: Int64
        let ultimateGoalProgress: [ProgressFractionEntry<UltimateGoalID>]
        let goalProgress: [ProgressFractionEntry<GoalID>]
        let milestoneProgress: [ProgressFractionEntry<MilestoneID>]
        let completedActionCount: Int
        let totalActionCount: Int
        let atRiskMilestoneIDs: [MilestoneID]

        init(_ value: ProgressSnapshot) {
            metadata = value.metadata
            capturedAt = value.capturedAt
            planRevision = value.planRevision
            ultimateGoalProgress = value.ultimateGoalProgress.map {
                ProgressFractionEntry(id: $0.key, fraction: $0.value)
            }.sorted { $0.id < $1.id }
            goalProgress = value.goalProgress.map {
                ProgressFractionEntry(id: $0.key, fraction: $0.value)
            }.sorted { $0.id < $1.id }
            milestoneProgress = value.milestoneProgress.map {
                ProgressFractionEntry(id: $0.key, fraction: $0.value)
            }.sorted { $0.id < $1.id }
            completedActionCount = value.completedActionCount
            totalActionCount = value.totalActionCount
            atRiskMilestoneIDs = value.atRiskMilestoneIDs.sorted()
        }
    }
}

/// Pure reducer: no disk, transport, clock or random-ID access. The caller
/// commits the returned archive and operation ledger entry atomically.
struct NextStepBetaCompletionOperationReducer: Sendable {
    func replay(
        _ operation: NextStepBetaGuidedActionCompletionOperation,
        in archive: NextStepBetaArchive
    ) throws -> NextStepBetaCompletionReplayResult {
        try archive.validate()
        _ = try operation.canonicalData()
        guard PlanningEngine.version == operation.planningEngineVersion else {
            throw NextStepBetaCompletionOperationError.unsupportedPlanningEngineVersion(
                operation.planningEngineVersion
            )
        }

        guard let action = archive.workspace.dailyActions.first(where: {
            $0.metadata.id == operation.actionID
        }) else {
            throw NextStepBetaCompletionOperationError.actionNotFound(operation.actionID)
        }
        guard let package = archive.workspace.guidedPackages.first(where: {
            $0.metadata.id == operation.packageID
        }) else {
            throw NextStepBetaCompletionOperationError.packageNotFound(operation.packageID)
        }
        guard action.packageID == package.metadata.id,
              package.dailyActionID == action.metadata.id,
              package.version == operation.packageVersion,
              action.metadata.id == operation.actionID,
              action.metadata.deletedAt == nil,
              package.metadata.deletedAt == nil,
              operation.completedAt >= action.metadata.createdAt,
              operation.completedAt >= package.metadata.createdAt else {
            throw NextStepBetaCompletionOperationError.actionPackageMismatch
        }
        let expectedDigest = try operation.expectedContractSHA256(
            action: action,
            package: package
        )
        guard expectedDigest == operation.completionContractSHA256 else {
            throw NextStepBetaCompletionOperationError.completionContractMismatch(
                expected: expectedDigest,
                actual: operation.completionContractSHA256
            )
        }
        try operation.validateEvidenceContract(action: action, package: package)

        try validateRecordCollisions(operation, archive: archive)
        try validateActionEvidenceSet(operation, archive: archive)
        if action.status == .completed {
            guard try isExactAppliedOperation(
                operation,
                archive: archive
            ) else {
                throw NextStepBetaCompletionOperationError.conflictingActionCompletion(
                    operation.actionID
                )
            }
            return NextStepBetaCompletionReplayResult(
                outcome: .alreadyApplied,
                archive: archive
            )
        }

        try rejectDerivedRecordCollisions(operation, archive: archive)
        var result = archive
        for response in operation.referencedUserResponses {
            guard result.workspace.userResponses.contains(where: {
                $0.metadata.id == response.metadata.id
            }) == false else { continue }
            result.workspace.userResponses.append(response)
        }

        do {
            result.workspace = try ExecutionService().completeAction(
                operation.actionID,
                evidence: operation.completionEvidence,
                in: result.workspace,
                at: operation.completedAt,
                progressSnapshotID: operation.progressSnapshotID,
                originDeviceID: operation.originDeviceID,
                currentDecision: archive.currentDecision
            )
        } catch {
            throw NextStepBetaCompletionOperationError.completionRejected(
                error.localizedDescription
            )
        }

        do {
            let today = try LocalDay(
                date: operation.completedAt,
                timeZoneIdentifier: result.workspace.userProfile.timeZoneIdentifier
            )
            let input = try PlanningInput(
                snapshot: result.workspace,
                horizonStart: today,
                horizonEnd: try today.adding(days: 30),
                createdAt: operation.completedAt
            )
            let proposal = try PlanningEngine().replan(
                input,
                previous: archive.currentDecision,
                trigger: .actionCompleted,
                decisionID: operation.planningDecisionID,
                originDeviceID: operation.originDeviceID
            )
            result.workspace = try ExecutionService().acceptReplan(
                proposal,
                in: result.workspace,
                eventID: operation.replanEventID,
                originDeviceID: operation.originDeviceID,
                at: operation.completedAt
            )
            result.currentDecisionID = operation.planningDecisionID
            let receipt = try NextStepBetaCompletionApplicationReceipt(
                operation: operation,
                baseArchive: archive,
                resultArchive: result
            )
            result.completionApplicationReceipts.append(receipt)
            result.completionApplicationReceipts.sort {
                $0.operationID < $1.operationID
            }
            try result.validate()
        } catch {
            throw NextStepBetaCompletionOperationError.replanningRejected(
                error.localizedDescription
            )
        }

        guard try isExactAppliedOperation(
            operation,
            archive: result
        ) else {
            throw NextStepBetaCompletionOperationError.replanningRejected(
                "derived completion records were not reproduced exactly"
            )
        }
        return NextStepBetaCompletionReplayResult(outcome: .applied, archive: result)
    }

    private func validateRecordCollisions(
        _ operation: NextStepBetaGuidedActionCompletionOperation,
        archive: NextStepBetaArchive
    ) throws {
        let responseByID = Dictionary(
            uniqueKeysWithValues: archive.workspace.userResponses.map {
                ($0.metadata.id, $0)
            }
        )
        for response in operation.referencedUserResponses {
            if let existing = responseByID[response.metadata.id], existing != response {
                throw NextStepBetaCompletionOperationError.conflictingUserResponse(
                    response.metadata.id
                )
            }
        }
        let evidenceByID = Dictionary(
            uniqueKeysWithValues: archive.workspace.completionEvidence.map {
                ($0.metadata.id, $0)
            }
        )
        for evidence in operation.completionEvidence {
            if let existing = evidenceByID[evidence.metadata.id], existing != evidence {
                throw NextStepBetaCompletionOperationError.conflictingCompletionEvidence(
                    evidence.metadata.id
                )
            }
        }
    }

    private func validateActionEvidenceSet(
        _ operation: NextStepBetaGuidedActionCompletionOperation,
        archive: NextStepBetaArchive
    ) throws {
        let supplied = Dictionary(uniqueKeysWithValues: operation.completionEvidence.map {
            ($0.metadata.id, $0)
        })
        for evidence in archive.workspace.completionEvidence
            where evidence.actionID == operation.actionID {
            if let matching = supplied[evidence.metadata.id] {
                guard matching == evidence else {
                    throw NextStepBetaCompletionOperationError.conflictingCompletionEvidence(
                        evidence.metadata.id
                    )
                }
                continue
            }
            // Only schema v1 permits earlier replayable quiz attempts as audit
            // history. Attestation-only v2 has exactly one evidence record, so
            // every other same-action record is a completion conflict.
            guard operation.isQuizBackedV1,
                  evidence.kind == .quizResult,
                  evidence.hasReplayableQuizResult,
                  evidence.packageID == operation.packageID,
                  evidence.packageVersion == operation.packageVersion else {
                throw NextStepBetaCompletionOperationError.conflictingActionCompletion(
                    operation.actionID
                )
            }
        }
    }

    private func rejectDerivedRecordCollisions(
        _ operation: NextStepBetaGuidedActionCompletionOperation,
        archive: NextStepBetaArchive
    ) throws {
        if archive.workspace.progressSnapshots.contains(where: {
            $0.metadata.id == operation.progressSnapshotID
        }) {
            throw NextStepBetaCompletionOperationError.derivedRecordConflict(
                kind: .progressSnapshot,
                id: operation.progressSnapshotID.rawValue
            )
        }
        if archive.workspace.planningDecisions.contains(where: {
            $0.metadata.id == operation.planningDecisionID
        }) {
            throw NextStepBetaCompletionOperationError.derivedRecordConflict(
                kind: .planningDecision,
                id: operation.planningDecisionID.rawValue
            )
        }
        if archive.workspace.replanEvents.contains(where: {
            $0.metadata.id == operation.replanEventID
        }) {
            throw NextStepBetaCompletionOperationError.derivedRecordConflict(
                kind: .replanEvent,
                id: operation.replanEventID.rawValue
            )
        }
        if archive.completionApplicationReceipts.contains(where: {
            $0.operationID == operation.operationID
        }) {
            throw NextStepBetaCompletionOperationError.conflictingApplicationReceipt(
                operation.operationID
            )
        }
    }

    private func isExactAppliedOperation(
        _ operation: NextStepBetaGuidedActionCompletionOperation,
        archive: NextStepBetaArchive
    ) throws -> Bool {
        guard let action = archive.workspace.dailyActions.first(where: {
            $0.metadata.id == operation.actionID
        }), action.status == .completed, action.completedAt == operation.completedAt else {
            return false
        }

        let responses = Dictionary(
            uniqueKeysWithValues: archive.workspace.userResponses.map {
                ($0.metadata.id, $0)
            }
        )
        guard operation.referencedUserResponses.allSatisfy({ response in
            responses[response.metadata.id] == response
        }) else { return false }

        let expectedEvidence = operation.completionEvidence
        let evidenceByID = Dictionary(
            uniqueKeysWithValues: archive.workspace.completionEvidence.map {
                ($0.metadata.id, $0)
            }
        )
        guard expectedEvidence.allSatisfy({ evidence in
            evidenceByID[evidence.metadata.id] == evidence
        }) else { return false }

        let progressMatches = archive.workspace.progressSnapshots.filter {
            $0.metadata.id == operation.progressSnapshotID
        }
        guard progressMatches.count == 1,
              let progress = progressMatches.first,
              progress.capturedAt == operation.completedAt,
              progress.metadata.createdAt == operation.completedAt,
              progress.metadata.originDeviceID == operation.originDeviceID,
              progress.metadata.provenance.kind == .deterministicEngine else { return false }

        let decisionMatches = archive.workspace.planningDecisions.filter {
            $0.metadata.id == operation.planningDecisionID
        }
        guard decisionMatches.count == 1,
              let decision = decisionMatches.first,
              decision.createdAt == operation.completedAt,
              decision.metadata.createdAt == operation.completedAt,
              decision.metadata.originDeviceID == operation.originDeviceID,
              decision.metadata.provenance.kind == .deterministicEngine,
              decision.engineVersion == PlanningEngine.version else { return false }

        let eventMatches = archive.workspace.replanEvents.filter {
            $0.metadata.id == operation.replanEventID
        }
        guard eventMatches.count == 1,
              let event = eventMatches.first,
              event.trigger == .actionCompleted,
              event.afterDecisionID == operation.planningDecisionID,
              event.resolution == .accepted,
              event.occurredAt == operation.completedAt,
              event.metadata.createdAt == operation.completedAt,
              event.metadata.originDeviceID == operation.originDeviceID,
              event.metadata.provenance.kind == .deterministicEngine else { return false }

        let receipts = archive.completionApplicationReceipts.filter {
            $0.operationID == operation.operationID
        }
        guard let receipt = receipts.first else {
            throw NextStepBetaCompletionOperationError.missingApplicationReceipt(
                operation.operationID
            )
        }
        guard receipts.count == 1, receipt.matches(operation) else {
            throw NextStepBetaCompletionOperationError.conflictingApplicationReceipt(
                operation.operationID
            )
        }
        try receipt.validate(in: archive)
        return true
    }
}
