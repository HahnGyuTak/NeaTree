import Foundation
import OrganizerCore
import Testing
@testable import OrganizerAppSupport

@Suite("Application consent and file lifecycle")
@MainActor
struct OrganizerAppModelTests {
    @Test func openingConfiguredAppDoesNotScanOrAnalyzeWithoutOptIn() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let recorder = CallRecorder()
        let model = try await fixture.model(recorder: recorder)
        defer { model.stop() }
        await model.start()

        #expect(model.settings != nil)
        #expect(model.entries.isEmpty)
        #expect(!model.watching)
        #expect(!model.automaticallyAnalyze)
        #expect(recorder.analysisCalls == 0)

        await model.scanNow()
        await model.scanNow()
        #expect(model.entries.count == 1)
        #expect(model.entries.first?.status == .ready)
        #expect(recorder.analysisCalls == 0)
    }

    @Test func startupRepairsCommittedMoveWhoseInboxUpdateWasInterrupted() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let service = try OrganizerService(stateDirectory: fixture.state)
        try await service.configure(downloads: fixture.downloads, roots: [fixture.archive])
        let entry = try await service.importItem(fixture.file)
        let competingInbox = try InboxStore(stateDirectory: fixture.state.appendingPathComponent("inbox"))
        try await competingInbox.setStatus(id: entry.id, status: .held)
        let folder = try #require(await service.configuration().folders.first)
        do {
            _ = try await service.apply(id: entry.id, name: "recovered.txt", folderID: folder.id)
            Issue.record("Expected a committed move with an interrupted inbox update")
        } catch OrganizerServiceError.operationCommitted { }

        let recorder = CallRecorder()
        let model = try OrganizerAppModel(stateDirectory: fixture.state, demo: false, dependencies: recorder.dependencies)
        defer { model.stop() }
        await model.start()

        let recovered = try #require(model.entries.first)
        let record = try #require(model.history.last)
        #expect(recovered.status == .applied)
        #expect(record.state == .applied)
        #expect(model.actualURL(for: recovered) == record.destination)
        #expect(try Data(contentsOf: record.destination) == Data("original content".utf8))
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(!model.watching)
        #expect(recorder.analysisCalls == 0)
        #expect(model.errorMessage == nil)
    }

    @Test func failedAutomaticAnalysisIsNotRepeatedForSameFileAcrossRestart() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let recorder = CallRecorder()
        let model = try await fixture.model(recorder: recorder)
        await model.start()
        model.setAutomaticAnalysis(true)
        await model.scanNow()
        await model.scanNow()
        #expect(recorder.analysisCalls == 1)
        #expect(model.errorMessage != nil)
        for _ in 0..<3 { await model.scanNow() }
        #expect(recorder.analysisCalls == 1)
        model.stop()

        let reopened = try OrganizerAppModel(stateDirectory: fixture.state, demo: false, dependencies: recorder.dependencies, settleInterval: 0)
        defer { reopened.stop() }
        await reopened.start()
        await reopened.scanNow()
        #expect(recorder.analysisCalls == 1)
        let id = try #require(reopened.entries.first?.id)
        await reopened.analyze(id)
        #expect(recorder.analysisCalls == 2) // A deliberate retry is allowed.

        try Data("changed content".utf8).write(to: fixture.file)
        await reopened.scanNow()
        await reopened.scanNow()
        #expect(recorder.analysisCalls == 3) // New bytes are a new analysis opportunity.
        let preferences = try String(contentsOf: fixture.state.appendingPathComponent("preferences.json"), encoding: .utf8)
        #expect(!preferences.contains("dummy-test-key"))
    }

    @Test func demoUsesIsolatedFilesAndNeverReadsOrChangesCredentials() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let recorder = CallRecorder()
        let model = try OrganizerAppModel(stateDirectory: fixture.state, demo: true, dependencies: recorder.dependencies)
        defer { model.stop(); try? FileManager.default.removeItem(at: model.stateDirectory.deletingLastPathComponent()) }
        await model.start()
        #expect(model.stateDirectory != fixture.state)
        #expect(model.entries.count == 2)
        #expect(!model.hasAPIKey)
        #expect(recorder.keyReads == 0)

        let entry = try #require(model.entries.first)
        await model.analyze(entry.id)
        await model.saveAPIKey("must-not-be-saved")
        await model.deleteAPIKey()
        #expect(recorder.keyReads == 0)
        #expect(recorder.keyWrites == 0)
        #expect(recorder.keyDeletes == 0)
        #expect(recorder.analysisCalls == 0)
        #expect(try Data(contentsOf: fixture.file) == Data("original content".utf8))
    }

    @Test func editedApplyAndUndoUseRealCoreAndRefreshBothViews() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let recorder = CallRecorder()
        let model = try await fixture.model(recorder: recorder)
        defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.file])
        let entry = try #require(model.entries.first)
        let folder = try #require(model.settings?.folders.first)
        await model.hold(entry.id)
        #expect(model.entries.first?.status == .held)
        await model.apply(id: entry.id, name: "수정한 문서.txt", folderID: folder.id)
        let moved = try #require(model.entries.first)
        let operation = try #require(model.history.last)
        #expect(moved.status == .applied)
        #expect(operation.state == .applied)
        #expect(model.actualURL(for: moved) == operation.destination)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(try Data(contentsOf: operation.destination) == Data("original content".utf8))

        await model.undo(operation.id)
        #expect(model.entries.first?.status == .held)
        #expect(model.history.last?.state == .undone)
        #expect(try Data(contentsOf: fixture.file) == Data("original content".utf8))
        #expect(!model.isBusy)
        #expect(recorder.analysisCalls == 0)
    }

    @Test func missingSourceCannotBeAppliedFromOldEditedFields() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let model = try await fixture.model(recorder: CallRecorder())
        defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.file])
        let entry = try #require(model.entries.first)
        let folder = try #require(model.settings?.folders.first)
        try Data("new bytes after review".utf8).write(to: fixture.file)
        await model.apply(id: entry.id, name: "edited.txt", folderID: folder.id)
        #expect(model.errorMessage != nil)
        #expect(model.history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.archive.appendingPathComponent("edited.txt").path))
    }

    @Test func unclassifiedUsesActualMovedURLAndCanBeRevisited() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let model = try await fixture.model(recorder: CallRecorder())
        defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.file])
        let entry = try #require(model.entries.first)
        await model.sendToUnclassified(entry.id)
        let moved = try #require(model.entries.first)
        #expect(moved.status == .unclassified)
        #expect(model.actualURL(for: moved).deletingLastPathComponent().lastPathComponent == "미분류")
        await model.revisit(entry.id)
        let revisited = try #require(model.selectedEntry)
        #expect(revisited.status == .ready)
        #expect(revisited.id != entry.id)
        // The journal uses physical paths while Foundation may return /var and
        // decomposed Korean names. Compare the filesystem object, not URL bytes.
        let revisitedAttributes = try FileManager.default.attributesOfItem(atPath: model.actualURL(for: revisited).path)
        let movedAttributes = try FileManager.default.attributesOfItem(atPath: model.actualURL(for: moved).path)
        let revisitedInode = try #require(revisitedAttributes[.systemFileNumber] as? NSNumber)
        let movedInode = try #require(movedAttributes[.systemFileNumber] as? NSNumber)
        let revisitedDevice = try #require(revisitedAttributes[.systemNumber] as? NSNumber)
        let movedDevice = try #require(movedAttributes[.systemNumber] as? NSNumber)
        #expect(revisitedInode == movedInode && revisitedDevice == movedDevice)
    }

    @Test func backgroundRefreshCannotMakeAnOldDraftApplyToNewBytes() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let model = try await fixture.model(recorder: CallRecorder())
        defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.file])
        let reviewed = try #require(model.entries.first)
        let folder = try #require(model.settings?.folders.first)
        try Data("replacement after the editor opened".utf8).write(to: fixture.file)
        await model.scanNow()
        await model.scanNow()
        #expect(model.entries.first?.fingerprint != reviewed.fingerprint)
        await model.apply(id: reviewed.id, name: "old-draft.txt", folderID: folder.id, reviewedFingerprint: reviewed.fingerprint)
        #expect(model.errorMessage != nil)
        #expect(model.history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func networkFailurePausesAutomaticAnalysisAndKeepsItsErrorVisible() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        try Data("second file".utf8).write(to: fixture.downloads.appendingPathComponent("second.txt"))
        let recorder = CallRecorder(failure: .httpFailure(statusCode: 429))
        let model = try await fixture.model(recorder: recorder)
        defer { model.stop() }
        await model.start()
        model.setAutomaticAnalysis(true)
        await model.scanNow()
        await model.scanNow()
        #expect(recorder.analysisCalls == 1)
        #expect(!model.automaticallyAnalyze)
        let failure = try #require(model.errorMessage)
        await model.scanNow()
        #expect(recorder.analysisCalls == 1)
        #expect(model.errorMessage == failure)
    }

    @Test func holdingDuringAnalysisCancelsTheRequestAndPreservesHeldState() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let service = try OrganizerService(stateDirectory: fixture.state)
        try await service.configure(downloads: fixture.downloads, roots: [fixture.archive])
        let probe = CancellationProbe()
        var dependencies = CallRecorder().dependencies
        dependencies.analyzeFile = { _, _, _ in try await probe.perform() }
        let model = try OrganizerAppModel(stateDirectory: fixture.state, demo: false, dependencies: dependencies)
        defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.file])
        let id = try #require(model.entries.first?.id)
        var proposals = 0
        model.onProposalReady = { _ in proposals += 1 }
        let analysis = Task { await model.analyze(id) }
        try await probe.waitForStart()
        await model.hold(id)
        await analysis.value
        #expect(await probe.wasCancelled)
        #expect(model.entries.first?.status == .held)
        #expect(model.errorMessage == nil)
        #expect(!model.isBusy)
        #expect(proposals == 0)
    }
}

private struct ModelFixture {
    let root: URL
    let downloads: URL
    let archive: URL
    let state: URL
    let file: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OrganizerModelTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        downloads = root.appendingPathComponent("Downloads")
        archive = root.appendingPathComponent("Documents")
        state = root.appendingPathComponent("State")
        file = downloads.appendingPathComponent("original.txt")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("original content".utf8).write(to: file)
    }
    @MainActor func model(recorder: CallRecorder) async throws -> OrganizerAppModel {
        let service = try OrganizerService(stateDirectory: state, settleInterval: 0)
        try await service.configure(downloads: downloads, roots: [archive])
        return try OrganizerAppModel(stateDirectory: state, demo: false, dependencies: recorder.dependencies, settleInterval: 0)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var analyses = 0
    private var reads = 0
    private var writes = 0
    private var deletes = 0
    private let failure: OpenAIClientError
    init(failure: OpenAIClientError = .invalidProposal) { self.failure = failure }
    var analysisCalls: Int { lock.withLock { analyses } }
    var keyReads: Int { lock.withLock { reads } }
    var keyWrites: Int { lock.withLock { writes } }
    var keyDeletes: Int { lock.withLock { deletes } }
    var dependencies: AppModelDependencies {
        AppModelDependencies(
            readKey: { self.lock.withLock { self.reads += 1 }; return "dummy-test-key" },
            saveKey: { _ in self.lock.withLock { self.writes += 1 } },
            deleteKey: { self.lock.withLock { self.deletes += 1 } },
            analyzeFile: { _, _, _ in
                self.lock.withLock { self.analyses += 1 }
                throw self.failure
            }
        )
    }
}

private actor CancellationProbe {
    private var started = false
    private(set) var wasCancelled = false

    func perform() async throws -> FileProposal {
        started = true
        do {
            try await Task.sleep(for: .seconds(5))
            throw OpenAIClientError.transportFailure
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }

    func waitForStart() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !started {
            guard ContinuousClock.now < deadline else { throw OpenAIClientError.transportFailure }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
