import AppKit
import OrganizerAppSupport
import OrganizerCore
import OrganizerDesignSystem
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct OrganizerMainView: View {
    @ObservedObject var model: OrganizerAppModel
    @State private var section: String? = "review"
    @State private var search = ""
    @State private var showingSettings = false
    @State private var dropTargeted = false
    @State private var selectedEntryIDs: Set<UUID> = []
    @State private var activeBatchEntries: [InboxEntry]?
    @State private var batchReport: BatchResultReport?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: OrganizerAppModel) { self.model = model }

    private var sidebarItems: [LiquidSidebarItem] {
        [
            .init(id: "review", title: "검토함", systemImage: "tray", count: model.entries.filter { $0.status.isReviewable }.count),
            .init(id: "unclassified", title: "미분류", systemImage: "folder", count: model.entries.filter { $0.status == .unclassified }.count),
            .init(id: "held", title: "보류", systemImage: "pause.circle", count: model.entries.filter { $0.status == .held }.count),
            .init(id: "history", title: "정리 이력", systemImage: "clock.arrow.circlepath"),
            .init(id: "rules", title: "분류 규칙", systemImage: "slider.horizontal.3")
        ]
    }

    private var displayedEntries: [InboxEntry] {
        model.entries.filter { entry in
            let belongs: Bool
            switch section {
            case "unclassified": belongs = entry.status == .unclassified
            case "held": belongs = entry.status == .held
            default: belongs = entry.status.isReviewable
            }
            return belongs && (search.isEmpty || URL(fileURLWithPath: entry.path).lastPathComponent.localizedCaseInsensitiveContains(search))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private var selectedEntry: InboxEntry? {
        displayedEntries.first { selectedEntryIDs.contains($0.id) }
    }

    private var selectedEntries: [InboxEntry] {
        activeBatchEntries ?? displayedEntries.filter { selectedEntryIDs.contains($0.id) }
    }

    private var listSelection: Binding<Set<UUID>> {
        Binding(get: { selectedEntryIDs }, set: { ids in
            selectedEntryIDs = ids
            if !ids.contains(model.selectedItemID ?? UUID()) {
                model.selectedItemID = displayedEntries.first { ids.contains($0.id) }?.id
            }
        })
    }

    /// A search/filter with no matches does not mean that the app has no files.
    private var showsCentralPsilo: Bool {
        // Completed journal entries remain in storage after the inbox is empty.
        model.settings == nil || (model.entries.allSatisfy { $0.status == .applied }
                                  && section == "review" && search.isEmpty)
    }

    private var psiloCaption: String {
        if model.psiloIssue != nil && model.psiloActivity.phase != .working {
            return "문제를 확인하고 있어요"
        }
        if model.psiloActivity.phase == .idle || model.psiloActivity.phase == .cancelled {
            return "필요하면 다시 살펴볼게요"
        }
        return model.psiloActivity.statusLabel
    }

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            LiquidSidebarLayout(items: sidebarItems, selection: $section, sidebarWidth: 190) {
                if model.settings == nil {
                    setupEmptyState
                } else if section == "history" {
                    HistoryView(model: model)
                } else if section == "rules" {
                    RuleManagementView(model: model)
                } else {
                    reviewContent
                }
            }
            footer
        }
        .frame(minWidth: 960, minHeight: 620)
        // One persistent renderer changes position rather than being recreated
        // between the empty state and sidebar. Its current pose is retained.
        .overlayPreferenceValue(PsiloPlacementPreferenceKey.self) { anchor in
            psiloOverlay(anchor: anchor)
        }
        .liquidCustomTitlebar()
        .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
        .sheet(item: $batchReport) { BatchResultsView(report: $0) }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("확인") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: section) { _, _ in
            selectedEntryIDs = []
            selectFirstIfNeeded()
        }
        .onChange(of: displayedEntries.map(\.id)) { _, _ in selectFirstIfNeeded() }
        .onChange(of: model.selectedItemID) { _, id in
            // A proposal opened from the menu bar or an imported file can
            // become the primary selection without breaking a local group.
            if let id, !selectedEntryIDs.contains(id), displayedEntries.contains(where: { $0.id == id }) {
                selectedEntryIDs = [id]
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OrganizerOpenSettings"))) { _ in
            showingSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OrganizerShowReview"))) { _ in
            section = "review"
            search = ""
            selectedEntryIDs = model.selectedItemID.map { [$0] } ?? []
            selectFirstIfNeeded()
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: acceptDrop)
        .overlay(alignment: .top) {
            if dropTargeted {
                Text(model.settings == nil ? "먼저 관리할 폴더를 설정하세요" : "놓아서 검토함에 추가")
                    .font(.headline)
                    .padding(14)
                    .liquidGlass()
                    .padding(.top, 68)
                    .allowsHitTesting(false)
            }
        }
    }

    private func psiloOverlay(anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { geometry in
            let placement = PsiloPlacement(anchor: anchor, geometry: geometry)

            // The representable is always the first child of this VStack. Only
            // its frame/position change; there are never two live viewports.
            VStack(spacing: 6) {
                Psilo3DView(
                    activity: model.psiloActivity,
                    issue: model.psiloIssue,
                    isPresented: !showingSettings && batchReport == nil
                )
                .frame(width: placement.viewportSize.width, height: placement.viewportSize.height)
                .accessibilityHidden(true)
                if !placement.isCentral {
                    Text(psiloCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .frame(width: placement.size.width, height: placement.size.height)
            .position(placement.center)
            .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.08), value: placement.isCentral)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("실로")
            .accessibilityValue(psiloCaption)
        }
        .allowsHitTesting(false)
    }

    private var titlebar: some View {
        HStack(spacing: 16) {
            LiquidWindowControls()
            Text("NeaTree").font(.system(size: 13, weight: .semibold))
            if model.isDemo {
                Text("데모").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if model.isBusy { ProgressView().controlSize(.small).accessibilityLabel("작업 중") }
            TextField("파일 검색", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .accessibilityLabel("파일 검색")
                .disabled(section == "history" || section == "rules")
            Button { importFiles() } label: { Image(systemName: "plus") }
                .help("파일 또는 폴더 가져오기")
                .accessibilityLabel("파일 또는 폴더 가져오기")
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.settings == nil || model.isBusy)
            Button { Task { await model.scanNow() } } label: { Image(systemName: "arrow.clockwise") }
                .help("다운로드 폴더 확인")
                .accessibilityLabel("다운로드 폴더 확인")
                .disabled(model.settings == nil || model.isBusy)
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .help("설정")
                .accessibilityLabel("설정")
                .keyboardShortcut(",", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(.ultraThinMaterial)
    }

    private var setupEmptyState: some View {
        VStack(spacing: 16) {
            centralPsiloSpace
            Text("정리할 폴더를 선택하세요").font(.title2.weight(.semibold))
            Text("다운로드 폴더와 파일을 보관할 폴더를 지정하면 시작할 수 있습니다.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("폴더 설정") { showingSettings = true }
                .buttonStyle(LiquidGlassButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewContent: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(sidebarItems.first(where: { $0.id == section })?.title ?? "검토함")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if section == "review" {
                        Button("모두 분석") { Task { await model.analyzeAll() } }
                            .disabled(model.isBusy || !(model.hasAPIKey || model.isDemo) || displayedEntries.isEmpty)
                    }
                }
                .padding(18)
                List(selection: listSelection) {
                    ForEach(displayedEntries) { entry in
                        FileListRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu {
                                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([model.actualURL(for: entry)]) }
                                if entry.status == .unclassified {
                                    Button("다시 검토") { Task { await model.revisit(entry.id) } }
                                } else if entry.status != .pending && entry.status != .missing {
                                    Button("분석") { Task { await model.analyze(entry.id) } }
                                        .disabled(!(model.hasAPIKey || model.isDemo) || model.isBusy)
                                    Button("보류") { Task { await model.hold(entry.id) } }
                                        .disabled(model.isBusy)
                                }
                            }
                    }
                }
                .listStyle(.inset)
                .disabled(activeBatchEntries != nil)
                .overlay {
                    if displayedEntries.isEmpty {
                        Group {
                            if showsCentralPsilo {
                                VStack(spacing: 16) {
                                    centralPsiloSpace
                                    Text("새 파일을 기다리고 있어요")
                                        .font(.headline)
                                    Text("파일을 끌어놓으면 이름과 위치를 함께 정리해요.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .padding(20)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "tray").font(.title).foregroundStyle(.secondary)
                                    Text(search.isEmpty ? "검토할 파일이 없습니다" : "검색 결과가 없습니다")
                                        .foregroundStyle(.secondary)
                                    if search.isEmpty && section == "review" {
                                        Text("파일을 끌어놓거나 가져오기를 누르세요.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }
                if !displayedEntries.isEmpty {
                    HStack {
                        Text(selectedEntryIDs.count > 1 ? "\(selectedEntryIDs.count)개 선택" : "⌘ 또는 ⇧로 여러 파일 선택")
                        Spacer(minLength: 8)
                        if selectedEntryIDs.count > 1 {
                            Button("선택 해제") {
                                selectedEntryIDs = []
                                model.selectedItemID = nil
                            }.buttonStyle(.link).disabled(model.isBusy)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                }
            }
            .frame(minWidth: 250, idealWidth: 310)
            Group {
                if selectedEntries.count > 1 {
                    BatchReviewView(
                        model: model, entries: selectedEntries,
                        onOpenIndividual: { id in
                            selectedEntryIDs = [id]
                            model.selectedItemID = id
                        },
                        onOperationStarted: { activeBatchEntries = $0 },
                        onCompleted: { report in
                            batchReport = report
                            activeBatchEntries = nil
                            selectFirstIfNeeded()
                        }
                    )
                } else if let entry = selectedEntry {
                    ReviewDetailView(model: model, entry: entry).id(entry.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34, weight: .light))
                        Text("파일을 선택해 제안을 검토하세요")
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, idealWidth: 450)
        }
    }

    private var centralPsiloSpace: some View {
        Color.clear
            .frame(width: 144, height: 114)
            .anchorPreference(key: PsiloPlacementPreferenceKey.self, value: .bounds) { $0 }
            .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.statusMessage ?? "\(model.entries.filter { $0.status.isReviewable }.count)개 검토 대기")
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(model.watching ? "다운로드 감시 중" : "감시 일시중지")
            Button(model.watching ? "일시중지" : "감시 시작") { model.setWatching(!model.watching) }
                .buttonStyle(.link)
                .disabled(model.settings == nil)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(.ultraThinMaterial)
    }

    private func selectFirstIfNeeded() {
        guard section != "history", section != "rules", activeBatchEntries == nil else { return }
        let available = Set(displayedEntries.map(\.id))
        selectedEntryIDs.formIntersection(available)
        if selectedEntryIDs.isEmpty {
            let id = model.selectedItemID.flatMap { available.contains($0) ? $0 : nil } ?? displayedEntries.first?.id
            selectedEntryIDs = id.map { [$0] } ?? []
        }
        if !selectedEntryIDs.contains(model.selectedItemID ?? UUID()) {
            model.selectedItemID = displayedEntries.first { selectedEntryIDs.contains($0.id) }?.id
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.title = "검토할 파일 또는 폴더 가져오기"
        panel.prompt = "가져오기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        section = "review"
        let urls = panel.urls
        Task { await model.importFiles(urls) }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.settings != nil else { showingSettings = true; return false }
        let accepted = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !accepted.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in accepted {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                            continuation.resume(returning: nil)
                            return
                        }
                        continuation.resume(returning: url)
                    }
                }
                if let url { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            section = "review"
            await model.importFiles(urls)
        }
        return true
    }
}

private struct PsiloPlacementPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct PsiloPlacement {
    let isCentral: Bool
    let size: CGSize
    let viewportSize: CGSize
    let center: CGPoint

    init(anchor: Anchor<CGRect>?, geometry: GeometryProxy) {
        if let anchor {
            let rect: CGRect = geometry[anchor]
            isCentral = true
            size = rect.size
            viewportSize = rect.size
            center = CGPoint(x: rect.midX, y: rect.midY)
        } else {
            isCentral = false
            size = CGSize(width: 150, height: 112)
            viewportSize = CGSize(width: 88, height: 76)
            // Stay within the sidebar, above the existing 32pt status bar.
            let sidebarMidX: CGFloat = 95
            let bottomInset: CGFloat = 32 + 18 + size.height / 2
            center = CGPoint(x: sidebarMidX, y: geometry.size.height - bottomInset)
        }
    }
}

private struct FileListRow: View {
    let entry: InboxEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: URL(fileURLWithPath: entry.path).pathExtension.isEmpty ? "folder" : "doc")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: entry.path).lastPathComponent).lineLimit(2)
                Text(entry.status.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct ReviewDetailView: View {
    @ObservedObject var model: OrganizerAppModel
    let entry: InboxEntry
    @State private var evidence: FileEvidence?
    @State private var duplicateReport: DuplicateReport?
    @State private var checkingDuplicates = false
    @State private var showingQuickLook = false

    private var proposal: FileProposal? { model.proposal(for: entry) }
    private var draft: ReviewDraft {
        model.draft(for: entry.id) ?? ReviewDraft(
            itemID: entry.id,
            name: proposal?.proposedName ?? URL(fileURLWithPath: entry.path).lastPathComponent,
            folderID: proposal?.destinationFolderID ?? "",
            reviewedFingerprint: entry.fingerprint, reviewedProposal: proposal,
            reviewedConfigurationRevision: model.settings?.revision ?? entry.id,
            reviewedProposalRevision: model.settings?.proposalRevisions[entry.id.uuidString]
        )
    }
    private var isDirty: Bool {
        draft.name != (draft.reviewedProposal?.proposedName ?? URL(fileURLWithPath: entry.path).lastPathComponent)
            || draft.folderID != (draft.reviewedProposal?.destinationFolderID ?? "")
    }
    private var canEdit: Bool { [.ready, .proposed, .held, .failed].contains(entry.status) }
    private var hasStaleSource: Bool { model.isDraftStale(draft) }
    private var validDestination: Bool { model.settings?.folders.contains(where: { $0.id == draft.folderID }) == true }
    private var canApply: Bool {
        canEdit && model.draft(for: entry.id) != nil && !hasStaleSource
            && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validDestination && !model.isBusy
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<ReviewDraft, Value>) -> Binding<Value> {
        Binding(get: { draft[keyPath: keyPath] }, set: { value in
            guard var updated = model.draft(for: entry.id) else { return }
            updated[keyPath: keyPath] = value
            if updated.name.contains("{serial}"), updated.serialWidth == nil { updated.serialWidth = 3 }
            model.saveDraft(updated)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                            .font(.title3.weight(.semibold))
                            .textSelection(.enabled)
                        Text(entry.status.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([model.actualURL(for: entry)]) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Finder에서 보기")
                    .accessibilityLabel("Finder에서 보기")
                }
                if entry.status == .unclassified {
                    Text("미분류에 보관된 파일입니다. 다시 검토하면 현재 규칙으로 새 제안을 받을 수 있습니다.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("다시 검토") { Task { await model.revisit(entry.id) } }
                        .buttonStyle(LiquidGlassButtonStyle()).disabled(model.isBusy)
                } else if canEdit {
                    proposalEditor
                } else if let note = entry.note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                preview
                duplicateSection
            }
            .padding(22)
        }
        .task(id: canEdit) { if canEdit { _ = model.prepareDraft(entry.id) } }
        .task(id: entry.fingerprint) {
            duplicateReport = nil
            evidence = await model.inspect(entry.id)
        }
        .sheet(isPresented: $showingQuickLook) {
            QuickLookPreview(url: model.actualURL(for: entry))
        }
    }

    private var proposalEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(proposal == nil ? "직접 정리" : "정리 제안").font(.headline)
                Spacer()
                Button(proposal == nil ? "분석" : "다시 분석") {
                    Task {
                        await model.analyze(entry.id)
                        if model.errorMessage == nil {
                            loadCurrentProposal()
                        }
                    }
                }
                    .disabled(model.isBusy || !(model.hasAPIKey || model.isDemo))
            }
            if !model.hasAPIKey && !model.isDemo {
                Text("설정에서 API 키를 추가하면 내용 분석과 제안을 사용할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if hasStaleSource {
                VStack(alignment: .leading, spacing: 8) {
                    Text("파일이나 분류 규칙이 변경되었습니다. 현재 내용을 다시 검토한 뒤 적용하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("현재 파일로 다시 검토", action: loadCurrentProposal)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("이름").font(.caption).foregroundStyle(.secondary)
                TextField("파일명", text: draftBinding(\.name)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("정리할 파일 이름")
                Text("확장자는 유지하세요. 번호를 배정하려면 {serial}을 넣으세요.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("위치").font(.caption).foregroundStyle(.secondary)
                Picker("정리할 폴더", selection: draftBinding(\.folderID)) {
                    Text("폴더 선택").tag("")
                    ForEach(model.settings?.folders ?? [], id: \.id) { folder in
                        Text(ReviewFolderLabel.text(for: folder, in: model.settings?.folders ?? []))
                            .lineLimit(1).truncationMode(.head).help(folder.path).tag(folder.id)
                    }
                }
                .labelsHidden()
                if let folder = model.settings?.folders.first(where: { $0.id == draft.folderID }) {
                    Text(folder.path).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            if draft.name.contains("{serial}") {
                HStack {
                    Stepper("번호 \(draft.serialWidth ?? 3)자리", value: Binding(
                        get: { draft.serialWidth ?? 3 },
                        set: { draftBinding(\.serialWidth).wrappedValue = $0 }
                    ), in: 1...12)
                    Toggle("빈 번호 사용", isOn: draftBinding(\.fillGaps)).toggleStyle(.checkbox)
                }
                .font(.caption)
            }
            if let proposal {
                VStack(alignment: .leading, spacing: 8) {
                    Text(proposal.reason).font(.callout)
                    ForEach(Array(proposal.evidence.enumerated()), id: \.offset) { _, item in
                        Text("• \(item)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !proposal.missingInformation.isEmpty {
                        Text("확인 필요: " + proposal.missingInformation.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !proposal.alternatives.isEmpty {
                        Menu("다른 위치 후보") {
                            ForEach(Array(proposal.alternatives.enumerated()), id: \.offset) { _, alternative in
                                if let folder = model.settings?.folders.first(where: { $0.id == alternative.folderID }) {
                                    Button("\(ReviewFolderLabel.text(for: folder, in: model.settings?.folders ?? [])) — \(alternative.reason)") {
                                        draftBinding(\.folderID).wrappedValue = folder.id
                                    }.help(folder.path)
                                }
                            }
                        }
                    }
                }
                if isDirty {
                    Toggle("이 수정으로 앞으로 사용할 규칙 후보 만들기", isOn: draftBinding(\.learnForFuture))
                        .font(.caption)
                        .toggleStyle(.checkbox)
                        .disabled(!model.hasAPIKey || model.isDemo)
                    if draft.learnForFuture {
                        Text("규칙은 후보로 저장되며 분류 규칙 화면에서 확인한 뒤 사용됩니다.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            LiquidGlassGroup(spacing: 8) {
                HStack(spacing: 12) {
                    Button("보류") { Task { await model.hold(entry.id) } }
                        .disabled(model.isBusy)
                    Button("미분류로 보내기") { Task { await model.sendToUnclassified(entry.id) } }
                        .disabled(model.isBusy)
                    Spacer(minLength: 0)
                    Button("적용") {
                        Task { await model.applyDraft(entry.id) }
                    }
                    .disabled(!canApply)
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .controlSize(.small)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("내용 미리보기").font(.headline)
                Spacer(minLength: 8)
                Button("원본 미리보기") { showingQuickLook = true }
                    .disabled(entry.status == .missing || entry.status == .pending)
                    .help("Quick Look으로 원본 파일을 확인합니다")
            }
            if let evidence {
                Text(evidence.readStatus.readStatusLabel).font(.caption).foregroundStyle(.secondary)
                if evidence.extractedText.isEmpty {
                    Text("텍스트로 읽을 수 없는 자료입니다. 원본 미리보기에서 확인하세요.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(String(evidence.extractedText.prefix(6_000)))
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(height: 170)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    if evidence.extractedText.count > 6_000 {
                        Text("미리보기에는 앞부분만 표시합니다.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("내용을 확인하는 중입니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var duplicateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("중복 확인").font(.headline)
                Spacer()
                if checkingDuplicates { ProgressView().controlSize(.small) }
                Button("동일 내용 찾기") {
                    checkingDuplicates = true
                    Task {
                        duplicateReport = await model.duplicates(entry.id)
                        checkingDuplicates = false
                    }
                }
                .disabled(checkingDuplicates || model.isBusy)
            }
            if let report = duplicateReport {
                Text(report.matches.isEmpty ? "확인한 범위에서 동일한 파일을 찾지 못했습니다." : "동일한 내용의 파일 \(report.matches.count)개")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(report.matches, id: \.self) { path in
                    Button(path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        .buttonStyle(.link).font(.caption).lineLimit(2)
                }
                if report.truncated {
                    Text("검사 한도 또는 읽기 실패로 일부 파일은 확인하지 못했습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadCurrentProposal() {
        _ = model.prepareDraft(entry.id, reset: true)
    }
}

@MainActor
private struct HistoryView: View {
    @ObservedObject var model: OrganizerAppModel
    @State private var selection: Set<UUID> = []
    @State private var undoRequest: UndoRequest?

    private var selectedRecords: [MoveRecord] {
        model.history.filter { selection.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
    }
    private var restorableRecords: [MoveRecord] { selectedRecords.filter { $0.state == .applied } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("정리 이력").font(.title2.weight(.semibold))
                Spacer(minLength: 12)
                if !selection.isEmpty {
                    Text("\(selection.count)개 선택").font(.callout).foregroundStyle(.secondary)
                    Button("선택 되돌리기") { undoRequest = UndoRequest(records: restorableRecords) }
                        .disabled(restorableRecords.isEmpty || model.isBusy)
                }
            }
            if model.history.isEmpty {
                Text("아직 정리한 파일이 없습니다.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(model.history.sorted { $0.createdAt > $1.createdAt }) { record in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.destination.lastPathComponent).font(.headline)
                                Text(record.source.path + " → " + record.destination.path)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(record.state.displayName) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let detail = record.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Button("되돌리기") { undoRequest = UndoRequest(records: [record]) }
                                .disabled(record.state != .applied || model.isBusy)
                        }
                        .padding(.vertical, 8).tag(record.id)
                    }
                }
                .listStyle(.inset)
                Text(selection.isEmpty
                     ? "⌘ 또는 ⇧로 여러 항목을 선택해 함께 되돌릴 수 있습니다."
                     : "선택한 \(selection.count)개 중 \(restorableRecords.count)개를 되돌릴 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .sheet(item: $undoRequest) { BatchUndoReviewView(model: model, records: $0.records) }
        .onChange(of: model.history.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
    }

    private struct UndoRequest: Identifiable {
        let id = UUID()
        let records: [MoveRecord]
    }
}

extension InboxStatus {
    var isReviewable: Bool { [.pending, .ready, .proposed, .failed, .missing].contains(self) }
    var displayName: String {
        switch self {
        case .pending: "다운로드 완료 대기"
        case .ready: "분석 대기"
        case .held: "보류"
        case .proposed: "제안 준비됨"
        case .applied: "정리 완료"
        case .unclassified: "미분류"
        case .failed: "확인 필요"
        case .missing: "원본을 찾을 수 없음"
        }
    }
}

private extension MoveRecord.State {
    var displayName: String {
        switch self {
        case .pending: "이동 확인 중"
        case .applied: "정리 완료"
        case .undoPending: "되돌리기 확인 중"
        case .undone: "되돌림"
        case .failed: "실패"
        }
    }
}

private extension String {
    var readStatusLabel: String {
        switch self {
        case "full_text": "텍스트를 읽었습니다."
        case "partial_text": "분석 한도 내에서 텍스트 일부를 읽었습니다."
        case "directory_listing": "폴더 내부 목록입니다."
        case "partial_directory_listing": "폴더 내부 목록 일부입니다."
        case "locked_pdf": "잠긴 PDF입니다."
        case "unreadable_pdf": "PDF를 읽지 못했습니다."
        case "oversized_pdf": "PDF가 읽기 한도를 초과했습니다."
        case "no_text_extracted": "추출할 수 있는 텍스트가 없습니다."
        case "ocr_text": "기기의 OCR로 읽은 텍스트입니다. 인식 오류가 있을 수 있습니다."
        case "partial_ocr_text": "한도 내에서 OCR로 일부를 읽었습니다. 원본과 확인하세요."
        case "no_text_recognized": "OCR에서 읽을 수 있는 글자를 찾지 못했습니다."
        case "ocr_limit": "OCR 처리 한도를 초과했습니다. 원본을 확인하세요."
        case "ocr_failed": "OCR을 완료하지 못했습니다. 원본을 확인하세요."
        case "oversized_image", "image_pixel_limit": "이미지가 OCR 크기 한도를 초과했습니다."
        case "unreadable_image": "이미지를 읽지 못했습니다."
        default: "이 형식의 텍스트를 추출하지 못했습니다."
        }
    }
}
