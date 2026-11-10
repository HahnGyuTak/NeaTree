import Combine
import Foundation
import OrganizerCore

/// One shared model drives the main window and the menu-bar proposal UI.
/// Opening an unconfigured app never scans Downloads or sends file data to an API.
@MainActor
public final class OrganizerAppModel: ObservableObject {
    public let stateDirectory: URL
    public let isDemo: Bool
    @Published public private(set) var entries: [InboxEntry] = []
    @Published public private(set) var settings: OrganizerSettings?
    @Published public private(set) var history: [MoveRecord] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var watching = false
    @Published public private(set) var automaticallyAnalyze = false
    @Published public private(set) var hasAPIKey = false
    @Published public var selectedItemID: UUID?
    @Published public var errorMessage: String?
    @Published public var statusMessage: String?
    public var onProposalReady: ((UUID) -> Void)?

    public var selectedEntry: InboxEntry? { entries.first { $0.id == selectedItemID } }
    public var pendingCount: Int { entries.filter { [.ready, .proposed, .failed].contains($0.status) }.count }

    private let service: OrganizerService
    private let dependencies: AppModelDependencies
    private var preferenceStore: AppPreferenceStore
    private var preferences: AppPreferences
    private var watcher: Task<Void, Never>?
    private var started = false
    private var operationCount = 0
    private var refreshGeneration = UUID()
    private var analysisGenerations: [UUID: UUID] = [:]
    private var analysisTasks: [UUID: Task<FileProposal, any Error>] = [:]
    private var automaticAnalysisIDs: Set<UUID> = []
    private var demoProposals: [UUID: FileProposal] = [:]
    private var deliveredProposalFingerprints: [UUID: String] = [:]

    public convenience init(stateDirectory: URL, demo: Bool = false) throws {
        try self.init(stateDirectory: stateDirectory, demo: demo, dependencies: .live)
    }

    init(stateDirectory: URL, demo: Bool, dependencies: AppModelDependencies, settleInterval: TimeInterval = 2) throws {
        isDemo = demo
        // A demo never opens the caller's existing state, credentials, or files.
        let directory = demo
            ? FileManager.default.temporaryDirectory.appendingPathComponent("FileOrganizer-Demo-\(UUID().uuidString)").appendingPathComponent("state")
            : stateDirectory
        self.stateDirectory = directory
        self.dependencies = dependencies
        service = try OrganizerService(stateDirectory: directory, settleInterval: settleInterval)
        preferenceStore = try AppPreferenceStore(directory: directory)
        preferences = try preferenceStore.load()
        automaticallyAnalyze = preferences.automaticAnalysis
    }

    public func start() async {
        guard !started else { return }
        started = true
        if isDemo {
            await run {
                try await self.prepareDemo()
                self.statusMessage = "샘플 파일로 실행 중입니다. 실제 다운로드와 API는 사용하지 않습니다."
            }
            return
        }
        refreshKeyAvailability()
        await run(clearError: false) {
            // Repair journal-backed state after an interrupted move before either
            // window can present the old source as an actionable inbox item.
            do { _ = try await self.service.reconcileHistory() }
            catch OrganizerServiceError.notConfigured { }
        }
        if preferences.watchEnabled, settings != nil { beginWatching() }
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        watching = false
        analysisGenerations.removeAll()
        for task in analysisTasks.values { task.cancel() }
        analysisTasks.removeAll()
        automaticAnalysisIDs.removeAll()
    }

    public func refresh() async { await reloadState() }

    public func configure(downloads: URL, roots: [URL]) async {
        await run {
            try await self.service.configure(downloads: downloads, roots: roots)
            self.statusMessage = "감시 폴더와 분류할 폴더를 저장했습니다."
        }
    }

    public func importFiles(_ urls: [URL]) async {
        await run {
            guard self.settings != nil else { throw OrganizerServiceError.notConfigured }
            var failures: [String] = []
            var imported: [InboxEntry] = []
            for url in urls {
                do { imported.append(try await self.service.importItem(url)) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if let first = imported.first { self.selectedItemID = first.id }
            self.statusMessage = "\(imported.count)개 항목을 검토함에 추가했습니다."
            if !failures.isEmpty { self.errorMessage = failures.joined(separator: "\n") }
            if self.isDemo { try await self.updateDemoHints(for: imported) }
        }
        await processAutomaticAnalysis()
    }

    public func analyze(_ id: UUID) async {
        await run { try await self.analyzeItem(id, automatic: false) }
    }

    public func analyzeAll() async {
        let ids = entries.filter { [.ready, .proposed, .failed].contains($0.status) }.map(\.id)
        for id in ids {
            guard !Task.isCancelled else { break }
            await analyze(id)
            // A network/key failure should not spend the remaining queue automatically.
            if errorMessage != nil { break }
        }
    }

    public func apply(id: UUID, name: String, folderID: String, serialWidth: Int? = nil, fillGaps: Bool = false, learnForFuture: Bool = false, reviewedFingerprint: String? = nil) async {
        await run {
            guard let entry = self.entries.first(where: { $0.id == id }),
                  [.ready, .proposed, .held, .failed].contains(entry.status) else {
                throw OrganizerServiceError.itemNotFound
            }
            if let reviewedFingerprint, reviewedFingerprint != entry.fingerprint {
                throw OrganizerServiceError.sourceChanged
            }
            // Editable fields still carry a reviewed proposal. Passing explicit
            // values must not accidentally bypass its rule-version requirement.
            let latest = try await self.service.configuration()
            if entry.proposal != nil {
                guard latest.proposalRevisions[id.uuidString] == latest.revision else {
                    throw OrganizerServiceError.sourceChanged
                }
            }
            if learnForFuture, entry.proposal != nil, !self.isDemo {
                let key = try self.requireAPIKey()
                _ = try await self.service.learnCorrection(id: id, folderID: folderID, name: name, client: OpenAIClient(apiKey: key))
            }
            self.analysisGenerations[id] = nil
            let serial = serialWidth.map { SerialPolicy(width: $0, allocation: fillGaps ? .fillGap : .appendMax) }
            _ = try await self.service.apply(id: id, name: name, folderID: folderID, serial: serial)
            self.demoProposals[id] = nil
            self.statusMessage = "파일을 정리했습니다. 이력에서 되돌릴 수 있습니다."
        }
    }

    public func hold(_ id: UUID) async {
        analysisGenerations[id] = nil
        analysisTasks.removeValue(forKey: id)?.cancel()
        automaticAnalysisIDs.remove(id)
        demoProposals[id] = nil
        await run(allowConcurrent: true) {
            try await self.service.hold(id: id)
            self.statusMessage = "파일을 그대로 두고 제안을 보류했습니다."
        }
    }

    public func sendToUnclassified(_ id: UUID) async {
        await run {
            self.analysisGenerations[id] = nil
            _ = try await self.service.sendToUnclassified(id: id)
            self.demoProposals[id] = nil
            self.statusMessage = "다운로드의 미분류 폴더로 옮겼습니다."
        }
    }

    public func undo(_ id: UUID) async {
        await run {
            _ = try await self.service.undo(recordID: id)
            self.statusMessage = "원래 이름과 위치로 되돌렸습니다."
        }
    }

    public func revisit(_ id: UUID) async {
        await run {
            let entry = try await self.service.revisit(id: id)
            self.selectedItemID = entry.id
            if self.isDemo { try await self.updateDemoHints(for: [entry]) }
            self.statusMessage = "미분류 파일을 검토함에 다시 추가했습니다."
        }
    }

    public func analyzeStructure() async {
        await run {
            guard !self.isDemo else { self.statusMessage = "데모에서는 API 규칙 분석을 실행하지 않습니다."; return }
            _ = try await self.service.analyzeStructure(client: OpenAIClient(apiKey: self.requireAPIKey()))
            self.statusMessage = "규칙 후보를 만들었습니다. 내용을 확인한 후 확정하세요."
        }
    }

    public func confirmRule(_ index: Int) async {
        await run {
            _ = try await self.service.confirmRule(index: index)
            self.statusMessage = "규칙을 확정했습니다. 이전 제안은 다시 분석해 주세요."
        }
    }

    public func saveAPIKey(_ key: String) async {
        await run {
            guard !self.isDemo else { throw AppModelError.demoCredentials }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw AppModelError.invalidAPIKey }
            try self.dependencies.saveKey(trimmed)
            self.refreshKeyAvailability()
            self.statusMessage = "API 키를 키체인에 저장했습니다."
        }
    }

    public func deleteAPIKey() async {
        await run {
            guard !self.isDemo else { throw AppModelError.demoCredentials }
            try self.dependencies.deleteKey()
            self.refreshKeyAvailability()
            self.statusMessage = self.hasAPIKey ? "키체인 키를 삭제했습니다. 환경변수의 키는 계속 설정되어 있습니다." : "키체인의 API 키를 삭제했습니다."
        }
    }

    public func setWatching(_ enabled: Bool) {
        guard !enabled || settings != nil else { errorMessage = OrganizerServiceError.notConfigured.localizedDescription; return }
        var next = preferences
        next.watchEnabled = enabled
        guard savePreferences(next) else { return }
        if enabled { beginWatching() }
        else { watcher?.cancel(); watcher = nil; watching = false }
    }

    public func setAutomaticAnalysis(_ enabled: Bool) {
        var next = preferences
        next.automaticAnalysis = enabled
        guard savePreferences(next) else { return }
        automaticallyAnalyze = enabled
        if !enabled {
            for id in automaticAnalysisIDs {
                analysisGenerations[id] = nil
                analysisTasks.removeValue(forKey: id)?.cancel()
            }
            automaticAnalysisIDs.removeAll()
        }
        if enabled, !hasAPIKey, !isDemo { statusMessage = "자동 분석을 켰습니다. API 키를 설정하면 분석할 수 있습니다." }
    }

    /// An explicit manual scan uses the same stability and retry policy as the watcher.
    public func scanNow() async {
        guard !isBusy else { return }
        var scanSucceeded = false
        await run(clearError: false) {
            _ = try await self.service.scanDownloads()
            scanSucceeded = true
        }
        guard scanSucceeded else {
            if watching {
                setWatching(false)
                statusMessage = "다운로드 폴더를 확인할 수 없어 감시를 일시중지했습니다."
            }
            return
        }
        await processAutomaticAnalysis()
    }

    public func inspect(_ id: UUID) async -> FileEvidence? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        do { return try await FileInspector.inspectAsync(actualURL(for: entry)) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    public func duplicates(_ id: UUID) async -> DuplicateReport? {
        guard let entry = entries.first(where: { $0.id == id }), let settings else { return nil }
        do { return try await DuplicateFinder.findAsync(for: actualURL(for: entry), in: settings.folders) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    public func actualURL(for entry: InboxEntry) -> URL {
        if [.applied, .unclassified].contains(entry.status), let note = entry.note,
           let operation = history.last(where: { $0.id.uuidString == note && $0.state == .applied }) {
            return operation.destination
        }
        return URL(fileURLWithPath: entry.path)
    }

    public func proposal(for entry: InboxEntry) -> FileProposal? {
        entry.proposal ?? (isDemo ? demoProposals[entry.id] : nil)
    }

    private func run(allowConcurrent: Bool = false, clearError: Bool = true, _ operation: () async throws -> Void) async {
        guard allowConcurrent || !isBusy else { return }
        operationCount += 1
        isBusy = true
        if clearError { errorMessage = nil }
        defer { operationCount -= 1; isBusy = operationCount > 0 }
        do { try await operation() }
        catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
        await reloadState()
    }

    private func reloadState() async {
        let generation = UUID()
        refreshGeneration = generation
        let updatedEntries = await service.entries()
        let configuration: OrganizerSettings?
        do { configuration = try await service.configuration() }
        catch OrganizerServiceError.notConfigured { configuration = nil }
        catch { errorMessage = error.localizedDescription; return }
        var updatedHistory: [MoveRecord] = []
        if configuration != nil {
            do { updatedHistory = try await service.history() }
            catch { errorMessage = error.localizedDescription }
        }
        guard refreshGeneration == generation else { return }
        entries = updatedEntries
        settings = configuration
        history = updatedHistory
        if selectedItemID == nil || !updatedEntries.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = updatedEntries.first(where: { [.ready, .proposed].contains($0.status) })?.id
        }
    }

    private func beginWatching() {
        guard watcher == nil else { watching = true; return }
        watching = true
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.scanNow()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    private func processAutomaticAnalysis() async {
        guard automaticallyAnalyze, !isBusy, settings != nil, hasAPIKey || isDemo else { return }
        let ready = entries.filter { $0.status == .ready }
        for entry in ready {
            guard automaticallyAnalyze, !Task.isCancelled else { return }
            guard preferences.attemptedFingerprints[entry.id.uuidString] != entry.fingerprint else { continue }
            var completed = false
            await run(clearError: false) {
                do {
                    try await self.analyzeItem(entry.id, automatic: true)
                    completed = true
                } catch {
                    if Self.shouldPauseAutomaticAnalysis(after: error) {
                        self.setAutomaticAnalysis(false)
                        self.statusMessage = "API 연결 문제로 자동 분석을 일시중지했습니다. 설정을 확인한 뒤 다시 켜 주세요."
                    }
                    throw error
                }
            }
            if !completed { return }
        }
    }

    private func analyzeItem(_ id: UUID, automatic: Bool) async throws {
        guard let entry = entries.first(where: { $0.id == id }), [.ready, .proposed, .held, .failed].contains(entry.status) else {
            throw OrganizerServiceError.itemNotFound
        }
        let generation = UUID()
        analysisGenerations[id] = generation
        var next = preferences
        next.attemptedFingerprints[id.uuidString] = entry.fingerprint
        if next.attemptedFingerprints.count > 1_000 {
            let activeIDs = Set(entries.suffix(1_000).map { $0.id.uuidString })
            next.attemptedFingerprints = next.attemptedFingerprints.filter { activeIDs.contains($0.key) }
        }
        guard savePreferences(next) else { throw AppPreferenceError.concurrentWrite }
        if isDemo {
            try await updateDemoHints(for: [entry])
        } else {
            let key = try requireAPIKey()
            let analyzeFile = dependencies.analyzeFile
            let service = self.service
            let task = Task { try await analyzeFile(service, id, key) }
            analysisTasks[id] = task
            if automatic { automaticAnalysisIDs.insert(id) }
            defer {
                if analysisGenerations[id] == generation {
                    analysisTasks[id] = nil
                    automaticAnalysisIDs.remove(id)
                }
            }
            do {
                _ = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
            } catch {
                // A user's hold/stop owns the final state; its cancelled analysis
                // must not replace that action with a late error alert.
                guard analysisGenerations[id] == generation else { return }
                throw error
            }
        }
        guard analysisGenerations[id] == generation, !Task.isCancelled else {
            if isDemo { demoProposals[id] = nil }
            return
        }
        await reloadState()
        guard let current = entries.first(where: { $0.id == id }),
              [.ready, .proposed].contains(current.status), proposal(for: current) != nil else { return }
        statusMessage = "분류 제안을 준비했습니다."
        // Reanalysis is explicit, but a background scan must not reopen the same popover.
        if (!automatic || deliveredProposalFingerprints[id] != current.fingerprint),
           !automatic || automaticallyAnalyze {
            deliveredProposalFingerprints[id] = current.fingerprint
            onProposalReady?(id)
        }
    }

    private func refreshKeyAvailability() {
        guard !isDemo else { hasAPIKey = false; return }
        do { hasAPIKey = !(try dependencies.readKey() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        catch { hasAPIKey = false; errorMessage = error.localizedDescription }
    }

    private static func shouldPauseAutomaticAnalysis(after error: any Error) -> Bool {
        guard let error = error as? OpenAIClientError else { return false }
        switch error {
        case .missingAPIKey, .transportFailure: return true
        case .httpFailure(let status): return status == 401 || status == 403 || status == 429 || status >= 500
        default: return false
        }
    }

    private func requireAPIKey() throws -> String {
        guard !isDemo else { throw AppModelError.demoCredentials }
        guard let key = try dependencies.readKey(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OpenAIClientError.missingAPIKey }
        return key
    }

    @discardableResult private func savePreferences(_ next: AppPreferences) -> Bool {
        do { try preferenceStore.save(next); preferences = next; return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    private func prepareDemo() async throws {
        let root = stateDirectory.deletingLastPathComponent()
        let downloads = root.appendingPathComponent("Downloads")
        let archive = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data("기존 번호 사례".utf8).write(to: archive.appendingPathComponent("001_기존 문서.txt"))
        let samples = [
            ("다운로드한 문서.txt", "프로젝트 견적 검토 자료\n새 파일의 이름과 위치를 확인합니다."),
            ("회의 메모.md", "# 회의 메모\n- 일정 확인\n- 작업 범위 검토")
        ]
        var imported: [InboxEntry] = []
        try await service.configure(downloads: downloads, roots: [archive])
        for (name, contents) in samples {
            let url = downloads.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            imported.append(try await service.importItem(url))
        }
        try await updateDemoHints(for: imported)
        selectedItemID = imported.first?.id
    }

    private func updateDemoHints(for entries: [InboxEntry]) async throws {
        let configuration = try await service.configuration()
        guard let folder = configuration.folders.first else { return }
        for entry in entries {
            let evidence = try await FileInspector.inspectAsync(URL(fileURLWithPath: entry.path))
            let original = URL(fileURLWithPath: entry.path)
            let filename = evidence.kind == "folder" || original.pathExtension.isEmpty
                ? original.lastPathComponent + "_정리"
                : original.deletingPathExtension().lastPathComponent + "_정리." + original.pathExtension
            demoProposals[entry.id] = FileProposal(
                fileID: evidence.id, status: "needsReview", destinationFolderID: folder.id,
                proposedName: filename, reason: "데모용 제안입니다. AI 분석 결과가 아니며 임시 샘플 파일만 사용합니다.",
                evidence: ["임시 샘플 문서"], alternatives: [], missingInformation: []
            )
        }
    }
}

struct AppModelDependencies: Sendable {
    var readKey: @Sendable () throws -> String?
    var saveKey: @Sendable (String) throws -> Void
    var deleteKey: @Sendable () throws -> Void
    var analyzeFile: @Sendable (OrganizerService, UUID, String) async throws -> FileProposal

    static var live: AppModelDependencies {
        AppModelDependencies(
            readKey: {
                if let environment = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !environment.isEmpty { return environment }
                return try APIKeyStore.read()
            },
            saveKey: { try APIKeyStore.save($0) },
            deleteKey: { try APIKeyStore.delete() },
            analyzeFile: { service, id, key in try await service.propose(id: id, client: OpenAIClient(apiKey: key)) }
        )
    }
}

enum AppModelError: LocalizedError {
    case demoCredentials, invalidAPIKey
    var errorDescription: String? {
        switch self {
        case .demoCredentials: "데모 모드에서는 API 키를 읽거나 변경하지 않습니다."
        case .invalidAPIKey: "공백이나 줄바꿈이 없는 API 키를 입력하세요."
        }
    }
}
