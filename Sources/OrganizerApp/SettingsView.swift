import AppKit
import OrganizerAppSupport
import OrganizerCore
import OrganizerDesignSystem
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var model: OrganizerAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var downloadsPath = ""
    @State private var destinationRoots: [String] = []
    @State private var apiKey = ""
    @State private var didLoad = false
    @State private var baselineDownloadsPath = ""
    @State private var baselineDestinationRoots: [String] = []
    @State private var hasExclusionEdits = false
    @State private var savingFolders = false
    @State private var savingAPIKey = false
    @State private var folderSaveMessage: String?
    @State private var apiMessage: String?
    @State private var confirmingAPICheck = false
    @State private var confirmingDiscard = false

    init(model: OrganizerAppModel) { self.model = model }

    private var canSaveFolders: Bool {
        !downloadsPath.isEmpty && !destinationRoots.isEmpty && hasFolderEdits
            && !foldersConfigurationChanged && !model.isBusy && !savingFolders
    }
    private var hasFolderEdits: Bool {
        downloadsPath != baselineDownloadsPath || destinationRoots != baselineDestinationRoots
    }
    private var foldersConfigurationChanged: Bool {
        (model.settings?.downloadsPath ?? "") != baselineDownloadsPath
            || (model.settings?.destinationRoots ?? []) != baselineDestinationRoots
    }
    private var hasUnsavedChanges: Bool { hasFolderEdits || hasExclusionEdits || !apiKey.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("설정").font(.title2.weight(.semibold))
                Spacer()
                Button("완료") { close() }.keyboardShortcut(.cancelAction)
                    .disabled(savingFolders || savingAPIKey || (model.isBusy && hasExclusionEdits))
            }
            .padding(22)

            Form {
                Section("관리할 폴더") {
                    LabeledContent("다운로드") {
                        HStack {
                            Text(downloadsPath.isEmpty ? "선택하지 않음" : downloadsPath)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                .help(downloadsPath)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("선택") { chooseDownloads() }
                                .disabled(model.isBusy || model.isDemo)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("파일을 보관할 폴더")
                            Spacer()
                            Button("추가") { addRoots() }.disabled(model.isBusy || model.isDemo)
                        }
                        if destinationRoots.isEmpty {
                            Text("선택한 폴더와 그 아래 폴더가 제안 위치 후보가 됩니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(destinationRoots, id: \.self) { path in
                            HStack {
                                Text(path).font(.callout).lineLimit(2).truncationMode(.middle)
                                    .textSelection(.enabled).help(path)
                                Spacer(minLength: 8)
                                Button {
                                    destinationRoots.removeAll { $0 == path }
                                    folderSaveMessage = nil
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(path) 관리 대상에서 제외")
                                .disabled(model.isBusy || model.isDemo)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("폴더 설정 저장") { saveFolders() }
                                .disabled(!canSaveFolders || model.isDemo)
                            if hasFolderEdits {
                                Button("되돌리기") { loadFolders() }
                                    .disabled(model.isBusy || savingFolders)
                                Text("저장하지 않은 변경").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let folderSaveMessage {
                            Text(folderSaveMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        if hasFolderEdits && foldersConfigurationChanged {
                            Text("저장된 폴더 설정이 바뀌었습니다. 되돌리기를 눌러 최신 설정을 확인하세요.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("저장하면 선택한 범위의 폴더 구조와 파일명 사례를 기기에서 확인합니다. GPT 분석은 분석 버튼 또는 자동 분석 설정으로 별도 시작합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("OpenAI API") {
                    LabeledContent("키 저장 상태", value: model.hasAPIKey ? "API 키 설정됨" : "API 키 없음")
                    SecureField("새 API 키", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .disabled(model.isBusy || model.isDemo || savingAPIKey)
                        .accessibilityLabel("OpenAI API 키")
                    HStack(spacing: 12) {
                        Button("키체인에 저장") {
                            let value = apiKey
                            savingAPIKey = true
                            apiMessage = nil
                            Task {
                                await model.saveAPIKey(value)
                                if model.errorMessage == nil {
                                    apiKey = ""
                                    apiMessage = model.statusMessage
                                }
                                savingAPIKey = false
                            }
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy || model.isDemo || savingAPIKey)
                        Button("저장한 키 삭제") {
                            Task {
                                await model.deleteAPIKey()
                                apiMessage = model.errorMessage == nil ? model.statusMessage : nil
                            }
                        }
                            .disabled(!model.hasAPIKey || model.isBusy || model.isDemo)
                    }
                    if let apiMessage { Text(apiMessage).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("키 파일 가져오기") { importKeyFile() }
                            .disabled(model.isBusy || model.isDemo)
                        Button("연결 확인") { confirmingAPICheck = true }
                            .disabled(!model.hasAPIKey || model.isBusy || model.isDemo || !apiKey.isEmpty)
                    }
                    if !apiKey.isEmpty {
                        Text("입력한 새 키를 저장한 뒤 연결을 확인하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let report = model.apiVerification {
                        Text(report.passed ? "연결·기본 분류 확인 완료" : "연결 검증 확인 필요")
                            .font(.callout.weight(.medium))
                        ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                            Label(check.detail, systemImage: check.passed ? "checkmark.circle" : "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("모델: \(report.model) · \(report.requestsAttempted)회 요청. 합성 자료의 기초 검증이며 모든 파일의 분류 정확도를 보장하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("키 저장과 실제 연결 확인은 별개입니다. 연결 확인은 합성 자료만 사용합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("분석할 때 선택한 파일의 추출 내용과 관련 폴더·규칙 정보가 OpenAI로 전송됩니다. API 키는 macOS 키체인에 저장합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                WatcherExclusionSettings(model: model, hasUnsavedChanges: $hasExclusionEdits)

                Section("백그라운드") {
                    Toggle("다운로드 폴더 감시", isOn: Binding(
                        get: { model.watching },
                        set: { model.setWatching($0) }
                    ))
                    .disabled(model.settings == nil)
                    Toggle("새 파일 자동 분석", isOn: Binding(
                        get: { model.automaticallyAnalyze },
                        set: { model.setAutomaticAnalysis($0) }
                    ))
                    .disabled(model.settings == nil || (!(model.hasAPIKey || model.isDemo) && !model.automaticallyAnalyze))
                    Text(model.isDemo
                         ? "데모 자동 분석은 임시 샘플 폴더의 새 파일에 예시 제안을 만듭니다. OpenAI API로 전송하지 않으며, 파일 이동은 적용을 눌렀을 때 실행됩니다."
                         : "자동 분석을 켜면 다운로드가 완료된 새 파일을 OpenAI API로 분석하며 API 사용 요금이 발생할 수 있습니다. 파일 이동은 제안의 적용을 눌렀을 때만 실행됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("창을 닫아도 메뉴바에서 감시를 유지합니다. 메뉴바의 종료를 선택하면 앱과 감시가 모두 종료됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if model.isDemo {
                    Section {
                        Text("데모에서는 임시 샘플 폴더만 사용합니다. 폴더 변경과 API 키 설정은 일반 실행에서 사용할 수 있습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.errorMessage {
                    Section {
                        Text(error).font(.callout).textSelection(.enabled)
                        Button("메시지 닫기") { model.errorMessage = nil }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 650, height: 660)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            loadFolders()
        }
        .onChange(of: model.settings?.downloadsPath) { _, _ in if !hasFolderEdits { loadFolders() } }
        .onChange(of: model.settings?.destinationRoots) { _, _ in if !hasFolderEdits { loadFolders() } }
        .onChange(of: apiKey) { _, value in if !value.isEmpty { apiMessage = nil } }
        .onDisappear { apiKey = "" }
        .interactiveDismissDisabled(hasUnsavedChanges || savingFolders || savingAPIKey)
        .alert("저장하지 않은 변경을 버릴까요?", isPresented: $confirmingDiscard) {
            Button("계속 편집", role: .cancel) { }
            Button("변경 버리기", role: .destructive) { dismiss() }
        } message: {
            Text("아직 저장하지 않은 폴더·감시 제외 설정과 입력한 API 키만 사라집니다. 이미 저장한 설정은 유지됩니다.")
        }
        .confirmationDialog("API 연결을 확인할까요?", isPresented: $confirmingAPICheck, titleVisibility: .visible) {
            Button("최대 2회 호출로 확인") { Task { await model.verifyAPIConnection() } }
            Button("취소", role: .cancel) { }
        } message: {
            Text("OpenAI API 사용 요금이 발생합니다. 요청당 출력은 최대 1,536토큰이며, 개인 파일 대신 앱이 만든 합성 자료만 보냅니다. 토큰 상한은 금액 한도가 아닙니다.")
        }
    }

    private func close() {
        if hasUnsavedChanges { confirmingDiscard = true } else { dismiss() }
    }

    private func loadFolders() {
        baselineDownloadsPath = model.settings?.downloadsPath ?? ""
        baselineDestinationRoots = model.settings?.destinationRoots ?? []
        downloadsPath = baselineDownloadsPath
        destinationRoots = baselineDestinationRoots
        folderSaveMessage = nil
    }

    private func saveFolders() {
        guard canSaveFolders else { return }
        let downloads = URL(fileURLWithPath: downloadsPath).standardizedFileURL
        let roots = destinationRoots.map { URL(fileURLWithPath: $0).standardizedFileURL }
        savingFolders = true
        folderSaveMessage = nil
        Task {
            await model.configure(downloads: downloads, roots: roots)
            if model.errorMessage == nil,
               model.settings?.downloadsPath == downloads.path,
               model.settings?.destinationRoots == roots.map(\.path) {
                loadFolders()
                folderSaveMessage = "폴더 설정을 저장했습니다."
            }
            savingFolders = false
        }
    }

    private func importKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "API 키 한 줄이 담긴 텍스트 또는 RTF 문서 선택"
        panel.prompt = "가져오기"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        savingAPIKey = true
        apiMessage = nil
        Task {
            await model.importAPIKeyFile(url)
            if model.errorMessage == nil {
                apiKey = ""
                apiMessage = model.statusMessage
            }
            savingAPIKey = false
        }
    }

    private func chooseDownloads() {
        let panel = NSOpenPanel()
        panel.title = "감시할 다운로드 폴더 선택"
        panel.prompt = "선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadsPath.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            : URL(fileURLWithPath: downloadsPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadsPath = url.standardizedFileURL.path
        folderSaveMessage = nil
    }

    private func addRoots() {
        let panel = NSOpenPanel()
        panel.title = "파일을 보관할 폴더 선택"
        panel.prompt = "추가"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !destinationRoots.contains(path) { destinationRoots.append(path) }
        }
        folderSaveMessage = nil
    }
}
