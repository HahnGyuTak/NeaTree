import Darwin
import Foundation
import OrganizerCore

@main struct OrganizerCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch {
            FileHandle.standardError.write(Data("오류: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ rawArguments: [String]) async throws {
        var args = Arguments(rawArguments)
        let statePath = args.option("--state") ?? ProcessInfo.processInfo.environment["FILE_ORGANIZER_STATE_DIR"]
        let command = args.next() ?? "help"
        if ["help", "--help", "-h"].contains(command) { print(help); return }
        if command == "key" { try keyCommand(args.next() ?? "status"); return }
        let defaultState = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FileOrganizer")
        let service = try OrganizerService(stateDirectory: statePath.map(url) ?? defaultState)
        switch command {
        case "configure":
            guard let downloads = args.option("--downloads") else { throw CLIError("--downloads 경로가 필요합니다.") }
            var roots: [URL] = []
            while let root = args.option("--root") { roots.append(url(root)) }
            try await service.configure(downloads: url(downloads), roots: roots)
            try output(await service.configuration())
        case "catalog": try output(await service.refreshCatalog())
        case "list": try output(await service.entries())
        case "scan": try output(await service.scanDownloads())
        case "watch":
            let analyze = args.flag("--analyze")
            let api = analyze ? try client() : nil
            print(analyze ? "다운로드 감시와 분석을 시작합니다. 종료: Ctrl+C" : "다운로드 감시를 시작합니다. 종료: Ctrl+C")
            while !Task.isCancelled {
                for entry in try await service.scanDownloads() {
                    print("검토함 추가: \(entry.id) \(URL(fileURLWithPath: entry.path).lastPathComponent)")
                    if let api {
                        do { try output(await service.propose(id: entry.id, client: api)) }
                        catch { FileHandle.standardError.write(Data("분석 대기: \(entry.id) — \(error.localizedDescription)\n".utf8)) }
                    }
                }
                try await Task.sleep(for: .seconds(2))
            }
        case "import":
            guard !args.values.isEmpty else { throw CLIError("가져올 파일 또는 폴더 경로가 필요합니다.") }
            for path in args.values { try output(await service.importItem(url(path))) }
        case "inspect":
            guard let path = args.next() else { throw CLIError("읽을 파일 경로가 필요합니다.") }
            try output(await FileInspector.inspectAsync(url(path)))
        case "analyze":
            let value = args.next() ?? "all"
            let api = try client()
            if value == "all" {
                let entries = await service.entries()
                for entry in entries where [.ready, .proposed, .failed].contains(entry.status) {
                    try output(await service.propose(id: entry.id, client: api))
                }
            } else { try output(await service.propose(id: uuid(value), client: api)) }
        case "rules":
            switch args.next() ?? "list" {
            case "analyze": try output(await service.analyzeStructure(client: client()))
            case "confirm":
                guard let raw = args.next(), let index = Int(raw), index >= 0 else { throw CLIError("확정할 후보 번호(0부터)를 지정하세요.") }
                try output(await service.confirmRule(index: index))
            case "list":
                let settings = try await service.configuration()
                try output(RuleListing(confirmed: settings.rules, candidates: settings.candidates))
            default: throw CLIError("rules list | analyze | confirm <후보 번호>")
            }
        case "apply":
            let name = args.option("--name")
            let folder = args.option("--folder")
            let width = args.option("--serial-width")
            let fill = args.flag("--fill-gaps")
            let policy: SerialPolicy?
            if let width {
                guard let value = Int(width) else { throw CLIError("번호 자리 수는 정수여야 합니다.") }
                policy = SerialPolicy(width: value, allocation: fill ? .fillGap : .appendMax)
            } else { policy = nil }
            guard let id = args.next() else { throw CLIError("적용할 항목 ID가 필요합니다.") }
            try output(await service.apply(id: uuid(id), name: name, folderID: folder, serial: policy))
        case "unclassified":
            guard let id = args.next() else { throw CLIError("항목 ID가 필요합니다.") }
            try output(await service.sendToUnclassified(id: uuid(id)))
        case "hold":
            guard let id = args.next() else { throw CLIError("항목 ID가 필요합니다.") }
            try await service.hold(id: uuid(id)); print("보류했습니다.")
        case "history": try output(await service.history())
        case "reconcile": try output(await service.reconcileHistory())
        case "revisit":
            guard let id = args.next() else { throw CLIError("미분류 항목 ID가 필요합니다.") }
            try output(await service.revisit(id: uuid(id)))
        case "learn":
            guard let name = args.option("--name"), let folder = args.option("--folder"), let id = args.next() else {
                throw CLIError("learn <항목 ID> --name <수정 이름> --folder <폴더 ID>")
            }
            try output(await service.learnCorrection(id: uuid(id), folderID: folder, name: name, client: client()))
        case "duplicates":
            guard let path = args.next() else { throw CLIError("중복을 확인할 파일 경로가 필요합니다.") }
            let settings = try await service.configuration()
            try output(await DuplicateFinder.findAsync(for: url(path), in: settings.folders))
        case "undo":
            guard let id = args.next() else { throw CLIError("이력의 작업 ID가 필요합니다.") }
            try output(await service.undo(recordID: uuid(id)))
        default: throw CLIError("알 수 없는 명령입니다. organizer help를 확인하세요.")
        }
    }

    private static func keyCommand(_ action: String) throws {
        switch action {
        case "set":
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("터미널에서 organizer key set을 실행하세요. 키를 명령 인자로 넣지 마세요.") }
            guard let buffer = getpass("OpenAI API key (화면에 표시되지 않음): ") else { throw CLIError("키를 읽지 못했습니다.") }
            let key = String(cString: buffer)
            defer { memset(buffer, 0, strlen(buffer)) }
            try APIKeyStore.save(key); print("API 키를 macOS 키체인에 저장했습니다.")
        case "status":
            let exists = try !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty || APIKeyStore.read() != nil
            print(exists ? "API 키 설정됨" : "API 키 미설정")
        case "delete": try APIKeyStore.delete(); print("키체인의 API 키를 삭제했습니다.")
        default: throw CLIError("key set | status | delete")
        }
    }

    private static func client() throws -> OpenAIClient {
        let key = try ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? APIKeyStore.read()
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("API 키가 없습니다. 터미널에서 organizer key set으로 설정하세요.")
        }
        return OpenAIClient(apiKey: key)
    }
    private static func uuid(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw CLIError("올바른 항목 또는 작업 ID가 아닙니다.") }; return id
    }
    private static func url(_ path: String) -> URL { URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL }
    private static func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    private struct RuleListing: Codable { let confirmed: [FolderRule]; let candidates: [RuleCandidate] }
    private struct CLIError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
    private struct Arguments {
        var values: [String]
        init(_ values: [String]) { self.values = values }
        mutating func next() -> String? { values.isEmpty ? nil : values.removeFirst() }
        mutating func option(_ name: String) -> String? {
            guard let index = values.firstIndex(of: name), index + 1 < values.count else { return nil }
            values.remove(at: index); return values.remove(at: index)
        }
        mutating func flag(_ name: String) -> Bool {
            guard let index = values.firstIndex(of: name) else { return false }; values.remove(at: index); return true
        }
    }

    private static let help = """
    파일 정리 도우미 — 내부 기능 개발용 CLI
    사용: organizer [--state <상태 저장 폴더>] <명령>

      configure --downloads <경로> --root <관리 폴더> [--root <추가 폴더>]
      catalog                         관리 대상 폴더 목록 갱신
      import <파일/폴더> ...            검토함에 직접 추가
      scan                            다운로드 상태 1회 확인 (안정된 파일만 등록)
      watch [--analyze]                다운로드 감시, 선택적으로 GPT 분석
      list                            검토함과 제안 보기
      inspect <파일/폴더>              추출 가능한 내용 확인
      rules analyze                   GPT로 기존 구조의 규칙 후보 생성
      rules list                      확정 규칙과 후보 보기
      rules confirm <번호>            규칙 후보 확정 (0부터)
      analyze <항목 ID|all>            파일 분류 제안 생성
      apply <항목 ID> [--name <이름>] [--folder <폴더 ID>]
            [--serial-width 3] [--fill-gaps]
      unclassified <항목 ID>          다운로드/미분류/로 이동
      hold <항목 ID>                  원본을 유지하고 보류
      history                         실제 정리 이력 보기
      undo <작업 ID>                  이름과 위치 복구
      reconcile                       작업 이력을 검토함에 다시 반영
      revisit <항목 ID>               미분류 파일을 재검토함에 등록
      learn <항목 ID> --name <이름> --folder <폴더 ID>
                                      수정 내용을 규칙 후보로 저장 (확정은 별도)
      duplicates <파일>               관리 폴더 안의 동일 내용 파일 찾기
      key set|status|delete           macOS 키체인 API 키 관리

    apply와 unclassified는 실제 파일을 이동합니다. 번호 템플릿: '{serial}_제목.pdf'
    GUI는 이미지 시안 승인 후 구현합니다. API 모델: gpt-6.1-sol
    """
}
