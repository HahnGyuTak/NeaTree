import Foundation
import OrganizerCore
import Testing
@testable import OrganizerAppSupport

@Suite("Psilo semantic work and recovery")
@MainActor
struct PsiloActivityTests {
    @Test func watcherPollAndStartupDoNotActLikeCharacterWork() async throws {
        let fixture = try PsiloFixture()
        defer { fixture.remove() }
        let model = try await fixture.configuredModel()
        defer { model.stop() }
        await model.start()
        let idle = model.psiloActivity
        await model.scanNow()
        await model.scanNow()
        await model.refresh()
        #expect(model.psiloActivity == idle)
        #expect(model.psiloActivity.phase == .idle)
        #expect(model.psiloIssue == nil)
    }

    @Test func proposalAndCommittedMoveHaveDifferentSuccessOutcomes() async throws {
        let model = try OrganizerAppModel(stateDirectory: URL(fileURLWithPath: "/unused"), demo: true)
        defer { model.stop(); try? FileManager.default.removeItem(at: model.stateDirectory.deletingLastPathComponent()) }
        await model.start()
        let entry = try #require(model.entries.first { URL(fileURLWithPath: $0.path).pathExtension == "txt" })
        let folder = try #require(model.settings?.folders.first)
        await model.analyze(entry.id)
        #expect(model.psiloActivity.phase == .succeeded)
        #expect(model.psiloActivity.outcome == .proposalReady)
        let analysisID = model.psiloActivity.id
        await model.apply(id: entry.id, name: "psilo-organized.txt", folderID: folder.id)
        #expect(model.psiloActivity.id != analysisID)
        #expect(model.psiloActivity.kind == .organizing)
        #expect(model.psiloActivity.outcome == .filesApplied)
        let record = try #require(model.history.last)
        await model.undo(record.id)
        #expect(model.psiloActivity.kind == .undo)
        #expect(model.psiloActivity.outcome == .restored)
    }

    @Test func dismissingFailureAlertDoesNotResolveIssueButSuccessfulRetryDoes() async throws {
        let model = try OrganizerAppModel(stateDirectory: URL(fileURLWithPath: "/unused"), demo: true)
        defer { model.stop(); try? FileManager.default.removeItem(at: model.stateDirectory.deletingLastPathComponent()) }
        await model.start()
        let entry = try #require(model.entries.first)
        let folder = try #require(model.settings?.folders.first)
        await model.apply(id: entry.id, name: "", folderID: folder.id)
        let issue = try #require(model.psiloIssue)
        #expect(model.psiloActivity.phase == .failed)
        #expect(model.errorMessage != nil)
        model.errorMessage = nil
        await model.refresh()
        await model.scanNow()
        #expect(model.psiloIssue == issue)
        await model.apply(id: entry.id, name: "retry-success.txt", folderID: folder.id)
        #expect(model.psiloActivity.outcome == .filesApplied)
        #expect(model.psiloIssue == nil)
    }

    @Test func partialBatchFailureDoesNotCelebrateAsFullSuccess() async throws {
        let model = try OrganizerAppModel(stateDirectory: URL(fileURLWithPath: "/unused"), demo: true)
        defer { model.stop(); try? FileManager.default.removeItem(at: model.stateDirectory.deletingLastPathComponent()) }
        await model.start()
        let entries = model.entries
        #expect(entries.count == 2)
        _ = model.prepareDraft(entries[0].id)
        var invalid = try #require(model.prepareDraft(entries[1].id))
        invalid.name = ""
        model.saveDraft(invalid)
        let results = await model.applyBatch(entries.map(\.id))
        #expect(results.filter(\.succeeded).count == 1)
        #expect(model.psiloActivity.phase == .failed)
        #expect(model.psiloActivity.outcome == .partialFailure)
        #expect(model.psiloActivity.completed == 1)
        #expect(model.psiloActivity.total == 2)
        #expect(model.psiloIssue != nil)
    }

    @Test func cancelledAnalysisReturnsWithoutSuccessOrIssue() async throws {
        let fixture = try PsiloFixture()
        defer { fixture.remove() }
        let model = try await fixture.configuredModel()
        defer { model.stop() }
        await model.start()
        let entry = try #require(model.entries.first)
        await model.analyze(entry.id)
        #expect(model.psiloActivity.kind == .fileAnalysis)
        #expect(model.psiloActivity.phase == .cancelled)
        #expect(model.psiloActivity.outcome == nil)
        #expect(model.psiloIssue == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func staleResponsesCannotReplaceCurrentWorkAndUnrelatedSuccessDoesNotResolveIssue() {
        var tracker = PsiloActivityTracker()
        let failed = tracker.begin(.organizing)
        tracker.fail(failed, message: "destination unavailable")
        let issue = tracker.issue
        let superseded = tracker.begin(.fileAnalysis)
        let current = tracker.begin(.structureAnalysis)
        tracker.succeed(superseded, outcome: .proposalReady)
        #expect(tracker.activity.id == current)
        #expect(tracker.activity.phase == .working)
        tracker.succeed(current, outcome: .rulesReady)
        #expect(tracker.issue == issue)
        let retry = tracker.begin(.organizing)
        tracker.succeed(retry, outcome: .filesApplied)
        tracker.fail(failed, message: "late failure")
        #expect(tracker.activity.id == retry)
        #expect(tracker.activity.phase == .succeeded)
        #expect(tracker.issue == nil)
    }

    @Test func successfulMoveOfAnotherFileDoesNotResolveFailedFile() {
        var tracker = PsiloActivityTracker()
        let failedFile = UUID(), otherFile = UUID()
        let failed = tracker.begin(.organizing, subjectIDs: [failedFile])
        tracker.fail(failed, message: "name collision")
        let unrelated = tracker.begin(.organizing, subjectIDs: [otherFile])
        tracker.succeed(unrelated, outcome: .filesApplied)
        #expect(tracker.issue?.subjectIDs == [failedFile])
        let retry = tracker.begin(.organizing, subjectIDs: [failedFile])
        tracker.succeed(retry, outcome: .filesApplied)
        #expect(tracker.issue == nil)
    }

    @Test func failedBatchResolvesAcrossSeparateSuccessfulFileRetries() throws {
        var tracker = PsiloActivityTracker()
        let first = UUID(), second = UUID(), unrelated = UUID()
        let batch = tracker.begin(.organizing, total: 2, subjectIDs: [first, second])
        tracker.fail(batch, message: "two files need attention")
        let original = try #require(tracker.issue)

        let retryFirst = tracker.begin(.organizing, subjectIDs: [first])
        tracker.succeed(retryFirst, outcome: .filesApplied)
        #expect(tracker.issue?.subjectIDs == [second])
        #expect(tracker.issue?.id == original.id)
        #expect(tracker.issue?.operationID == original.operationID)
        #expect(tracker.issue?.message == original.message)

        let otherMove = tracker.begin(.organizing, subjectIDs: [unrelated])
        tracker.succeed(otherMove, outcome: .filesApplied)
        #expect(tracker.issue?.subjectIDs == [second])

        let retrySecond = tracker.begin(.organizing, subjectIDs: [second])
        tracker.succeed(retrySecond, outcome: .filesApplied)
        #expect(tracker.issue == nil)
    }

    @Test func failedRetryOfOneBatchFileDoesNotForgetOtherPendingFiles() throws {
        var tracker = PsiloActivityTracker()
        let first = UUID(), second = UUID(), unattempted = UUID()
        let batch = tracker.begin(.organizing, total: 3, subjectIDs: [first, second, unattempted])
        tracker.fail(batch, message: "three files need attention")
        let original = try #require(tracker.issue)

        let failedRetry = tracker.begin(.organizing, subjectIDs: [first])
        tracker.fail(failedRetry, message: "first file still unavailable")
        #expect(tracker.issue?.subjectIDs == [first, second, unattempted])
        #expect(tracker.issue?.id == original.id)

        let retry = tracker.begin(.organizing, total: 2, subjectIDs: [first, second])
        tracker.fail(retry, message: "only second file failed", partial: true,
                     completed: 1, failedSubjectIDs: [second])
        #expect(tracker.issue?.subjectIDs == [second, unattempted])
        let finish = tracker.begin(.organizing, subjectIDs: [second])
        tracker.succeed(finish, outcome: .filesApplied)
        #expect(tracker.issue?.subjectIDs == [unattempted])
        let finishLast = tracker.begin(.organizing, subjectIDs: [unattempted])
        tracker.succeed(finishLast, outcome: .filesApplied)
        #expect(tracker.issue == nil)
    }

    @Test func wholeOperationIssueClearsOnSuccessfulSameKindRetry() {
        var tracker = PsiloActivityTracker()
        let failed = tracker.begin(.structureAnalysis)
        tracker.fail(failed, message: "structure analysis failed")
        let retry = tracker.begin(.structureAnalysis)
        tracker.succeed(retry, outcome: .rulesReady)
        #expect(tracker.issue == nil)
    }
}

private struct PsiloFixture {
    let root: URL
    var state: URL { root.appendingPathComponent("state") }
    var downloads: URL { root.appendingPathComponent("Downloads") }
    var archive: URL { root.appendingPathComponent("Archive") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PsiloTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    @MainActor func configuredModel() async throws -> OrganizerAppModel {
        let file = downloads.appendingPathComponent("sample.txt")
        try Data("sample document".utf8).write(to: file)
        let service = try OrganizerService(stateDirectory: state, settleInterval: 0)
        try await service.configure(downloads: downloads, roots: [archive])
        _ = try await service.importItem(file)
        return try OrganizerAppModel(stateDirectory: state, demo: false, dependencies: AppModelDependencies(
            readKey: { "dummy-local-test-key" }, saveKey: { _ in }, deleteKey: { },
            analyzeFile: { _, _, _ in throw CancellationError() }
        ), settleInterval: 0)
    }
}
