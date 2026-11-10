import Foundation
import Darwin

public struct OrganizerSettings: Codable, Sendable {
    public var downloadsPath: String
    public var downloadsPhysicalPath: String
    public var destinationRoots: [String]
    public var importedSources: [String] = []
    public var folders: [FolderRecord] = []
    public var rules: [FolderRule] = []
    public var candidates: [RuleCandidate] = []
    public var fingerprints: [String: FileFingerprint] = [:]
    public var revision: UUID = UUID()
    public var proposalRevisions: [String: UUID] = [:]
    public var excludedExtensions: [String] = []
    public var excludedRelativeFolders: [String] = []
    public init(downloadsPath: String, destinationRoots: [String]) {
        self.downloadsPath = downloadsPath; self.downloadsPhysicalPath = downloadsPath; self.destinationRoots = destinationRoots
    }

    private enum CodingKeys: String, CodingKey {
        case downloadsPath, downloadsPhysicalPath, destinationRoots, importedSources, folders, rules, candidates
        case fingerprints, revision, proposalRevisions, excludedExtensions, excludedRelativeFolders
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        downloadsPath = try values.decode(String.self, forKey: .downloadsPath)
        downloadsPhysicalPath = try values.decodeIfPresent(String.self, forKey: .downloadsPhysicalPath) ?? downloadsPath
        destinationRoots = try values.decode([String].self, forKey: .destinationRoots)
        importedSources = try values.decodeIfPresent([String].self, forKey: .importedSources) ?? []
        folders = try values.decodeIfPresent([FolderRecord].self, forKey: .folders) ?? []
        rules = try values.decodeIfPresent([FolderRule].self, forKey: .rules) ?? []
        candidates = try values.decodeIfPresent([RuleCandidate].self, forKey: .candidates) ?? []
        fingerprints = try values.decodeIfPresent([String: FileFingerprint].self, forKey: .fingerprints) ?? [:]
        revision = try values.decodeIfPresent(UUID.self, forKey: .revision) ?? UUID()
        proposalRevisions = try values.decodeIfPresent([String: UUID].self, forKey: .proposalRevisions) ?? [:]
        excludedExtensions = try values.decodeIfPresent([String].self, forKey: .excludedExtensions) ?? []
        excludedRelativeFolders = try values.decodeIfPresent([String].self, forKey: .excludedRelativeFolders) ?? []
    }
}

public enum OrganizerServiceError: LocalizedError {
    case notConfigured, invalidFolder, itemNotFound, missingSnapshot, sourceChanged, missingDestination, missingName, invalidRule
    case configurationChanged, invalidExclusion
    case operationCommitted(UUID)
    public var errorDescription: String? {
        switch self {
        case .notConfigured: "먼저 다운로드 폴더와 관리할 폴더를 지정하세요."
        case .invalidFolder: "실제 디렉토리를 지정하세요. 시스템 루트와 심볼릭 링크는 관리 대상으로 사용할 수 없습니다."
        case .itemNotFound: "해당 검토 항목을 찾을 수 없습니다."
        case .missingSnapshot: "원본 확인 정보가 없습니다. 파일을 다시 가져오거나 분석하세요."
        case .sourceChanged: "검토한 뒤 파일 내용이 바뀌었습니다. 다시 분석하세요."
        case .missingDestination: "허용된 폴더 중 목적지를 선택하세요."
        case .missingName: "적용할 파일명을 지정하세요."
        case .invalidRule: "허용된 폴더와 비어 있지 않은 규칙을 지정하세요. 수정할 규칙이나 후보가 있는지도 확인하세요."
        case .invalidExclusion: "확장자는 pdf처럼, 제외 폴더는 다운로드 폴더 아래의 상대 경로로 입력하세요. 빈 값과 상위 폴더(..)는 사용할 수 없습니다."
        case .configurationChanged: "다른 실행에서 설정이 변경되었습니다. 앱을 다시 열어 최신 설정을 불러오세요."
        case .operationCommitted(let id): "파일 작업은 완료됐지만 검토함을 갱신하지 못했습니다. 작업 ID: \(id). reconcile로 이력을 반영하세요."
        }
    }
}

/// Orchestrates local state and explicit user actions. No background API calls on initialization.
public actor OrganizerService {
    public let stateDirectory: URL
    private let configURL: URL
    private let inbox: InboxStore
    private var settings: OrganizerSettings?
    private var savedConfigData: Data?
    private var analysisTokens: [UUID: UUID] = [:]

    public init(stateDirectory: URL, settleInterval: TimeInterval = 2) throws {
        self.stateDirectory = stateDirectory
        self.configURL = stateDirectory.appendingPathComponent("configuration.json")
        self.inbox = try InboxStore(stateDirectory: stateDirectory.appendingPathComponent("inbox"), settleInterval: settleInterval)
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            self.settings = try JSONDecoder().decode(OrganizerSettings.self, from: data)
            self.savedConfigData = data
        }
    }

    public func configure(downloads: URL, roots: [URL]) async throws {
        guard !roots.isEmpty else { throw OrganizerServiceError.invalidFolder }
        for url in [downloads] + roots {
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard v.isDirectory == true, v.isSymbolicLink != true, url.standardizedFileURL.path != "/" else {
                throw OrganizerServiceError.invalidFolder
            }
        }
        let expectedRevision = settings?.revision
        let folders = try await CatalogBuilder.scanAsync(roots: roots)
        guard settings?.revision == expectedRevision else { throw OrganizerServiceError.configurationChanged }
        // Merge state written by imports while the metadata scan was running.
        var next = settings ?? OrganizerSettings(downloadsPath: downloads.path, destinationRoots: roots.map(\.path))
        next.downloadsPath = downloads.standardizedFileURL.path
        next.downloadsPhysicalPath = try physicalPath(downloads)
        next.destinationRoots = roots.map { $0.standardizedFileURL.path }
        next.folders = folders
        // A revoked destination cannot remain an active rule.
        let ids = Set(next.folders.map(\.id))
        next.rules = next.rules.filter { ids.contains($0.folderID) }
        next.candidates = next.candidates.filter { ids.contains($0.folderID) }
        next.revision = UUID()
        try save(next)
    }

    public func configuration() throws -> OrganizerSettings { try requireSettings() }
    public func entries() async -> [InboxEntry] { await inbox.entries() }

    @discardableResult public func refreshCatalog() async throws -> [FolderRecord] {
        let original = try requireSettings()
        let folders = try await CatalogBuilder.scanAsync(roots: original.destinationRoots.map { URL(fileURLWithPath: $0) })
        var next = try requireSettings()
        guard next.revision == original.revision else { throw OrganizerServiceError.configurationChanged }
        if folders != next.folders { next.revision = UUID() }
        next.folders = folders
        try save(next)
        return next.folders
    }

    public func importItem(_ url: URL) async throws -> InboxEntry {
        var next = try requireSettings()
        let path = url.standardizedFileURL.path
        if !next.importedSources.contains(path) { next.importedSources.append(path) }
        let engine = try makeEngine(next)
        let fingerprint = try await engine.fingerprint(of: url)
        let entry = try await inbox.add(url: url)
        var latest = try requireSettings()
        if !latest.importedSources.contains(path) { latest.importedSources.append(path) }
        latest.fingerprints[entry.id.uuidString] = fingerprint
        try save(latest)
        return entry
    }

    public func scanDownloads() async throws -> [InboxEntry] {
        let current = try requireSettings()
        let ready = try await inbox.poll(
            downloads: URL(fileURLWithPath: current.downloadsPath),
            excludedExtensions: Set(current.excludedExtensions),
            excludedRelativeFolders: Set(current.excludedRelativeFolders),
            explicitPaths: Set(current.importedSources)
        )
        guard try requireSettings().revision == current.revision else { return [] }
        let engine = try makeEngine(current)
        var verifiedReady: [InboxEntry] = []
        for entry in ready {
            do {
                let fingerprint = try await engine.fingerprint(of: URL(fileURLWithPath: entry.path))
                var latest = try requireSettings()
                guard latest.revision == current.revision else { return [] }
                latest.fingerprints[entry.id.uuidString] = fingerprint
                try save(latest)
                verifiedReady.append(entry)
            } catch {
                try await inbox.setStatus(id: entry.id, status: .failed, note: error.localizedDescription)
            }
        }
        return verifiedReady
    }

    public func analyzeStructure(client: OpenAIClient) async throws -> RuleAnalysis {
        let folders = try await refreshCatalog()
        let analysis = try await client.analyzeStructure(folders: folders)
        var next = try requireSettings()
        guard next.folders == folders else { throw OrganizerServiceError.sourceChanged }
        next.candidates = analysis.candidates
        try save(next)
        return analysis
    }

    public func confirmRule(index: Int) throws -> FolderRule {
        var next = try requireSettings()
        guard next.candidates.indices.contains(index) else { throw OrganizerServiceError.invalidRule }
        let candidate = next.candidates[index]
        let instruction = try validatedInstruction(candidate.instruction, folderID: candidate.folderID, settings: next)
        let rule = FolderRule(id: UUID().uuidString, folderID: candidate.folderID, instruction: instruction, confirmed: true)
        next.rules.append(rule)
        next.revision = UUID()
        next.candidates.remove(at: index)
        try save(next)
        return rule
    }

    @discardableResult
    public func createRule(folderID: String, instruction: String) throws -> FolderRule {
        var next = try requireSettings()
        let text = try validatedInstruction(instruction, folderID: folderID, settings: next)
        let rule = FolderRule(id: UUID().uuidString, folderID: folderID, instruction: text, confirmed: true)
        next.rules.append(rule)
        next.revision = UUID()
        try save(next)
        return rule
    }

    @discardableResult
    public func updateRule(id: String, folderID: String, instruction: String) throws -> FolderRule {
        var next = try requireSettings()
        guard let index = next.rules.firstIndex(where: { $0.id == id }) else { throw OrganizerServiceError.invalidRule }
        let text = try validatedInstruction(instruction, folderID: folderID, settings: next)
        let rule = FolderRule(id: id, folderID: folderID, instruction: text, confirmed: true)
        if next.rules[index] != rule { next.revision = UUID() }
        next.rules[index] = rule
        try save(next)
        return rule
    }

    public func deleteRule(id: String) throws {
        var next = try requireSettings()
        guard let index = next.rules.firstIndex(where: { $0.id == id }) else { throw OrganizerServiceError.invalidRule }
        next.rules.remove(at: index)
        next.revision = UUID()
        try save(next)
    }

    @discardableResult
    public func updateCandidate(index: Int, folderID: String, instruction: String) throws -> RuleCandidate {
        var next = try requireSettings()
        guard next.candidates.indices.contains(index) else { throw OrganizerServiceError.invalidRule }
        let text = try validatedInstruction(instruction, folderID: folderID, settings: next)
        let old = next.candidates[index]
        let candidate = RuleCandidate(folderID: folderID, instruction: text, evidence: old.evidence, uncertainties: old.uncertainties)
        next.candidates[index] = candidate
        try save(next)
        return candidate
    }

    public func deleteCandidate(index: Int) throws {
        var next = try requireSettings()
        guard next.candidates.indices.contains(index) else { throw OrganizerServiceError.invalidRule }
        next.candidates.remove(at: index)
        try save(next)
    }

    /// Folder paths are relative to Downloads. A nested exclusion skips its enclosing top-level folder unit.
    public func setWatcherExclusions(extensions: [String], relativeFolders: [String]) async throws {
        let extensions = try Self.normalizedExtensions(extensions)
        let relativeFolders = try Self.normalizedRelativeFolders(relativeFolders)
        var next = try requireSettings()
        if next.excludedExtensions != extensions || next.excludedRelativeFolders != relativeFolders {
            next.excludedExtensions = extensions
            next.excludedRelativeFolders = relativeFolders
            next.revision = UUID()
            try save(next)
        }
        try await inbox.reconcileWatcherExclusions(
            downloads: URL(fileURLWithPath: next.downloadsPath),
            excludedExtensions: Set(extensions), excludedRelativeFolders: Set(relativeFolders),
            explicitPaths: Set(next.importedSources)
        )
    }

    public func propose(id: UUID, client: OpenAIClient) async throws -> FileProposal {
        let token = UUID()
        analysisTokens[id] = token
        let prior = try await item(id)
        guard analysisTokens[id] == token else { throw OrganizerServiceError.sourceChanged }
        guard [.ready, .proposed, .held, .failed].contains(prior.status) else { throw OrganizerServiceError.itemNotFound }
        let entry = try await inbox.add(url: URL(fileURLWithPath: prior.path), explicitImport: false)
        guard analysisTokens[id] == token else { throw OrganizerServiceError.sourceChanged }
        if entry.status != .ready && entry.status != .proposed {
            try await inbox.setStatus(id: id, status: .ready)
        }
        let current = try requireSettings()
        let engine = try makeEngine(current)
        let url = URL(fileURLWithPath: entry.path)
        let before = try await engine.fingerprint(of: url)
        let evidence = try await FileInspector.inspectAsync(url)
        guard try requireSettings().revision == current.revision, analysisTokens[id] == token else {
            throw OrganizerServiceError.sourceChanged
        }
        let proposal = try await client.propose(file: evidence, folders: current.folders, rules: current.rules)
        let after = try await engine.fingerprint(of: url)
        let latest = try requireSettings()
        guard before == after, latest.revision == current.revision, analysisTokens[id] == token else {
            throw OrganizerServiceError.sourceChanged
        }
        var next = latest
        next.fingerprints[id.uuidString] = after
        next.proposalRevisions[id.uuidString] = current.revision
        try save(next)
        try await inbox.recordProposal(id: id, proposal: proposal)
        return proposal
    }

    public func hold(id: UUID) async throws {
        analysisTokens[id] = nil
        try await inbox.setStatus(id: id, status: .held, note: nil)
    }

    public func apply(id: UUID, name: String? = nil, folderID: String? = nil, serial: SerialPolicy? = nil) async throws -> MoveRecord {
        let entry = try await item(id)
        let current = try requireSettings()
        analysisTokens[id] = nil
        if name == nil || folderID == nil {
            guard current.proposalRevisions[id.uuidString] == current.revision else { throw OrganizerServiceError.sourceChanged }
        }
        guard let targetID = folderID ?? entry.proposal?.destinationFolderID,
              let folder = current.folders.first(where: { $0.id == targetID }) else { throw OrganizerServiceError.missingDestination }
        guard let filename = name ?? entry.proposal?.proposedName, !filename.isEmpty else { throw OrganizerServiceError.missingName }
        guard let fingerprint = current.fingerprints[id.uuidString] else { throw OrganizerServiceError.missingSnapshot }
        let engine = try makeEngine(current)
        let record = try await engine.apply(MoveRequest(source: URL(fileURLWithPath: entry.path), destinationDirectory: URL(fileURLWithPath: folder.path), proposedName: filename, expectedFingerprint: fingerprint, serial: serial))
        do { try await inbox.setStatus(id: id, status: .applied, note: record.id.uuidString) }
        catch { throw OrganizerServiceError.operationCommitted(record.id) }
        return record
    }

    public func sendToUnclassified(id: UUID) async throws -> MoveRecord {
        let entry = try await item(id)
        let current = try requireSettings()
        analysisTokens[id] = nil
        guard let fingerprint = current.fingerprints[id.uuidString] else { throw OrganizerServiceError.missingSnapshot }
        let directory = URL(fileURLWithPath: current.downloadsPath).appendingPathComponent("미분류", isDirectory: true)
        // Reject an existing symlink before creating or resolving the destination.
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw OrganizerServiceError.invalidFolder }
        } else {
            // Open every component without following symlinks, then create relative to that descriptor.
            var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard fd >= 0 else { throw OrganizerServiceError.invalidFolder }
            defer { close(fd) }
            let resolved = try physicalPath(URL(fileURLWithPath: current.downloadsPath))
            guard resolved == current.downloadsPhysicalPath else { throw OrganizerServiceError.invalidFolder }
            for component in (resolved as NSString).pathComponents where component != "/" {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw OrganizerServiceError.invalidFolder }
                close(fd); fd = next
            }
            guard mkdirat(fd, "미분류", 0o755) == 0 || errno == EEXIST else { throw OrganizerServiceError.invalidFolder }
        }
        let engine = try makeEngine(current)
        let source = URL(fileURLWithPath: entry.path)
        let record = try await engine.apply(MoveRequest(source: source, destinationDirectory: directory, proposedName: source.lastPathComponent, expectedFingerprint: fingerprint))
        do { try await inbox.setStatus(id: id, status: .unclassified, note: record.id.uuidString) }
        catch { throw OrganizerServiceError.operationCommitted(record.id) }
        return record
    }

    public func history() async throws -> [MoveRecord] { try await makeEngine(requireSettings()).history() }

    public func undo(recordID: UUID) async throws -> MoveRecord {
        let engine = try makeEngine(requireSettings())
        let record = try await engine.undo(id: recordID)
        do {
            for entry in await inbox.entries() where entry.note == recordID.uuidString {
                analysisTokens[entry.id] = nil
                try await inbox.setStatus(id: entry.id, status: .held, note: "정리를 되돌렸습니다.")
            }
        } catch { throw OrganizerServiceError.operationCommitted(recordID) }
        return record
    }

    public func revisit(id: UUID) async throws -> InboxEntry {
        let entry = try await item(id)
        guard entry.status == .unclassified, let note = entry.note, let recordID = UUID(uuidString: note),
              let record = try await history().first(where: { $0.id == recordID && $0.state == .applied }) else {
            throw OrganizerServiceError.itemNotFound
        }
        return try await importItem(record.destination)
    }

    public func learnCorrection(id: UUID, folderID: String, name: String, client: OpenAIClient) async throws -> RuleAnalysis {
        let entry = try await item(id)
        guard let proposal = entry.proposal else { throw OrganizerServiceError.itemNotFound }
        let before = try requireSettings()
        let result = try await client.suggestRule(from: proposal, correctedFolderID: folderID, correctedName: name, folders: before.folders, applyToFuture: true)
        var latest = try requireSettings()
        guard before.revision == latest.revision else { throw OrganizerServiceError.sourceChanged }
        latest.candidates.append(contentsOf: result.candidates)
        try save(latest)
        return result
    }

    /// Repair inbox state from the durable journal after an operation committed but its UI state did not.
    public func reconcileHistory() async throws -> [MoveRecord] {
        let current = try requireSettings()
        let engine = try makeEngine(current)
        let records = try await engine.recoverPending()
        for entry in await inbox.entries() {
            let source = URL(fileURLWithPath: entry.path)
            guard let parent = try? physicalPath(source.deletingLastPathComponent()) else { continue }
            let canonicalSource = parent + "/" + source.lastPathComponent
            guard let snapshot = current.fingerprints[entry.id.uuidString],
                  let latest = records.last(where: { $0.fingerprint == snapshot && $0.source.path == canonicalSource }) else { continue }
            if latest.state == .applied {
                let state: InboxStatus = latest.destination.deletingLastPathComponent().lastPathComponent == "미분류" ? .unclassified : .applied
                if entry.status != state || entry.note != latest.id.uuidString {
                    try await inbox.setStatus(id: entry.id, status: state, note: latest.id.uuidString)
                }
            } else if latest.state == .undone && [.applied, .unclassified].contains(entry.status) {
                try await inbox.setStatus(id: entry.id, status: .held, note: "정리를 되돌렸습니다.")
            }
        }
        return records
    }

    private func item(_ id: UUID) async throws -> InboxEntry {
        guard let entry = await inbox.entries().first(where: { $0.id == id }) else { throw OrganizerServiceError.itemNotFound }
        return entry
    }
    private func requireSettings() throws -> OrganizerSettings {
        guard let settings else { throw OrganizerServiceError.notConfigured }; return settings
    }
    private func validatedInstruction(_ instruction: String, folderID: String, settings: OrganizerSettings) throws -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, settings.folders.contains(where: { $0.id == folderID }) else {
            throw OrganizerServiceError.invalidRule
        }
        return trimmed
    }
    private static func normalizedExtensions(_ values: [String]) throws -> [String] {
        try Array(Set(values.map { value in
            var ext = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ext.hasPrefix(".") { ext.removeFirst() }
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+"))
            guard !ext.isEmpty, ext.unicodeScalars.allSatisfy(allowed.contains) else {
                throw OrganizerServiceError.invalidExclusion
            }
            return ext.precomposedStringWithCanonicalMapping
        })).sorted()
    }
    private static func normalizedRelativeFolders(_ values: [String]) throws -> [String] {
        try Array(Set(values.map { value in
            var path = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw OrganizerServiceError.invalidExclusion
            }
            if path.hasSuffix("/") { path.removeLast() }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw OrganizerServiceError.invalidExclusion
            }
            return path
        })).sorted()
    }
    private func physicalPath(_ url: URL) throws -> String {
        guard let pointer = realpath(url.path, nil) else { throw OrganizerServiceError.invalidFolder }
        defer { free(pointer) }
        return String(cString: pointer)
    }
    private func makeEngine(_ config: OrganizerSettings) throws -> MoveEngine {
        let downloads = URL(fileURLWithPath: config.downloadsPath)
        let unclassified = downloads.appendingPathComponent("미분류")
        let values = try? unclassified.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let extra = values?.isDirectory == true && values?.isSymbolicLink != true ? [unclassified] : []
        return try MoveEngine(sourceRoots: [downloads], destinationRoots: config.destinationRoots.map { URL(fileURLWithPath: $0) } + extra, stateDirectory: stateDirectory.appendingPathComponent("operations"), exactSources: config.importedSources.map { URL(fileURLWithPath: $0) })
    }
    private func save(_ next: OrganizerSettings) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let lock = open(stateDirectory.appendingPathComponent("configuration.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw OrganizerServiceError.configurationChanged }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw OrganizerServiceError.configurationChanged }
        let disk = FileManager.default.fileExists(atPath: configURL.path) ? try Data(contentsOf: configURL) : nil
        guard disk == savedConfigData else { throw OrganizerServiceError.configurationChanged }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try data.write(to: configURL, options: .atomic)
        savedConfigData = data
        settings = next
    }
}
