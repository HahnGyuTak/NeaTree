import AppKit
import OrganizerAppSupport
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
    @State private var folderSaveMessage: String?

    init(model: OrganizerAppModel) { self.model = model }

    private var canSaveFolders: Bool {
        !downloadsPath.isEmpty && !destinationRoots.isEmpty && !model.isBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("설정").font(.title2.weight(.semibold))
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(22)

            Form {
                Section("관리할 폴더") {
                    LabeledContent("다운로드") {
                        HStack {
                            Text(downloadsPath.isEmpty ? "선택하지 않음" : downloadsPath)
                                .lineLimit(2).textSelection(.enabled)
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
                                Text(path).font(.callout).lineLimit(2).textSelection(.enabled)
                                Spacer(minLength: 8)
                                Button {
                                    destinationRoots.removeAll { $0 == path }
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("\(path) 관리 대상에서 제외")
                                .disabled(model.isBusy || model.isDemo)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Button("폴더 설정 저장") {
                            let downloads = URL(fileURLWithPath: downloadsPath)
                            let roots = destinationRoots.map { URL(fileURLWithPath: $0) }
                            Task {
                                await model.configure(downloads: downloads, roots: roots)
                                if model.settings?.downloadsPath == downloads.standardizedFileURL.path {
                                    folderSaveMessage = "폴더 설정을 저장했습니다."
                                }
                            }
                        }
                        .disabled(!canSaveFolders || model.isDemo)
                        if let folderSaveMessage {
                            Text(folderSaveMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("저장하면 선택한 범위의 폴더 구조와 파일명 사례를 기기에서 확인합니다. GPT 분석은 분석 버튼 또는 자동 분석 설정으로 별도 시작합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("OpenAI API") {
                    LabeledContent("연결 상태", value: model.hasAPIKey ? "API 키 설정됨" : "API 키 없음")
                    SecureField("새 API 키", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .disabled(model.isBusy || model.isDemo)
                        .accessibilityLabel("OpenAI API 키")
                    HStack(spacing: 12) {
                        Button("키체인에 저장") {
                            let value = apiKey
                            apiKey = ""
                            Task { await model.saveAPIKey(value) }
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy || model.isDemo)
                        Button("저장한 키 삭제") { Task { await model.deleteAPIKey() } }
                            .disabled(!model.hasAPIKey || model.isBusy || model.isDemo)
                    }
                    Text("분석할 때 선택한 파일의 추출 내용과 관련 폴더·규칙 정보가 OpenAI로 전송됩니다. API 키는 macOS 키체인에 저장합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }

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
            downloadsPath = model.settings?.downloadsPath ?? ""
            destinationRoots = model.settings?.destinationRoots ?? []
        }
        .onDisappear { apiKey = "" }
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
