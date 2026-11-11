import AppKit
import OrganizerAppSupport
import OrganizerCore
import SwiftUI

/// Confirmation belongs to the exact values on screen, not merely an item ID.
/// Saved drafts survive navigation; their review checkmarks intentionally do not.
@MainActor
struct BatchReviewView: View {
    @ObservedObject var model: OrganizerAppModel
    let entries: [InboxEntry]
    let onOpenIndividual: (UUID) -> Void
    let onOperationStarted: ([InboxEntry]) -> Void
    let onCompleted: (BatchResultReport) -> Void
    @State private var confirmations: [UUID: ReviewDraft] = [:]
    @State private var commonFolderID = ""
    @State private var isRunning = false
    @State private var confirmUnclassified = false

    private var allEditable: Bool { !entries.isEmpty && entries.allSatisfy(\.canBatchReview) }
    private var reviewedCount: Int { entries.filter(isConfirmed).count }
    private var canApply: Bool {
        allEditable && !isRunning && !model.isBusy && reviewedCount == entries.count
    }
    private var canSendToUnclassified: Bool {
        allEditable && !isRunning && !model.isBusy && entries.allSatisfy { entry in
            guard let draft = model.draft(for: entry.id) else { return false }
            return !model.isDraftStale(draft)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(entries.count)개 선택").font(.title2.weight(.semibold))
                        Text("파일마다 이름과 위치를 확인하세요. 편집한 내용은 자동으로 저장됩니다.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    commonDestination
                    Divider()
                    ForEach(entries) { entry in
                        BatchReviewRow(
                            model: model, entry: entry,
                            isConfirmed: Binding(
                                get: { isConfirmed(entry) },
                                set: { confirmed in
                                    confirmations[entry.id] = confirmed ? model.draft(for: entry.id) : nil
                                }
                            ),
                            onOpenIndividual: { onOpenIndividual(entry.id) }
                        )
                        Divider()
                    }
                }.padding(22)
            }
            .disabled(isRunning)
            actions
        }
        .task(id: entries.map(\.id)) {
            for entry in entries where entry.canBatchReview {
                _ = model.prepareDraft(entry.id)
            }
            discardChangedConfirmations()
        }
        .onChange(of: model.reviewDrafts) { _, _ in discardChangedConfirmations() }
        .onChange(of: model.settings?.revision) { _, _ in discardChangedConfirmations() }
        .onChange(of: model.settings?.folders.map(\.id)) { _, ids in
            if ids?.contains(commonFolderID) != true { commonFolderID = "" }
        }
        .confirmationDialog("선택한 \(entries.count)개 파일을 미분류로 보낼까요?", isPresented: $confirmUnclassified) {
            Button("미분류로 보내기") { perform(.unclassified) }
            Button("취소", role: .cancel) { }
        } message: {
            Text("원래 이름으로 다운로드의 미분류 폴더에 이동합니다. 편집한 이름과 제안 위치는 적용하지 않습니다.")
        }
    }

    private var commonDestination: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("선택한 파일의 공통 위치").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                Picker("공통 폴더", selection: $commonFolderID) {
                    Text("폴더 선택").tag("")
                    ForEach(model.settings?.folders ?? [], id: \.id) { folder in
                        Text(ReviewFolderLabel.text(for: folder, in: model.settings?.folders ?? []))
                            .lineLimit(1).truncationMode(.head).help(folder.path).tag(folder.id)
                    }
                }.labelsHidden().frame(maxWidth: .infinity)
                    .accessibilityLabel("선택한 파일의 공통 정리 폴더")
                Button("모두에 지정", action: setCommonDestination)
                    .disabled(!allEditable || commonFolderID.isEmpty || model.isBusy || entries.contains { entry in
                        guard let draft = model.draft(for: entry.id) else { return true }
                        return model.isDraftStale(draft)
                    })
            }
            if let folder = model.settings?.folders.first(where: { $0.id == commonFolderID }) {
                Text(folder.path).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Text("위치를 지정하면 각 파일의 확인 표시가 해제됩니다. 실제 이동은 아래의 적용 버튼으로 실행합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                if isRunning { ProgressView().controlSize(.small) }
                Text(isRunning ? "파일별 결과를 확인하고 있습니다…" : "\(reviewedCount)/\(entries.count)개 이름·위치 확인")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { secondaryActions; Spacer(minLength: 8); applyButton }
                VStack(alignment: .trailing, spacing: 10) {
                    HStack(spacing: 10) { secondaryActions; Spacer(minLength: 0) }
                    applyButton
                }
            }
            Text("실행 직전에 원본과 목적지를 다시 검사합니다. 일부 파일이 실패해도 완료된 파일은 이력에 남습니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22).padding(.bottom, 16)
    }

    @ViewBuilder private var secondaryActions: some View {
        Button("선택 보류") { perform(.hold) }
            .disabled(!allEditable || isRunning || model.isBusy)
            .help("이름과 위치를 바꾸지 않고 보류합니다")
        Button("미분류로 보내기") { confirmUnclassified = true }
            .disabled(!canSendToUnclassified)
    }

    private var applyButton: some View {
        Button("검토 후 적용") { perform(.apply) }
            .disabled(!canApply)
            .help("각 파일의 이름과 위치를 확인하면 적용할 수 있습니다")
    }

    private func isConfirmed(_ entry: InboxEntry) -> Bool {
        guard entry.canBatchReview, let draft = model.draft(for: entry.id),
              confirmations[entry.id] == draft else { return false }
        return BatchDraftValidation.message(for: draft, entry: entry, model: model) == nil
    }

    private func discardChangedConfirmations() {
        let selectedIDs = Set(entries.map(\.id))
        confirmations = confirmations.filter { id, draft in
            selectedIDs.contains(id) && model.draft(for: id) == draft && !model.isDraftStale(draft)
        }
    }

    private func setCommonDestination() {
        guard allEditable, !model.isBusy,
              model.settings?.folders.contains(where: { $0.id == commonFolderID }) == true else { return }
        for entry in entries {
            guard var draft = model.draft(for: entry.id), !model.isDraftStale(draft) else { continue }
            draft.folderID = commonFolderID
            model.saveDraft(draft)
        }
        confirmations = [:]
    }

    private func perform(_ action: BatchAction) {
        guard !isRunning, !model.isBusy else { return }
        if action == .apply && !canApply { return }
        if action == .unclassified && !canSendToUnclassified { return }
        let snapshot = entries
        let ids = snapshot.map(\.id)
        isRunning = true
        onOperationStarted(snapshot)
        Task {
            let results: [BatchItemResult]
            switch action {
            case .apply: results = await model.applyBatch(ids)
            case .hold: results = await model.holdBatch(ids)
            case .unclassified: results = await model.sendToUnclassifiedBatch(ids)
            case .review, .undo: results = []
            }
            isRunning = false
            confirmations = [:]
            onCompleted(BatchResultReport(action: action, results: results, names: Dictionary(
                uniqueKeysWithValues: snapshot.map { ($0.id, URL(fileURLWithPath: $0.path).lastPathComponent) }
            )))
        }
    }
}

@MainActor
private struct BatchReviewRow: View {
    @ObservedObject var model: OrganizerAppModel
    let entry: InboxEntry
    @Binding var isConfirmed: Bool
    let onOpenIndividual: () -> Void
    @State private var resetRequested = false

    private var draft: ReviewDraft? { model.draft(for: entry.id) }
    private var isStale: Bool { draft.map(model.isDraftStale) ?? true }
    private var validationMessage: String? {
        guard entry.canBatchReview else { return "이 파일은 현재 상태에서 일괄 적용할 수 없습니다. 개별 검토에서 확인하세요." }
        guard let draft else { return "검토할 내용을 불러오지 못했습니다. 개별 검토에서 확인하세요." }
        return BatchDraftValidation.message(for: draft, entry: entry, model: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                        .font(.headline).lineLimit(2).textSelection(.enabled)
                    Text(entry.status.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("개별 검토", action: onOpenIndividual).disabled(model.isBusy)
                    .accessibilityLabel("\(URL(fileURLWithPath: entry.path).lastPathComponent) 개별 검토")
            }
            if entry.canBatchReview, let draft {
                VStack(alignment: .leading, spacing: 7) {
                    Text("이름").font(.caption).foregroundStyle(.secondary)
                    TextField("파일 이름", text: binding(\.name, default: ""))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(URL(fileURLWithPath: entry.path).lastPathComponent) 정리할 이름")
                    Text("위치").font(.caption).foregroundStyle(.secondary)
                    Picker("정리할 폴더", selection: binding(\.folderID, default: "")) {
                        Text("폴더 선택").tag("")
                        if !draft.folderID.isEmpty, model.settings?.folders.contains(where: { $0.id == draft.folderID }) != true {
                            Text("목록에서 제거된 폴더").tag(draft.folderID)
                        }
                        ForEach(model.settings?.folders ?? [], id: \.id) { folder in
                            Text(ReviewFolderLabel.text(for: folder, in: model.settings?.folders ?? []))
                                .lineLimit(1).truncationMode(.head).help(folder.path).tag(folder.id)
                        }
                    }.labelsHidden()
                        .accessibilityLabel("\(URL(fileURLWithPath: entry.path).lastPathComponent) 정리할 폴더")
                    if let folder = model.settings?.folders.first(where: { $0.id == draft.folderID }) {
                        Text(folder.path).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if draft.name.contains("{serial}") {
                        Stepper("번호 \(draft.serialWidth ?? 3)자리", value: Binding(
                            get: { draft.serialWidth ?? 3 },
                            set: { binding(\.serialWidth, default: nil).wrappedValue = $0 }
                        ), in: 1...12)
                        Toggle("빈 번호 사용", isOn: binding(\.fillGaps, default: false)).toggleStyle(.checkbox)
                    }
                    Text("확장자는 유지하세요. {serial}은 적용 시 순서대로 배정됩니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.disabled(isStale || model.isBusy)
                if let proposal = draft.reviewedProposal {
                    Text(proposal.reason).font(.caption).foregroundStyle(.secondary)
                    if !proposal.missingInformation.isEmpty {
                        Text("확인 필요: " + proposal.missingInformation.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if entry.canBatchReview, draft != nil, isStale {
                    Button("최신 내용으로 초안 다시 불러오기") { resetRequested = true }
                        .font(.caption).disabled(model.isBusy)
                }
            }
            Toggle("이름과 위치 확인", isOn: $isConfirmed)
                .toggleStyle(.checkbox).font(.callout)
                .accessibilityLabel("\(URL(fileURLWithPath: entry.path).lastPathComponent) 이름과 위치 확인")
                .disabled(validationMessage != nil || model.isBusy)
        }
        .padding(.vertical, 2)
        .confirmationDialog("최신 내용으로 초안을 바꿀까요?", isPresented: $resetRequested) {
            Button("최신 내용 불러오기") {
                isConfirmed = false
                _ = model.prepareDraft(entry.id, reset: true)
            }
            Button("취소", role: .cancel) { }
        } message: {
            Text("이 파일에서 편집한 이름과 위치를 현재 제안으로 초기화합니다. 규칙 변경으로 제안이 오래되었다면 개별 검토에서 다시 분석해야 합니다.")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ReviewDraft, Value>, default fallback: Value) -> Binding<Value> {
        Binding(get: { draft?[keyPath: keyPath] ?? fallback }, set: { value in
            guard var updated = model.draft(for: entry.id), !model.isDraftStale(updated), !model.isBusy else { return }
            isConfirmed = false
            updated[keyPath: keyPath] = value
            if updated.name.contains("{serial}"), updated.serialWidth == nil { updated.serialWidth = 3 }
            model.saveDraft(updated)
        })
    }
}

@MainActor
private enum BatchDraftValidation {
    static func message(for draft: ReviewDraft, entry: InboxEntry, model: OrganizerAppModel) -> String? {
        if model.isDraftStale(draft) { return "원본이나 규칙이 변경되었습니다. 최신 내용을 다시 검토하세요." }
        if draft.learnForFuture {
            return "향후 규칙 반영이 선택된 파일입니다. 개별 검토에서 적용하거나 해당 선택을 해제하세요. 일괄 작업에서는 규칙 후보를 만들지 않습니다."
        }
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "파일 이름을 입력하세요." }
        if draft.name.contains("/") || draft.name.contains(":") || draft.name == "." || draft.name == ".." {
            return "파일 이름에는 /, : 또는 경로를 사용할 수 없습니다."
        }
        // File-vs-folder extension checks belong to the service: a directory
        // may legitimately contain a dot in its name and has no extension.
        let serialParts = draft.name.components(separatedBy: "{serial}")
        if serialParts.count > 2 { return "이름에는 {serial}을 한 번만 넣을 수 있습니다." }
        if model.settings?.folders.contains(where: { $0.id == draft.folderID }) != true { return "현재 목록에서 정리할 폴더를 선택하세요." }
        return nil
    }
}

private extension InboxEntry {
    var canBatchReview: Bool { [.ready, .proposed, .held, .failed].contains(status) }
}

/// The meaningful destination stays visible even when a sandbox or home prefix
/// is long. Matching suffixes expand just enough to distinguish configured roots.
enum ReviewFolderLabel {
    static func text(for folder: FolderRecord, in folders: [FolderRecord]) -> String {
        let components = folder.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return folder.path }
        let peers = folders.filter { $0.id != folder.id }.map { $0.path.split(separator: "/").map(String.init) }
        var count = 1
        while count < components.count && peers.contains(where: { $0.suffix(count) == components.suffix(count) }) {
            count += 1
        }
        return components.suffix(count).joined(separator: " › ")
    }
}

struct BatchResultReport: Identifiable {
    let id = UUID()
    let action: BatchAction
    let results: [BatchItemResult]
    let names: [UUID: String]

    var title: String {
        switch action {
        case .review: "일괄 검토 결과"
        case .apply: "일괄 정리 결과"
        case .hold: "보류 결과"
        case .unclassified: "미분류 이동 결과"
        case .undo: "되돌리기 결과"
        }
    }
}

@MainActor
struct BatchResultsView: View {
    let report: BatchResultReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BatchResultsContent(report: report)
            HStack {
                Spacer()
                Button("확인") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 500, idealWidth: 560, minHeight: 320, idealHeight: 420)
    }
}

private struct BatchResultsContent: View {
    let report: BatchResultReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.title).font(.title2.weight(.semibold))
            Text("\(report.results.filter(\.succeeded).count)개 완료 · \(report.results.filter { !$0.succeeded }.count)개 확인 필요")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(report.results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: result.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(report.names[result.itemID] ?? "파일").font(.headline).textSelection(.enabled)
                                Text(result.succeeded ? "완료" : result.message)
                                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                if !result.succeeded && result.operationID != nil {
                                    Text("파일 이동이 이미 기록되었을 수 있습니다. 다시 실행하기 전에 정리 이력을 확인하세요.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
            if report.results.contains(where: { !$0.succeeded }) {
                Text("완료된 항목은 다시 실행하지 않습니다. 확인이 필요한 파일을 검토한 뒤 개별적으로 다시 시도하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct BatchUndoReviewView: View {
    @ObservedObject var model: OrganizerAppModel
    let records: [MoveRecord]
    @Environment(\.dismiss) private var dismiss
    @State private var report: BatchResultReport?
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let report {
                BatchResultsContent(report: report)
                HStack { Spacer(); Button("확인") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Text("\(records.count)개 파일 되돌리기").font(.title2.weight(.semibold))
                Text("아래의 원래 이름과 위치로 복원합니다. 파일이 변경되었거나 원래 위치에 다른 파일이 있으면 해당 항목은 중단합니다.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.destination.lastPathComponent).font(.headline)
                                Text("현재: " + record.destination.path).font(.caption).foregroundStyle(.secondary)
                                Text("복원: " + record.source.path).font(.caption).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
                HStack {
                    if isRunning { ProgressView().controlSize(.small); Text("되돌리는 중…").font(.caption) }
                    Spacer()
                    Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isRunning)
                    Button("\(records.count)개 되돌리기", action: undo)
                        .disabled(isRunning || model.isBusy || records.isEmpty)
                }
            }
        }
        .padding(24).frame(minWidth: 540, idealWidth: 620, minHeight: 360, idealHeight: 460)
        .interactiveDismissDisabled(isRunning)
    }

    private func undo() {
        guard !isRunning, !model.isBusy else { return }
        isRunning = true
        Task {
            let results = await model.undoBatch(records.map(\.id))
            report = BatchResultReport(action: .undo, results: results, names: Dictionary(
                uniqueKeysWithValues: records.map { ($0.id, $0.destination.lastPathComponent) }
            ))
            isRunning = false
        }
    }
}
