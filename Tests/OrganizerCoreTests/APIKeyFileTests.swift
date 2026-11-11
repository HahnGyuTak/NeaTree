import Darwin
import Foundation
import Testing
@testable import OrganizerCore

@Suite("Explicit API key file import")
struct APIKeyFileTests {
    @Test func acceptsOneUTF8KeyAndTrailingLineEnding() throws {
        #expect(try APIKeyFile.parse(Data("  dummy-fixture-key_123\r\n".utf8)) == "dummy-fixture-key_123")
        #expect(try APIKeyFile.parse(Data([0xEF, 0xBB, 0xBF]) + Data("dummy-bom-key\n".utf8)) == "dummy-bom-key")
    }

    @Test func decodesRTFWithoutTreatingMarkupAsPartOfTheKey() throws {
        let rtf = #"{\rtf1\ansi\deff0 {\fonttbl {\f0 Helvetica;}}\f0\fs24 dummy-rtf-fixture\par}"#
        #expect(try APIKeyFile.parse(Data(rtf.utf8)) == "dummy-rtf-fixture")
        let multiline = #"{\rtf1\ansi dummy-one\par dummy-two\par}"#
        #expect(throws: APIKeyFileError.invalidContents) { try APIKeyFile.parse(Data(multiline.utf8)) }
        #expect(throws: APIKeyFileError.tooLarge) { try APIKeyFile.parse(Data(repeating: 65, count: APIKeyFile.maximumFileBytes + 1)) }
    }

    @Test func rejectsEnvironmentAssignmentsQuotesMultipleLinesAndInvisibleCharacters() {
        for value in ["", " \n", "OPENAI_API_KEY=dummy-fixture", "\"dummy-fixture\"", "'dummy-fixture'",
                      "dummy-one\ndummy-two", "dummy key", "dummy\tkey", "dummy\0key", "dummy\u{200B}key"] {
            #expect(throws: APIKeyFileError.invalidContents) { try APIKeyFile.parse(Data(value.utf8)) }
        }
        #expect(throws: APIKeyFileError.invalidEncoding) { try APIKeyFile.parse(Data([0xFF, 0xFE])) }
        #expect(throws: APIKeyFileError.tooLarge) { try APIKeyFile.parse(Data(repeating: 65, count: APIKeyFile.maximumBytes + 1)) }
    }

    @Test func readsOnlySelectedRegularFileAndDoesNotChangeIt() throws {
        try withFixture { root in
            let file = root.appendingPathComponent("key.txt")
            let bytes = Data("dummy-file-fixture\n".utf8)
            try bytes.write(to: file)
            #expect(try APIKeyFile.read(from: file) == "dummy-file-fixture")
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func rejectsSymlinkDirectoryFIFOAndOversizedFile() throws {
        try withFixture { root in
            let file = root.appendingPathComponent("key.txt")
            try Data("dummy-file-fixture".utf8).write(to: file)
            let link = root.appendingPathComponent("key-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(throws: APIKeyFileError.notRegularFile) { try APIKeyFile.read(from: link) }
            #expect(throws: APIKeyFileError.notRegularFile) { try APIKeyFile.read(from: root) }
            let fifo = root.appendingPathComponent("fifo")
            #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
            #expect(throws: APIKeyFileError.notRegularFile) { try APIKeyFile.read(from: fifo) }
            try Data(repeating: 65, count: APIKeyFile.maximumBytes + 1).write(to: file)
            #expect(throws: APIKeyFileError.tooLarge) { try APIKeyFile.read(from: file) }
        }
    }

    @Test func errorsNeverIncludePathOrContents() throws {
        try withFixture { root in
            let file = root.appendingPathComponent("SECRET_PATH_MARKER.txt")
            try Data("PRIVATE_CONTENT_MARKER\nsecond-line".utf8).write(to: file)
            do {
                _ = try APIKeyFile.read(from: file)
                Issue.record("Expected malformed key failure")
            } catch {
                #expect(!error.localizedDescription.contains("PRIVATE_CONTENT_MARKER"))
                #expect(!error.localizedDescription.contains("SECRET_PATH_MARKER"))
            }
        }
    }

    @Test func importValidatesBeforeSavingAndDoesNotAlterInvalidExistingCredential() throws {
        try withFixture { root in
            let file = root.appendingPathComponent("key.rtf")
            try Data(#"{\rtf1\ansi dummy-import-fixture\par}"#.utf8).write(to: file)
            var stored = "existing-fixture"
            try APIKeyFile.importKey(from: file, save: { stored = $0 })
            #expect(stored == "dummy-import-fixture")
            try Data("invalid\nsecond-line".utf8).write(to: file)
            #expect(throws: APIKeyFileError.invalidContents) {
                try APIKeyFile.importKey(from: file, save: { stored = $0 })
            }
            #expect(stored == "dummy-import-fixture")
        }
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeaTree-key-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
