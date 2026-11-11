import Combine
import Darwin
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
    @Published public private(set) var psiloActivity = PsiloActivity()
    @Published public private(set) var psiloIssue: PsiloIssue?
    @Published public private(set) var watching = false
    @Published public private(set) var automaticallyAnalyze = false
    @Published public private(set) var hasAPIKey = false
    @Published public private(set) var reviewDrafts: [UUID: ReviewDraft] = [:]
    @Published public private(set) var batchResults: [BatchItemResult] = []
    @Published public var selectedItemID: UUID?
    @Published public var errorMessage: String?
    @Published public var statusMessage: String?
    public var onProposalReady: ((UUID) -> Void)?

    public var selectedEntry: InboxEntry? { entries.first { $0.id == selectedItemID } }
    public var pendingCount: Int { entries.filter { [.ready, .proposed, .failed].contains($0.status) }.count }

    private let service: OrganizerService
    private let dependencies: AppModelDependencies
    private let demoRootPath: String?
    private var preferenceStore: AppPreferenceStore
    private var preferences: AppPreferences
    private var watcher: Task<Void, Never>?
    private var started = false
    private var operationCount = 0
    private var psiloTracker = PsiloActivityTracker()
    private var analysisPsiloIDs: [UUID: UUID] = [:]
    private var batchInProgress = false
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
        demoRootPath = demo ? try Self.canonicalFilePath(directory.deletingLastPathComponent()) : nil
        preferenceStore = try AppPreferenceStore(directory: directory)
        preferences = try preferenceStore.load()
        automaticallyAnalyze = preferences.automaticAnalysis
        reviewDrafts = Dictionary(preferences.reviewDrafts.values.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
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
        analysisPsiloIDs.removeAll()
        psiloTracker.cancel(psiloTracker.activity.id)
        publishPsiloActivity()
    }

    public func refresh() async { await reloadState() }

    public func configure(downloads: URL, roots: [URL]) async {
        await run {
            guard !self.isDemo else { throw AppModelError.demoConfiguration }
            try await self.service.configure(downloads: downloads, roots: roots)
            self.statusMessage = "감시 폴더와 분류할 폴더를 저장했습니다."
        }
    }

    public func importFiles(_ urls: [URL]) async {
        await run {
            // Validate the whole drop before importing any item, so a mixed drop
            // cannot partly enter the demo queue. realpath checks parent symlinks.
            if let demoRootPath = self.demoRootPath {
                for url in urls {
                    let path = try Self.canonicalFilePath(url)
                    guard path == demoRootPath || path.hasPrefix(demoRootPath + "/") else {
                        throw AppModelError.demoFilesOnly
                    }
                }
            }
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

    public func draft(for id: UUID) -> ReviewDraft? { reviewDrafts[id] }

    @discardableResult
    public func prepareDraft(_ id: UUID, reset: Bool = false) -> ReviewDraft? {
        if !reset, let existing = reviewDrafts[id] { return existing }
        guard let entry = entries.first(where: { $0.id == id }), Self.canReview(entry), let settings else {
            errorMessage = OrganizerServiceError.itemNotFound.localizedDescription
            return nil
        }
        let proposal = proposal(for: entry)
        let draft = ReviewDraft(
            itemID: id, name: proposal?.proposedName ?? URL(fileURLWithPath: entry.path).lastPathComponent,
            folderID: proposal?.destinationFolderID ?? settings.folders.first?.id ?? "",
            serialWidth: proposal?.proposedName?.contains("{serial}") == true ? 3 : nil,
            reviewedFingerprint: entry.fingerprint, reviewedProposal: proposal,
            reviewedConfigurationRevision: settings.revision,
            reviewedProposalRevision: settings.proposalRevisions[id.uuidString]
        )
        var next = preferences
        next.reviewDrafts[id.uuidString] = draft
        return savePreferences(next) ? draft : nil
    }

    public func saveDraft(_ draft: ReviewDraft) {
        guard let entry = entries.first(where: { $0.id == draft.itemID }), Self.canReview(entry) else { return }
        // Accept deliberate empty edits, but a delayed binding from an older
        // review must not replace the snapshot established by a newer review.
        if let saved = reviewDrafts[draft.itemID] {
            guard draft.reviewedFingerprint == saved.reviewedFingerprint,
                  draft.reviewedProposal == saved.reviewedProposal,
                  draft.reviewedConfigurationRevision == saved.reviewedConfigurationRevision,
                  draft.reviewedProposalRevision == saved.reviewedProposalRevision else {
                errorMessage = AppModelError.staleDraft.localizedDescription
                return
            }
        } else if isDraftStale(draft) {
            errorMessage = AppModelError.staleDraft.localizedDescription
            return
        }
        var next = preferences
        next.reviewDrafts[draft.itemID.uuidString] = draft
        _ = savePreferences(next)
    }

    public func discardDraft(_ id: UUID) {
        var next = preferences
        next.reviewDrafts[id.uuidString] = nil
        _ = savePreferences(next)
    }

    public func isDraftStale(_ draft: ReviewDraft) -> Bool {
        guard let entry = entries.first(where: { $0.id == draft.itemID }), Self.canReview(entry), let settings else { return true }
        return draft.reviewedFingerprint != entry.fingerprint
            || draft.reviewedProposal != proposal(for: entry)
            || draft.reviewedConfigurationRevision != settings.revision
            || draft.reviewedProposalRevision != settings.proposalRevisions[draft.itemID.uuidString]
            || (entry.proposal != nil && settings.proposalRevisions[draft.itemID.uuidString] != settings.revision)
    }

    public func applyDraft(_ id: UUID) async {
        await run(activity: .organizing, outcome: .filesApplied, subjectIDs: [id]) {
            guard let draft = self.reviewDrafts[id] else { throw AppModelError.reviewRequired }
            _ = try await self.applyReviewedDraft(draft, allowLearning: true)
            self.statusMessage = "파일을 정리했습니다. 이력에서 되돌릴 수 있습니다."
        }
    }

    @discardableResult public func reviewBatch(_ ids: [UUID]) async -> [BatchItemResult] {
        await performBatch(ids, action: .review) { id in
            guard self.prepareDraft(id) != nil else { throw AppModelError.reviewRequired }
            guard let draft = self.reviewDrafts[id], !self.isDraftStale(draft) else { throw AppModelError.staleDraft }
            return nil
        }
    }

    @discardableResult public func applyBatch(_ ids: [UUID]) async -> [BatchItemResult] {
        let reviewedDrafts = reviewDrafts
        return await performBatch(ids, action: .apply) { id in
            guard let draft = reviewedDrafts[id] else { throw AppModelError.reviewRequired }
            return try await self.applyReviewedDraft(draft, allowLearning: false).id
        }
    }

    @discardableResult public func holdBatch(_ ids: [UUID]) async -> [BatchItemResult] {
        await performBatch(ids, action: .hold) { id in
            guard let entry = self.entries.first(where: { $0.id == id }), Self.canReview(entry) else { throw OrganizerServiceError.itemNotFound }
            self.analysisGenerations[id] = nil
            try await self.service.hold(id: id)
            self.demoProposals[id] = nil
            return nil
        }
    }

    @discardableResult public func sendToUnclassifiedBatch(_ ids: [UUID]) async -> [BatchItemResult] {
        await performBatch(ids, action: .unclassified) { id in
            guard let entry = self.entries.first(where: { $0.id == id }), Self.canReview(entry) else { throw OrganizerServiceError.itemNotFound }
            if let draft = self.reviewDrafts[id], self.isDraftStale(draft) { throw AppModelError.staleDraft }
            self.analysisGenerations[id] = nil
            let record = try await self.service.sendToUnclassified(id: id)
            self.demoProposals[id] = nil
            return record.id
        }
    }

    @discardableResult public func undoBatch(_ recordIDs: [UUID]) async -> [BatchItemResult] {
        await performBatch(recordIDs, action: .undo) { id in
            guard self.history.contains(where: { $0.id == id && $0.state == .applied }) else { throw OrganizerServiceError.itemNotFound }
            return try await self.service.undo(recordID: id).id
        }
    }

    public func apply(id: UUID, name: String, folderID: String, serialWidth: Int? = nil, fillGaps: Bool = false, learnForFuture: Bool = false, reviewedFingerprint: String? = nil) async {
        await run(activity: .organizing, outcome: .filesApplied, subjectIDs: [id]) {
            guard let entry = self.entries.first(where: { $0.id == id }),
                  [.ready, .proposed, .held, .failed].contains(entry.status) else {
                throw OrganizerServiceError.itemNotFound
            }
            if let reviewedFingerprint, reviewedFingerprint != entry.fingerprint {
                throw OrganizerServiceError.sourceChanged
            }
            if let draft = self.reviewDrafts[id], self.isDraftStale(draft) { throw AppModelError.staleDraft }
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
        guard !self.batchInProgress else { errorMessage = AppModelError.busy.localizedDescription; return }
        let wasAnalyzing = analysisTasks[id] != nil
        if let activityID = analysisPsiloIDs.removeValue(forKey: id) {
            psiloTracker.cancel(activityID)
            publishPsiloActivity()
        }
        guard !isBusy || wasAnalyzing else { errorMessage = AppModelError.busy.localizedDescription; return }
        analysisGenerations[id] = nil
        analysisTasks.removeValue(forKey: id)?.cancel()
        automaticAnalysisIDs.remove(id)
        demoProposals[id] = nil
        await run(allowConcurrent: wasAnalyzing) {
            try await self.service.hold(id: id)
            self.statusMessage = "파일을 그대로 두고 제안을 보류했습니다."
        }
    }

    public func sendToUnclassified(_ id: UUID) async {
        await run(activity: .organizing, outcome: .filesApplied, subjectIDs: [id]) {
            self.analysisGenerations[id] = nil
            _ = try await self.service.sendToUnclassified(id: id)
            self.demoProposals[id] = nil
            self.statusMessage = "다운로드의 미분류 폴더로 옮겼습니다."
        }
    }

    public func undo(_ id: UUID) async {
        await run(activity: .undo, outcome: .restored, subjectIDs: [id]) {
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
        guard !isDemo else { statusMessage = "데모에서는 API 규칙 분석을 실행하지 않습니다."; return }
        await run(activity: .structureAnalysis, outcome: .rulesReady) {
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

    public func createRule(folderID: String, instruction: String) async {
        await run { _ = try await self.service.createRule(folderID: folderID, instruction: instruction) }
    }

    public func updateRule(id: String, folderID: String, instruction: String) async {
        await run { _ = try await self.service.updateRule(id: id, folderID: folderID, instruction: instruction) }
    }

    public func deleteRule(id: String) async {
        await run { try await self.service.deleteRule(id: id) }
    }

    public func updateCandidate(index: Int, folderID: String, instruction: String) async {
        await run { _ = try await self.service.updateCandidate(index: index, folderID: folderID, instruction: instruction) }
    }

    public func deleteCandidate(index: Int) async {
        await run { try await self.service.deleteCandidate(index: index) }
    }

    public func setWatcherExclusions(extensions: [String], relativeFolders: [String]) async {
        await run { try await self.service.setWatcherExclusions(extensions: extensions, relativeFolders: relativeFolders) }
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
                if let activityID = analysisPsiloIDs.removeValue(forKey: id) { psiloTracker.cancel(activityID) }
                analysisGenerations[id] = nil
                analysisTasks.removeValue(forKey: id)?.cancel()
            }
            automaticAnalysisIDs.removeAll()
            publishPsiloActivity()
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

    private static func canReview(_ entry: InboxEntry) -> Bool {
        [.ready, .proposed, .held, .failed].contains(entry.status)
    }

    private func applyReviewedDraft(_ draft: ReviewDraft, allowLearning: Bool) async throws -> MoveRecord {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OrganizerServiceError.missingName }
        guard !draft.folderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OrganizerServiceError.missingDestination }
        guard let entry = await service.entries().first(where: { $0.id == draft.itemID }), Self.canReview(entry) else { throw OrganizerServiceError.itemNotFound }
        let configuration = try await service.configuration()
        guard draft.reviewedFingerprint == entry.fingerprint,
              draft.reviewedProposal == proposal(for: entry),
              draft.reviewedConfigurationRevision == configuration.revision,
              draft.reviewedProposalRevision == configuration.proposalRevisions[draft.itemID.uuidString],
              entry.proposal == nil || configuration.proposalRevisions[draft.itemID.uuidString] == configuration.revision else {
            throw AppModelError.staleDraft
        }
        if draft.learnForFuture, !allowLearning { throw AppModelError.individualLearningRequired }
        if draft.learnForFuture, entry.proposal != nil, !isDemo {
            _ = try await service.learnCorrection(id: draft.itemID, folderID: draft.folderID, name: draft.name, client: OpenAIClient(apiKey: requireAPIKey()))
        }
        analysisGenerations[draft.itemID] = nil
        let serial = draft.name.contains("{serial}")
            ? draft.serialWidth.map { SerialPolicy(width: $0, allocation: draft.fillGaps ? .fillGap : .appendMax) }
            : nil
        let record = try await service.apply(id: draft.itemID, name: draft.name, folderID: draft.folderID, serial: serial)
        demoProposals[draft.itemID] = nil
        return record
    }

    private func performBatch(_ requestedIDs: [UUID], action: BatchAction, operation: (UUID) async throws -> UUID?) async -> [BatchItemResult] {
        var seen: Set<UUID> = []
        let ids = requestedIDs.filter { seen.insert($0).inserted }
        guard !isBusy else {
            let results = ids.map { BatchItemResult(itemID: $0, action: action, succeeded: false, message: AppModelError.busy.localizedDescription) }
            if !batchInProgress { batchResults = results }
            errorMessage = AppModelError.busy.localizedDescription
            return results
        }
        operationCount += 1
        isBusy = true
        batchInProgress = true
        batchResults = []
        errorMessage = nil
        let kind: PsiloActivity.Kind? = switch action {
        case .apply, .unclassified: .organizing
        case .undo: .undo
        case .review, .hold: nil
        }
        let activityID = !ids.isEmpty ? kind.map { beginPsiloActivity($0, total: ids.count, subjectIDs: Set(ids)) } : nil
        var cancellations = 0
        defer { batchInProgress = false; operationCount -= 1; isBusy = operationCount > 0 }
        for id in ids {
            do {
                try Task.checkCancellation()
                let operationID = try await operation(id)
                batchResults.append(BatchItemResult(itemID: id, action: action, succeeded: true, message: "완료", operationID: operationID))
            } catch {
                if error is CancellationError { cancellations += 1 }
                var operationID: UUID?
                if case OrganizerServiceError.operationCommitted(let committedID) = error {
                    operationID = committedID
                    _ = try? await service.reconcileHistory()
                }
                let message = error is CancellationError ? "작업을 취소했습니다." : error.localizedDescription
                batchResults.append(BatchItemResult(itemID: id, action: action, succeeded: false, message: message, operationID: operationID))
            }
            if let activityID {
                psiloTracker.progress(activityID, completed: batchResults.count)
                publishPsiloActivity()
            }
            await reloadState()
        }
        let completed = batchResults.filter(\.succeeded).count
        statusMessage = "\(completed)개 완료 · \(batchResults.count - completed)개 확인 필요"
        if let activityID {
            if completed == ids.count {
                psiloTracker.succeed(activityID, outcome: action == .undo ? .restored : .filesApplied)
            } else if cancellations == ids.count {
                psiloTracker.cancel(activityID)
            } else {
                let message = batchResults.filter { !$0.succeeded }.prefix(3).map(\.message).joined(separator: "\n")
                psiloTracker.fail(activityID, message: message, partial: completed > 0, completed: completed,
                                  failedSubjectIDs: Set(batchResults.filter { !$0.succeeded }.map(\.itemID)))
            }
            publishPsiloActivity()
        }
        return batchResults
    }

    private func run(allowConcurrent: Bool = false, clearError: Bool = true,
                     activity: PsiloActivity.Kind? = nil, outcome: PsiloActivity.Outcome? = nil, subjectIDs: Set<UUID> = [],
                     _ operation: () async throws -> Void) async {
        guard allowConcurrent || !isBusy else { errorMessage = AppModelError.busy.localizedDescription; return }
        operationCount += 1
        isBusy = true
        let activityID = activity.map { beginPsiloActivity($0, subjectIDs: subjectIDs) }
        if clearError { errorMessage = nil }
        defer { operationCount -= 1; isBusy = operationCount > 0 }
        do {
            try await operation()
            if let activityID, let outcome { psiloTracker.succeed(activityID, outcome: outcome) }
        } catch is CancellationError {
            if let activityID { psiloTracker.cancel(activityID) }
        } catch {
            errorMessage = error.localizedDescription
            if let activityID { psiloTracker.fail(activityID, message: error.localizedDescription) }
        }
        publishPsiloActivity()
        await reloadState()
    }

    @discardableResult private func beginPsiloActivity(_ kind: PsiloActivity.Kind, total: Int = 1, subjectIDs: Set<UUID> = []) -> UUID {
        let id = psiloTracker.begin(kind, total: total, subjectIDs: subjectIDs)
        publishPsiloActivity()
        return id
    }

    private func publishPsiloActivity() {
        if psiloActivity != psiloTracker.activity { psiloActivity = psiloTracker.activity }
        if psiloIssue != psiloTracker.issue { psiloIssue = psiloTracker.issue }
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
        let retainedIDs = Set(updatedEntries.filter { ![.applied, .unclassified].contains($0.status) }.map { $0.id.uuidString })
        let retainedDrafts = preferences.reviewDrafts.filter { retainedIDs.contains($0.key) }
        if retainedDrafts != preferences.reviewDrafts {
            var next = preferences
            next.reviewDrafts = retainedDrafts
            _ = savePreferences(next)
        }
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
        let activityID = beginPsiloActivity(.fileAnalysis, subjectIDs: [id])
        analysisPsiloIDs[id] = activityID
        defer {
            if analysisPsiloIDs[id] == activityID { analysisPsiloIDs[id] = nil }
            psiloTracker.cancel(activityID) // No-op after a current success/failure.
            publishPsiloActivity()
        }
        do {
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
            psiloTracker.succeed(activityID, outcome: .proposalReady)
        } catch is CancellationError {
            psiloTracker.cancel(activityID)
            throw CancellationError()
        } catch {
            psiloTracker.fail(activityID, message: error.localizedDescription)
            throw error
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
        if next == preferences { return true }
        do {
            try preferenceStore.save(next)
            preferences = next
            reviewDrafts = Dictionary(next.reviewDrafts.values.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
            return true
        }
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
                fileID: evidence.id, status: original.lastPathComponent == "다운로드한 문서.txt" ? "ready" : "needsReview", destinationFolderID: folder.id,
                proposedName: filename, reason: "데모용 제안입니다. AI 분석 결과가 아니며 임시 샘플 파일만 사용합니다.",
                evidence: ["임시 샘플 문서"], alternatives: [], missingInformation: []
            )
        }
    }

    private static func canonicalFilePath(_ url: URL) throws -> String {
        guard url.isFileURL, (url.host() ?? "").isEmpty,
              let pointer = realpath(url.path, nil) else { throw AppModelError.demoFilesOnly }
        defer { free(pointer) }
        return String(cString: pointer)
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
    case demoCredentials, demoConfiguration, demoFilesOnly, invalidAPIKey
    case busy, reviewRequired, staleDraft, individualLearningRequired
    var errorDescription: String? {
        switch self {
        case .demoCredentials: "데모 모드에서는 API 키를 읽거나 변경하지 않습니다."
        case .demoConfiguration: "데모에서는 감시 폴더와 분류 폴더를 변경할 수 없습니다. 일반 실행에서 설정하세요."
        case .demoFilesOnly: "데모에서는 앱이 만든 임시 폴더 안의 파일만 사용할 수 있습니다. 외부 파일은 가져오지 않았습니다."
        case .invalidAPIKey: "공백이나 줄바꿈이 없는 API 키를 입력하세요."
        case .busy: "다른 작업이 진행 중입니다. 완료 후 다시 시도하세요."
        case .reviewRequired: "먼저 이름과 폴더를 검토하고 초안을 저장하세요."
        case .staleDraft: "검토한 뒤 파일, 제안 또는 분류 규칙이 바뀌었습니다. 초안을 다시 검토하세요."
        case .individualLearningRequired: "향후 규칙 학습을 선택한 항목은 개별 적용에서 처리하세요. 일괄 적용은 API를 호출하지 않습니다."
        }
    }
}
