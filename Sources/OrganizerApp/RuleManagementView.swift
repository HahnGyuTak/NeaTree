import AppKit
import OrganizerAppSupport
import OrganizerCore
import SwiftUI

@MainActor
struct RuleManagementView: View {
    @ObservedObject var model: OrganizerAppModel
    @State private var editing: RuleEditorTarget?
    @State private var deleting: RuleEditorTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("분류 규칙").font(.title2.weight(.semibold))
                    Spacer()
                    Button("폴더 구조 분석") { Task { await model.analyzeStructure() } }
                        .disabled(!model.hasAPIKey || model.isDemo || model.isBusy || model.settings?.folders.isEmpty != false)
                    Button("규칙 추가") { editing = .init(kind: .new) }
                        .disabled(model.isBusy || model.settings?.folders.isEmpty != false)
                }
                Text("확정한 규칙만 새 제안에 사용합니다. 규칙을 바꾸면 이전 제안은 다시 검토해야 합니다.")
                    .font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text("확정한 규칙").font(.headline)
                    if model.settings?.rules.isEmpty != false {
                        Text("규칙을 추가하거나 폴더 구조를 분석해 시작하세요.")
                            .foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach(model.settings?.rules ?? [], id: \.id) { rule in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(folderPath(rule.folderID)).font(.subheadline.weight(.medium))
                                    .lineLimit(2).truncationMode(.middle).help(folderPath(rule.folderID))
                                Text(rule.instruction).font(.callout).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Spacer(minLength: 12)
                            Button("편집") { editing = .init(kind: .rule(rule)) }
                                .accessibilityLabel("\(folderPath(rule.folderID)) 규칙 편집")
                            Button("삭제") { deleting = .init(kind: .rule(rule)) }
                                .accessibilityLabel("\(folderPath(rule.folderID)) 규칙 삭제")
                        }
                        .disabled(model.isBusy).padding(.vertical, 8)
                        Divider()
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("검토할 규칙 후보").font(.headline)
                    if model.settings?.candidates.isEmpty != false {
                        Text("규칙 후보가 없습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(Array((model.settings?.candidates ?? []).enumerated()), id: \.offset) { index, candidate in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(folderPath(candidate.folderID)).font(.subheadline.weight(.medium))
                                .lineLimit(2).truncationMode(.middle).help(folderPath(candidate.folderID))
                            Text(candidate.instruction).textSelection(.enabled)
                            ForEach(Array(candidate.evidence.enumerated()), id: \.offset) { _, evidence in
                                Text("• \(evidence)").font(.caption).foregroundStyle(.secondary)
                            }
                            if !candidate.uncertainties.isEmpty {
                                Text("확인 필요: " + candidate.uncertainties.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("편집") { editing = .init(kind: .candidate(index, candidate)) }
                                Button("삭제") { deleting = .init(kind: .candidate(index, candidate)) }
                                Spacer()
                                Button("규칙 확정") {
                                    let target = RuleEditorTarget(kind: .candidate(index, candidate))
                                    Task {
                                        guard target.isCurrent(in: model) else {
                                            model.errorMessage = "규칙 후보가 변경되었습니다. 현재 내용을 확인한 뒤 다시 확정하세요."
                                            return
                                        }
                                        await model.confirmRule(index)
                                    }
                                }
                            }.disabled(model.isBusy)
                        }.padding(.vertical, 10)
                        Divider()
                    }
                }
            }.padding(24)
        }
        .sheet(item: $editing) { RuleEditorSheet(model: model, target: $0) }
        .alert("규칙을 삭제할까요?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("취소", role: .cancel) { deleting = nil }
            Button("삭제", role: .destructive) {
                guard let target = deleting else { return }
                deleting = nil
                guard target.isCurrent(in: model) else {
                    model.errorMessage = "규칙 목록이 변경되었습니다. 현재 내용을 확인한 뒤 다시 시도하세요."
                    return
                }
                Task {
                    switch target.kind {
                    case .rule(let rule): await model.deleteRule(id: rule.id)
                    case .candidate(let index, _): await model.deleteCandidate(index: index)
                    case .new: break
                    }
                }
            }
        } message: {
            Text("파일은 이동하지 않습니다. 확정 규칙을 삭제하면 이전 제안은 다시 검토해야 합니다.")
        }
    }

    private func folderPath(_ id: String) -> String {
        model.settings?.folders.first(where: { $0.id == id })?.path ?? "현재 목록에 없는 폴더"
    }
}

private struct RuleEditorTarget: Identifiable {
    enum Kind { case new, rule(FolderRule), candidate(Int, RuleCandidate) }
    let id = UUID()
    let kind: Kind
    var folderID: String {
        switch kind { case .new: ""; case .rule(let r): r.folderID; case .candidate(_, let r): r.folderID }
    }
    var instruction: String {
        switch kind { case .new: ""; case .rule(let r): r.instruction; case .candidate(_, let r): r.instruction }
    }
    var title: String {
        switch kind { case .new: "규칙 추가"; case .rule: "규칙 편집"; case .candidate: "규칙 후보 편집" }
    }
    @MainActor func isCurrent(in model: OrganizerAppModel) -> Bool {
        switch kind {
        case .new: return true
        case .rule(let rule): return model.settings?.rules.first(where: { $0.id == rule.id }) == rule
        case .candidate(let index, let candidate):
            guard let candidates = model.settings?.candidates, candidates.indices.contains(index) else { return false }
            return candidates[index] == candidate
        }
    }
}

@MainActor
private struct RuleEditorSheet: View {
    @ObservedObject var model: OrganizerAppModel
    let target: RuleEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var folderID = ""
    @State private var instruction = ""
    @State private var localError: String?
    @State private var didLoad = false
    @State private var isSaving = false
    @State private var confirmingDiscard = false
    @FocusState private var editorFocused: Bool
    private var hasEdits: Bool { folderID != target.folderID || instruction != target.instruction }
    private var selectedFolderPath: String? {
        model.settings?.folders.first(where: { $0.id == folderID })?.path
    }
    private var canSave: Bool {
        !model.isBusy && !isSaving && hasEdits && target.isCurrent(in: model)
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.settings?.folders.contains(where: { $0.id == folderID }) == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target.title).font(.title2.weight(.semibold))
            Picker("폴더", selection: $folderID) {
                Text("폴더 선택").tag("")
                ForEach(model.settings?.folders ?? [], id: \.id) {
                    Text($0.path).lineLimit(1).truncationMode(.middle).tag($0.id)
                }
            }
            .disabled(isSaving)
            if let selectedFolderPath {
                Text(selectedFolderPath).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).truncationMode(.middle).textSelection(.enabled).help(selectedFolderPath)
            }
            Text("이 폴더에 보관할 파일과 이름 규칙을 적으세요.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $instruction)
                .font(.body).frame(minHeight: 140).focused($editorFocused)
                .accessibilityLabel("분류 규칙 내용")
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
                .disabled(isSaving)
            if let localError { Text(localError).font(.callout).foregroundStyle(.secondary) }
            if !target.isCurrent(in: model) {
                Text("편집 중 규칙 목록이 바뀌었습니다. 내용을 복사해 보관한 뒤 현재 규칙을 다시 열어 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("취소") { if hasEdits { confirmingDiscard = true } else { dismiss() } }
                    .keyboardShortcut(.cancelAction).disabled(model.isBusy || isSaving)
                Button("저장") { save() }.keyboardShortcut(.return, modifiers: .command).disabled(!canSave)
            }
        }.padding(24).frame(width: 520)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            folderID = target.folderID
            instruction = target.instruction
            editorFocused = true
        }
        .interactiveDismissDisabled(hasEdits || model.isBusy || isSaving)
        .alert("규칙 변경을 버릴까요?", isPresented: $confirmingDiscard) {
            Button("계속 편집", role: .cancel) { }
            Button("변경 버리기", role: .destructive) { dismiss() }
        } message: {
            Text("저장하지 않은 규칙 내용과 폴더 선택이 사라집니다.")
        }
    }
    private func save() {
        guard canSave else { return }
        guard target.isCurrent(in: model) else {
            localError = "편집 중 규칙 목록이 바뀌었습니다. 닫은 뒤 현재 규칙을 다시 열어 주세요."
            return
        }
        localError = nil
        isSaving = true
        let savedFolderID = folderID, savedInstruction = instruction
        Task {
            guard target.isCurrent(in: model) else {
                isSaving = false
                localError = "규칙 목록이 바뀌었습니다. 현재 규칙을 다시 열어 주세요."
                return
            }
            switch target.kind {
            case .new: await model.createRule(folderID: savedFolderID, instruction: savedInstruction)
            case .rule(let rule): await model.updateRule(id: rule.id, folderID: savedFolderID, instruction: savedInstruction)
            case .candidate(let index, _): await model.updateCandidate(index: index, folderID: savedFolderID, instruction: savedInstruction)
            }
            isSaving = false
            if let error = model.errorMessage { localError = error } else { dismiss() }
        }
    }
}
