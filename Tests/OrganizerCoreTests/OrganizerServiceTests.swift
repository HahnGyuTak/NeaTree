import Foundation
import Testing
@testable import OrganizerCore

private struct ServiceFixture {
    let base: URL
    let downloads: URL
    let archive: URL
    let state: URL
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("organizer-integration-\(UUID())")
        downloads = base.appendingPathComponent("Downloads")
        archive = base.appendingPathComponent("Archive")
        state = base.appendingPathComponent("State")
        for url in [downloads, archive] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Test func manualImportEditedApplyAndUndoSurviveRestart() async throws {
    let fixture = try ServiceFixture(); defer { fixture.cleanup() }
    let source = fixture.base.appendingPathComponent("outside.txt")
    try Data("계약 관련 메모".utf8).write(to: source)
    let service = try OrganizerService(stateDirectory: fixture.state)
    try await service.configure(downloads: fixture.downloads, roots: [fixture.archive])
    let entry = try await service.importItem(source)
    let folder = try #require(await service.configuration().folders.first { $0.path == fixture.archive.path })
    let moved = try await service.apply(id: entry.id, name: "001_수정한이름.txt", folderID: folder.id)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: moved.destination, encoding: .utf8) == "계약 관련 메모")
    let restarted = try OrganizerService(stateDirectory: fixture.state)
    let undone = try await restarted.undo(recordID: moved.id)
    #expect(undone.state == .undone)
    #expect(try String(contentsOf: source, encoding: .utf8) == "계약 관련 메모")
    #expect(await restarted.entries().first?.status == .held)
}

@Test func unclassifiedDoesNotReenterDownloadQueue() async throws {
    let fixture = try ServiceFixture(); defer { fixture.cleanup() }
    let source = fixture.downloads.appendingPathComponent("불명.txt")
    try Data("???".utf8).write(to: source)
    let service = try OrganizerService(stateDirectory: fixture.state, settleInterval: 0)
    try await service.configure(downloads: fixture.downloads, roots: [fixture.archive])
    let entry = try await service.importItem(source)
    let record = try await service.sendToUnclassified(id: entry.id)
    #expect(record.destination.deletingLastPathComponent().lastPathComponent == "미분류")
    #expect(try await service.scanDownloads().isEmpty)
    #expect(try await service.scanDownloads().isEmpty)
    #expect(await service.entries().count == 1)
    #expect(await service.entries().first?.status == .unclassified)
    _ = try await service.undo(recordID: record.id)
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func manualEditCannotMoveToUnlistedFolderOrStaleSource() async throws {
    let fixture = try ServiceFixture(); defer { fixture.cleanup() }
    let source = fixture.downloads.appendingPathComponent("original.txt")
    try Data("before".utf8).write(to: source)
    let service = try OrganizerService(stateDirectory: fixture.state)
    try await service.configure(downloads: fixture.downloads, roots: [fixture.archive])
    let entry = try await service.importItem(source)
    await #expect(throws: (any Error).self) {
        _ = try await service.apply(id: entry.id, name: "changed.txt", folderID: "/tmp")
    }
    let folder = try #require(await service.configuration().folders.first)
    try Data("after".utf8).write(to: source)
    await #expect(throws: (any Error).self) {
        _ = try await service.apply(id: entry.id, name: "changed.txt", folderID: folder.id)
    }
    #expect(try String(contentsOf: source, encoding: .utf8) == "after")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.archive.path).isEmpty)
}

@Test func unclassifiedCanBeExplicitlyRevisitedAtItsActualLocation() async throws {
    let fixture = try ServiceFixture(); defer { fixture.cleanup() }
    let source = fixture.downloads.appendingPathComponent("unknown.txt")
    try Data("later".utf8).write(to: source)
    let service = try OrganizerService(stateDirectory: fixture.state)
    try await service.configure(downloads: fixture.downloads, roots: [fixture.archive])
    let entry = try await service.importItem(source)
    let record = try await service.sendToUnclassified(id: entry.id)
    let revisited = try await service.revisit(id: entry.id)
    #expect(revisited.path == record.destination.standardizedFileURL.path)
    #expect(revisited.status == .ready)
    let folder = try #require(await service.configuration().folders.first)
    let moved = try await service.apply(id: revisited.id, name: "known.txt", folderID: folder.id)
    #expect(try String(contentsOf: moved.destination, encoding: .utf8) == "later")
}

@Test func invalidUnclassifiedFolderDoesNotDisableNormalMoves() async throws {
    let fixture = try ServiceFixture(); defer { fixture.cleanup() }
    let source = fixture.downloads.appendingPathComponent("source.txt")
    try Data("content".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: fixture.downloads.appendingPathComponent("미분류"), withDestinationURL: fixture.archive)
    let service = try OrganizerService(stateDirectory: fixture.state)
    try await service.configure(downloads: fixture.downloads, roots: [fixture.archive])
    let entry = try await service.importItem(source)
    await #expect(throws: (any Error).self) { _ = try await service.sendToUnclassified(id: entry.id) }
    let folder = try #require(await service.configuration().folders.first)
    let result = try await service.apply(id: entry.id, name: "source.txt", folderID: folder.id)
    #expect(result.state == .applied)
}

@Test func committedMoveIsReportedAndReconciledAfterInboxConflict() async throws {
    let fixture = try ServiceFixture(); defer { fixture.cleanup() }
    let source = fixture.downloads.appendingPathComponent("source.txt")
    try Data("content".utf8).write(to: source)
    let service = try OrganizerService(stateDirectory: fixture.state)
    try await service.configure(downloads: fixture.downloads, roots: [fixture.archive])
    let entry = try await service.importItem(source)
    let otherInbox = try InboxStore(stateDirectory: fixture.state.appendingPathComponent("inbox"))
    try await otherInbox.setStatus(id: entry.id, status: .held)
    let folder = try #require(await service.configuration().folders.first)
    do {
        _ = try await service.apply(id: entry.id, name: "source.txt", folderID: folder.id)
        Issue.record("Expected an explicitly reported committed operation")
    } catch OrganizerServiceError.operationCommitted { }
    #expect(!FileManager.default.fileExists(atPath: source.path))
    let reopened = try OrganizerService(stateDirectory: fixture.state)
    let journal = try await reopened.reconcileHistory()
    #expect(await reopened.entries().first?.status == .applied)
    let record = try #require(journal.first)
    _ = try await reopened.undo(recordID: record.id)
    #expect(FileManager.default.fileExists(atPath: source.path))
}
