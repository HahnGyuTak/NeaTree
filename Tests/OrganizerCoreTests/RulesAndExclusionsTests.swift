import Foundation
import Testing
@testable import OrganizerCore

@Suite("Rules and watcher exclusions")
struct RulesAndExclusionsTests {
    @Test func ruleCRUDInvalidatesPreviouslyReviewedProposalsAndSurvivesRestart() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        let service = try await fixture.service()
        let source = try fixture.write("memo.txt")
        let entry = try await service.importItem(source)
        let folder = try #require(await service.configuration().folders.first)
        let client = try proposalClient(source: source, folderID: folder.id)

        _ = try await service.propose(id: entry.id, client: client)
        let initialRevision = try await service.configuration().revision
        let rule = try await service.createRule(folderID: folder.id, instruction: "  제목 앞에 날짜를 붙인다. \n")
        #expect(rule.instruction == "제목 앞에 날짜를 붙인다.")
        #expect(try await service.configuration().revision != initialRevision)
        await expectObsolete { _ = try await service.apply(id: entry.id) }

        _ = try await service.propose(id: entry.id, client: client)
        let updated = try await service.updateRule(id: rule.id, folderID: folder.id, instruction: "프로젝트 코드로 시작한다.")
        #expect(updated.id == rule.id)
        await expectObsolete { _ = try await service.apply(id: entry.id) }
        let restarted = try OrganizerService(stateDirectory: fixture.state)
        #expect(try await restarted.configuration().rules == [updated])

        _ = try await restarted.propose(id: entry.id, client: client)
        try await restarted.deleteRule(id: rule.id)
        await expectObsolete { _ = try await restarted.apply(id: entry.id) }
        #expect(try await restarted.configuration().rules.isEmpty)
        #expect(try await restarted.history().isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
        let reopened = try OrganizerService(stateDirectory: fixture.state)
        #expect(try await reopened.configuration().rules.isEmpty)
    }

    @Test func invalidRuleEditsLeaveConfigurationUntouched() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        let service = try await fixture.service()
        let folder = try #require(await service.configuration().folders.first)
        let rule = try await service.createRule(folderID: folder.id, instruction: "원래 규칙")
        let revision = try await service.configuration().revision
        await #expect(throws: OrganizerServiceError.self) { _ = try await service.createRule(folderID: folder.id, instruction: " \n\t") }
        await #expect(throws: OrganizerServiceError.self) { _ = try await service.createRule(folderID: "outside", instruction: "금지") }
        await #expect(throws: OrganizerServiceError.self) { _ = try await service.updateRule(id: rule.id, folderID: "outside", instruction: "금지") }
        await #expect(throws: OrganizerServiceError.self) { _ = try await service.updateRule(id: rule.id, folderID: folder.id, instruction: " ") }
        await #expect(throws: OrganizerServiceError.self) { try await service.deleteRule(id: "missing") }
        #expect(try await service.configuration().rules == [rule])
        #expect(try await service.configuration().revision == revision)
    }

    @Test func candidatesCanBeCorrectedAndDismissedWithoutActivatingThem() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        let original = try await fixture.service()
        var configuration = try await original.configuration()
        let folder = try #require(configuration.folders.first)
        configuration.candidates = [
            RuleCandidate(folderID: folder.id, instruction: "추정한 규칙", evidence: ["001_문서.txt"], uncertainties: ["번호 범위 확인"]),
            RuleCandidate(folderID: folder.id, instruction: "삭제할 후보", evidence: [], uncertainties: [])
        ]
        try JSONEncoder().encode(configuration).write(to: fixture.state.appendingPathComponent("configuration.json"), options: .atomic)
        let service = try OrganizerService(stateDirectory: fixture.state)
        let corrected = try await service.updateCandidate(index: 0, folderID: folder.id, instruction: "  수정한 규칙  ")
        #expect(corrected.instruction == "수정한 규칙")
        #expect(corrected.evidence == ["001_문서.txt"])
        #expect(corrected.uncertainties == ["번호 범위 확인"])
        await #expect(throws: OrganizerServiceError.self) { _ = try await service.updateCandidate(index: 0, folderID: folder.id, instruction: " ") }
        await #expect(throws: OrganizerServiceError.self) { _ = try await service.updateCandidate(index: 0, folderID: "outside", instruction: "금지") }
        try await service.deleteCandidate(index: 1)
        #expect(try await service.configuration().revision == configuration.revision)
        #expect(try await service.configuration().rules.isEmpty)
        let confirmed = try await service.confirmRule(index: 0)
        #expect(confirmed.instruction == corrected.instruction)
        #expect(try await service.configuration().candidates.isEmpty)
        #expect(try await service.configuration().revision != configuration.revision)
    }

    @Test func legacyJSONLoadsWithEmptyExclusionsAndKeepsExplicitImportOverride() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        let service = try await fixture.service()
        let source = try fixture.write("manual.pdf")
        let entry = try await service.importItem(source)
        let configURL = fixture.state.appendingPathComponent("configuration.json")
        var config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        config.removeValue(forKey: "excludedExtensions")
        config.removeValue(forKey: "excludedRelativeFolders")
        try JSONSerialization.data(withJSONObject: config).write(to: configURL, options: .atomic)
        let inboxURL = fixture.state.appendingPathComponent("inbox/inbox.json")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: inboxURL)) as? [String: Any])
        var entries = try #require(document["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "isExplicitImport")
        entries[0].removeValue(forKey: "explicitImportIdentity")
        document["entries"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: inboxURL, options: .atomic)

        let restarted = try OrganizerService(stateDirectory: fixture.state, settleInterval: 0)
        #expect(try await restarted.configuration().excludedExtensions.isEmpty)
        #expect(try await restarted.configuration().excludedRelativeFolders.isEmpty)
        try await restarted.setWatcherExclusions(extensions: ["pdf"], relativeFolders: [])
        #expect(await restarted.entries().first?.id == entry.id)
        #expect(await restarted.entries().first?.isExplicitImport == true)
        #expect(await restarted.entries().first?.status == .ready)
    }

    @Test func exclusionsRemovePendingItemsPersistAndAllowManualOverride() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        let service = try await fixture.service()
        let ignored = try fixture.write("ignore.PDF")
        _ = try fixture.write("keep.txt")
        #expect(try await service.scanDownloads().isEmpty)
        #expect(await service.entries().count == 2)
        let revision = try await service.configuration().revision
        try await service.setWatcherExclusions(extensions: [" .PDF ", "pdf"], relativeFolders: ["Private/"])
        #expect(await service.entries().map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["keep.txt"])
        #expect(try await service.configuration().revision != revision)
        let restarted = try OrganizerService(stateDirectory: fixture.state, settleInterval: 0)
        #expect(try await restarted.configuration().excludedExtensions == ["pdf"])
        #expect(try await restarted.configuration().excludedRelativeFolders == ["Private"])
        let ready = try await restarted.scanDownloads()
        #expect(ready.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["keep.txt"])
        #expect(try await restarted.scanDownloads().isEmpty)
        let manual = try await restarted.importItem(ignored)
        #expect(manual.status == .ready)
        #expect(manual.isExplicitImport)
        #expect(try await restarted.scanDownloads().isEmpty)
        #expect(await restarted.entries().contains { $0.id == manual.id && $0.status == .ready })
        let reopened = try OrganizerService(stateDirectory: fixture.state, settleInterval: 0)
        #expect(try await reopened.scanDownloads().isEmpty)
        #expect(await reopened.entries().contains { $0.id == manual.id && $0.isExplicitImport })
    }

    @Test func folderExclusionsRespectComponentBoundariesAndPreserveUserDecisions() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        for name in ["Private", "Private-copy", "Bundle/Secret", "Bundle-copy", "held", "applied", "unclassified"] {
            try FileManager.default.createDirectory(at: fixture.downloads.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let storeURL = fixture.state.appendingPathComponent("standalone-inbox")
        let store = try InboxStore(stateDirectory: storeURL, settleInterval: 0)
        let start = Date(timeIntervalSince1970: 100)
        _ = try await store.poll(downloads: fixture.downloads, now: start)
        let entries = await store.entries()
        for (name, status) in [("held", InboxStatus.held), ("applied", .applied), ("unclassified", .unclassified)] {
            let entry = try #require(entries.first { URL(fileURLWithPath: $0.path).lastPathComponent == name })
            try await store.setStatus(id: entry.id, status: status)
        }
        let excluded: Set<String> = ["Private", "Bundle/Secret", "held", "applied", "unclassified"]
        try await store.reconcileWatcherExclusions(downloads: fixture.downloads, excludedRelativeFolders: excluded)
        let restarted = try InboxStore(stateDirectory: storeURL, settleInterval: 0)
        let ready = try await restarted.poll(downloads: fixture.downloads, now: start.addingTimeInterval(5), excludedRelativeFolders: excluded)
        #expect(Set(ready.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["Private-copy", "Bundle-copy"])
        let after = await restarted.entries()
        #expect(after.count == 5)
        for (name, status) in [("held", InboxStatus.held), ("applied", .applied), ("unclassified", .unclassified)] {
            #expect(after.first { URL(fileURLWithPath: $0.path).lastPathComponent == name }?.status == status)
        }
        #expect(try await restarted.poll(downloads: fixture.downloads, now: start.addingTimeInterval(10), excludedRelativeFolders: excluded).isEmpty)
        _ = try await restarted.poll(downloads: fixture.downloads, now: start.addingTimeInterval(15))
        let restored = try await restarted.poll(downloads: fixture.downloads, now: start.addingTimeInterval(20))
        #expect(Set(restored.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == ["Private", "Bundle"])
        #expect(await restarted.entries().first { URL(fileURLWithPath: $0.path).lastPathComponent == "held" }?.status == .held)
    }

    @Test func completedManualImportDoesNotExemptFutureFileAtTheSamePath() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        let service = try await fixture.service()
        let source = try fixture.write("report.pdf")
        let entry = try await service.importItem(source)
        let folder = try #require(await service.configuration().folders.first)
        _ = try await service.apply(id: entry.id, name: "archived-report.pdf", folderID: folder.id)
        try await service.setWatcherExclusions(extensions: ["pdf"], relativeFolders: [])
        try Data("a newly downloaded report".utf8).write(to: source)
        let restarted = try OrganizerService(stateDirectory: fixture.state, settleInterval: 0)
        #expect(try await restarted.configuration().importedSources.contains(source.path))
        for _ in 0..<3 { #expect(try await restarted.scanDownloads().isEmpty) }
        let entries = await restarted.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.id == entry.id)
        #expect(entries.first?.status == .applied)
        #expect(entries.first?.isExplicitImport == false)
        #expect(try String(contentsOf: source, encoding: .utf8) == "a newly downloaded report")
    }

    @Test func activeManualOverrideDoesNotFollowAReplacementWithIdenticalBytes() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        let service = try await fixture.service()
        let source = try fixture.write("report.pdf")
        let entry = try await service.importItem(source)
        try await service.setWatcherExclusions(extensions: ["pdf"], relativeFolders: [])
        try await service.hold(id: entry.id)
        let restarted = try OrganizerService(stateDirectory: fixture.state, settleInterval: 0)
        #expect(try await restarted.scanDownloads().isEmpty)
        #expect(await restarted.entries().first?.isExplicitImport == true)
        #expect(await restarted.entries().first?.status == .held)
        // Keep the original inode alive so the replacement necessarily has a different identity.
        try FileManager.default.moveItem(at: source, to: fixture.archive.appendingPathComponent("original.pdf"))
        _ = try fixture.write("report.pdf")
        for _ in 0..<3 { #expect(try await restarted.scanDownloads().isEmpty) }
        #expect(await restarted.entries().first?.isExplicitImport == false)
        #expect(await restarted.entries().first?.status == .held)
        let reopened = try OrganizerService(stateDirectory: fixture.state, settleInterval: 0)
        #expect(try await reopened.scanDownloads().isEmpty)
        #expect(await reopened.entries().first?.isExplicitImport == false)
    }

    @Test func legacyPathOnlyImportDoesNotAuthorizeAChangedFile() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        let service = try await fixture.service()
        let source = try fixture.write("report.pdf")
        _ = try await service.importItem(source)
        let inboxURL = fixture.state.appendingPathComponent("inbox/inbox.json")
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: inboxURL)) as? [String: Any])
        var entries = try #require(document["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "isExplicitImport")
        entries[0].removeValue(forKey: "explicitImportIdentity")
        document["entries"] = entries
        try JSONSerialization.data(withJSONObject: document).write(to: inboxURL, options: .atomic)
        try Data("changed after legacy import".utf8).write(to: source)
        let restarted = try OrganizerService(stateDirectory: fixture.state, settleInterval: 0)
        try await restarted.setWatcherExclusions(extensions: ["pdf"], relativeFolders: [])
        for _ in 0..<3 { #expect(try await restarted.scanDownloads().isEmpty) }
        #expect(await restarted.entries().isEmpty)
    }

    @Test func exclusionFolderCaseFollowsTheFixtureVolumeWithoutBroadPrefixMatches() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        for name in ["Private", "Private-copy", "Bundle/Secret"] {
            try FileManager.default.createDirectory(at: fixture.downloads.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let caseSensitive = try #require(fixture.downloads.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames as Bool?)
        let store = try InboxStore(stateDirectory: fixture.state, settleInterval: 0)
        let exclusions: Set<String> = ["private", "bundle/secret"]
        let start = Date(timeIntervalSince1970: 100)
        _ = try await store.poll(downloads: fixture.downloads, now: start, excludedRelativeFolders: exclusions)
        let ready = try await store.poll(downloads: fixture.downloads, now: start.addingTimeInterval(5), excludedRelativeFolders: exclusions)
        let expected: Set<String> = caseSensitive ? ["Private", "Private-copy", "Bundle"] : ["Private-copy"]
        #expect(Set(ready.map { URL(fileURLWithPath: $0.path).lastPathComponent }) == expected)
    }

    @Test func invalidExclusionPathsCannotExpandScopeOrChangeSavedSettings() async throws {
        let fixture = try RuleExclusionFixture(); defer { fixture.remove() }
        let service = try await fixture.service()
        try await service.setWatcherExclusions(extensions: ["zip"], relativeFolders: ["Private"])
        let revision = try await service.configuration().revision
        for path in ["", "/outside", "../outside", "Private/../Other", "Private//Other", ".", "Private\\Other"] {
            await #expect(throws: OrganizerServiceError.self) { try await service.setWatcherExclusions(extensions: [], relativeFolders: [path]) }
        }
        for ext in ["", "*", "../pdf", "tar.gz"] {
            await #expect(throws: OrganizerServiceError.self) { try await service.setWatcherExclusions(extensions: [ext], relativeFolders: []) }
        }
        #expect(try await service.configuration().revision == revision)
        #expect(try await service.configuration().excludedExtensions == ["zip"])
        #expect(try await service.configuration().excludedRelativeFolders == ["Private"])
    }

    private func proposalClient(source: URL, folderID: String) throws -> OpenAIClient {
        let proposal = FileProposal(fileID: CatalogPaths.identifier(source), status: "ready", destinationFolderID: folderID,
                                    proposedName: "renamed.txt", reason: "테스트", evidence: ["메모"], alternatives: [], missingInformation: [])
        let payload = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: [
            "status": "completed", "output": [["type": "message", "status": "completed", "content": [["type": "output_text", "text": payload]]]]
        ])
        return OpenAIClient(apiKey: "fixture-key", transport: { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (data, response)
        })
    }

    private func expectObsolete(_ operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("An obsolete proposal must require fresh analysis") }
        catch OrganizerServiceError.sourceChanged { }
        catch { Issue.record("Unexpected error: \(error)") }
    }
}

private struct RuleExclusionFixture: Sendable {
    let root: URL
    let downloads: URL
    let archive: URL
    let state: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-exclusions-\(UUID())").resolvingSymlinksInPath()
        downloads = root.appendingPathComponent("Downloads")
        archive = root.appendingPathComponent("Archive")
        state = root.appendingPathComponent("State")
        for url in [downloads, archive] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    func service() async throws -> OrganizerService {
        let service = try OrganizerService(stateDirectory: state, settleInterval: 0)
        try await service.configure(downloads: downloads, roots: [archive])
        return service
    }
    func write(_ name: String) throws -> URL {
        let url = downloads.appendingPathComponent(name)
        try Data("메모 테스트".utf8).write(to: url)
        return url
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
