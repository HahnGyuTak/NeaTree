import XCTest
@testable import OrganizerCore

@MainActor
final class CatalogInboxTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let downloads: URL
        let state: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("OrganizerCatalogTests-" + UUID().uuidString)
                .resolvingSymlinksInPath()
            downloads = root.appendingPathComponent("Downloads")
            state = root.appendingPathComponent("State")
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, text: String = "내용") throws -> URL {
            let url = downloads.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
    }

    func testCatalogHasStableIdentifiersAndSkipsLinksHiddenAndPackages() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let project = f.downloads.appendingPathComponent("Project")
        let hidden = f.downloads.appendingPathComponent(".private")
        let bundle = f.downloads.appendingPathComponent("App.app")
        for directory in [project, hidden, bundle] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let document = project.appendingPathComponent("계약서.txt")
        try Data("계약서".utf8).write(to: document)
        try FileManager.default.createSymbolicLink(at: f.downloads.appendingPathComponent("External"), withDestinationURL: f.root)
        let first = try CatalogBuilder.scan(roots: [f.downloads])
        let second = try CatalogBuilder.scan(roots: [f.downloads])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first(where: { $0.path == project.path })?.sampleNames, ["계약서.txt"])
        XCTAssertFalse(first.contains { $0.path.contains("External") || $0.path.contains(".private") || $0.path.hasSuffix("App.app") })
        XCTAssertEqual(try CatalogBuilder.scan(roots: [f.downloads], maxFolders: 1).count, 1)
    }

    func testInspectorReportsPartialTextAndUnsupportedBinaryWithoutPretending() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let large = try f.file("large.txt", text: String(repeating: "a", count: 180_000))
        let partial = try FileInspector.inspect(large)
        XCTAssertEqual(partial.extractedText.count, 131_072)
        XCTAssertEqual(partial.readStatus, "partial_text")
        let binary = f.downloads.appendingPathComponent("archive.zip")
        try Data([0, 1, 2, 3, 4]).write(to: binary)
        let unsupported = try FileInspector.inspect(binary)
        XCTAssertEqual(unsupported.readStatus, "unsupported")
        XCTAssertEqual(unsupported.extractedText, "")
    }

    func testCanonicalUnicodePathsShareFileAndFolderIdentifiers() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let composedName = "메모".precomposedStringWithCanonicalMapping
        let decomposedName = composedName.decomposedStringWithCanonicalMapping
        let folderNFC = f.downloads.appendingPathComponent(composedName)
        let folderNFD = f.downloads.appendingPathComponent(decomposedName)
        try FileManager.default.createDirectory(at: folderNFC, withIntermediateDirectories: true)
        let fileNFC = folderNFC.appendingPathComponent(composedName + ".txt")
        let fileNFD = folderNFD.appendingPathComponent(decomposedName + ".txt")
        try Data("정리할 문서".utf8).write(to: fileNFC)
        // Foundation may return NFD from URL.path for either spelling on APFS.
        XCTAssertNotEqual(Array(composedName.utf8), Array(decomposedName.utf8))
        let composedEvidence = try FileInspector.inspect(fileNFC)
        let decomposedEvidence = try FileInspector.inspect(fileNFD)
        XCTAssertEqual(composedEvidence.id, decomposedEvidence.id)
        let composedCatalog = try CatalogBuilder.scan(roots: [folderNFC])
        let decomposedCatalog = try CatalogBuilder.scan(roots: [folderNFD])
        XCTAssertEqual(composedCatalog.first?.id, decomposedCatalog.first?.id)
        let parentCatalog = try CatalogBuilder.scan(roots: [f.downloads])
        XCTAssertEqual(parentCatalog.first(where: { $0.path == folderNFC.path })?.id, composedCatalog.first?.id)
    }

    func testDownloadRequiresStableObservationsAndChangedBytesRestartTimer() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = try f.file("report.txt", text: "first")
        let store = try InboxStore(stateDirectory: f.state, settleInterval: 2)
        let start = Date(timeIntervalSince1970: 10_000)
        let first = try await store.poll(downloads: f.downloads, now: start)
        let second = try await store.poll(downloads: f.downloads, now: start.addingTimeInterval(1))
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        try Data("other".utf8).write(to: file)
        let changed = try await store.poll(downloads: f.downloads, now: start.addingTimeInterval(2))
        XCTAssertTrue(changed.isEmpty)
        let notYet = try await store.poll(downloads: f.downloads, now: start.addingTimeInterval(3))
        XCTAssertTrue(notYet.isEmpty)
        let ready = try await store.poll(downloads: f.downloads, now: start.addingTimeInterval(4))
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.status, .ready)
        let repeated = try await store.poll(downloads: f.downloads, now: start.addingTimeInterval(8))
        XCTAssertTrue(repeated.isEmpty)
    }

    func testPollingExcludesPartialHiddenUnclassifiedAndConfiguredExtensions() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        for name in ["archive.zip.crdownload", "download.part", ".hidden", "installer.dmg", "report.txt"] {
            _ = try f.file(name)
        }
        try FileManager.default.createDirectory(at: f.downloads.appendingPathComponent("미분류"), withIntermediateDirectories: true)
        let store = try InboxStore(stateDirectory: f.state, settleInterval: 0, excludedExtensions: ["DMG"])
        _ = try await store.poll(downloads: f.downloads)
        let ready = try await store.poll(downloads: f.downloads)
        let entries = await store.entries()
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(entries.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["report.txt"])
    }

    func testHoldAndAppliedStateSurviveRestartWithoutRepeatedSuggestions() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let heldURL = try f.file("held.txt")
        let appliedURL = try f.file("applied.txt")
        let store = try InboxStore(stateDirectory: f.state, settleInterval: 0)
        let held = try await store.add(url: heldURL)
        let applied = try await store.add(url: appliedURL)
        try await store.setStatus(id: held.id, status: .held, note: "사용자가 보류")
        try await store.setStatus(id: applied.id, status: .applied)
        let reopened = try InboxStore(stateDirectory: f.state, settleInterval: 0)
        let ready = try await reopened.poll(downloads: f.downloads)
        let entries = await reopened.entries()
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(entries.first(where: { $0.id == held.id })?.status, .held)
        XCTAssertEqual(entries.first(where: { $0.id == applied.id })?.status, .applied)
    }

    func testFolderIsOneUnitAndLateNestedChangesRestartStability() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let folder = f.downloads.appendingPathComponent("자료")
        let nested = folder.appendingPathComponent("첨부")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: nested.appendingPathComponent("one.txt"))
        let store = try InboxStore(stateDirectory: f.state, settleInterval: 2)
        let t = Date(timeIntervalSince1970: 20_000)
        _ = try await store.poll(downloads: f.downloads, now: t)
        try Data("two".utf8).write(to: nested.appendingPathComponent("two.txt"))
        let changed = try await store.poll(downloads: f.downloads, now: t.addingTimeInterval(3))
        XCTAssertTrue(changed.isEmpty)
        let ready = try await store.poll(downloads: f.downloads, now: t.addingTimeInterval(5))
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.path, folder.path)
        XCTAssertEqual(try FileInspector.inspect(folder).kind, "folder")
        let entries = await store.entries()
        XCTAssertEqual(entries.count, 1)
    }

    func testDeletedPendingItemCannotBecomeReady() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = try f.file("gone.txt")
        let store = try InboxStore(stateDirectory: f.state, settleInterval: 0)
        _ = try await store.poll(downloads: f.downloads)
        try FileManager.default.removeItem(at: file)
        let ready = try await store.poll(downloads: f.downloads)
        let entries = await store.entries()
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(entries.first?.status, .missing)
    }

    func testSymlinkImportIsRejectedAndReplacementInvalidatesReadyItem() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let real = try f.file("original.txt")
        let link = f.downloads.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try FileInspector.inspect(link))
        let store = try InboxStore(stateDirectory: f.state)
        do {
            _ = try await store.add(url: link)
            XCTFail("Symlink accepted")
        } catch { XCTAssertTrue(error is CatalogError) }
        let entry = try await store.add(url: real)
        try FileManager.default.removeItem(at: real)
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: f.root)
        _ = try await store.poll(downloads: f.downloads)
        let entries = await store.entries()
        XCTAssertEqual(entries.first(where: { $0.id == entry.id })?.status, .failed)
    }

    func testProposalIsRejectedWhenFileChangesDuringAnalysis() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = try f.file("report.txt", text: "original")
        let store = try InboxStore(stateDirectory: f.state)
        let entry = try await store.add(url: file)
        let evidence = try FileInspector.inspect(file)
        let proposal = FileProposal(fileID: evidence.id, status: "ready", destinationFolderID: nil,
                                    proposedName: "report.txt", reason: "example", evidence: [], alternatives: [], missingInformation: [])
        try Data("changed".utf8).write(to: file)
        do {
            try await store.recordProposal(id: entry.id, proposal: proposal)
            XCTFail("Stale proposal accepted")
        } catch { XCTAssertTrue(error is InboxError) }
        let entries = await store.entries()
        XCTAssertNil(entries.first?.proposal)
    }

    func testConcurrentStoreDoesNotOverwriteNewerHoldState() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = try f.file("report.txt")
        let first = try InboxStore(stateDirectory: f.state)
        let entry = try await first.add(url: file)
        let stale = try InboxStore(stateDirectory: f.state)
        try await first.setStatus(id: entry.id, status: .held)
        do {
            try await stale.setStatus(id: entry.id, status: .applied)
            XCTFail("Stale store overwrote a newer decision")
        } catch { XCTAssertTrue(error is InboxError) }
        let reopened = try InboxStore(stateDirectory: f.state)
        let saved = await reopened.entries()
        XCTAssertEqual(saved.first?.status, .held)
    }
}
