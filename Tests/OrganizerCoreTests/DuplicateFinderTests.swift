import XCTest
@testable import OrganizerCore

@MainActor
final class DuplicateFinderTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("OrganizerDuplicateTests-" + UUID().uuidString)
                .standardizedFileURL
            destination = root.appendingPathComponent("Documents")
            source = root.appendingPathComponent("original.txt")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("same bytes".utf8).write(to: source)
        }
        var folder: FolderRecord { FolderRecord(id: "folder", path: destination.path, sampleNames: []) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, content: String = "same bytes") throws -> URL {
            let url = destination.appendingPathComponent(name)
            try Data(content.utf8).write(to: url)
            return url
        }
    }

    func testDifferentNameMatchesIdenticalBytesAndSameNameDifferentBytesDoesNot() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let duplicate = try f.file("renamed.bin")
        let sameName = try f.file("original.txt", content: "other data")
        let report = try DuplicateFinder.find(for: f.source, in: [f.folder])
        XCTAssertEqual(report.matches, [duplicate.path])
        XCTAssertEqual(report.checkedCount, 2)
        XCTAssertEqual(report.skippedCount, 0)
        XCTAssertFalse(report.truncated)
        XCTAssertEqual(try String(contentsOf: f.source, encoding: .utf8), "same bytes")
        XCTAssertEqual(try String(contentsOf: sameName, encoding: .utf8), "other data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: duplicate.path))
    }

    func testSourceAndRepeatedCatalogFolderAreNotDoubleCounted() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let rootRecord = FolderRecord(id: "root", path: f.root.path, sampleNames: [])
        let duplicate = f.root.appendingPathComponent("copy.txt")
        try Data("same bytes".utf8).write(to: duplicate)
        let report = try DuplicateFinder.find(for: f.source, in: [rootRecord, rootRecord])
        XCTAssertEqual(report.matches, [duplicate.path])
        XCTAssertEqual(report.checkedCount, 1)
        XCTAssertFalse(report.truncated)
    }

    func testOnlyExplicitFolderDirectChildrenAreSearched() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let nested = f.destination.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let duplicate = nested.appendingPathComponent("copy.txt")
        try Data("same bytes".utf8).write(to: duplicate)
        let shallow = try DuplicateFinder.find(for: f.source, in: [f.folder])
        XCTAssertEqual(shallow.matches, [])
        XCTAssertEqual(shallow.checkedCount, 0)
        let nestedRecord = FolderRecord(id: "nested", path: nested.path, sampleNames: [])
        let explicit = try DuplicateFinder.find(for: f.source, in: [f.folder, nestedRecord])
        XCTAssertEqual(explicit.matches, [duplicate.path])
        XCTAssertEqual(explicit.checkedCount, 1)
    }

    func testLimitReportsIncompleteComparisonHonestly() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try f.file("a.txt", content: "different")
        _ = try f.file("z.txt")
        let report = try DuplicateFinder.find(for: f.source, in: [f.folder], maximumFiles: 1)
        XCTAssertTrue(report.matches.isEmpty)
        XCTAssertEqual(report.checkedCount, 1)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertTrue(report.truncated)
        let zero = try DuplicateFinder.find(for: f.source, in: [f.folder], maximumFiles: 0)
        XCTAssertEqual(zero.checkedCount, 0)
        XCTAssertTrue(zero.truncated)
    }

    func testLinksAndHiddenFilesAreExcluded() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try f.file(".hidden")
        let symlink = f.destination.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: f.source)
        let report = try DuplicateFinder.find(for: f.source, in: [f.folder])
        XCTAssertTrue(report.matches.isEmpty)
        XCTAssertEqual(report.checkedCount, 0)
        XCTAssertEqual(report.skippedCount, 2)
        XCTAssertFalse(report.truncated)
        XCTAssertThrowsError(try DuplicateFinder.find(for: symlink, in: [f.folder]))
    }

    func testFolderSourceThrowsInsteadOfClaimingNoDuplicates() throws {
        let f = try Fixture(); defer { f.cleanup() }
        XCTAssertThrowsError(try DuplicateFinder.find(for: f.destination, in: [f.folder])) { error in
            guard case DuplicateFinderError.unsupportedSource = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMissingFolderProducesIncompleteReport() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let missing = FolderRecord(id: "missing", path: f.root.appendingPathComponent("missing").path, sampleNames: [])
        let report = try DuplicateFinder.find(for: f.source, in: [missing])
        XCTAssertEqual(report.checkedCount, 0)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertTrue(report.truncated)
    }

    func testAncestorSymlinkDoesNotExpandApprovedSearchScope() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try f.file("copy.txt")
        let link = f.root.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.destination)
        let record = FolderRecord(id: "redirect", path: link.path, sampleNames: [])
        let report = try DuplicateFinder.find(for: f.source, in: [record])
        XCTAssertTrue(report.matches.isEmpty)
        XCTAssertTrue(report.truncated)
        XCTAssertEqual(report.skippedCount, 1)
    }
}
