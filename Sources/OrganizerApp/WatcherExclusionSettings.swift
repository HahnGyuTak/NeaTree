import OrganizerAppSupport
import SwiftUI

@MainActor
struct WatcherExclusionSettings: View {
    @ObservedObject var model: OrganizerAppModel
    @Binding var hasUnsavedChanges: Bool
    @State private var extensions = ""
    @State private var folders = ""
    @State private var baselineExtensions: [String] = []
    @State private var baselineFolders: [String] = []
    @State private var message: String?
    @State private var didLoad = false
    @State private var isSaving = false

    private var extensionValues: [String] {
        extensions.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }
    private var folderValues: [String] {
        folders.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var hasEdits: Bool {
        extensions != baselineExtensions.joined(separator: ", ") || folders != baselineFolders.joined(separator: "\n")
    }
    private var configurationChanged: Bool {
        (model.settings?.excludedExtensions ?? []) != baselineExtensions
            || (model.settings?.excludedRelativeFolders ?? []) != baselineFolders
    }

    var body: some View {
        Section("감시 제외") {
            TextField("제외할 확장자", text: $extensions, prompt: Text("dmg, zip"))
                .autocorrectionDisabled()
            VStack(alignment: .leading, spacing: 6) {
                Text("제외할 다운로드 하위 폴더 — 한 줄에 하나")
                TextEditor(text: $folders).font(.body).frame(height: 55)
                    .accessibilityLabel("감시에서 제외할 상대 폴더 경로")
                Text("예: 임시자료 또는 프로젝트/캐시. 하위 경로를 제외하면 이를 담은 다운로드 바로 아래 폴더 전체를 건너뜁니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("직접 가져온 파일은 제외 규칙과 관계없이 검토합니다. 이미 정리한 파일이나 보류한 파일은 이 설정으로 이동하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if hasEdits { Text("저장하지 않은 변경").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("되돌리기") { load() }.disabled(!hasEdits || model.isBusy)
                Button("제외 설정 저장") { save() }
                    .disabled(!hasEdits || configurationChanged || model.settings == nil || model.isBusy || isSaving)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if hasEdits && configurationChanged {
                Text("다른 작업에서 제외 설정이 바뀌었습니다. 되돌리기를 눌러 최신 설정을 확인하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(model.isBusy || model.settings == nil || isSaving)
        .onAppear { if !didLoad { didLoad = true; load() } }
        .onChange(of: model.settings?.excludedExtensions) { _, _ in if !hasEdits && configurationChanged { load() } }
        .onChange(of: model.settings?.excludedRelativeFolders) { _, _ in if !hasEdits && configurationChanged { load() } }
        .onChange(of: hasEdits, initial: true) { _, value in hasUnsavedChanges = value }
        .onChange(of: extensions) { _, _ in if hasEdits { message = nil } }
        .onChange(of: folders) { _, _ in if hasEdits { message = nil } }
    }

    private func load() {
        baselineExtensions = model.settings?.excludedExtensions ?? []
        baselineFolders = model.settings?.excludedRelativeFolders ?? []
        extensions = baselineExtensions.joined(separator: ", ")
        folders = baselineFolders.joined(separator: "\n")
        message = nil
    }

    private func save() {
        guard hasEdits, !isSaving, !model.isBusy else { return }
        guard !configurationChanged else {
            message = "현재 저장된 설정이 바뀌었습니다. 되돌리기를 누른 뒤 다시 편집해 주세요."
            return
        }
        let nextExtensions = extensionValues, nextFolders = folderValues
        isSaving = true
        message = nil
        Task {
            await model.setWatcherExclusions(extensions: nextExtensions, relativeFolders: nextFolders)
            if let error = model.errorMessage { message = error }
            else { load(); message = "감시 제외 설정을 저장했습니다." }
            isSaving = false
        }
    }
}
