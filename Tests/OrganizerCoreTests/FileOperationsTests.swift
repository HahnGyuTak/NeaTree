import Foundation
import Testing
@testable import OrganizerCore

private struct MoveFixture {
    let root: URL
    let downloads: URL
    let archive: URL
    let state: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        downloads = root.appendingPathComponent("Downloads")
        archive = root.appendingPathComponent("Archive")
        state = root.appendingPathComponent("State")
        for directory in [downloads, archive, state] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func engine(exactSources: [URL] = []) throws -> MoveEngine {
        try MoveEngine(
            sourceRoots: [downloads], destinationRoots: [archive],
            stateDirectory: state, exactSources: exactSources
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func writeText(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func readText(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

@Test func fileMoveCanBeUndoneAfterReopeningTheJournal() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    let source = fixture.downloads.appendingPathComponent("untitled.txt")
    let target = fixture.archive.appendingPathComponent("summary.txt")
    try writeText("Review notes", to: source)
    let engine = try fixture.engine()
    let fingerprint = try await engine.fingerprint(of: source)
    let record = try await engine.apply(MoveRequest(
        source: source, destinationDirectory: fixture.archive,
        proposedName: "summary.txt", expectedFingerprint: fingerprint
    ))

    #expect(record.state == .applied)
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try readText(target) == "Review notes")
    let reopened = try fixture.engine()
    let restored = try await reopened.undo(id: record.id)
    #expect(restored.state == .undone)
    #expect(try readText(source) == "Review notes")
    #expect(!FileManager.default.fileExists(atPath: target.path))
    let history = try await reopened.history()
    #expect(history.map(\.state) == [.undone])
}

@Test func destinationCollisionAndExtensionChangeLeaveBothFilesIntact() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    let source = fixture.downloads.appendingPathComponent("original.txt")
    let existing = fixture.archive.appendingPathComponent("report.txt")
    try writeText("new bytes", to: source)
    try writeText("existing bytes", to: existing)
    let engine = try fixture.engine()
    let fingerprint = try await engine.fingerprint(of: source)

    do {
        _ = try await engine.apply(MoveRequest(
            source: source, destinationDirectory: fixture.archive,
            proposedName: "report.txt", expectedFingerprint: fingerprint
        ))
        Issue.record("Expected a destination collision.")
    } catch FileOperationError.pathOccupied {
        #expect(try readText(existing) == "existing bytes")
    }
    do {
        _ = try await engine.apply(MoveRequest(
            source: source, destinationDirectory: fixture.archive,
            proposedName: "original.pdf", expectedFingerprint: fingerprint
        ))
        Issue.record("Expected the extension change to be rejected.")
    } catch FileOperationError.changedExtension {
        #expect(try readText(source) == "new bytes")
    }
}

@Test func numberingFillsGapsAndCoordinatesConcurrentApplies() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    for name in ["report-01.txt", "report-03.txt"] {
        try writeText("existing", to: fixture.archive.appendingPathComponent(name))
    }
    let firstEngine = try fixture.engine()
    let secondEngine = try fixture.engine()
    var requests: [MoveRequest] = []
    for (index, allocation) in [SerialAllocation.fillGap, .appendMax, .appendMax].enumerated() {
        let source = fixture.downloads.appendingPathComponent("incoming-\(index).txt")
        try writeText("original \(index)", to: source)
        let fingerprint = try await firstEngine.fingerprint(of: source)
        requests.append(MoveRequest(
            source: source, destinationDirectory: fixture.archive,
            proposedName: "report-{serial}.txt", expectedFingerprint: fingerprint,
            serial: SerialPolicy(width: 2, allocation: allocation)
        ))
    }
    let gap = try await firstEngine.apply(requests[0])
    #expect(gap.destination.lastPathComponent == "report-02.txt")

    let firstRequest = requests[1]
    let secondRequest = requests[2]
    async let first = firstEngine.apply(firstRequest)
    async let second = secondEngine.apply(secondRequest)
    let records = try await [first, second]
    #expect(Set(records.map { $0.destination.lastPathComponent }) == ["report-04.txt", "report-05.txt"])
    #expect(Set(try records.map { try readText($0.destination) }) == ["original 1", "original 2"])
}

@Test func numberingRecognizesCanonicallyEquivalentKoreanFilenames() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    let first = fixture.archive.appendingPathComponent("메모-001.txt".decomposedStringWithCanonicalMapping)
    try writeText("existing", to: first)
    let engine = try fixture.engine()

    let firstSource = fixture.downloads.appendingPathComponent("first.txt")
    try writeText("new", to: firstSource)
    let firstFingerprint = try await engine.fingerprint(of: firstSource)
    let appended = try await engine.apply(MoveRequest(
        source: firstSource, destinationDirectory: fixture.archive,
        proposedName: "메모-{serial}.txt", expectedFingerprint: firstFingerprint,
        serial: SerialPolicy(width: 3, allocation: .appendMax)
    ))
    #expect(appended.destination.lastPathComponent == "메모-002.txt")

    let fourth = fixture.archive.appendingPathComponent("메모-004.txt".decomposedStringWithCanonicalMapping)
    try writeText("another existing", to: fourth)
    let secondSource = fixture.downloads.appendingPathComponent("second.txt")
    try writeText("gap", to: secondSource)
    let secondFingerprint = try await engine.fingerprint(of: secondSource)
    let filled = try await engine.apply(MoveRequest(
        source: secondSource, destinationDirectory: fixture.archive,
        proposedName: "메모-{serial}.txt", expectedFingerprint: secondFingerprint,
        serial: SerialPolicy(width: 3, allocation: .fillGap)
    ))
    #expect(filled.destination.lastPathComponent == "메모-003.txt")
    #expect(try readText(first) == "existing")
    #expect(try readText(fourth) == "another existing")
}

@Test func numberedPrefixSharesDirectorySequenceAcrossTitlesAndExtensions() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    let existing = fixture.archive.appendingPathComponent("001_계약서.pdf".decomposedStringWithCanonicalMapping)
    try writeText("existing", to: existing)
    try writeText("other series", to: fixture.archive.appendingPathComponent("009-메모.txt"))
    try writeText("different width", to: fixture.archive.appendingPathComponent("0008_메모.txt"))
    let source = fixture.downloads.appendingPathComponent("incoming.txt")
    try writeText("new", to: source)
    let engine = try fixture.engine()
    let fingerprint = try await engine.fingerprint(of: source)
    let record = try await engine.apply(MoveRequest(
        source: source, destinationDirectory: fixture.archive,
        proposedName: "{serial}_견적서.txt", expectedFingerprint: fingerprint,
        serial: SerialPolicy(width: 3, allocation: .appendMax)
    ))
    #expect(record.destination.lastPathComponent == "002_견적서.txt")
    #expect(try readText(existing) == "existing")
}

@Test func folderFingerprintIncludesNestedNamesAndBytes() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    let source = fixture.downloads.appendingPathComponent("bundle")
    let nested = source.appendingPathComponent("assets")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let originalFile = nested.appendingPathComponent("notes.md")
    let renamedFile = nested.appendingPathComponent("minutes.md")
    try writeText("notes", to: originalFile)
    let engine = try fixture.engine()
    let old = try await engine.fingerprint(of: source)
    try FileManager.default.moveItem(at: originalFile, to: renamedFile)
    do {
        _ = try await engine.apply(MoveRequest(
            source: source, destinationDirectory: fixture.archive,
            proposedName: "Workshop", expectedFingerprint: old
        ))
        Issue.record("Expected a nested rename to invalidate the proposal.")
    } catch FileOperationError.sourceChanged {
        #expect(try readText(renamedFile) == "notes")
    }
    let current = try await engine.fingerprint(of: source)
    let record = try await engine.apply(MoveRequest(
        source: source, destinationDirectory: fixture.archive,
        proposedName: "Workshop", expectedFingerprint: current
    ))
    let movedFile = record.destination.appendingPathComponent("assets").appendingPathComponent("minutes.md")
    #expect(try readText(movedFile) == "notes")
    try await engine.undo(id: record.id)
    #expect(try readText(renamedFile) == "notes")
}

@Test func explicitImportsAuthorizeOneItemAndSurviveEngineRestart() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    let outside = fixture.root.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let imported = outside.appendingPathComponent("selected.txt")
    let sibling = outside.appendingPathComponent("unselected.txt")
    try writeText("chosen", to: imported)
    try writeText("other", to: sibling)

    let engine = try fixture.engine(exactSources: [imported])
    let fingerprint = try await engine.fingerprint(of: imported)
    do {
        _ = try await engine.fingerprint(of: sibling)
        Issue.record("An explicit import must not grant access to its siblings.")
    } catch FileOperationError.outsideAllowedRoots { }
    let record = try await engine.apply(MoveRequest(
        source: imported, destinationDirectory: fixture.archive,
        proposedName: "notes.txt", expectedFingerprint: fingerprint
    ))
    let reopened = try fixture.engine(exactSources: [imported])
    try await reopened.undo(id: record.id)
    #expect(try readText(imported) == "chosen")
    #expect(try readText(sibling) == "other")
}

@Test func escapingPathsAndNestedSymlinksAreRejected() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    let source = fixture.downloads.appendingPathComponent("report.txt")
    try writeText("original", to: source)
    let outside = fixture.root.appendingPathComponent("Outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let alias = fixture.archive.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)

    let engine = try fixture.engine()
    let fingerprint = try await engine.fingerprint(of: source)
    do {
        _ = try await engine.apply(MoveRequest(
            source: source, destinationDirectory: alias,
            proposedName: "report.txt", expectedFingerprint: fingerprint
        ))
        Issue.record("The destination alias leaves the selected root.")
    } catch FileOperationError.symbolicLink { }
    do {
        _ = try await engine.apply(MoveRequest(
            source: source, destinationDirectory: fixture.archive,
            proposedName: "../Outside/report.txt", expectedFingerprint: fingerprint
        ))
        Issue.record("A proposed file name must be a single path component.")
    } catch FileOperationError.invalidFilename { }

    let group = fixture.downloads.appendingPathComponent("group")
    try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: group.appendingPathComponent("inside"), withDestinationURL: outside
    )
    do {
        _ = try await engine.fingerprint(of: group)
        Issue.record("A nested symlink must be rejected before reviewing a folder.")
    } catch FileOperationError.symbolicLink { }
    #expect(try readText(source) == "original")
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test func undoRejectsAnOccupiedOriginalPathAndModifiedDestination() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    let source = fixture.downloads.appendingPathComponent("notes.txt")
    try writeText("original", to: source)
    let engine = try fixture.engine()
    let fingerprint = try await engine.fingerprint(of: source)
    let record = try await engine.apply(MoveRequest(
        source: source, destinationDirectory: fixture.archive,
        proposedName: "notes.txt", expectedFingerprint: fingerprint
    ))

    try writeText("new item", to: source)
    do {
        _ = try await engine.undo(id: record.id)
        Issue.record("Undo must not replace a new item at the original path.")
    } catch FileOperationError.pathOccupied {
        #expect(try readText(source) == "new item")
        #expect(try readText(record.destination) == "original")
    }
    try FileManager.default.removeItem(at: source)
    try writeText("modified", to: record.destination)
    do {
        _ = try await engine.undo(id: record.id)
        Issue.record("Undo must not move a changed destination.")
    } catch FileOperationError.destinationChanged {
        #expect(try readText(record.destination) == "modified")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
    let history = try await engine.history()
    #expect(history.map(\.state) == [.applied])
}

@Test func pendingJournalCanReconcileACompletedRename() async throws {
    let fixture = try MoveFixture()
    defer { fixture.cleanUp() }
    let source = fixture.downloads.appendingPathComponent("report.txt")
    try writeText("original", to: source)
    let engine = try fixture.engine()
    let fingerprint = try await engine.fingerprint(of: source)
    let applied = try await engine.apply(MoveRequest(
        source: source, destinationDirectory: fixture.archive,
        proposedName: "report.txt", expectedFingerprint: fingerprint
    ))

    let journal = fixture.state.appendingPathComponent("operations.json")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: journal))
    var entries = try #require(json as? [[String: Any]])
    entries[0]["state"] = "pending"
    try JSONSerialization.data(withJSONObject: entries).write(to: journal, options: [.atomic])

    let reopened = try fixture.engine()
    let pending = try await reopened.history()
    #expect(pending.map(\.state) == [.pending])
    let recovered = try await reopened.recoverPending()
    #expect(recovered.map(\.state) == [.applied])
    #expect(recovered.map(\.id) == [applied.id])
    #expect(try readText(applied.destination) == "original")
}
