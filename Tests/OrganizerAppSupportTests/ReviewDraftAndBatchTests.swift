import Foundation
import Testing
@testable import OrganizerCore
@testable import OrganizerAppSupport

@Suite("Durable review and sequential batch actions")
@MainActor
struct ReviewDraftAndBatchTests {
    @Test func deliberateBlankEditsSurviveRestartAndCannotBeApplied() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let model = try await fixture.model()
        await model.start()
        await model.importFiles([fixture.first])
        let entry = try #require(model.entries.first)
        var draft = try #require(model.prepareDraft(entry.id))
        draft.name = "{serial}_검토한 이름.txt"
        draft.serialWidth = 3
        draft.fillGaps = true
        draft.learnForFuture = true
        model.saveDraft(draft)
        var blank = draft
        blank.name = "   "
        blank.folderID = ""
        model.saveDraft(blank)
        await model.scanNow()
        await model.refresh()
        #expect(model.draft(for: entry.id) == blank)
        await model.applyDraft(entry.id)
        #expect(model.errorMessage != nil)
        #expect(model.history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.first.path))
        model.stop()

        let restarted = try OrganizerAppModel(stateDirectory: fixture.state, demo: false, dependencies: fixture.dependencies, settleInterval: 0)
        defer { restarted.stop() }
        await restarted.start()
        #expect(restarted.draft(for: entry.id) == blank)
        #expect(!restarted.isDraftStale(blank))
        restarted.saveDraft(draft)
        #expect(restarted.draft(for: entry.id) == draft)
        #expect(await fixture.probe.calls == 0)
    }

    @Test func legacyPreferencesDecodeWithoutDraftFields() throws {
        let data = Data(#"{"version":1,"watchEnabled":true,"automaticAnalysis":false,"attemptedFingerprints":{"old":"snapshot"}}"#.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(preferences.reviewDrafts.isEmpty)
        #expect(preferences.watchEnabled)
        #expect(preferences.attemptedFingerprints["old"] == "snapshot")
    }

    @Test func ruleAndFileChangesRequireExplicitDraftReview() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let model = try await fixture.model(); defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.first])
        let entry = try #require(model.entries.first)
        let draft = try #require(model.prepareDraft(entry.id))
        await model.createRule(folderID: draft.folderID, instruction: "텍스트 문서는 이 폴더에 정리한다.")
        #expect(model.isDraftStale(draft))
        await model.applyDraft(entry.id)
        #expect(model.errorMessage != nil)
        #expect(model.history.isEmpty)
        #expect(model.draft(for: entry.id) == draft)

        let reviewed = try #require(model.prepareDraft(entry.id, reset: true))
        #expect(!model.isDraftStale(reviewed))
        var delayedOldBinding = draft
        delayedOldBinding.name = "old binding must not replace the newer review.txt"
        model.saveDraft(delayedOldBinding)
        #expect(model.draft(for: entry.id) == reviewed)
        try Data("new contents after review".utf8).write(to: fixture.first)
        await model.scanNow()
        await model.scanNow()
        #expect(model.isDraftStale(reviewed))
        let results = await model.applyBatch([entry.id])
        #expect(results.first?.succeeded == false)
        #expect(model.history.isEmpty)
        #expect(try String(contentsOf: fixture.first, encoding: .utf8) == "new contents after review")
    }

    @Test func aNewProposalDoesNotReplaceTheProposalTheDraftReviewed() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let model = try await fixture.model(); defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.first])
        let entry = try #require(model.entries.first)
        await model.analyze(entry.id)
        var draft = try #require(model.prepareDraft(entry.id))
        draft.name = "my-edit.txt"
        model.saveDraft(draft)
        await model.analyze(entry.id)
        #expect(model.draft(for: entry.id) == draft)
        #expect(model.isDraftStale(draft))
        await model.applyDraft(entry.id)
        #expect(model.history.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.first.path))
    }

    @Test func batchPreservesConflictsAndContinuesWithIndependentItems() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let model = try await fixture.model(); defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.first, fixture.second])
        let ids = model.entries.map(\.id)
        let reviewed = await model.reviewBatch(ids)
        #expect(reviewed.allSatisfy { $0.succeeded })
        for id in ids {
            var draft = try #require(model.draft(for: id))
            draft.name = id == ids[0] ? "occupied.txt" : "completed.txt"
            model.saveDraft(draft)
        }
        let occupied = fixture.archive.appendingPathComponent("occupied.txt")
        try Data("keep this original".utf8).write(to: occupied)
        let results = await model.applyBatch(ids)
        #expect(results.map(\.succeeded) == [false, true])
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "keep this original")
        #expect(FileManager.default.fileExists(atPath: fixture.first.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.second.path))
        #expect(model.draft(for: ids[0]) != nil)
        #expect(model.draft(for: ids[1]) == nil)
        #expect(await fixture.probe.calls == 0)
    }

    @Test func serialBatchAllocatesSequentiallyAndUndoRetainsConflictingOriginal() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let model = try await fixture.model(); defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.first, fixture.second])
        let ids = model.entries.map(\.id)
        _ = await model.reviewBatch(ids)
        for id in ids {
            var draft = try #require(model.draft(for: id))
            draft.name = "report-{serial}.txt"
            draft.serialWidth = 3
            model.saveDraft(draft)
        }
        let applied = await model.applyBatch(ids)
        #expect(applied.allSatisfy { $0.succeeded })
        #expect(model.history.map { $0.destination.lastPathComponent } == ["report-001.txt", "report-002.txt"])
        #expect(model.reviewDrafts.isEmpty)
        let records = model.history.map(\.id)
        try Data("new original path occupant".utf8).write(to: fixture.first)
        let undone = await model.undoBatch(records)
        #expect(undone.map(\.succeeded) == [false, true])
        #expect(try String(contentsOf: fixture.first, encoding: .utf8) == "new original path occupant")
        #expect(try String(contentsOf: fixture.second, encoding: .utf8) == "second contents")
        #expect(await fixture.probe.calls == 0)
    }

    @Test func removingSerialTemplateKeepsWidthPreferenceButAppliesFixedName() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let model = try await fixture.model(); defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.first])
        let entry = try #require(model.entries.first)
        var draft = try #require(model.prepareDraft(entry.id))
        draft.name = "report-{serial}.txt"
        draft.serialWidth = 3
        draft.fillGaps = true
        model.saveDraft(draft)
        draft.name = "fixed-report.txt"
        model.saveDraft(draft)
        #expect(model.draft(for: entry.id)?.serialWidth == 3)
        await model.applyDraft(entry.id)
        #expect(model.errorMessage == nil)
        #expect(model.history.last?.destination.lastPathComponent == "fixed-report.txt")
        #expect(!FileManager.default.fileExists(atPath: fixture.first.path))
        #expect(try String(contentsOf: fixture.archive.appendingPathComponent("fixed-report.txt"), encoding: .utf8) == "first contents")
    }

    @Test func batchRequiresSavedDraftsAndNeverUsesLearningAPI() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let model = try await fixture.model(); defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.first, fixture.second])
        let ids = model.entries.map(\.id)
        var first = try #require(model.prepareDraft(ids[0]))
        first.learnForFuture = true
        model.saveDraft(first)
        let results = await model.applyBatch(ids)
        #expect(results.map(\.succeeded) == [false, false])
        #expect(model.draft(for: ids[1]) == nil)
        #expect(model.history.isEmpty)
        #expect(await fixture.probe.calls == 0)
    }

    @Test func busyAnalysisRejectsBatchWithoutMutatingFilesAndCanStillBeHeld() async throws {
        let fixture = try DraftFixture(blockAnalysis: true); defer { fixture.remove() }
        let model = try await fixture.model(); defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.first])
        let entry = try #require(model.entries.first)
        _ = model.prepareDraft(entry.id)
        let analysis = Task { await model.analyze(entry.id) }
        try await fixture.probe.waitForStart()
        let results = await model.applyBatch([entry.id])
        #expect(results.first?.succeeded == false)
        #expect(model.isBusy)
        #expect(model.history.isEmpty)
        await model.hold(entry.id)
        await analysis.value
        #expect(model.entries.first?.status == .held)
        #expect(!model.isBusy)
        #expect(FileManager.default.fileExists(atPath: fixture.first.path))
    }

    @Test func heldAndUnclassifiedBatchesReportEverySelectedItem() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        let model = try await fixture.model(); defer { model.stop() }
        await model.start()
        await model.importFiles([fixture.first, fixture.second])
        let ids = model.entries.map(\.id)
        _ = await model.reviewBatch(ids)
        let held = await model.holdBatch(ids + [UUID()])
        #expect(held.map(\.succeeded) == [true, true, false])
        #expect(model.reviewDrafts.count == 2)
        try Data("changed after review".utf8).write(to: fixture.first)
        let moved = await model.sendToUnclassifiedBatch(ids)
        #expect(moved.map(\.succeeded) == [false, true])
        #expect(model.draft(for: ids[0]) != nil)
        #expect(model.draft(for: ids[1]) == nil)
        #expect(await fixture.probe.calls == 0)
    }

    @Test func actualWatcherStabilizesNewFileAndPresentsOneProposalWithoutRepeatingHeldItem() async throws {
        let fixture = try DraftFixture(); defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.first)
        try FileManager.default.removeItem(at: fixture.second)
        let model = try await fixture.model(); defer { model.stop() }
        await model.start()
        var proposals: [UUID] = []
        model.onProposalReady = { proposals.append($0) }
        model.setAutomaticAnalysis(true)
        model.setWatching(true)
        try Data("a newly downloaded file".utf8).write(to: fixture.first)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while proposals.isEmpty {
            guard ContinuousClock.now < deadline else {
                Issue.record("The actual watcher did not deliver a stable-file proposal within five seconds")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let id = try #require(proposals.first)
        // Wait for the callback's enclosing model operation to finish before hold.
        while model.isBusy {
            guard ContinuousClock.now < deadline else { throw OpenAIClientError.transportFailure }
            try await Task.sleep(for: .milliseconds(5))
        }
        await model.hold(id)
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(proposals == [id])
        #expect(model.entries.first?.status == .held)
        #expect(await fixture.probe.calls == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.first.path))
    }
}

private struct DraftFixture {
    let root: URL
    let downloads: URL
    let archive: URL
    let state: URL
    let first: URL
    let second: URL
    let probe: DraftAnalysisProbe

    init(blockAnalysis: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DraftTests-\(UUID())")
        downloads = root.appendingPathComponent("Downloads")
        archive = root.appendingPathComponent("Archive")
        state = root.appendingPathComponent("State")
        first = downloads.appendingPathComponent("first.txt")
        second = downloads.appendingPathComponent("second.txt")
        probe = DraftAnalysisProbe(block: blockAnalysis)
        for directory in [downloads, archive] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("first contents".utf8).write(to: first)
        try Data("second contents".utf8).write(to: second)
    }

    var dependencies: AppModelDependencies {
        AppModelDependencies(keyIsConfigured: { true }, readKey: { "test-key" }, saveKey: { _ in }, deleteKey: { }, analyzeFile: { service, id, key in
            let number = try await probe.begin()
            let entry = try #require(await service.entries().first { $0.id == id })
            let evidence = try await FileInspector.inspectAsync(URL(fileURLWithPath: entry.path))
            let folder = try #require(await service.configuration().folders.first)
            let proposal = FileProposal(fileID: evidence.id, status: "ready", destinationFolderID: folder.id, proposedName: "proposal-\(number).txt", reason: "Mock analysis", evidence: [], alternatives: [], missingInformation: [])
            let encoded = try JSONEncoder().encode(proposal)
            let response = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "status": "completed", "phase": "final_answer", "content": [["type": "output_text", "text": String(decoding: encoded, as: UTF8.self)]]]]])
            let client = OpenAIClient(apiKey: key, transport: { request in
                (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            return try await service.propose(id: id, client: client)
        })
    }

    @MainActor func model() async throws -> OrganizerAppModel {
        let service = try OrganizerService(stateDirectory: state, settleInterval: 0)
        try await service.configure(downloads: downloads, roots: [archive])
        return try OrganizerAppModel(stateDirectory: state, demo: false, dependencies: dependencies, settleInterval: 0)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor DraftAnalysisProbe {
    private(set) var calls = 0
    let block: Bool
    init(block: Bool) { self.block = block }

    func begin() async throws -> Int {
        calls += 1
        if block { try await Task.sleep(for: .seconds(20)) }
        return calls
    }

    func waitForStart() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while calls == 0 {
            guard ContinuousClock.now < deadline else { throw OpenAIClientError.transportFailure }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
