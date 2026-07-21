import CryptoKit
import Foundation
import NextStepDomain
@testable import NextStepPersistence
@testable import NotesApp
import XCTest

final class NextStepBetaStoreTests: XCTestCase {
    @MainActor
    func testInitializationFailureRemainsStickyAndNeverWritesTemporaryFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-init-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = "Application Support unavailable"
        let model = NextStepBetaModel(
            store: NextStepBetaStore(rootURL: root),
            importer: NextStepBetaSourceImporter(applicationSupportRoot: root),
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            initialLoadFailure: failure
        )

        XCTAssertEqual(model.loadState, .failed(failure))
        await model.load()
        XCTAssertEqual(model.loadState, .failed(failure))
        XCTAssertNil(model.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAtomicRoundTripPreservesImmutableUserDeadline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        let deadline = try LocalDay(year: 2026, month: 12, day: 31)
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "完成論文口試",
            deadline: deadline,
            dailyMinutes: 45,
            to: archive,
            now: now
        )

        let store = NextStepBetaStore(rootURL: root)
        try await store.save(archive, replacing: nil)
        let loadedValue = try await store.load()
        let loaded = try XCTUnwrap(loadedValue)
        let persistedDeadline = try XCTUnwrap(loaded.workspace.ultimateGoals.first?.targetDay)

        XCTAssertEqual(persistedDeadline.value, deadline)
        XCTAssertEqual(persistedDeadline.authority, .userConfirmed)
        XCTAssertEqual(persistedDeadline.mutability, .immutable)
        XCTAssertEqual(persistedDeadline.confirmedAt, now)
        XCTAssertEqual(loaded.workspace.userProfile.maximumDailyMinutes, 45)

        let filenames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(filenames.contains(NextStepBetaStore.archiveFilename))
        XCTAssertTrue(filenames.contains(NextStepBetaSQLiteArchiveRepository.databaseFilename))
        XCTAssertFalse(filenames.contains { $0.contains("partial") || $0.hasSuffix(".tmp") })
    }

    func testStoredSourceResolverRejectsTraversal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NextStepBetaStore(rootURL: root)

        do {
            _ = try await store.resolveStoredSource(relativePath: "../outside.pdf")
            XCTFail("Traversal should be rejected")
        } catch let error as NextStepBetaStoreError {
            XCTAssertEqual(error, .unsafeStoredPath)
        }
    }

    func testV1ArchiveMigratesToCurrentSchemaWithEmptyGroundingState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-v1-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let original = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let currentData = try encoder.encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "grounding")
        let v1Data = try JSONSerialization.data(withJSONObject: object)
        let store = NextStepBetaStore(rootURL: root)

        let migrated = try await store.decodeArchiveForSync(v1Data)
        XCTAssertEqual(migrated.schemaVersion, NextStepBetaArchive.currentSchemaVersion)
        XCTAssertEqual(migrated.deviceID, original.deviceID)
        XCTAssertEqual(migrated.workspace, original.workspace)
        XCTAssertEqual(migrated.currentDecisionID, original.currentDecisionID)
        XCTAssertEqual(migrated.grounding, .empty)

        try await store.save(migrated, replacing: nil)
        let loaded = try await store.load()
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.grounding, .empty)
        XCTAssertEqual(reloaded.schemaVersion, NextStepBetaArchive.currentSchemaVersion)
    }

    func testLegacyJSONMigratesWithByteIdenticalBackupAndSQLiteWinsAfterCutover() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-legacy-cutover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let original = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "grounding")
        let legacyBytes = try JSONSerialization.data(withJSONObject: object)
        let legacyURL = root.appendingPathComponent(NextStepBetaStore.archiveFilename)
        try legacyBytes.write(to: legacyURL, options: .atomic)

        let store = NextStepBetaStore(rootURL: root)
        let migratedValue = try await store.load()
        let migrated = try XCTUnwrap(migratedValue)
        XCTAssertEqual(migrated.workspace, original.workspace)
        XCTAssertEqual(migrated.schemaVersion, NextStepBetaArchive.currentSchemaVersion)

        let backupURL = root
            .appendingPathComponent(
                NextStepBetaSQLiteArchiveRepository.migrationBackupDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                NextStepBetaSQLiteArchiveRepository.migrationBackupFilename
            )
        XCTAssertEqual(try Data(contentsOf: backupURL), legacyBytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                NextStepBetaSQLiteArchiveRepository.databaseFilename
            ).path
        ))

        // The JSON path is a non-authoritative mirror after cutover. A damaged
        // mirror must never replace or downgrade a valid SQLite projection.
        try Data("damaged-legacy-mirror".utf8).write(to: legacyURL, options: .atomic)
        let reopened = NextStepBetaStore(rootURL: root)
        let reloadedValue = try await reopened.load()
        let reloaded = try XCTUnwrap(reloadedValue)
        XCTAssertEqual(reloaded.schemaVersion, migrated.schemaVersion)
        XCTAssertEqual(reloaded.deviceID, migrated.deviceID)
        XCTAssertEqual(reloaded.workspace, migrated.workspace)
        XCTAssertEqual(reloaded.currentDecisionID, migrated.currentDecisionID)
        XCTAssertEqual(reloaded.grounding, migrated.grounding)

        let advanced = try NextStepBetaGoalBuilder().addGoal(
            title: "Post-migration goal",
            deadline: try LocalDay(year: 2028, month: 8, day: 31),
            dailyMinutes: 30,
            to: reloaded,
            now: now.addingTimeInterval(10)
        )
        try await reopened.save(advanced, replacing: reloaded)
        do {
            let raw = try SQLiteConnection(
                localDatabaseURL: root.appendingPathComponent(
                    NextStepBetaSQLiteArchiveRepository.databaseFilename
                )
            )
            XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM outbox_intents"), 0)
            XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM canonical_payloads"), 2)
            XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM migration_ledger"), 1)
            try raw.close()
        }
        let postSaveValue = try await NextStepBetaStore(rootURL: root).load()
        let postSave = try XCTUnwrap(postSaveValue)
        XCTAssertEqual(postSave.workspace.ultimateGoals.first?.title, "Post-migration goal")

        try Data("tampered-backup".utf8).write(to: backupURL, options: .atomic)
        do {
            _ = try await NextStepBetaStore(rootURL: root).load()
            XCTFail("A changed post-cutover migration backup must fail closed.")
        } catch {
            XCTAssertEqual(error as? NextStepBetaStoreError, .localPersistenceFailure)
        }

        try legacyBytes.write(to: backupURL, options: .atomic)
        try FileManager.default.removeItem(at: backupURL)
        do {
            _ = try await NextStepBetaStore(rootURL: root).load()
            XCTFail("A missing post-cutover migration backup must fail closed.")
        } catch {
            XCTAssertEqual(error as? NextStepBetaStoreError, .localPersistenceFailure)
        }
    }

    func testMismatchedCreateOnceMigrationBackupFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-backup-mismatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: Date(timeIntervalSince1970: 1_750_000_000),
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let source = try encoder.encode(archive)
        try source.write(
            to: root.appendingPathComponent(NextStepBetaStore.archiveFilename),
            options: .atomic
        )
        let backupDirectory = root.appendingPathComponent(
            NextStepBetaSQLiteArchiveRepository.migrationBackupDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: false
        )
        try Data("different-backup".utf8).write(
            to: backupDirectory.appendingPathComponent(
                NextStepBetaSQLiteArchiveRepository.migrationBackupFilename
            ),
            options: .atomic
        )

        let store = NextStepBetaStore(rootURL: root)
        do {
            _ = try await store.load()
            XCTFail("A changed create-once migration backup must fail closed.")
        } catch {
            XCTAssertEqual(error as? NextStepBetaStoreError, .localPersistenceFailure)
        }
    }

    func testMirrorFailureDoesNotUndoSQLiteCommitAndOutboxRepairsOnLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-mirror-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mirrorURL = root.appendingPathComponent(NextStepBetaStore.archiveFilename)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let base = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        let store = NextStepBetaStore(rootURL: root)
        try await store.save(base, replacing: nil)
        try FileManager.default.removeItem(at: mirrorURL)
        try FileManager.default.createDirectory(at: mirrorURL, withIntermediateDirectories: false)
        let changed = try NextStepBetaGoalBuilder().addGoal(
            title: "Mirror repair goal",
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            dailyMinutes: 30,
            to: base,
            now: now.addingTimeInterval(60)
        )

        // The canonical commit succeeds even though the compatibility path is
        // temporarily unpublishable.
        try await store.save(changed, replacing: base)
        let databaseURL = root.appendingPathComponent(
            NextStepBetaSQLiteArchiveRepository.databaseFilename
        )
        var inspector = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let committedProjection = try await inspector.loadProjection()
        let pendingAfterMirrorFailure = try await inspector.pendingOutbox(limit: 10)
        XCTAssertNotNil(committedProjection)
        XCTAssertEqual(pendingAfterMirrorFailure.count, 1)
        try await inspector.close()

        try FileManager.default.removeItem(at: mirrorURL)
        let loadedValue = try await store.load()
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.schemaVersion, changed.schemaVersion)
        XCTAssertEqual(loaded.deviceID, changed.deviceID)
        XCTAssertEqual(loaded.workspace, changed.workspace)
        XCTAssertEqual(loaded.currentDecisionID, changed.currentDecisionID)
        XCTAssertEqual(loaded.grounding, changed.grounding)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mirrorURL.path))

        inspector = try NextStepPersistenceStore(localDatabaseURL: databaseURL)
        let pendingAfterRepair = try await inspector.pendingOutbox(limit: 10)
        XCTAssertTrue(pendingAfterRepair.isEmpty)
        try await inspector.close()
    }

    func testAbandonedSourceStageDoesNotPoisonCreateOnceInstallation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-source-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = UUID()
        let sourceDirectory = root
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let abandonedStage = sourceDirectory.appendingPathComponent(
            ".nextstep-source-stage-interrupted.tmp"
        )
        try Data("partial orphan".utf8).write(to: abandonedStage, options: .atomic)

        let bytes = Data("complete verified source".utf8)
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let relativePath = "Sources/\(sourceID.uuidString)/original.pdf"
        let store = NextStepBetaStore(rootURL: root)
        try await store.installSyncedSource(
            bytes,
            relativePath: relativePath,
            expectedSHA256: digest
        )

        let installed = try await store.storedSourceData(relativePath: relativePath)
        XCTAssertEqual(installed, bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: abandonedStage.path))
    }

    func testTwoRepositoriesDoNotRefreshAndOverwriteAStaleProjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-adapter-cas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let base = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        let firstStore = NextStepBetaStore(rootURL: root)
        try await firstStore.save(base, replacing: nil)

        let secondStore = NextStepBetaStore(rootURL: root)
        let secondBaseValue = try await secondStore.load()
        let secondBase = try XCTUnwrap(secondBaseValue)
        let deadline = try LocalDay(year: 2027, month: 6, day: 30)
        let firstUpdate = try NextStepBetaGoalBuilder().addGoal(
            title: "First writer",
            deadline: deadline,
            dailyMinutes: 30,
            to: base,
            now: now.addingTimeInterval(1)
        )
        let staleUpdate = try NextStepBetaGoalBuilder().addGoal(
            title: "Stale writer",
            deadline: deadline,
            dailyMinutes: 45,
            to: secondBase,
            now: now.addingTimeInterval(1)
        )

        try await firstStore.save(firstUpdate, replacing: base)
        do {
            try await secondStore.save(staleUpdate, replacing: secondBase)
            XCTFail("A stale repository must not refresh its token and overwrite the winner.")
        } catch {
            XCTAssertEqual(error as? NextStepBetaStoreError, .localPersistenceFailure)
        }

        let verifier = NextStepBetaStore(rootURL: root)
        let winningValue = try await verifier.load()
        let winning = try XCTUnwrap(winningValue)
        XCTAssertEqual(winning.workspace.ultimateGoals.first?.title, "First writer")
        XCTAssertEqual(winning.workspace.userProfile.maximumDailyMinutes, 30)
    }

    func testOneRepositoryRejectsSequentialAndConcurrentStaleDerivedArchives() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-caller-cas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let base = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        let store = NextStepBetaStore(rootURL: root)
        try await store.save(base, replacing: nil)
        let deadline = try LocalDay(year: 2027, month: 12, day: 31)
        let sequentialWinner = try NextStepBetaGoalBuilder().addGoal(
            title: "Sequential winner",
            deadline: deadline,
            dailyMinutes: 25,
            to: base,
            now: now.addingTimeInterval(1)
        )
        let sequentialStale = try NextStepBetaGoalBuilder().addGoal(
            title: "Sequential stale",
            deadline: deadline,
            dailyMinutes: 35,
            to: base,
            now: now.addingTimeInterval(1)
        )
        try await store.save(sequentialWinner, replacing: base)
        do {
            try await store.save(sequentialStale, replacing: base)
            XCTFail("A later call derived from the old archive must fail CAS.")
        } catch {
            XCTAssertEqual(error as? NextStepBetaStoreError, .localPersistenceFailure)
        }

        let concurrentBaseValue = try await store.load()
        let concurrentBase = try XCTUnwrap(concurrentBaseValue)
        let candidateA = try replacingGoalTitle(
            in: concurrentBase,
            title: "Concurrent A",
            now: now.addingTimeInterval(2)
        )
        let candidateB = try replacingGoalTitle(
            in: concurrentBase,
            title: "Concurrent B",
            now: now.addingTimeInterval(2)
        )
        async let resultA = Self.attemptSave(
            store: store,
            archive: candidateA,
            replacing: concurrentBase,
            label: "Concurrent A"
        )
        async let resultB = Self.attemptSave(
            store: store,
            archive: candidateB,
            replacing: concurrentBase,
            label: "Concurrent B"
        )
        let firstResult = await resultA
        let secondResult = await resultB
        let winners = [firstResult, secondResult].compactMap { $0 }
        XCTAssertEqual(winners.count, 1)

        let finalValue = try await store.load()
        let finalArchive = try XCTUnwrap(finalValue)
        XCTAssertEqual(finalArchive.workspace.ultimateGoals.first?.title, winners.first)
    }

    func testRepeatedMirrorPublicationsKeepSQLiteRetentionBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-bounded-retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let store = NextStepBetaStore(rootURL: root)
        var current = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        try await store.save(current, replacing: nil)
        let withGoal = try NextStepBetaGoalBuilder().addGoal(
            title: "Retention 0",
            deadline: try LocalDay(year: 2028, month: 1, day: 31),
            dailyMinutes: 20,
            to: current,
            now: now.addingTimeInterval(1)
        )
        try await store.save(withGoal, replacing: current)
        current = withGoal

        for index in 1 ... 20 {
            let updated = try replacingGoalTitle(
                in: current,
                title: "Retention \(index)",
                now: now.addingTimeInterval(Double(index + 1))
            )
            try await store.save(updated, replacing: current)
            current = updated
        }

        let databaseURL = root.appendingPathComponent(
            NextStepBetaSQLiteArchiveRepository.databaseFilename
        )
        let raw = try SQLiteConnection(localDatabaseURL: databaseURL)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM outbox_intents"), 0)
        XCTAssertEqual(try raw.scalarInt64("SELECT COUNT(*) FROM canonical_payloads"), 1)
        try raw.close()
    }

    private func replacingGoalTitle(
        in archive: NextStepBetaArchive,
        title: String,
        now: Date
    ) throws -> NextStepBetaArchive {
        var updated = archive
        guard updated.workspace.ultimateGoals.isEmpty == false else {
            throw NextStepBetaStoreError.localPersistenceFailure
        }
        updated.workspace.ultimateGoals[0].title = title
        updated.workspace.revision += 1
        updated.workspace.savedAt = now
        try updated.validate()
        return updated
    }

    private static func attemptSave(
        store: NextStepBetaStore,
        archive: NextStepBetaArchive,
        replacing expectedArchive: NextStepBetaArchive,
        label: String
    ) async -> String? {
        do {
            try await store.save(archive, replacing: expectedArchive)
            return label
        } catch {
            return nil
        }
    }
}
